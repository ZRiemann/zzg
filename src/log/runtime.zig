const std = @import("std");
const t = @import("types.zig");
const config = @import("config.zig");
const time = @import("time.zig");
const format = @import("format.zig");
const output = @import("output.zig");
const options = @import("options");
const Allocator = std.mem.Allocator;

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
var final_failed: std.atomic.Value(bool) = .init(false);
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
    /// Submit a flush; async requests may drop when full and do not wait for completion.
    pub fn flush(self: LogGuard) !void {
        const r = acquire() orelse {
            while (phase.load(.acquire) == .closing) self.io.futexWaitUncancelable(Phase, &phase.raw, .closing);
            if (final_failed.load(.monotonic)) return error.OutputFailure;
            return;
        };
        defer release(r);
        try r.flush();
    }
    pub fn shutdown(self: LogGuard) !void {
        lockGate();
        const state = phase.load(.acquire);
        if (state != .ready) {
            unlockGate();
            while (phase.load(.acquire) == .closing) self.io.futexWaitUncancelable(Phase, &phase.raw, .closing);
            if (final_failed.load(.monotonic)) return error.OutputFailure;
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
        r.flushOutputs();
        const failed = r.failed.load(.monotonic);
        r.destroy();
        lockGate();
        final_failed.store(failed, .monotonic);
        phase.store(.closed, .release);
        unlockGate();
        self.io.futexWake(Phase, &phase.raw, std.math.maxInt(u32));
        if (failed) return error.OutputFailure;
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
    flush: bool = false,
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
    calendar_cache: time.CalendarCache = .{},
    pattern: format.Pattern,
    important_pattern: format.Pattern,
    runtime_file: ?output.FileSink = null,
    important_file: ?output.FileSink = null,
    color: bool = false,
    pid: u32,
    level: std.atomic.Value(u8),
    failed: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    output_mutex: std.Io.Mutex = .init,
    queue: []Slot = &.{},
    head: usize = 0,
    count: usize = 0,
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
    fn failure(r: *Runtime, operation: []const u8, err: anyerror) void {
        if (!r.failed.swap(true, .monotonic)) {
            var buffer: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "zzg log {s}: {s}\n", .{ operation, @errorName(err) }) catch "zzg log output failure\n";
            std.Io.File.stderr().writeStreamingAll(r.io, text) catch {};
        }
    }
    pub fn submit(r: *Runtime, record: format.Record) !void {
        if (!r.cfg.async) {
            r.output_mutex.lockUncancelable(r.io);
            defer r.output_mutex.unlock(r.io);
            r.writeRecord(record);
            return;
        }
        // Long payload allocation precedes queue locking; queue stores owned bytes.
        const heap = if (record.message.len > 1024) try r.allocator.dupe(u8, record.message) else null;
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.count == r.queue.len) {
            if (heap) |bytes| r.allocator.free(bytes);
            return;
        }
        const slot = &r.queue[(r.head + r.count) % r.queue.len];
        slot.* = .{ .record = record, .heap = heap, .len = record.message.len };
        if (heap == null) @memcpy(slot.inline_bytes[0..record.message.len], record.message);
        slot.record.message = ""; // Do not retain even an unused borrowed pointer.
        r.count += 1;
        r.condition.broadcast(r.io);
    }
    pub fn flush(r: *Runtime) !void {
        if (r.cfg.async) {
            r.mutex.lockUncancelable(r.io);
            if (r.count < r.queue.len) {
                r.queue[(r.head + r.count) % r.queue.len] = .{ .flush = true };
                r.count += 1;
                r.condition.broadcast(r.io);
            }
            r.mutex.unlock(r.io);
        } else {
            r.output_mutex.lockUncancelable(r.io);
            r.flushOutputs();
            r.output_mutex.unlock(r.io);
        }
        if (r.failed.load(.monotonic)) return error.OutputFailure;
    }
    fn writeRecord(r: *Runtime, record: format.Record) void {
        const runtime_calendar = record.runtime and (r.cfg.console or r.runtime_file != null) and r.pattern.needs_calendar;
        const important_calendar = record.important and r.important_file != null and (r.cfg.important.format == .jsonl or r.important_pattern.needs_calendar);
        const local: ?time.Calendar = if (runtime_calendar or important_calendar) r.calendar_cache.get(&r.zone, record.seconds) else null;
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
            const result = if (r.cfg.important.format == .jsonl) format.json(&r.rendered.writer, record, r.cfg, local.?, r.pid) else r.important_pattern.render(&r.rendered.writer, record, r.cfg, local, r.pid, false);
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
                r.mutex.unlock(r.io);
                if (slot.flush) r.flushOutputs() else {
                    slot.record.message = slot.bytes();
                    r.writeRecord(slot.record);
                }
                if (slot.heap) |heap| r.allocator.free(heap);
                r.mutex.lockUncancelable(r.io);
            } else if (r.stopping) break else if (r.cfg.flush_interval_sec == 0) {
                r.condition.waitUncancelable(r.io, &r.mutex);
            } else {
                r.condition.waitTimeout(r.io, &r.mutex, .{ .deadline = .{ .clock = .awake, .raw = deadline } }) catch {};
            }
            if (r.cfg.flush_interval_sec > 0 and std.Io.Clock.awake.now(r.io).nanoseconds >= deadline.nanoseconds) {
                r.mutex.unlock(r.io);
                r.output_mutex.lockUncancelable(r.io);
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

// Gate the existing worker before consumption; no production test hooks.
const PausedWorker = struct {
    runtime: *Runtime,
    ready: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    flushed: std.atomic.Value(bool) = .init(false),
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
        self.runtime.flush() catch {
            self.failed.store(true, .release);
        };
        self.flushed.store(true, .release);
    }
};
test "paused bounded worker drops incoming data and flush without waiting" {
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
    const kept = std.mem.eql(u8, r.queue[0].bytes(), "kept");
    const flushing = try std.Thread.spawn(.{}, PausedWorker.flush, .{&gate_worker});
    const flush_start = std.Io.Clock.awake.now(io);
    while (!gate_worker.flushed.load(.acquire) and flush_start.untilNow(io, .awake).toNanoseconds() < 2 * std.time.ns_per_s) std.atomic.spinLoopHint();
    const flush_returned = gate_worker.flushed.load(.acquire);
    const count = r.count; // Producers finished and the worker remains paused.
    gate_worker.proceed.store(true, .release);
    flushing.join();
    try std.testing.expect(returned);
    try std.testing.expect(kept);
    try std.testing.expect(flush_returned);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(!gate_worker.failed.load(.acquire));
    try std.testing.expect(!r.failed.load(.monotonic));
}

test "accepted async flush request writes buffered output before destruction" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(a, &.{ buffer[0..length], "runtime.log" });
    defer a.free(path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    const r = try Runtime.create(a, io, &env, .{ .console = false, .rotating_file = true, .name = path, .pattern = "%v", .flush_interval_sec = 0, .flush_level = .off });
    defer r.destroy();
    r.queue = try a.alloc(Slot, 2);
    r.cfg.async = true;
    try r.submit(.{ .level = .info, .seconds = 0, .micros = 0, .tid = 0, .source = @src(), .message = "kept", .runtime = true, .important = false });
    try r.flush();
    // Run the same worker loop deterministically, stopping after queued work.
    r.stopping = true;
    Runtime.work(r);
    const actual = try tmp.dir.readFileAlloc(io, "runtime.log", a, .limited(65536));
    defer a.free(actual);
    try std.testing.expectEqualStrings("kept\n", actual);
}

test "calendar conversion follows active destinations and inherited patterns" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    const Important = struct { enabled: bool, format: t.SinkFormat = .pattern, pattern: []const u8 = "" };
    const important_cases = [_]Important{
        .{ .enabled = false },
        .{ .enabled = true },
        .{ .enabled = true, .pattern = "%v" },
        .{ .enabled = true, .pattern = "%S" },
        .{ .enabled = true, .format = .jsonl },
    };
    for ([_]bool{ false, true }) |file_enabled| for ([_][]const u8{ "", "%v", "%%Y %e %f", "%S" }) |pattern| {
        for (important_cases) |important| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = try tmp.dir.realPath(io, &buffer);
            const path = try std.fs.path.join(a, &.{ buffer[0..length], "runtime.log" });
            defer a.free(path);
            const important_path = try std.fs.path.join(a, &.{ buffer[0..length], "important.log" });
            defer a.free(important_path);
            const r = try Runtime.create(a, io, &env, .{
                .console = false,
                .rotating_file = file_enabled,
                .name = path,
                .pattern = pattern,
                .flush_interval_sec = 0,
                .flush_level = .off,
                .important = .{ .enabled = important.enabled, .name = important_path, .format = important.format, .pattern = important.pattern },
            });
            defer r.destroy();
            if (important.pattern.len == 0) try std.testing.expectEqual(r.pattern.needs_calendar, r.important_pattern.needs_calendar);
            var expected: usize = 0;
            for ([_]bool{ false, true }) |ordinary_route| for ([_]bool{ false, true }) |important_route| {
                const seconds: i64 = @as(i64, if (ordinary_route) 2 else 0) + @as(i64, if (important_route) 1 else 0);
                const needs = (ordinary_route and file_enabled and r.pattern.needs_calendar) or
                    (important_route and important.enabled and (important.format == .jsonl or r.important_pattern.needs_calendar));
                if (needs) expected += 1;
                for ([_]u32{ 1, 999999 }) |micros| {
                    try r.submit(.{ .level = .info, .seconds = seconds, .micros = micros, .tid = 0, .source = @src(), .message = "payload", .runtime = ordinary_route, .important = important_route });
                    try std.testing.expectEqual(expected, r.calendar_cache.conversions);
                }
            };
            try r.flush();
        }
    };
}

test "paused async backlog formats record timestamps and microseconds in queue order" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(a, &.{ buffer[0..length], "runtime.log" });
    defer a.free(path);
    const important_path = try std.fs.path.join(a, &.{ buffer[0..length], "important.jsonl" });
    defer a.free(important_path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    const r = try Runtime.create(a, io, &env, .{ .console = false, .rotating_file = true, .name = path, .pattern = "%Y-%m-%d %H:%M:%S.%f %v", .flush_interval_sec = 0, .flush_level = .off, .important = .{ .enabled = true, .name = important_path } });
    defer r.destroy();
    r.queue = try a.alloc(Slot, 8);
    r.cfg.async = true;
    var worker_state: PausedWorker = .{ .runtime = r };
    const worker = try std.Thread.spawn(.{}, PausedWorker.run, .{&worker_state});
    var joined = false;
    defer if (!joined) {
        r.mutex.lockUncancelable(io);
        r.stopping = true;
        r.condition.broadcast(io);
        r.mutex.unlock(io);
        worker_state.proceed.store(true, .release);
        worker.join();
    };
    const seconds = [_]i64{ 100, 100, 101, 100, -1, 0 };
    const micros = [_]u32{ 1, 999999, 123456, 654321, 999999, 0 };
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    var json: std.Io.Writer.Allocating = .init(a);
    defer json.deinit();
    for (seconds, micros) |epoch, fraction| {
        const record: format.Record = .{ .level = .warn, .seconds = epoch, .micros = fraction, .tid = 7, .source = @src(), .message = "[backlog:check] payload", .runtime = true, .important = true };
        try r.submit(record);
        const direct = r.zone.local(epoch, fraction);
        try r.pattern.render(&text.writer, record, r.cfg, direct, r.pid, false);
        try format.json(&json.writer, record, r.cfg, direct, r.pid);
    }
    try std.testing.expectEqual(@as(usize, 0), r.calendar_cache.conversions);
    r.mutex.lockUncancelable(io);
    r.stopping = true;
    r.mutex.unlock(io);
    worker_state.proceed.store(true, .release);
    worker.join();
    joined = true;
    r.flushOutputs();
    try std.testing.expectEqual(@as(usize, 5), r.calendar_cache.conversions);
    const actual_text = try tmp.dir.readFileAlloc(io, "runtime.log", a, .limited(65536));
    defer a.free(actual_text);
    const actual_json = try tmp.dir.readFileAlloc(io, "important.jsonl", a, .limited(65536));
    defer a.free(actual_json);
    try std.testing.expectEqualStrings(text.written(), actual_text);
    try std.testing.expectEqualStrings(json.written(), actual_json);
}

test "synchronous producers retain complete fractional timestamps" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(a, &.{ buffer[0..length], "runtime.log" });
    defer a.free(path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    const r = try Runtime.create(a, io, &env, .{ .console = false, .rotating_file = true, .name = path, .pattern = "%S.%f %t %v", .flush_interval_sec = 0, .flush_level = .off });
    defer r.destroy();
    const Producer = struct {
        runtime: *Runtime,
        id: u32,
        failed: bool = false,
        fn run(p: *@This()) void {
            for (0..50) |i| {
                p.runtime.submit(.{ .level = .info, .seconds = @intCast(i % 2), .micros = p.id * 100 + @as(u32, @intCast(i)), .tid = p.id, .source = @src(), .message = "payload", .runtime = true, .important = false }) catch {
                    p.failed = true;
                };
            }
        }
    };
    var producers: [4]Producer = undefined;
    var workers: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (workers[0..spawned]) |worker| worker.join();
    for (&producers, &workers, 0..) |*producer, *worker, id| {
        producer.* = .{ .runtime = r, .id = @intCast(id) };
        worker.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
        spawned += 1;
    }
    for (workers) |worker| worker.join();
    spawned = 0;
    for (producers) |producer| try std.testing.expect(!producer.failed);
    try r.flush();
    const actual = try tmp.dir.readFileAlloc(io, "runtime.log", a, .limited(65536));
    defer a.free(actual);
    try std.testing.expectEqual(@as(usize, 200), std.mem.count(u8, actual, "\n"));
    for (0..4) |id| for (0..50) |i| {
        var line: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&line, "{d:0>2}.{d:0>6} {d:0>2} payload\n", .{ i % 2, id * 100 + i, id });
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, actual, expected));
    };
}
