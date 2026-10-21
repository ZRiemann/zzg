const std = @import("std");
const z = @import("z");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var loaded: ?z.log.LoadedConfig = null;
    defer if (loaded) |*cfg| cfg.deinit();
    if (args.len != 1 and args.len != 3) return error.ExpectedConfigPathAndSection;
    var diagnostic: z.log.Diagnostic = .{};
    if (args.len == 3) loaded = z.log.fromZppFile(init.gpa, init.io, args[1], args[2], &diagnostic) catch |err| {
        std.debug.print("{s}: {s}\n", .{ diagnostic.path(), diagnostic.reason });
        return err;
    };
    const guard = try z.log.init(init.gpa, init.io, init.environ_map, if (loaded) |cfg| cfg.value else .{});
    defer guard.deinit();
    z.log.trace(@src(), "[example:scalar] signed={d} unsigned={d} float={d:.3} bool={}", .{ @as(i64, -42), @as(u64, 42), @as(f64, 3.14159), true });
    z.log.debug(@src(), "[example:composite] values={any}", .{[_]u16{ 1, 2, 3 }});
    z.log.info(@src(), "[example:text] hello {s}", .{"ZetaX 世界"});
    z.log.warn(@src(), "[example:levels] demonstration warning", .{});
    z.log.err(@src(), "[example:levels] demonstration error", .{});
    z.log.critical(@src(), "[example:levels] demonstration critical", .{});
    z.log.important(@src(), "[example:ready] ready", .{});
    try guard.shutdown();
}
