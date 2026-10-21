const std = @import("std");
const z = @import("z");
const renamed = @import("renamed");
pub fn main() !void {
    if (z.log.Config != renamed.log.Config or &z.log.init != &renamed.log.init) return error.DuplicateModule;
    if (z.log.enabled(.info)) return error.AcceptedBeforeInit;
    z.log.info(@src(), "before init {d}", .{1});
    _ = std;
}
