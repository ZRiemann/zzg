const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0")) @panic("zzg requires Zig 0.17.0");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_log = b.option(bool, "log", "Enable z.log") orelse false;
    const cutoff = b.option([]const u8, "log-level", "Compiled minimum: trace/debug/info/warn/err/critical/off") orelse "trace";
    const release_cutoff = b.option([]const u8, "log-release-level", "Release compiled minimum") orelse cutoff;
    const active = if (optimize == .debug) cutoff else release_cutoff;
    const levels = [_][]const u8{ "trace", "debug", "info", "warn", "err", "critical", "off" };
    var active_level: ?u8 = null;
    for (levels, 0..) |level, i| if (std.mem.eql(u8, level, active)) {
        active_level = @intCast(i);
    };
    const opts = b.addOptions();
    opts.addOption(bool, "log", enable_log);
    opts.addOption(u8, "active_level", active_level orelse @panic("invalid compiled log level"));
    const opts_module = opts.createModule();
    const logging = b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = optimize, .link_libc = false });
    logging.addImport("options", opts_module);
    const z = b.addModule("z", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = false });
    z.addImport("options", opts_module);
    if (enable_log) z.addImport("logging", logging);
    // A component-only facade preserves z.log and shares the same logging module.
    const component = b.addModule("zzg-log", .{ .root_source_file = b.path("src/log_root.zig"), .target = target, .optimize = optimize, .link_libc = false });
    component.addImport("logging", logging);

    const empty = b.addExecutable(.{ .name = "no-log-consumer", .root_module = b.createModule(.{ .root_source_file = b.path("tests/no_log.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "z", .module = z }}, .link_libc = false }) });
    const filtered = b.addExecutable(.{ .name = "static-filter", .root_module = b.createModule(.{ .root_source_file = b.path("tests/static_filter.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "z", .module = component }, .{ .name = "options", .module = opts_module } }, .link_libc = false }) });
    b.step("filter-test", "Verify a compiled cutoff above info").dependOn(&b.addRunArtifact(filtered).step);
    const tests = b.addTest(.{ .root_module = logging });
    const test_step = b.step("test", "Run logging correctness tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const profile = if (optimize == .debug) "debug" else "release";
    const optimize_name = switch (optimize) {
        .debug => "Debug",
        .fast => "ReleaseFast",
        .safe => "ReleaseSafe",
        .small => "ReleaseSmall",
    };
    const external = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file" });
    external.addFileArg(b.path("tests/consumer/build.zig"));
    external.addArgs(&.{ "test", "--cache-dir", b.fmt("build/zig/{s}/consumer-cache", .{profile}), b.fmt("-Doptimize={s}", .{optimize_name}), "-j2" });
    external.setCwd(b.path("."));
    test_step.dependOn(&external.step);
    const check = b.step("check", "Check formatting and compile tests/consumers without running them");
    check.dependOn(&b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("examples"), b.path("tests") }, .check = true }).step);
    check.dependOn(&tests.step);
    check.dependOn(&empty.step);
    test_step.dependOn(&b.addRunArtifact(empty).step);
    const consumer = b.addExecutable(.{ .name = "zzg-consumer", .root_module = b.createModule(.{ .root_source_file = b.path("tests/consumer.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "z", .module = component }, .{ .name = "renamed", .module = component } }, .link_libc = false }) });
    check.dependOn(&consumer.step);
    test_step.dependOn(&b.addRunArtifact(consumer).step);
    const library = b.step("zzg", "Compile library tests and real consumption without execution");
    library.dependOn(&tests.step);
    library.dependOn(&consumer.step);
    b.default_step = library;
    const log_step = b.step("zzg-log", "Compile standalone log component consumption");
    log_step.dependOn(&consumer.step);
    inline for (.{ "logging", "benchmark", "scenario" }) |name| {
        const path = if (std.mem.eql(u8, name, "scenario")) "tests/scenario.zig" else "examples/" ++ name ++ ".zig";
        const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .imports = &.{.{ .name = "z", .module = component }}, .link_libc = false }) });
        const install = b.addInstallArtifact(exe, .{});
        b.step(name, "Build " ++ name).dependOn(&install.step);
        if (std.mem.eql(u8, name, "logging")) check.dependOn(&exe.step);
        if (std.mem.eql(u8, name, "scenario")) {
            inline for (.{ "sync", "async", "failure", "rotate", "periodic", "long", "metadata", "shutdown-race", "level-race", "level-shutdown", "important-only", "disabled" }) |mode| {
                const run = b.addRunArtifact(exe);
                run.addArg(mode);
                test_step.dependOn(&run.step);
            }
        }
    }
}
