const std = @import("std");
const z = @import("z");
const independent = @import("independent");
pub fn main(init: std.process.Init) !void {
    if (&z.log.init != &independent.log.init) return error.DuplicateRuntime;
    var env = std.process.Environ.Map.init(init.gpa);
    defer env.deinit();
    try env.put("TZ", "UTC0");
    const guard = try z.log.init(init.gpa, init.io, &env, .{ .console = false, .flush_interval_sec = 0 });
    defer guard.deinit();
    if (independent.log.init(init.gpa, init.io, &env, .{})) |_| return error.DuplicateRuntime else |err| {
        if (err != error.AlreadyInitialized) return err;
    }
    try guard.shutdown();
}
