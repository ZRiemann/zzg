const std = @import("std");
const t = @import("types.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const format = @import("format.zig");
const output = @import("output.zig");
const options = @import("options");
const Allocator = std.mem.Allocator;

pub const Stats = struct { dropped: u64 = 0, accepted: u64 = 0, processed: u64 = 0, failures: u64 = 0, queue_high_water: usize = 0 };
// Worker-owned report state; shutdown accesses it only after joining.
const OverflowReport = struct {
    total: u64 = 0,
    last: ?i96 = null,
    fn delta(self: *OverflowReport, total: u64, now: i96, force: bool) ?u64 {
        if (total == self.total) return null;
        if (!force) if (self.last) |last| {
            if (now - last < 5 * std.time.ns_per_s) return null;
        };
        const result = total - self.total;
        self.total = total;
        self.last = now;
        return result;
    }
};
// Independent storage: readers never touch Runtime or share the reference-count cache line.
const FilterCache = struct {
    value: std.atomic.Value(u32) = .init(0),
    padding: [std.atomic.cache_line - @sizeOf(std.atomic.Value(u32))]u8 = @splat(0),
};
var filter_cache: FilterCache align(std.atomic.cache_line) = .{};
const important_bit: u32 = 1 << 6;
var gate: std.atomic.Value(bool) = .init(false);
const Phase = enum(u32) { fresh, initializing, ready, closing, closed };
var phase: std.atomic.Value(Phase) = .init(.fresh);
var current: ?*Runtime = null;
// Static storage prevents the final submission from waking a freed futex.
var references: std.atomic.Value(u32) = .init(0);
var final_stats: Stats = .{};
var next_tid: std.atomic.Value(u64) = .init(0);
threadlocal var thread_id: ?u64 = null;
fn lockGate() void {
    while (gate.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn unlockGate() void {
    gate.store(false, .release);
}
fn acquire() ?*Runtime {
    lockGate();
    defer unlockGate();
    const r = current orelse return null;
    _ = references.fetchAdd(1, .monotonic);
    return r;
}
fn release(r: *Runtime) void {
    lockGate();
    defer unlockGate();
    const io = r.io;
    if (references.fetchSub(1, .release) == 1 and phase.load(.acquire) == .closing)
        io.futexWake(u32, &references.raw, 1);
}

fn compiled(comptime level: t.Level) bool {
    return level != .off and @backingInt(level) >= options.active_level;
}
const Route = struct { runtime: bool, important: bool };
fn routeFor(cfg: t.Config, threshold: t.Level, level: t.Level, explicit: bool) Route {
    const ordinary = threshold.accepts(level);
    return .{ .runtime = ordinary and (cfg.console or cfg.rotating_file), .important = level != .off and cfg.important.enabled and (explicit or (ordinary and cfg.important.level.accepts(level))) };
}
fn destinations(r: *Runtime, level: t.Level, explicit: bool) Route {
    return routeFor(r.cfg, @fromBackingInt(@intCast(r.level.load(.monotonic))), level, explicit);
}
fn severityBit(level: t.Level) u32 {
    return if (level == .off) 0 else @as(u32, 1) << @as(u5, @intCast(@backingInt(level)));
}
fn filterMask(cfg: t.Config, threshold: t.Level) u32 {
    var mask: u32 = 0;
    inline for (.{ t.Level.trace, t.Level.debug, t.Level.info, t.Level.warn, t.Level.err, t.Level.critical }) |level| {
        const route = routeFor(cfg, threshold, level, false);
        if (route.runtime or route.important) mask |= severityBit(level);
    }
    const explicit = routeFor(cfg, threshold, .info, true);
    if (explicit.runtime or explicit.important) mask |= important_bit;
    return mask;
}
fn prefiltered(comptime level: t.Level, comptime explicit: bool) bool {
    // This value filters only; Runtime publication and reclamation still use gate.
    return filter_cache.value.load(.monotonic) & (if (explicit) important_bit else severityBit(level)) != 0;
}
pub fn enabled(comptime level: t.Level) bool {
    if (comptime !compiled(level)) return false;
    return prefiltered(level, false);
}
pub fn importantEnabled() bool {
    if (comptime !compiled(.info)) return false;
    return prefiltered(.info, true);
}
pub fn setLevel(level: t.Level) void {
    lockGate();
    defer unlockGate();
    const r = current orelse return;
    r.level.store(@backingInt(level), .monotonic);
    filter_cache.value.store(filterMask(r.cfg, level), .monotonic);
}
pub fn stats() Stats {
    const r = acquire() orelse {
        lockGate();
        defer unlockGate();
        return final_stats;
    };
    defer release(r);
    return r.snapshot();
}
pub fn emit(comptime severity: t.Level, comptime explicit: bool, comptime source: std.lang.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    if (comptime !compiled(severity)) return;
    if (!prefiltered(severity, explicit)) return;
    const r = acquire() orelse return;
    defer release(r);
    const route = destinations(r, severity, explicit);
    if (!route.runtime and !route.important) return;
    const ns = std.Io.Clock.real.now(r.io).toNanoseconds();
    if (thread_id == null) thread_id = next_tid.fetchAdd(1, .monotonic);
    var scratch: [1024]u8 = undefined;
    var buffer_allocator: std.heap.BufferFirstAllocator = .init(&scratch, r.allocator);
    var message = std.Io.Writer.Allocating.initCapacity(buffer_allocator.allocator(), scratch.len) catch |err| {
        r.failure("message buffer", err);
        return;
    };
    defer message.deinit();
    message.writer.print(fmt, args) catch |err| {
        r.failure("format", err);
        return;
    };
    const record: format.Record = .{ .level = severity, .seconds = @intCast(@divFloor(ns, std.time.ns_per_s)), .micros = @intCast(@divFloor(@mod(ns, std.time.ns_per_s), 1000)), .tid = thread_id.?, .source = source, .message = message.written(), .runtime = route.runtime, .important = route.important };
    r.submit(record) catch |err| r.failure("submit", err);
}

pub fn init(a: Allocator, io: std.Io, env: *const std.process.Environ.Map, cfg: t.Config) !LogGuard {
    lockGate();
    if (phase.load(.monotonic) != .fresh) {
        unlockGate();
        return error.AlreadyInitialized;
    }
    phase.store(.initializing, .release);
    unlockGate();
    errdefer phase.store(.fresh, .release);
    const r = try Runtime.create(a, io, env, cfg);
    // Preserve the padded allocation: global scalar replacement may otherwise put gate
    // into the unused tail of this cache line. This cold-path escape emits no fence.
    std.mem.doNotOptimizeAway(&filter_cache);
    lockGate();
    current = r;
    phase.store(.ready, .release);
    filter_cache.value.store(filterMask(r.cfg, cfg.level), .monotonic);
    unlockGate();
    return .{ .io = io };
}
pub const LogGuard = struct {
    io: std.Io,
    /// Completion barrier for records accepted before this call's queue position.
    pub fn flush(self: LogGuard) !void {
        const r = acquire() orelse {
            while (phase.load(.acquire) == .closing) self.io.futexWaitUncancelable(Phase, &phase.raw, .closing);
            if (stats().failures != 0) return error.OutputFailure;
            return;
        };
        defer release(r);
        try r.barrier();
    }
    pub fn shutdown(self: LogGuard) !void {
        lockGate();
        const state = phase.load(.acquire);
        if (state != .ready) {
            unlockGate();
            while (phase.load(.acquire) == .closing) self.io.futexWaitUncancelable(Phase, &phase.raw, .closing);
            if (stats().failures != 0) return error.OutputFailure;
            return;
        }
        const r = current.?;
        filter_cache.value.store(0, .monotonic);
        current = null;
        phase.store(.closing, .release);
        unlockGate();
        while (true) {
            const refs = references.load(.acquire);
            if (refs == 0) break;
            r.io.futexWaitUncancelable(u32, &references.raw, refs);
        }
        // Pair with the final release before freeing resources or returning to the Io owner.
        lockGate();
        unlockGate();
        r.mutex.lockUncancelable(r.io);
        r.stopping = true;
        r.condition.broadcast(r.io);
        r.mutex.unlock(r.io);
        if (r.worker) |worker| worker.join();
        r.reportOverflow(true);
        r.flushOutputs();
        const result = r.snapshot();
        r.destroy();
        lockGate();
        final_stats = result;
        phase.store(.closed, .release);
        unlockGate();
        self.io.futexWake(Phase, &phase.raw, std.math.maxInt(u32));
        if (result.failures != 0) return error.OutputFailure;
    }
    /// Best-effort defer cleanup; explicit shutdown is required to observe errors.
    pub fn deinit(self: LogGuard) void {
        self.shutdown() catch {};
    }
};
const Slot = struct {
    record: format.Record = undefined,
    inline_bytes: [1024]u8 = undefined,
    heap: ?[]u8 = null,
    len: usize = 0,
    barrier: u64 = 0,
    fn bytes(s: *const Slot) []const u8 {
        return if (s.heap) |heap| heap else s.inline_bytes[0..s.len];
    }
};

/// Private, explicitly owned instance; tests can exercise isolated lifecycles.
pub const Runtime = struct {
    allocator: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    cfg: t.Config,
    zone: time.Zone,
    pattern: format.Pattern,
    important_pattern: format.Pattern,
    runtime_file: ?output.FileSink = null,
    important_file: ?output.FileSink = null,
    color: bool = false,
    pid: u32,
    level: std.atomic.Value(u8),
    dropped: std.atomic.Value(u64) = .init(0),
    overflow_report: OverflowReport = .{},
    failures: std.atomic.Value(u64) = .init(0),
    accepted: std.atomic.Value(u64) = .init(0),
    processed: std.atomic.Value(u64) = .init(0),
    high_water: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    output_mutex: std.Io.Mutex = .init,
    queue: []Slot = &.{},
    head: usize = 0,
    count: usize = 0,
    next_barrier: u64 = 0,
    done_barrier: u64 = 0,
    stopping: bool = false,
    worker: ?std.Thread = null,
    rendered: std.Io.Writer.Allocating,

    pub fn create(a: Allocator, io: std.Io, env: *const std.process.Environ.Map, input: t.Config) !*Runtime {
        if (@import("builtin").os.tag != .linux) @compileError("zzg log currently supports Linux");
        var d: t.Diagnostic = .{};
        try config.validate(input, "spd", &d);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var cfg = input;
        inline for (@typeInfo(t.Config).@"struct".field_names, @typeInfo(t.Config).@"struct".field_types) |name, Field| if (Field == []const u8) {
            @field(cfg, name) = try owned.dupe(u8, @field(input, name));
        };
        cfg.important.name = try owned.dupe(u8, input.important.name);
        cfg.important.pattern = try owned.dupe(u8, input.important.pattern);
        if (cfg.pattern.len == 0) cfg.pattern = t.default_pattern;
        if (cfg.important.pattern.len == 0) cfg.important.pattern = cfg.pattern;
        if (cfg.important.enabled and cfg.important.name.len == 0) cfg.important.name = try owned.print("{s}.important.jsonl", .{cfg.logger_name});
        // Resolve and validate everything before opening any sink.
        if (cfg.rotating_file) cfg.name = try config.expandPath(owned, cfg.name, env);
        if (cfg.important.enabled) cfg.important.name = try config.expandPath(owned, cfg.important.name, env);
        if (cfg.rotating_file and cfg.important.enabled) {
            const one = try std.fs.path.resolve(owned, &.{cfg.name});
            const two = try std.fs.path.resolve(owned, &.{cfg.important.name});
            if (std.mem.eql(u8, one, two)) return error.ConflictingPaths;
        }
        var zone = try time.Zone.load(a, io, env);
        errdefer zone.deinit();
        var pattern = try format.Pattern.compile(a, cfg.pattern);
        errdefer pattern.deinit();
        var important_pattern = try format.Pattern.compile(a, cfg.important.pattern);
        errdefer important_pattern.deinit();
        var rendered = try std.Io.Writer.Allocating.initCapacity(a, 4096);
        errdefer rendered.deinit();
        const r = try a.create(Runtime);
        errdefer a.destroy(r);
        r.* = .{ .allocator = a, .io = io, .arena = arena, .cfg = cfg, .zone = zone, .pattern = pattern, .important_pattern = important_pattern, .pid = @intCast(std.os.linux.getpid()), .level = .init(@backingInt(cfg.level)), .rendered = rendered };
        if (cfg.console) r.color = (try std.Io.File.stdout().isTty(io)) and env.get("NO_COLOR") == null and !std.mem.eql(u8, env.get("TERM") orelse "", "dumb");
        if (cfg.rotating_file) r.runtime_file = try output.FileSink.init(a, io, cfg.name, cfg.max_size, cfg.rotats, cfg.rotate_on_open);
        errdefer if (r.runtime_file) |*file| file.deinit();
        if (cfg.important.enabled) r.important_file = try output.FileSink.init(a, io, cfg.important.name, cfg.important.max_size, cfg.important.rotats, cfg.important.rotate_on_open);
        errdefer if (r.important_file) |*file| file.deinit();
        if (cfg.async) r.queue = try a.alloc(Slot, cfg.queue_size);
        errdefer a.free(r.queue);
        if (cfg.async or cfg.flush_interval_sec > 0) r.worker = try std.Thread.spawn(.{}, work, .{r});
        return r;
    }
    pub fn destroy(r: *Runtime) void {
        if (r.runtime_file) |*file| file.deinit();
        if (r.important_file) |*file| file.deinit();
        r.allocator.free(r.queue);
        r.rendered.deinit();
        r.pattern.deinit();
        r.important_pattern.deinit();
        r.zone.deinit();
        r.arena.deinit();
        r.allocator.destroy(r);
    }
    fn snapshot(r: *Runtime) Stats {
        return .{ .dropped = r.dropped.load(.monotonic), .accepted = r.accepted.load(.monotonic), .processed = r.processed.load(.monotonic), .failures = r.failures.load(.monotonic), .queue_high_water = r.high_water.load(.monotonic) };
    }
    fn failure(r: *Runtime, operation: []const u8, err: anyerror) void {
        if (r.failures.fetchAdd(1, .monotonic) == 0) {
            var buffer: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "zzg log {s}: {s}\n", .{ operation, @errorName(err) }) catch "zzg log output failure\n";
            std.Io.File.stderr().writeStreamingAll(r.io, text) catch {};
        }
    }
    pub fn submit(r: *Runtime, record: format.Record) !void {
        if (!r.cfg.async) {
            r.output_mutex.lockUncancelable(r.io);
            defer r.output_mutex.unlock(r.io);
            _ = r.accepted.fetchAdd(1, .monotonic);
            r.writeRecord(record);
            return;
        }
        // Long payload allocation precedes queue locking; queue stores owned bytes.
        const heap = if (record.message.len > 1024) try r.allocator.dupe(u8, record.message) else null;
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.count == r.queue.len) {
            _ = r.dropped.fetchAdd(1, .monotonic);
            if (heap) |bytes| r.allocator.free(bytes);
            return;
        }
        const slot = &r.queue[(r.head + r.count) % r.queue.len];
        slot.* = .{ .record = record, .heap = heap, .len = record.message.len };
        if (heap == null) @memcpy(slot.inline_bytes[0..record.message.len], record.message);
        slot.record.message = ""; // Do not retain even an unused borrowed pointer.
        r.count += 1;
        _ = r.accepted.fetchAdd(1, .monotonic);
        if (r.count > r.high_water.load(.monotonic)) r.high_water.store(r.count, .monotonic);
        r.condition.broadcast(r.io);
    }
    pub fn barrier(r: *Runtime) !void {
        if (r.cfg.async) {
            r.mutex.lockUncancelable(r.io);
            while (r.count == r.queue.len) r.condition.waitUncancelable(r.io, &r.mutex);
            r.next_barrier += 1;
            const sequence = r.next_barrier;
            r.queue[(r.head + r.count) % r.queue.len] = .{ .barrier = sequence };
            r.count += 1;
            if (r.count > r.high_water.load(.monotonic)) r.high_water.store(r.count, .monotonic);
            r.condition.broadcast(r.io);
            while (r.done_barrier < sequence) r.condition.waitUncancelable(r.io, &r.mutex);
            r.mutex.unlock(r.io);
        } else {
            r.output_mutex.lockUncancelable(r.io);
            r.flushOutputs();
            r.output_mutex.unlock(r.io);
        }
        if (r.failures.load(.monotonic) != 0) return error.OutputFailure;
    }
    fn reportOverflow(r: *Runtime, force: bool) void {
        const total = r.dropped.load(.monotonic);
        const delta = r.overflow_report.delta(total, std.Io.Clock.awake.now(r.io).nanoseconds, force) orelse return;
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "[logging:overflow] dropped_delta={d} dropped_total={d} queue_size={d}", .{ delta, total, r.cfg.queue_size }) catch unreachable;
        const ns = std.Io.Clock.real.now(r.io).toNanoseconds();
        if (thread_id == null) thread_id = next_tid.fetchAdd(1, .monotonic);
        r.writeOutputs(.{ .level = .warn, .seconds = @intCast(@divFloor(ns, std.time.ns_per_s)), .micros = @intCast(@divFloor(@mod(ns, std.time.ns_per_s), 1000)), .tid = thread_id.?, .source = @src(), .message = message, .runtime = true, .important = r.cfg.important.enabled and r.cfg.important.level.accepts(.warn) });
    }
    fn writeRecord(r: *Runtime, record: format.Record) void {
        defer _ = r.processed.fetchAdd(1, .monotonic);
        r.writeOutputs(record);
    }
    fn writeOutputs(r: *Runtime, record: format.Record) void {
        const local = r.zone.local(record.seconds, record.micros);
        if (record.runtime) {
            if (r.cfg.console) {
                r.rendered.writer.end = 0;
                if (r.pattern.render(&r.rendered.writer, record, r.cfg, local, r.pid, r.color)) |_| {
                    std.Io.File.stdout().writeStreamingAll(r.io, r.rendered.written()) catch |err| r.failure("console", err);
                } else |err| r.failure("console format", err);
            }
            if (r.runtime_file) |*file| {
                r.rendered.writer.end = 0;
                if (r.pattern.render(&r.rendered.writer, record, r.cfg, local, r.pid, false)) |_| {
                    file.write(r.rendered.written()) catch |err| r.failure("runtime file", err);
                } else |err| r.failure("runtime format", err);
            }
        }
        if (record.important) if (r.important_file) |*file| {
            r.rendered.writer.end = 0;
            const result = if (r.cfg.important.format == .jsonl) format.json(&r.rendered.writer, record, r.cfg, local, r.pid) else r.important_pattern.render(&r.rendered.writer, record, r.cfg, local, r.pid, false);
            if (result) |_| {
                file.write(r.rendered.written()) catch |err| r.failure("important file", err);
            } else |err| r.failure("important format", err);
        };
        if (r.cfg.flush_level.accepts(record.level)) r.flushOutputs();
    }
    fn flushOutputs(r: *Runtime) void {
        if (r.runtime_file) |*file| file.flush() catch |err| r.failure("runtime flush", err);
        if (r.important_file) |*file| file.flush() catch |err| r.failure("important flush", err);
    }
    fn work(r: *Runtime) void {
        const interval = std.Io.Duration.fromSeconds(r.cfg.flush_interval_sec);
        var deadline = std.Io.Clock.awake.now(r.io).addDuration(interval);
        r.mutex.lockUncancelable(r.io);
        while (true) {
            if (r.count > 0) {
                var slot = r.queue[r.head];
                r.head = (r.head + 1) % r.queue.len;
                r.count -= 1;
                r.condition.broadcast(r.io);
                r.mutex.unlock(r.io);
                r.reportOverflow(false);
                if (slot.barrier > 0) r.flushOutputs() else {
                    slot.record.message = slot.bytes();
                    r.writeRecord(slot.record);
                }
                if (slot.heap) |heap| r.allocator.free(heap);
                r.mutex.lockUncancelable(r.io);
                if (slot.barrier > 0) {
                    r.done_barrier = slot.barrier;
                    r.condition.broadcast(r.io);
                }
            } else if (r.stopping) break else if (r.cfg.flush_interval_sec == 0) {
                r.condition.waitUncancelable(r.io, &r.mutex);
            } else {
                r.condition.waitTimeout(r.io, &r.mutex, .{ .deadline = .{ .clock = .awake, .raw = deadline } }) catch {};
            }
            if (r.cfg.flush_interval_sec > 0 and std.Io.Clock.awake.now(r.io).nanoseconds >= deadline.nanoseconds) {
                r.mutex.unlock(r.io);
                r.output_mutex.lockUncancelable(r.io);
                r.reportOverflow(false);
                r.flushOutputs();
                r.output_mutex.unlock(r.io);
                deadline = std.Io.Clock.awake.now(r.io).addDuration(interval);
                r.mutex.lockUncancelable(r.io);
            }
        }
        r.mutex.unlock(r.io);
    }
};

test "filter snapshot covers levels, destinations and explicit important routing" {
    try std.testing.expectEqual(std.atomic.cache_line, @sizeOf(FilterCache));
    const levels = std.enums.values(t.Level);
    for (levels) |threshold| for ([_]bool{ false, true }) |console| {
        for ([_]bool{ false, true }) |file| for ([_]bool{ false, true }) |important| {
            for (levels) |important_level| {
                const cfg: t.Config = .{ .console = console, .rotating_file = file, .important = .{ .enabled = important, .level = important_level } };
                const mask = filterMask(cfg, threshold);
                for (levels) |severity| {
                    const ordinary = severity != .off and @backingInt(severity) >= @backingInt(threshold);
                    const expect_runtime = ordinary and (console or file);
                    const expect_important = ordinary and important and @backingInt(severity) >= @backingInt(important_level);
                    const route = routeFor(cfg, threshold, severity, false);
                    try std.testing.expectEqual(expect_runtime, route.runtime);
                    try std.testing.expectEqual(expect_important, route.important);
                    try std.testing.expectEqual(expect_runtime or expect_important, mask & severityBit(severity) != 0);
                }
                const explicit = routeFor(cfg, threshold, .info, true);
                const expect_explicit = (threshold.accepts(.info) and (console or file)) or important;
                try std.testing.expectEqual(expect_explicit, explicit.runtime or explicit.important);
                try std.testing.expectEqual(expect_explicit, mask & important_bit != 0);
            }
        };
    };
}

test "overflow report clock and final pending delta" {
    var report: OverflowReport = .{};
    try std.testing.expectEqual(@as(?u64, 2), report.delta(2, 0, false));
    try std.testing.expectEqual(@as(?u64, null), report.delta(3, 4 * std.time.ns_per_s, false));
    try std.testing.expectEqual(@as(?u64, 3), report.delta(5, 5 * std.time.ns_per_s, false));
    try std.testing.expectEqual(@as(?u64, 1), report.delta(6, 5 * std.time.ns_per_s, true));
    try std.testing.expectEqual(@as(?u64, null), report.delta(6, 6 * std.time.ns_per_s, true));
}

// Gate the existing worker before consumption; no production test hooks.
const PausedWorker = struct {
    runtime: *Runtime,
    ready: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    fn run(self: *PausedWorker) void {
        self.ready.store(true, .release);
        while (!self.proceed.load(.acquire)) std.atomic.spinLoopHint();
        Runtime.work(self.runtime);
    }
    fn produce(self: *PausedWorker) void {
        const long: [4096]u8 = @splat('x');
        for (0..20) |i| {
            const record: format.Record = .{ .level = @fromBackingInt(@as(u8, @intCast(i % 6))), .seconds = 0, .micros = 0, .tid = 0, .source = @src(), .message = &long, .runtime = true, .important = true };
            self.runtime.submit(record) catch {
                self.failed.store(true, .release);
            };
        }
        _ = self.finished.fetchAdd(1, .release);
    }
    fn flush(self: *PausedWorker) void {
        self.runtime.barrier() catch {
            self.failed.store(true, .release);
        };
    }
};
test "paused bounded worker drops all incoming levels and long buffers but retains barrier" {
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    // Construct the private runtime without auto-starting a worker, then gate its loop.
    const r = try Runtime.create(std.testing.allocator, io, &env, .{ .console = false, .flush_interval_sec = 0, .queue_size = 1 });
    defer r.destroy();
    r.queue = try std.testing.allocator.alloc(Slot, 1);
    r.cfg.async = true;
    var gate_worker: PausedWorker = .{ .runtime = r };
    const worker = try std.Thread.spawn(.{}, PausedWorker.run, .{&gate_worker});
    defer {
        r.mutex.lockUncancelable(io);
        r.stopping = true;
        r.condition.broadcast(io);
        r.mutex.unlock(io);
        gate_worker.proceed.store(true, .release);
        worker.join();
    }
    while (!gate_worker.ready.load(.acquire)) std.atomic.spinLoopHint();
    try r.submit(.{ .level = .info, .seconds = 0, .micros = 0, .tid = 0, .source = @src(), .message = "kept", .runtime = true, .important = false });
    var producers: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        gate_worker.proceed.store(true, .release);
        for (producers[0..spawned]) |thread| thread.join();
    }
    for (&producers) |*thread| {
        thread.* = try std.Thread.spawn(.{}, PausedWorker.produce, .{&gate_worker});
        spawned += 1;
    }
    const start = std.Io.Clock.awake.now(io);
    while (gate_worker.finished.load(.acquire) != 4 and start.untilNow(io, .awake).toNanoseconds() < 2 * std.time.ns_per_s) std.atomic.spinLoopHint();
    const returned = gate_worker.finished.load(.acquire) == 4;
    const before = r.snapshot();
    const kept = std.mem.eql(u8, r.queue[0].bytes(), "kept");
    const flushing = try std.Thread.spawn(.{}, PausedWorker.flush, .{&gate_worker});
    gate_worker.proceed.store(true, .release);
    flushing.join();
    try std.testing.expect(returned);
    try std.testing.expect(kept);
    try std.testing.expectEqual(@as(u64, 1), before.accepted);
    try std.testing.expectEqual(@as(u64, 80), before.dropped);
    try std.testing.expectEqual(@as(u64, 1), r.snapshot().processed);
    try std.testing.expect(!gate_worker.failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), r.snapshot().failures);
}
