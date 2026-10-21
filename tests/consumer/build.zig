const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zzg", .{ .target = target, .optimize = optimize, .log = true });
    const exe = b.addExecutable(.{ .name = "external-consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "z", .module = dep.module("z") }, .{ .name = "independent", .module = dep.module("zzg-log") } },
        .link_libc = false,
    }) });
    b.step("test", "Verify external package and component share state").dependOn(&b.addRunArtifact(exe).step);
}
