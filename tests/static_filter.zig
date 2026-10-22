const std = @import("std");
const z = @import("z");
const options = @import("options");
pub fn main(init: std.process.Init) !void {
    if (options.active_level <= 2) return error.ExpectedInfoCompiledOut;
    var env = std.process.Environ.Map.init(init.gpa);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    // An invalid stdout handle is unnecessary: console routing alone makes an
    // unfiltered info record eligible, while compiled filters still reject it.
    const guard = try z.log.init(init.gpa, init.io, &env, .{ .console = true, .flush_interval_sec = 0 });
    defer guard.deinit();
    if (z.log.enabled(.info) or z.log.importantEnabled()) return error.CompiledFilterIgnored;
    z.log.info(@src(), "invalid format {never-analyzed}", .{});
    z.log.important(@src(), "invalid format {never-analyzed}", .{});
    try guard.shutdown();
}
