//! Shared logging API. Source locations must be passed from the caller.
const std = @import("std");
const runtime = @import("log/runtime.zig");
const types = @import("log/types.zig");
pub const Config = types.Config;
pub const ImportantConfig = types.ImportantConfig;
pub const Level = types.Level;
pub const SinkFormat = types.SinkFormat;
pub const Diagnostic = types.Diagnostic;
pub const LogGuard = runtime.LogGuard;
pub const LoadedConfig = @import("log/config.zig").LoadedConfig;
pub const fromSpdJson = @import("log/config.zig").fromSpdJson;
pub const fromZppFile = @import("log/config.zig").fromZppFile;
pub const init = runtime.init;
pub const enabled = runtime.enabled;
pub const importantEnabled = runtime.importantEnabled;
pub const setLevel = runtime.setLevel;
pub fn trace(comptime src: std.lang.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    runtime.emit(.trace, false, src, fmt, args);
}
pub fn debug(comptime src: std.lang.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    runtime.emit(.debug, false, src, fmt, args);
}
pub fn info(comptime src: std.lang.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    runtime.emit(.info, false, src, fmt, args);
}
pub fn warn(comptime src: std.lang.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    runtime.emit(.warn, false, src, fmt, args);
}
pub fn err(comptime src: std.lang.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    runtime.emit(.err, false, src, fmt, args);
}
pub fn critical(comptime src: std.lang.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    runtime.emit(.critical, false, src, fmt, args);
}
pub fn important(comptime src: std.lang.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    runtime.emit(.info, true, src, fmt, args);
}
test {
    _ = @import("log/config.zig");
    _ = @import("log/time.zig");
    _ = @import("log/format.zig");
    _ = @import("log/runtime_test.zig");
    _ = runtime;
}
