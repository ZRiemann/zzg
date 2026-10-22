//! Bounded benchmark; --help describes modes, producer counts and measurement rounds.
const std = @import("std");
const z = @import("z");
const Allocator = std.mem.Allocator;
const Counter = struct {
    parent: Allocator,
    allocations: std.atomic.Value(u64) = .init(0),
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    fn allocator(c: *Counter) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grow(c: *Counter, n: usize) void {
        const value = c.live.fetchAdd(n, .monotonic) + n;
        var peak = c.peak.load(.monotonic);
        while (value > peak) peak = c.peak.cmpxchgWeak(peak, value, .monotonic, .monotonic) orelse break;
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        const ptr = c.parent.rawAlloc(n, alignment, ra) orelse return null;
        _ = c.allocations.fetchAdd(1, .monotonic);
        c.grow(n);
        return ptr;
    }
    fn resize(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        if (!c.parent.rawResize(old, alignment, n, ra)) return false;
        if (n > old.len) c.grow(n - old.len) else _ = c.live.fetchSub(old.len - n, .monotonic);
        return true;
    }
    fn remap(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        const ptr = c.parent.rawRemap(old, alignment, n, ra) orelse return null;
        if (n > old.len) c.grow(n - old.len) else _ = c.live.fetchSub(old.len - n, .monotonic);
        return ptr;
    }
    fn free(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        c.parent.rawFree(old, alignment, ra);
        _ = c.live.fetchSub(old.len, .monotonic);
    }
};
var formatting_calls: std.atomic.Value(u64) = .init(0);
const Payload = struct {
    long: bool,
    pub fn format(p: Payload, w: *std.Io.Writer) !void {
        _ = formatting_calls.fetchAdd(1, .monotonic);
        if (p.long) {
            const bytes: [4096]u8 = @splat('x');
            try w.writeAll(&bytes);
        } else try w.writeAll("short-payload");
    }
};
const Mode = enum { sync, async, pressure, filtered, long, mixed };
const Format = enum { payload, default, jsonl };
const Settings = struct {
    mode: Mode,
    threads: usize,
    records: usize = 20000,
    format: Format = .payload,
    tz: []const u8 = "UTC0",

    fn parse(args: []const [:0]const u8) !Settings {
        if (args.len < 3 or !std.mem.eql(u8, args[1], "--run")) return error.InvalidArguments;
        const mode = std.meta.stringToEnum(Mode, args[2]) orelse return error.UnknownBenchmark;
        var result: Settings = .{ .mode = mode, .threads = if (mode == .pressure) 4 else 1 };
        var seen_threads = false;
        var seen_records = false;
        var seen_format = false;
        var seen_tz = false;
        var i: usize = 3;
        while (i < args.len) : (i += 2) {
            if (i + 1 == args.len) return error.MissingValue;
            const value = args[i + 1];
            if (std.mem.eql(u8, args[i], "--threads") and !seen_threads) {
                result.threads = std.fmt.parseInt(usize, value, 10) catch return error.InvalidNumber;
                seen_threads = true;
            } else if (std.mem.eql(u8, args[i], "--records") and !seen_records) {
                result.records = std.fmt.parseInt(usize, value, 10) catch return error.InvalidNumber;
                seen_records = true;
            } else if (std.mem.eql(u8, args[i], "--format") and !seen_format) {
                result.format = std.meta.stringToEnum(Format, value) orelse return error.UnknownFormat;
                seen_format = true;
            } else if (std.mem.eql(u8, args[i], "--tz") and !seen_tz) {
                for (value) |byte| if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return error.InvalidTimezoneArgument;
                result.tz = value;
                seen_tz = true;
            } else return error.InvalidArguments;
        }
        switch (result.threads) {
            1, 2, 4, 8 => {},
            else => return error.InvalidThreadCount,
        }
        if (result.records == 0 or result.records % result.threads != 0) return error.InvalidRecordCount;
        if (mode == .mixed and result.records % (10 * result.threads) != 0) return error.InvalidMixedRecordCount;
        return result;
    }
    fn eligible(self: Settings, calls: usize) usize {
        return switch (self.mode) {
            .filtered => 0,
            .mixed => calls / 10,
            else => calls,
        };
    }
};
fn usage() void {
    std.debug.print("Usage: benchmark --run sync|async|pressure|filtered|long|mixed [--threads 1|2|4|8] [--records N]\n" ++
        "                 [--format payload|default|jsonl] [--tz STRING]\n" ++
        "Defaults: 20,000 total calls per measured round; one producer (pressure: four).\n" ++
        "Format defaults to payload (%v); timezone defaults to UTC0. JSONL uses important-only output.\n" ++
        "Records must divide evenly across producers; mixed needs multiples of 10 per producer.\n" ++
        "Example: benchmark --run filtered --threads 8 --records 200000\n", .{});
}
fn logCall(mode: Mode, index: usize) void {
    if (mode == .mixed and index % 10 != 9) {
        z.log.debug(@src(), "{f}", .{Payload{ .long = false }});
    } else z.log.info(@src(), "{f}", .{Payload{ .long = mode == .long }});
}
const Round = enum { warmup, batch, latency };
/// Producers remain alive across rounds; synchronization is outside the call loop.
const Producers = struct {
    io: std.Io,
    settings: Settings,
    samples: []u64,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    generation: usize = 0,
    ready: usize = 0,
    done: usize = 0,
    stopping: bool = false,
    round: Round = .warmup,

    fn work(group: *Producers, id: usize) void {
        group.mutex.lockUncancelable(group.io);
        group.ready += 1;
        group.condition.broadcast(group.io);
        var generation: usize = 0;
        while (true) {
            while (!group.stopping and group.generation == generation) group.condition.waitUncancelable(group.io, &group.mutex);
            if (group.stopping) break;
            generation = group.generation;
            const round = group.round;
            group.mutex.unlock(group.io);
            const count = (if (round == .warmup) @as(usize, 1000) else group.settings.records) / group.settings.threads;
            const offset = id * count;
            for (0..count) |i| {
                if (round == .latency) {
                    const start = std.Io.Clock.awake.now(group.io);
                    logCall(group.settings.mode, offset + i);
                    group.samples[offset + i] = @intCast(start.untilNow(group.io, .awake).toNanoseconds());
                } else logCall(group.settings.mode, offset + i);
            }
            group.mutex.lockUncancelable(group.io);
            group.done += 1;
            group.condition.broadcast(group.io);
        }
        group.mutex.unlock(group.io);
    }
    fn waitReady(group: *Producers) void {
        group.mutex.lockUncancelable(group.io);
        defer group.mutex.unlock(group.io);
        while (group.ready != group.settings.threads) group.condition.waitUncancelable(group.io, &group.mutex);
    }
    fn run(group: *Producers, round: Round) i96 {
        group.mutex.lockUncancelable(group.io);
        defer group.mutex.unlock(group.io);
        group.round = round;
        group.done = 0;
        group.generation += 1;
        const start = std.Io.Clock.awake.now(group.io);
        group.condition.broadcast(group.io);
        while (group.done != group.settings.threads) group.condition.waitUncancelable(group.io, &group.mutex);
        return start.untilNow(group.io, .awake).toNanoseconds();
    }
    fn stop(group: *Producers, threads: []std.Thread) void {
        group.mutex.lockUncancelable(group.io);
        group.stopping = true;
        group.condition.broadcast(group.io);
        group.mutex.unlock(group.io);
        for (threads) |thread| thread.join();
    }
};
const Measurement = struct { submit_ns: i96, allocations: u64 };
fn measure(group: *Producers, counter: *Counter, round: Round) !Measurement {
    const allocations = counter.allocations.load(.monotonic);
    const formats = formatting_calls.load(.monotonic);
    const submit_ns = group.run(round);
    const calls = if (round == .warmup) 1000 else group.settings.records;
    const expected = group.settings.eligible(calls);
    const hot_allocations = counter.allocations.load(.monotonic) - allocations;
    if (formatting_calls.load(.monotonic) - formats != expected) return error.RecordCountMismatch;
    // Async allocation windows may overlap worker initialization/output.
    if (round != .warmup and group.settings.mode != .long and
        group.settings.mode != .async and group.settings.mode != .pressure and hot_allocations != 0)
        return error.ShortMessageAllocation;
    return .{ .submit_ns = submit_ns, .allocations = hot_allocations };
}
fn rate(records: usize, ns: i96) f64 {
    return @as(f64, @floatFromInt(records)) * 1e9 / @as(f64, @floatFromInt(ns));
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        usage();
        return;
    }
    const settings = Settings.parse(args) catch |err| {
        usage();
        return err;
    };
    const dir = try init.gpa.print("/tmp/zzg-bench-{d}", .{std.os.linux.getpid()});
    defer init.gpa.free(dir);
    try std.Io.Dir.cwd().createDir(init.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, dir) catch {};
    const path = try std.fs.path.join(init.gpa, &.{ dir, "runtime.log" });
    defer init.gpa.free(path);
    var env = std.process.Environ.Map.init(init.gpa);
    defer env.deinit();
    try env.put("TZ", settings.tz);
    var counter: Counter = .{ .parent = init.gpa };
    const async_mode = switch (settings.mode) {
        .async, .pressure, .long => true,
        else => false,
    };
    const guard = try z.log.init(counter.allocator(), init.io, &env, .{ .console = false, .rotating_file = settings.format != .jsonl, .name = path, .rotate_on_open = false, .async = async_mode, .queue_size = if (settings.mode == .pressure) 2 else 64, .flush_interval_sec = 0, .flush_level = .off, .pattern = if (settings.format == .payload) "%v" else (z.log.Config{}).pattern, .level = switch (settings.mode) {
        .filtered => .off,
        .mixed => .info,
        else => .trace,
    }, .max_size = 256, .important = .{ .enabled = settings.format == .jsonl, .name = path, .level = .info, .format = .jsonl, .rotate_on_open = false, .max_size = 256 } });
    defer guard.deinit();
    const samples = try init.gpa.alloc(u64, settings.records);
    defer init.gpa.free(samples);
    var group: Producers = .{ .io = init.io, .settings = settings, .samples = samples };
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    defer group.stop(threads[0..spawned]);
    while (spawned < settings.threads) : (spawned += 1) threads[spawned] = try std.Thread.spawn(.{}, Producers.work, .{ &group, spawned });
    group.waitReady();
    _ = try measure(&group, &counter, .warmup);
    const batch = try measure(&group, &counter, .batch);
    const latency = try measure(&group, &counter, .latency);
    // Producers are idle; joining is outside every measured interval.
    group.stop(threads[0..spawned]);
    spawned = 0;
    const closing = std.Io.Clock.awake.now(init.io);
    try guard.shutdown();
    const shutdown_ns = closing.untilNow(init.io, .awake).toNanoseconds();
    if (counter.live.load(.monotonic) != 0) return error.BenchmarkCorrectnessFailure;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    std.debug.print("mode={s} format={s} tz={s} threads={d} records={d} batch_attempts_per_sec={d:.0} latency_attempts_per_sec={d:.0} p50_ns={d} p99_ns={d} shutdown_ns={d} hot_allocations={d} batch_hot_allocations={d} peak_allocated_bytes={d}\n", .{ @tagName(settings.mode), @tagName(settings.format), settings.tz, settings.threads, settings.records, rate(settings.records, batch.submit_ns), rate(settings.records, latency.submit_ns), samples[settings.records / 2], samples[settings.records * 99 / 100], shutdown_ns, latency.allocations, batch.allocations, counter.peak.load(.monotonic) });
}
