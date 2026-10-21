const std = @import("std");
const t = @import("types.zig");
const time = @import("time.zig");

pub const Record = struct {
    level: t.Level,
    seconds: i64,
    micros: u32,
    tid: u64,
    source: std.lang.SourceLocation,
    message: []const u8,
    runtime: bool,
    important: bool,
};
const Op = union(enum) { literal: []const u8, flag: u8 };
pub const Pattern = struct {
    allocator: std.mem.Allocator,
    ops: []Op,
    pub fn compile(a: std.mem.Allocator, input: []const u8) !Pattern {
        const pattern = if (input.len == 0) t.default_pattern else input;
        var ops: std.ArrayList(Op) = .empty;
        errdefer ops.deinit(a);
        var i: usize = 0;
        while (i < pattern.len) {
            const start = i;
            while (i < pattern.len and pattern[i] != '%') : (i += 1) {}
            if (i > start) try ops.append(a, .{ .literal = pattern[start..i] });
            if (i == pattern.len) break;
            i += 1;
            if (i == pattern.len or std.mem.indexOfScalar(u8, "%YmdHMSeftPlLnvs g#!^$", pattern[i]) == null or pattern[i] == ' ') return error.UnsupportedPattern;
            try ops.append(a, .{ .flag = pattern[i] });
            i += 1;
        }
        return .{ .allocator = a, .ops = try ops.toOwnedSlice(a) };
    }
    pub fn deinit(p: *Pattern) void {
        p.allocator.free(p.ops);
    }
    pub fn render(p: Pattern, w: *std.Io.Writer, record: Record, cfg: t.Config, local: time.Calendar, pid: u32, color: bool) !void {
        for (p.ops) |op| switch (op) {
            .literal => |bytes| try w.writeAll(bytes),
            .flag => |flag| switch (flag) {
                '%' => try w.writeByte('%'),
                'Y' => try writeYear(w, local.year),
                'm' => try w.print("{d:0>2}", .{local.month}),
                'd' => try w.print("{d:0>2}", .{local.day}),
                'H' => try w.print("{d:0>2}", .{local.hour}),
                'M' => try w.print("{d:0>2}", .{local.minute}),
                'S' => try w.print("{d:0>2}", .{local.second}),
                'e' => try w.print("{d:0>3}", .{local.microsecond / 1000}),
                'f' => try w.print("{d:0>6}", .{local.microsecond}),
                't' => try w.print("{d:0>2}", .{record.tid}),
                'P' => try w.print("{d}", .{pid}),
                'l' => try w.writeAll(record.level.text()),
                'L' => try w.writeByte(record.level.short()),
                'n' => try w.writeAll(cfg.logger_name),
                'v' => try w.writeAll(record.message),
                's' => try w.writeAll(std.fs.path.basename(record.source.file)),
                'g' => try w.writeAll(record.source.file),
                '#' => try w.print("{d}", .{record.source.line}),
                '!' => try w.writeAll(record.source.fn_name),
                '^' => if (color) {
                    try w.writeAll(switch (record.level) {
                        .warn => "\x1b[33m",
                        .err, .critical => "\x1b[31m",
                        .debug, .trace => "\x1b[36m",
                        else => "\x1b[32m",
                    });
                },
                '$' => if (color) {
                    try w.writeAll("\x1b[0m");
                },
                else => unreachable,
            },
        };
        if (color) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
    }
};
fn writeYear(w: *std.Io.Writer, year: i32) !void {
    if (year < 0) try w.writeByte('-');
    try w.print("{d:0>4}", .{@abs(year)});
}
fn quoted(w: *std.Io.Writer, bytes: []const u8, comptime dots: bool) !void {
    try w.writeByte('"');
    const valid_utf8 = std.unicode.utf8ValidateSlice(bytes);
    for (bytes) |original| {
        const byte = if (dots and original == ':') '.' else original;
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (byte < 32 or (!valid_utf8 and byte >= 128)) {
                try w.print("\\u00{x:0>2}", .{byte});
            } else {
                try w.writeByte(byte);
            },
        }
    }
    try w.writeByte('"');
}
fn field(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try w.print(",\"{s}\":", .{key});
    try quoted(w, value, false);
}
const Tags = struct { component: []const u8 = "", action: []const u8 = "" };
fn tags(message: []const u8) Tags {
    if (message.len == 0 or message[0] != '[') return .{};
    const end = std.mem.indexOfScalar(u8, message, ']') orelse return .{};
    const body = message[1..end];
    const split = std.mem.lastIndexOfScalar(u8, body, ':') orelse return .{};
    if (split == 0 or split + 1 == body.len) return .{};
    for (body, 0..) |byte, i| {
        if (std.ascii.isWhitespace(byte) or byte == '[' or (byte == ':' and (i == 0 or body[i - 1] == ':'))) return .{};
    }
    return .{ .component = body[0..split], .action = body[split + 1 ..] };
}
pub fn json(w: *std.Io.Writer, r: Record, cfg: t.Config, local: time.Calendar, pid: u32) !void {
    try w.writeAll("{\"ts\":\"");
    try writeYear(w, local.year);
    try w.print("-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}\"", .{ local.month, local.day, local.hour, local.minute, local.second, local.microsecond });
    try field(w, "level", r.level.json());
    try field(w, "logger", cfg.logger_name);
    try field(w, "service", cfg.service);
    try field(w, "node", cfg.node);
    try field(w, "run_id", cfg.run_id);
    try w.print(",\"pid\":{d},\"tid\":{d}", .{ pid, r.tid });
    try field(w, "file", r.source.file);
    try w.print(",\"line\":{d}", .{r.source.line});
    try field(w, "function", r.source.fn_name);
    const tag = tags(r.message);
    try w.writeAll(",\"component\":");
    try quoted(w, tag.component, true);
    try field(w, "action", tag.action);
    try field(w, "message", r.message);
    try w.writeAll("}\n");
}

test "compiled default pattern and JSONL contract" {
    const a = std.testing.allocator;
    var p = try Pattern.compile(a, t.default_pattern);
    defer p.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const source: std.lang.SourceLocation = .{ .module = "test", .file = "src/main.zig", .fn_name = "main", .line = 42, .column = 1 };
    const r: Record = .{ .level = .warn, .seconds = 0, .micros = 123456, .tid = 7, .source = source, .message = "[nng:scope:ready] quote \"\n", .runtime = true, .important = true };
    const local = time.calendar(0, r.micros, 0);
    try p.render(&out.writer, r, .{}, local, 100, false);
    try std.testing.expectEqualStrings("01 00:00:00.123456 07 W: [nng:scope:ready] quote \"\n\tsrc/main.zig:42\n", out.written());
    out.writer.end = 0;
    try json(&out.writer, r, .{}, local, 100);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 14), parsed.value.object.count());
    try std.testing.expectEqualStrings("nng.scope", parsed.value.object.get("component").?.string);
    try std.testing.expectEqualStrings(r.message, parsed.value.object.get("message").?.string);
    try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("tid").?.integer);
    try std.testing.expectError(error.UnsupportedPattern, Pattern.compile(a, "%8v"));
}

test "all supported flags, file colors and invalid UTF-8 JSON" {
    var p = try Pattern.compile(std.testing.allocator, "%% %Y-%m-%d %H:%M:%S %e %f %t %P %l %L %n %s %g %# %! %^%v%$");
    defer p.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const source: std.lang.SourceLocation = .{ .module = "test", .file = "src/a.zig", .fn_name = "a", .line = 9, .column = 1 };
    var r: Record = .{ .level = .warn, .seconds = 0, .micros = 123456, .tid = 123, .source = source, .message = "payload", .runtime = true, .important = true };
    try p.render(&out.writer, r, .{}, time.calendar(0, r.micros, 28800), 42, false);
    try std.testing.expectEqualStrings("% 1970-01-01 08:00:00 123 123456 123 42 warning W zpp a.zig src/a.zig 9 a payload\n", out.written());
    out.writer.end = 0;
    r.message = "[bad\x01:tag] \xff\x00";
    try json(&out.writer, r, .{}, time.calendar(0, 0, 0), 42);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 14), parsed.value.object.count());
    for ([_][]const u8{ "%", "%q", "%-8v", "%+" }) |invalid_pattern| try std.testing.expectError(error.UnsupportedPattern, Pattern.compile(std.testing.allocator, invalid_pattern));
    for ([_][]const u8{ "plain", "[:action]", "[component:]", "[a::b]", "[a b:c]" }) |message| try std.testing.expectEqualStrings("", tags(message).component);
}
