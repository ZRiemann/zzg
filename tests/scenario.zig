//! Each scenario runs in its own process to verify the public singleton contract.
const std = @import("std");
const z = @import("z");
fn require(ok: bool) !void {
    if (!ok) return error.ScenarioAssertion;
}
fn read(init: std.process.Init, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024));
}
fn produce(id: usize) void {
    for (0..500) |i| z.log.info(@src(), "{d}:{d}", .{ id, i });
}
fn close(guard: z.log.LogGuard, failed: *std.atomic.Value(bool)) void {
    guard.shutdown() catch {
        failed.store(true, .release);
    };
}
fn metadataProducer(id: usize) void {
    z.log.info(@src(), "worker-{d}", .{id});
}
const BlockingFormat = struct {
    entered: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
    pub fn format(self: *BlockingFormat, w: *std.Io.Writer) !void {
        self.entered.store(true, .release);
        while (!self.proceed.load(.acquire)) std.atomic.spinLoopHint();
        try w.writeAll("in-flight");
    }
};
fn slowProduce(state: *BlockingFormat) void {
    z.log.info(@src(), "{f}", .{state});
}
const NoFormat = struct {
    called: *bool,
    pub fn format(self: NoFormat, _: *std.Io.Writer) !void {
        self.called.* = true;
        return error.WriteFailed;
    }
};
const LevelRace = struct {
    ready: std.atomic.Value(u32) = .init(0),
    start: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    fn run(state: *LevelRace, id: usize, until_stop: bool) void {
        _ = state.ready.fetchAdd(1, .release);
        while (!state.start.load(.acquire)) std.atomic.spinLoopHint();
        var i: usize = 0;
        while (if (until_stop) !state.stop.load(.acquire) else i < 1000) : (i += 1) {
            z.log.setLevel(if (i % 2 == 0) .off else .info);
            if (!until_stop) z.log.info(@src(), "race-{d}:{d}", .{ id, i });
        }
    }
};
fn levelRace(init: std.process.Init, guard: z.log.LogGuard, path: []const u8, shutdown: bool) !void {
    var state: LevelRace = .{};
    var blocking: BlockingFormat = .{};
    // Establish a retained submission before level writers or shutdown can intervene.
    const producer: ?std.Thread = if (shutdown) try std.Thread.spawn(.{}, slowProduce, .{&blocking}) else null;
    if (shutdown) while (!blocking.entered.load(.acquire)) std.atomic.spinLoopHint();
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        state.start.store(true, .release);
        state.stop.store(true, .release);
        blocking.proceed.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
        if (producer) |thread| thread.join();
    }
    while (spawned < threads.len) : (spawned += 1) threads[spawned] = try std.Thread.spawn(.{}, LevelRace.run, .{ &state, spawned, shutdown });
    while (state.ready.load(.acquire) != threads.len) std.atomic.spinLoopHint();
    state.start.store(true, .release);
    if (shutdown) {
        var failed: std.atomic.Value(bool) = .init(false);
        const closer = try std.Thread.spawn(.{}, close, .{ guard, &failed });
        // Explicit important remains enabled through every setLevel until closing.
        while (z.log.importantEnabled()) std.atomic.spinLoopHint();
        for (0..1000) |_| z.log.setLevel(.trace);
        const disabled = !z.log.enabled(.info) and !z.log.importantEnabled();
        state.stop.store(true, .release);
        blocking.proceed.store(true, .release);
        closer.join();
        try require(disabled and !failed.load(.acquire));
    }
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;
    if (!shutdown) {
        try guard.flush();
        z.log.setLevel(.warn);
        try require(!z.log.enabled(.info) and z.log.enabled(.warn) and z.log.importantEnabled());
        var formatted = false;
        z.log.info(@src(), "{f}", .{NoFormat{ .called = &formatted }});
        try require(!formatted);
        z.log.warn(@src(), "stable-warning", .{});
        z.log.important(@src(), "stable-important", .{});
        try guard.flush();
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        try require(std.mem.endsWith(u8, bytes, "stable-warning\n"));
    } else {
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        try require(std.mem.eql(u8, bytes, "in-flight\n"));
    }
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const mode = args[1];
    var fixture_diagnostic: z.log.Diagnostic = .{};
    var zpp_fixture = try z.log.fromZppFile(init.gpa, init.io, "tests/fixtures/zpp.json", "server", &fixture_diagnostic);
    defer zpp_fixture.deinit();
    var zust_fixture = try z.log.fromZppFile(init.gpa, init.io, "tests/fixtures/zust.json", "example", &fixture_diagnostic);
    defer zust_fixture.deinit();
    try require(zpp_fixture.value.async and zpp_fixture.value.rotating_file and zust_fixture.value.important.enabled);
    const dir = try init.gpa.print("/tmp/zzg-scenario-{d}", .{std.os.linux.getpid()});
    defer init.gpa.free(dir);
    try std.Io.Dir.cwd().createDir(init.io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, dir) catch {};
    const path = try std.fs.path.join(init.gpa, &.{ dir, "runtime.log" });
    defer init.gpa.free(path);
    const important = try std.fs.path.join(init.gpa, &.{ dir, "important.jsonl" });
    defer init.gpa.free(important);
    var env = std.process.Environ.Map.init(init.gpa);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    var cfg: z.log.Config = .{ .console = false, .rotating_file = true, .name = path, .rotate_on_open = false, .pattern = "%v", .flush_interval_sec = 0, .flush_level = .off };
    if (std.mem.eql(u8, mode, "async")) {
        cfg.async = true;
        cfg.queue_size = 2;
    }
    if (std.mem.eql(u8, mode, "long") or std.mem.eql(u8, mode, "metadata") or std.mem.eql(u8, mode, "shutdown-race") or std.mem.eql(u8, mode, "level-shutdown")) {
        cfg.async = true;
        cfg.queue_size = 2;
    }
    if (std.mem.eql(u8, mode, "metadata")) {
        cfg.pattern = "%t %v %g:%# %!";
        cfg.queue_size = 128; // This scenario verifies metadata, not overload.
    }
    if (std.mem.eql(u8, mode, "periodic")) cfg.flush_interval_sec = 1;
    if (std.mem.eql(u8, mode, "sync") or std.mem.eql(u8, mode, "failure") or std.mem.eql(u8, mode, "level-race") or std.mem.eql(u8, mode, "level-shutdown") or std.mem.eql(u8, mode, "important-only")) {
        cfg.important = .{ .enabled = true, .name = if (std.mem.eql(u8, mode, "failure")) "/dev/full" else important, .rotate_on_open = false };
    }
    if (std.mem.eql(u8, mode, "rotate")) {
        cfg.max_size = 1;
        cfg.rotate_on_open = true;
        const f = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer f.close(init.io);
        try f.writeStreamingAll(init.io, "old\n");
    }
    if (std.mem.eql(u8, mode, "disabled")) cfg.rotating_file = false;
    if (std.mem.eql(u8, mode, "important-only")) {
        cfg.rotating_file = false;
        cfg.level = .off;
        cfg.important.level = .off;
    }
    try require(!z.log.enabled(.info) and !z.log.importantEnabled() and !z.log.enabled(.off));
    z.log.setLevel(.trace);
    z.log.info(@src(), "before-init", .{});
    // A failed initialization must be retryable and publish no runtime.
    var bad = cfg;
    bad.pattern = "%unknown";
    if (z.log.init(init.gpa, init.io, &env, bad)) |_| return error.AcceptedInvalidPattern else |err| try require(err == error.UnsupportedPattern);
    try require(!z.log.enabled(.info) and !z.log.importantEnabled());
    const guard = try z.log.init(init.gpa, init.io, &env, cfg);
    defer guard.deinit();
    if (std.mem.eql(u8, mode, "level-race") or std.mem.eql(u8, mode, "level-shutdown")) {
        try levelRace(init, guard, path, std.mem.eql(u8, mode, "level-shutdown"));
    } else if (std.mem.eql(u8, mode, "disabled") or std.mem.eql(u8, mode, "important-only")) {
        try require(!z.log.enabled(.info) and !z.log.enabled(.off));
        const important_only = std.mem.eql(u8, mode, "important-only");
        try require(z.log.importantEnabled() == important_only);
        var formatted = false;
        z.log.info(@src(), "{f}", .{NoFormat{ .called = &formatted }});
        if (!important_only) z.log.important(@src(), "{f}", .{NoFormat{ .called = &formatted }});
        try require(!formatted);
        if (important_only) z.log.important(@src(), "explicit-only", .{});
        try guard.flush();
        if (read(init, path)) |bytes| {
            init.gpa.free(bytes);
            return error.UnexpectedRuntimeFile;
        } else |err| try require(err == error.FileNotFound);
        if (important_only) {
            const output = try read(init, important);
            defer init.gpa.free(output);
            try require(std.mem.indexOf(u8, output, "explicit-only") != null);
        }
    } else if (std.mem.eql(u8, mode, "async")) {
        var threads: [4]std.Thread = undefined;
        for (&threads, 0..) |*thread, id| thread.* = try std.Thread.spawn(.{}, produce, .{id});
        for (threads) |thread| thread.join();
        var failed: std.atomic.Value(bool) = .init(false);
        const one = try std.Thread.spawn(.{}, close, .{ guard, &failed });
        const two = try std.Thread.spawn(.{}, close, .{ guard, &failed });
        one.join();
        two.join();
        try require(!failed.load(.acquire));
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        var seen: [2000]bool = @splat(false);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedRecord;
            const thread = try std.fmt.parseInt(usize, line[0..colon], 10);
            const number = try std.fmt.parseInt(usize, line[colon + 1 ..], 10);
            try require(thread < 4 and number < 500);
            const index = thread * 500 + number;
            try require(!seen[index]);
            seen[index] = true;
            count += 1;
        }
        try require(count > 0 and count <= 2000);
    } else if (std.mem.eql(u8, mode, "long")) {
        const payload = try init.gpa.alloc(u8, 4096);
        defer init.gpa.free(payload);
        @memset(payload, 'x');
        z.log.info(@src(), "{s}", .{payload});
        @memset(payload, 'y');
        z.log.info(@src(), "{s}", .{payload});
        @memset(payload, 'z');
        try guard.shutdown();
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        try require(bytes.len == 8194 and bytes[4096] == '\n' and bytes[8193] == '\n');
        for (bytes[0..4096]) |byte| try require(byte == 'x');
        for (bytes[4097..8193]) |byte| try require(byte == 'y');
    } else if (std.mem.eql(u8, mode, "metadata")) {
        for (0..70) |id| {
            const thread = try std.Thread.spawn(.{}, metadataProducer, .{id});
            thread.join();
        }
        try guard.shutdown();
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        for (0..70) |id| {
            const line = lines.next() orelse return error.MissingRecord;
            var prefix: [64]u8 = undefined;
            const expected = try std.fmt.bufPrint(&prefix, "{d:0>2} worker-{d} ", .{ id, id });
            try require(std.mem.startsWith(u8, line, expected));
            try require(std.mem.indexOf(u8, line, "scenario.zig:") != null and std.mem.indexOf(u8, line, "metadataProducer") != null);
        }
        try require(lines.next().?.len == 0 and lines.next() == null);
    } else if (std.mem.eql(u8, mode, "shutdown-race")) {
        var state: BlockingFormat = .{};
        const producer = try std.Thread.spawn(.{}, slowProduce, .{&state});
        while (!state.entered.load(.acquire)) std.atomic.spinLoopHint();
        var failed: std.atomic.Value(bool) = .init(false);
        const closer = try std.Thread.spawn(.{}, close, .{ guard, &failed });
        while (z.log.enabled(.info)) std.atomic.spinLoopHint();
        state.proceed.store(true, .release);
        producer.join();
        closer.join();
        try require(!failed.load(.acquire));
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        try require(std.mem.eql(u8, bytes, "in-flight\n"));
    } else if (std.mem.eql(u8, mode, "sync")) {
        z.log.info(@src(), "ordinary", .{});
        z.log.warn(@src(), "[test:warn] warning", .{});
        z.log.setLevel(.warn);
        var formatted = false;
        z.log.info(@src(), "{f}", .{NoFormat{ .called = &formatted }});
        try require(!formatted);
        z.log.important(@src(), "[test:ready] ready\nquoted \"", .{});
        try guard.flush();
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        try require(std.mem.eql(u8, bytes, "ordinary\n[test:warn] warning\n"));
        const jsonl = try read(init, important);
        defer init.gpa.free(jsonl);
        var lines = std.mem.splitScalar(u8, jsonl, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, line, .{});
            defer parsed.deinit();
            try require(parsed.value.object.count() == 14);
            try require(std.mem.eql(u8, parsed.value.object.get("logger").?.string, "zpp"));
            count += 1;
        }
        try require(count == 2);
    } else if (std.mem.eql(u8, mode, "failure")) {
        z.log.warn(@src(), "survives-other-sink-failure", .{});
        if (guard.flush()) |_| return error.MissingOutputFailure else |err| try require(err == error.OutputFailure);
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        try require(std.mem.eql(u8, bytes, "survives-other-sink-failure\n"));
        if (guard.shutdown()) |_| return error.MissingShutdownFailure else |err| try require(err == error.OutputFailure);
        if (guard.shutdown()) |_| return error.MissingRepeatedFailure else |err| try require(err == error.OutputFailure);
        if (guard.flush()) |_| return error.MissingClosedFailure else |err| try require(err == error.OutputFailure);
        return;
    } else if (std.mem.eql(u8, mode, "rotate")) {
        const big = try init.gpa.alloc(u8, 1024 * 1024 + 17);
        defer init.gpa.free(big);
        @memset(big, 'x');
        z.log.info(@src(), "{s}", .{big});
        z.log.info(@src(), "tail", .{});
        try guard.flush();
        const backup = try std.fs.path.join(init.gpa, &.{ dir, "runtime.1.log" });
        defer init.gpa.free(backup);
        const old = try std.fs.path.join(init.gpa, &.{ dir, "runtime.2.log" });
        defer init.gpa.free(old);
        const data = try read(init, backup);
        defer init.gpa.free(data);
        try require(data.len == big.len + 1 and std.mem.eql(u8, data[0..big.len], big));
        const previous = try read(init, old);
        defer init.gpa.free(previous);
        try require(std.mem.eql(u8, previous, "old\n"));
    } else if (std.mem.eql(u8, mode, "periodic")) {
        z.log.info(@src(), "periodic", .{});
        try init.io.sleep(.fromMilliseconds(1200), .awake);
        const bytes = try read(init, path);
        defer init.gpa.free(bytes);
        try require(std.mem.eql(u8, bytes, "periodic\n"));
    } else return error.UnknownScenario;
    try guard.shutdown();
    try guard.shutdown();
    z.log.setLevel(.trace);
    z.log.info(@src(), "after-shutdown", .{});
    try require(!z.log.enabled(.info) and !z.log.importantEnabled() and !z.log.enabled(.off));
    if (z.log.init(init.gpa, init.io, &env, cfg)) |_| return error.Reinitialized else |err| try require(err == error.AlreadyInitialized);
}
