const std = @import("std");

pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warn,
    err,
    critical,
    off,

    pub fn accepts(self: Level, severity: Level) bool {
        return severity != .off and @backingInt(severity) >= @backingInt(self);
    }
    pub fn parse(value: []const u8) !Level {
        inline for (@typeInfo(Level).@"enum".field_names) |name| {
            if (std.mem.eql(u8, value, name)) return @field(Level, name);
        }
        if (std.mem.eql(u8, value, "warning")) return .warn;
        if (std.mem.eql(u8, value, "error")) return .err;
        return error.InvalidLevel;
    }
    pub fn text(self: Level) []const u8 {
        return switch (self) {
            .warn => "warning",
            .err => "error",
            else => @tagName(self),
        };
    }
    pub fn json(self: Level) []const u8 {
        return if (self == .err) "error" else @tagName(self);
    }
    pub fn short(self: Level) u8 {
        return "TDIWECO"[@backingInt(self)];
    }
};
pub const SinkFormat = enum { pattern, jsonl };
pub const default_pattern = "%d %H:%M:%S.%f %t %^%L%$: %v\t%g:%#";
pub const ImportantConfig = struct {
    enabled: bool = false,
    name: []const u8 = "",
    max_size: usize = 32,
    rotats: usize = 3,
    rotate_on_open: bool = true,
    level: Level = .warn,
    format: SinkFormat = .jsonl,
    pattern: []const u8 = "",
};
pub const Config = struct {
    async: bool = false,
    console: bool = true,
    rotating_file: bool = false,
    name: []const u8 = "server.log",
    max_size: usize = 32,
    rotats: usize = 3,
    rotate_on_open: bool = true,
    queue_size: usize = 8192,
    flush_interval_sec: u32 = 2,
    level: Level = .trace,
    flush_level: Level = .warn,
    logger_name: []const u8 = "zpp",
    pattern: []const u8 = default_pattern,
    service: []const u8 = "",
    node: []const u8 = "",
    run_id: []const u8 = "",
    important: ImportantConfig = .{},
};

/// Diagnostic storage belongs to the caller, including on parser failure.
pub const Diagnostic = struct {
    field: [256]u8 = undefined,
    length: usize = 0,
    reason: []const u8 = "",
    pub fn path(self: *const Diagnostic) []const u8 {
        return self.field[0..self.length];
    }
    pub fn fail(self: *Diagnostic, field: []const u8, reason: []const u8) error{InvalidConfig} {
        self.length = @min(field.len, self.field.len);
        @memcpy(self.field[0..self.length], field[0..self.length]);
        self.reason = reason;
        return error.InvalidConfig;
    }
};
