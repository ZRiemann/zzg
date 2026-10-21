const std = @import("std");
test "severity ordering" {
    const Level = @import("types.zig").Level;
    try std.testing.expect(Level.warn.accepts(.critical));
    try std.testing.expect(!Level.off.accepts(.critical));
    try std.testing.expect(!Level.trace.accepts(.off));
}

fn allocationProbe(a: std.mem.Allocator) !void {
    const Runtime = @import("runtime.zig").Runtime;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    const runtime = try Runtime.create(a, std.testing.io, &env, .{ .console = false, .flush_interval_sec = 0 });
    runtime.destroy();
}
test "runtime initialization unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
