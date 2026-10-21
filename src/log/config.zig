const std = @import("std");
const t = @import("types.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const LoadedConfig = struct {
    arena: std.heap.ArenaAllocator,
    value: t.Config,
    pub fn deinit(self: *LoadedConfig) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn fromSpdJson(allocator: Allocator, json: []const u8, diagnostic: *t.Diagnostic) !LoadedConfig {
    return parse(allocator, json, null, diagnostic);
}
pub fn fromZppFile(allocator: Allocator, io: std.Io, path: []const u8, section: []const u8, diagnostic: *t.Diagnostic) !LoadedConfig {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    return parse(allocator, bytes, section, diagnostic);
}
fn parse(allocator: Allocator, json: []const u8, section: ?[]const u8, d: *t.Diagnostic) !LoadedConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const document = std.json.parseFromSlice(Value, a, json, .{ .allocate = .alloc_always }) catch |err| return if (err == error.OutOfMemory) err else d.fail("spd", "invalid JSON");
    var value = document.value;
    var prefix: []const u8 = "spd";
    var cfg: t.Config = .{ .rotating_file = true };
    if (section) |name| {
        prefix = try a.print("{s}.spd", .{name});
        if (value != .object) return d.fail(name, "expected service object");
        value = value.object.get(name) orelse return d.fail(name, "missing service object");
        if (value != .object) return d.fail(name, "expected service object");
        value = value.object.get("spd") orelse return d.fail(prefix, "missing logging object");
        cfg.service = try a.dupe(u8, name);
    }
    try fields(t.Config, &cfg, value, prefix, a, d);
    if (cfg.important.enabled and cfg.important.name.len == 0)
        cfg.important.name = try a.print("{s}.important.jsonl", .{if (cfg.service.len == 0) "zpp" else cfg.service});
    if (cfg.flush_interval_sec == 0) return d.fail(try a.print("{s}.flush_interval_sec", .{prefix}), "must be positive in JSON");
    try validate(cfg, prefix, d);
    return .{ .arena = arena, .value = cfg };
}
fn fields(comptime T: type, out: *T, value: Value, prefix: []const u8, a: Allocator, d: *t.Diagnostic) !void {
    if (value != .object) return d.fail(prefix, "expected object");
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, Field| {
        // rotating_file is a programmatic switch, not part of zpp JSON.
        if (comptime !std.mem.eql(u8, name, "rotating_file")) {
            if (value.object.get(name)) |item| {
                const path = try a.print("{s}.{s}", .{ prefix, name });
                if (Field == t.ImportantConfig) {
                    try fields(Field, &@field(out, name), item, path, a, d);
                } else if (Field == bool) {
                    if (item != .bool) return d.fail(path, "expected boolean");
                    @field(out, name) = item.bool;
                } else if (Field == []const u8) {
                    if (item != .string) return d.fail(path, "expected string");
                    @field(out, name) = item.string;
                } else if (Field == t.Level) {
                    if (item != .string) return d.fail(path, "expected level string");
                    @field(out, name) = t.Level.parse(item.string) catch return d.fail(path, "invalid level");
                } else if (Field == t.SinkFormat) {
                    if (item != .string) return d.fail(path, "expected format string");
                    @field(out, name) = std.meta.stringToEnum(t.SinkFormat, item.string) orelse return d.fail(path, "expected pattern or jsonl");
                } else {
                    if (item != .integer or item.integer <= 0) return d.fail(path, "expected positive integer");
                    @field(out, name) = std.math.cast(Field, item.integer) orelse return d.fail(path, "integer overflow");
                }
            }
        }
    }
}
pub fn validate(cfg: t.Config, prefix: []const u8, d: *t.Diagnostic) !void {
    var buf: [256]u8 = undefined;
    inline for (.{ "max_size", "rotats", "queue_size" }) |name| {
        const n = @field(cfg, name);
        const max = if (comptime std.mem.eql(u8, name, "max_size")) std.math.maxInt(usize) / (1024 * 1024) else std.math.maxInt(usize) / 2048;
        if (n == 0 or n > max) return d.fail(std.fmt.bufPrint(&buf, "{s}.{s}", .{ prefix, name }) catch prefix, "invalid capacity");
    }
    if (cfg.important.max_size == 0 or cfg.important.max_size > std.math.maxInt(usize) / (1024 * 1024)) return d.fail(std.fmt.bufPrint(&buf, "{s}.important.max_size", .{prefix}) catch prefix, "invalid capacity");
    if (cfg.important.rotats == 0 or cfg.important.rotats == std.math.maxInt(usize)) return d.fail(std.fmt.bufPrint(&buf, "{s}.important.rotats", .{prefix}) catch prefix, "invalid capacity");
    if (cfg.rotating_file and cfg.name.len == 0) return d.fail(std.fmt.bufPrint(&buf, "{s}.name", .{prefix}) catch prefix, "enabled file requires a name");
}

/// Expand each original token once. Environment values are never reparsed.
pub fn expandPath(a: Allocator, path: []const u8, env: *const std.process.Environ.Map) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var i: usize = 0;
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = env.get("HOME") orelse return error.UndefinedEnvironment;
        if (home.len == 0) return error.UndefinedEnvironment;
        try out.writer.writeAll(home);
        i = 1;
    }
    while (i < path.len) {
        if (path[i] != '$' or i + 1 == path.len) {
            try out.writer.writeByte(path[i]);
            i += 1;
            continue;
        }
        const start = i + 1;
        var end = start;
        var next: usize = undefined;
        var name: []const u8 = undefined;
        if (path[start] == '{') {
            end = std.mem.indexOfScalarPos(u8, path, start + 1, '}') orelse {
                try out.writer.writeByte('$');
                i += 1;
                continue;
            };
            name = path[start + 1 .. end];
            next = end + 1;
        } else {
            while (end < path.len and (std.ascii.isAlphanumeric(path[end]) or path[end] == '_')) : (end += 1) {}
            if (end == start) {
                try out.writer.writeByte('$');
                i += 1;
                continue;
            }
            name = path[start..end];
            next = end;
        }
        const replacement = env.get(name) orelse return error.UndefinedEnvironment;
        try out.writer.writeAll(replacement);
        i = next;
    }
    return out.toOwnedSlice();
}

test "configuration contract and diagnostics" {
    var d: t.Diagnostic = .{};
    var loaded = try fromSpdJson(std.testing.allocator, "{\"async\":true,\"level\":\"warning\",\"important\":{\"enabled\":true},\"unrelated\":1}", &d);
    defer loaded.deinit();
    try std.testing.expect(loaded.value.async and loaded.value.rotating_file);
    try std.testing.expectEqual(t.Level.warn, loaded.value.level);
    try std.testing.expectEqualStrings("zpp.important.jsonl", loaded.value.important.name);
    try std.testing.expectError(error.InvalidConfig, fromSpdJson(std.testing.allocator, "{\"queue_size\":0}", &d));
    try std.testing.expectEqualStrings("spd.queue_size", d.path());
    try std.testing.expectError(error.InvalidConfig, fromSpdJson(std.testing.allocator, "{\"important\":{\"format\":\"bad\"}}", &d));
    try std.testing.expectEqualStrings("spd.important.format", d.path());
}
test "single path expansion" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/$UNCHANGED");
    try env.put("NAME", "test");
    const path = try expandPath(std.testing.allocator, "~/${NAME}/$NAME.log", &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/$UNCHANGED/test/test.log", path);
    try std.testing.expectError(error.UndefinedEnvironment, expandPath(std.testing.allocator, "$MISSING", &env));
}

test "unified configuration, strict types, units and defaults" {
    var d: t.Diagnostic = .{};
    var loaded = try parse(std.testing.allocator, "{\"service\":{\"spd\":{\"name\":\"x.log\",\"max_size\":2,\"rotats\":5,\"important\":{\"enabled\":true}}}}", "service", &d);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("service", loaded.value.service);
    try std.testing.expectEqualStrings("service.important.jsonl", loaded.value.important.name);
    try std.testing.expectEqual(@as(usize, 2), loaded.value.max_size);
    try std.testing.expectEqual(@as(usize, 5), loaded.value.rotats);
    for ([_][]const u8{ "[]", "{\"console\":1}", "{\"name\":null}", "{\"level\":\"INFO\"}", "{\"max_size\":-1}", "{\"rotats\":1.5}", "{\"flush_interval_sec\":0}", "{\"queue_size\":18446744073709551616}", "{\"important\":[]}" }) |json| {
        try std.testing.expectError(error.InvalidConfig, fromSpdJson(std.testing.allocator, json, &d));
        try std.testing.expect(d.path().len > 0);
    }
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "{}", "missing", &d));
    try std.testing.expectEqualStrings("missing", d.path());
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "{\"server\":{}}", "server", &d));
    try std.testing.expectEqualStrings("server.spd", d.path());
    try validate(.{ .flush_interval_sec = 0 }, "spd", &d);
    try std.testing.expectError(error.InvalidConfig, validate(.{ .max_size = std.math.maxInt(usize) }, "spd", &d));
}

fn allocationProbe(a: Allocator) !void {
    var d: t.Diagnostic = .{};
    var loaded = try fromSpdJson(a, "{\"service\":\"probe\",\"important\":{\"enabled\":true,\"name\":\"\"}}", &d);
    defer loaded.deinit();
}
test "configuration allocation failures do not leak or mask OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
