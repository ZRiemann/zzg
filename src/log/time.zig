//! Linux local calendar time without libc. TZ data is immutable after init.
const std = @import("std");
const Allocator = std.mem.Allocator;
const invalid = error.InvalidTimezone;

pub const Calendar = struct { year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8, microsecond: u32 };

/// One immutable Zone per cache; its Runtime serializes all access.
pub const CalendarCache = struct {
    seconds: ?i64 = null,
    value: Calendar = undefined,
    conversions: if (@import("builtin").is_test) usize else void = if (@import("builtin").is_test) 0 else {},

    pub fn get(c: *CalendarCache, zone: *const Zone, seconds: i64) Calendar {
        if (c.seconds == null or c.seconds.? != seconds) {
            c.value = zone.local(seconds, 0);
            c.seconds = seconds;
            if (@import("builtin").is_test) c.conversions += 1;
        }
        return c.value;
    }
};

pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = @as(i64, month) + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * m + 2, 5) + day - 1;
    return era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
}
pub fn calendar(seconds: i64, micros: u32, offset: i32) Calendar {
    const local = seconds + offset;
    const z = @divFloor(local, 86400) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const month = mp + @as(i64, if (mp < 10) 3 else -9);
    const tod = @mod(local, 86400);
    return .{ .year = @intCast(yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0)), .month = @intCast(month), .day = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1), .hour = @intCast(@divTrunc(tod, 3600)), .minute = @intCast(@divTrunc(@mod(tod, 3600), 60)), .second = @intCast(@mod(tod, 60)), .microsecond = micros };
}
fn leap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}
const Rule = struct {
    kind: enum { julian, ordinal, month },
    a: u16,
    b: u8 = 0,
    c: u8 = 0,
    seconds: i32 = 7200,
    fn transition(self: Rule, year: i32, prior_offset: i32) i64 {
        var day: i64 = self.a;
        switch (self.kind) {
            .ordinal => {},
            .julian => {
                day -= 1;
                if (leap(year) and self.a >= 60) day += 1;
            },
            .month => {
                const month: u8 = @intCast(self.a);
                const first = daysFromCivil(year, month, 1);
                const weekday = @mod(first + 4, 7);
                var dom = @mod(@as(i64, self.c) - weekday, 7) + 1 + 7 * (@as(i64, self.b) - 1);
                const next = if (month == 12) daysFromCivil(year + 1, 1, 1) else daysFromCivil(year, month + 1, 1);
                if (dom > next - first) dom -= 7;
                day = first - daysFromCivil(year, 1, 1) + dom - 1;
            },
        }
        return (daysFromCivil(year, 1, 1) + day) * 86400 + self.seconds - prior_offset;
    }
};
pub const Posix = struct {
    standard: i32,
    daylight: ?i32 = null,
    start: Rule = undefined,
    end: Rule = undefined,
    pub fn parse(text: []const u8) !Posix {
        var p: Parser = .{ .text = text };
        try p.name();
        const standard = -(try p.hms(24));
        var result: Posix = .{ .standard = standard };
        if (p.done()) return result;
        try p.name();
        result.daylight = if (p.peek() != ',') -(try p.hms(24)) else standard + 3600;
        try p.take(',');
        result.start = try p.rule();
        try p.take(',');
        result.end = try p.rule();
        if (!p.done()) return invalid;
        return result;
    }
    pub fn offset(self: Posix, seconds: i64) i32 {
        const dst = self.daylight orelse return self.standard;
        const year = calendar(seconds, 0, self.standard).year;
        const start = self.start.transition(year, self.standard);
        const end = self.end.transition(year, dst);
        const active = if (start < end) seconds >= start and seconds < end else seconds >= start or seconds < end;
        return if (active) dst else self.standard;
    }
};
const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    fn done(p: Parser) bool {
        return p.pos == p.text.len;
    }
    fn peek(p: Parser) u8 {
        return if (p.done()) 0 else p.text[p.pos];
    }
    fn take(p: *Parser, byte: u8) !void {
        if (p.peek() != byte) return invalid;
        p.pos += 1;
    }
    fn number(p: *Parser, max: u32) !u32 {
        const start = p.pos;
        var n: u32 = 0;
        while (std.ascii.isDigit(p.peek())) : (p.pos += 1) {
            n = std.math.mul(u32, n, 10) catch return invalid;
            n = std.math.add(u32, n, p.peek() - '0') catch return invalid;
            if (n > max) return invalid;
        }
        if (p.pos == start) return invalid;
        return n;
    }
    fn name(p: *Parser) !void {
        const quoted = p.peek() == '<';
        if (quoted) p.pos += 1;
        const start = p.pos;
        while (std.ascii.isAlphabetic(p.peek()) or (quoted and (std.ascii.isDigit(p.peek()) or p.peek() == '+' or p.peek() == '-'))) p.pos += 1;
        if (p.pos - start < 3) return invalid;
        if (quoted) try p.take('>');
    }
    fn hms(p: *Parser, max_hour: u32) !i32 {
        var sign: i32 = 1;
        if (p.peek() == '-') {
            sign = -1;
            p.pos += 1;
        } else if (p.peek() == '+') p.pos += 1;
        var seconds = (try p.number(max_hour)) * 3600;
        if (p.peek() == ':') {
            p.pos += 1;
            seconds += (try p.number(59)) * 60;
            if (p.peek() == ':') {
                p.pos += 1;
                seconds += try p.number(59);
            }
        }
        return @as(i32, @intCast(seconds)) * sign;
    }
    fn rule(p: *Parser) !Rule {
        var r: Rule = undefined;
        if (p.peek() == 'M') {
            p.pos += 1;
            const month = try p.number(12);
            try p.take('.');
            const week = try p.number(5);
            try p.take('.');
            const weekday = try p.number(6);
            if (month == 0 or week == 0) return invalid;
            r = .{ .kind = .month, .a = @intCast(month), .b = @intCast(week), .c = @intCast(weekday) };
        } else if (p.peek() == 'J') {
            p.pos += 1;
            const n = try p.number(365);
            if (n == 0) return invalid;
            r = .{ .kind = .julian, .a = @intCast(n) };
        } else r = .{ .kind = .ordinal, .a = @intCast(try p.number(365)) };
        if (p.peek() == '/') {
            p.pos += 1;
            r.seconds = try p.hms(167);
        }
        return r;
    }
};
const LocalType = struct { offset: i32 };
pub const Zone = struct {
    allocator: Allocator,
    transitions: []i64 = &.{},
    indices: []u8 = &.{},
    types: []LocalType = &.{},
    future: ?Posix = null,
    pub fn utc(a: Allocator) Zone {
        return .{ .allocator = a, .future = .{ .standard = 0 } };
    }
    pub fn deinit(z: *Zone) void {
        z.allocator.free(z.transitions);
        z.allocator.free(z.indices);
        z.allocator.free(z.types);
        z.* = undefined;
    }
    pub fn load(a: Allocator, io: std.Io, env: *const std.process.Environ.Map) !Zone {
        var name: []const u8 = env.get("TZ") orelse "/etc/localtime";
        if (name.len == 0) return utc(a);
        if (name[0] == ':') name = name[1..];
        if (name.len == 0) return invalid;
        if (!std.fs.path.isAbsolute(name)) {
            if (Posix.parse(name)) |posix| return .{ .allocator = a, .future = posix } else |_| {}
        }
        const path = if (std.fs.path.isAbsolute(name)) try a.dupe(u8, name) else try std.fs.path.join(a, &.{ "/usr/share/zoneinfo", name });
        defer a.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        defer a.free(bytes);
        return parse(a, bytes);
    }
    pub fn offset(z: *const Zone, seconds: i64) i32 {
        if (z.transitions.len == 0 or seconds > z.transitions[z.transitions.len - 1]) {
            if (z.future) |future| return future.offset(seconds);
        }
        var lo: usize = 0;
        var hi = z.transitions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (z.transitions[mid] <= seconds) lo = mid + 1 else hi = mid;
        }
        return z.types[if (lo == 0) 0 else z.indices[lo - 1]].offset;
    }
    pub fn local(z: *const Zone, seconds: i64, micros: u32) Calendar {
        return calendar(seconds, micros, z.offset(seconds));
    }
    pub fn parse(a: Allocator, bytes: []const u8) !Zone {
        var cursor: usize = 0;
        var h = try Header.read(bytes, cursor);
        cursor += 44;
        var width: usize = 4;
        if (h.version != 0) {
            cursor = std.math.add(usize, cursor, try h.size(4)) catch return invalid;
            const first_version = h.version;
            h = try Header.read(bytes, cursor);
            if (h.version != first_version) return invalid;
            cursor += 44;
            width = 8;
        }
        const size = try h.size(width);
        if (cursor > bytes.len or size > bytes.len - cursor) return invalid;
        if (h.leaps != 0) return error.LeapSecondsUnsupported;
        var z: Zone = .{ .allocator = a };
        errdefer z.deinit();
        z.transitions = try a.alloc(i64, h.times);
        z.indices = try a.alloc(u8, h.times);
        z.types = try a.alloc(LocalType, h.types);
        for (z.transitions, 0..) |*entry, i| {
            entry.* = if (width == 8) std.mem.readInt(i64, bytes[cursor..][0..8], .big) else std.mem.readInt(i32, bytes[cursor..][0..4], .big);
            cursor += width;
            if (i > 0 and entry.* <= z.transitions[i - 1]) return invalid;
        }
        @memcpy(z.indices, bytes[cursor..][0..h.times]);
        cursor += h.times;
        for (z.indices) |index| if (index >= h.types) return invalid;
        const types_start = cursor;
        for (z.types) |*entry| {
            entry.offset = std.mem.readInt(i32, bytes[cursor..][0..4], .big);
            if (entry.offset < -89999 or entry.offset > 93599 or bytes[cursor + 4] > 1 or bytes[cursor + 5] >= h.chars) return invalid;
            cursor += 6;
        }
        const names = bytes[cursor..][0..h.chars];
        for (z.types, 0..) |_, i| if (std.mem.indexOfScalar(u8, names[bytes[types_start + i * 6 + 5]..], 0) == null) return invalid;
        cursor += h.chars;
        for (bytes[cursor..][0 .. h.standard + h.ut]) |flag| if (flag > 1) return invalid;
        cursor += h.standard + h.ut;
        if (h.version == 0) {
            if (cursor != bytes.len) return invalid;
            return z;
        }
        if (bytes.len - cursor < 2 or bytes[cursor] != '\n' or bytes[bytes.len - 1] != '\n') return invalid;
        const footer = bytes[cursor + 1 .. bytes.len - 1];
        if (footer.len > 0) z.future = try Posix.parse(footer);
        return z;
    }
};
const Header = struct {
    version: u8,
    ut: usize,
    standard: usize,
    leaps: usize,
    times: usize,
    types: usize,
    chars: usize,
    fn read(bytes: []const u8, pos: usize) !Header {
        if (pos > bytes.len or bytes.len - pos < 44) return invalid;
        const b = bytes[pos..][0..44];
        if (!std.mem.eql(u8, b[0..4], "TZif") or (b[4] != 0 and (b[4] < '2' or b[4] > '4'))) return invalid;
        const h: Header = .{ .version = b[4], .ut = u32At(b, 20), .standard = u32At(b, 24), .leaps = u32At(b, 28), .times = u32At(b, 32), .types = u32At(b, 36), .chars = u32At(b, 40) };
        if (h.types == 0 or h.types > 256 or h.chars == 0 or (h.ut != 0 and h.ut != h.types) or (h.standard != 0 and h.standard != h.types)) return invalid;
        if (h.leaps != 0) return error.LeapSecondsUnsupported;
        return h;
    }
    fn size(h: Header, width: usize) !usize {
        // Input counts are u32; compute in u64 before narrowing on 32-bit hosts.
        return std.math.cast(usize, @as(u64, h.times) * (width + 1) + @as(u64, h.types) * 6 + h.chars + @as(u64, h.leaps) * (width + 4) + h.standard + h.ut) orelse invalid;
    }
};
fn u32At(b: []const u8, pos: usize) u32 {
    return std.mem.readInt(u32, b[pos..][0..4], .big);
}

test "calendar and POSIX northern/southern future rules" {
    const expect = std.testing.expectEqual;
    try expect(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const before = calendar(-1, 999999, 0);
    try expect(@as(i32, 1969), before.year);
    try expect(@as(u8, 31), before.day);
    const china = try Posix.parse("CST-8");
    try expect(@as(i32, 28800), china.offset(0));
    const ny = try Posix.parse("EST5EDT,M3.2.0,M11.1.0");
    const spring = daysFromCivil(2050, 3, 13) * 86400 + 7 * 3600;
    try expect(@as(i32, -18000), ny.offset(spring - 1));
    try expect(@as(i32, -14400), ny.offset(spring));
    const au = try Posix.parse("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try expect(@as(i32, 39600), au.offset(daysFromCivil(2050, 1, 1) * 86400));
    try expect(@as(i32, 36000), au.offset(daysFromCivil(2050, 7, 1) * 86400));
    try std.testing.expectError(invalid, Posix.parse("EST5EDT"));
    _ = try Posix.parse("<+03>-3<+04>,J60/-2,300/26");
}
test "minimal TZif fixture and malformed boundaries" {
    var bytes: [54]u8 = @splat(0);
    @memcpy(bytes[0..4], "TZif");
    std.mem.writeInt(u32, bytes[36..40], 1, .big);
    std.mem.writeInt(u32, bytes[40..44], 4, .big);
    @memcpy(bytes[50..54], "UTC\x00");
    var zone = try Zone.parse(std.testing.allocator, &bytes);
    defer zone.deinit();
    try std.testing.expectEqual(@as(i32, 0), zone.offset(2208988800));
    try std.testing.expectError(invalid, Zone.parse(std.testing.allocator, bytes[0..53]));
    bytes[49] = 4;
    try std.testing.expectError(invalid, Zone.parse(std.testing.allocator, &bytes));
    bytes[49] = 0;
    bytes[31] = 1;
    try std.testing.expectError(error.LeapSecondsUnsupported, Zone.parse(std.testing.allocator, &bytes));
}

fn appendHeader(w: *std.Io.Writer, version: u8, transitions: u32) !void {
    var bytes: [44]u8 = @splat(0);
    @memcpy(bytes[0..4], "TZif");
    bytes[4] = version;
    std.mem.writeInt(u32, bytes[32..36], transitions, .big);
    std.mem.writeInt(u32, bytes[36..40], 1, .big);
    std.mem.writeInt(u32, bytes[40..44], 4, .big);
    try w.writeAll(&bytes);
}
fn fixture(a: Allocator, version: u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try appendHeader(&out.writer, version, 0);
    try out.writer.writeAll("\x00\x00\x70\x80\x00\x00CST\x00");
    try appendHeader(&out.writer, version, 1);
    var transition: [8]u8 = undefined;
    std.mem.writeInt(i64, &transition, 2208988800, .big);
    try out.writer.writeAll(&transition);
    try out.writer.writeByte(0);
    try out.writer.writeAll("\x00\x00\x70\x80\x00\x00CST\x00\nCST-8\n");
    return out.toOwnedSlice();
}
test "TZif v2-v4 64-bit table and future rule fixtures" {
    for ([_]u8{ '2', '3', '4' }) |version| {
        const bytes = try fixture(std.testing.allocator, version);
        defer std.testing.allocator.free(bytes);
        var zone = try Zone.parse(std.testing.allocator, bytes);
        defer zone.deinit();
        for ([_]i64{ -1, 2208988799, 2208988800, 4102444800 }) |epoch| try std.testing.expectEqual(@as(i32, 28800), zone.offset(epoch));
        for (0..bytes.len) |len| try std.testing.expectError(invalid, Zone.parse(std.testing.allocator, bytes[0..len]));
    }
}
test "POSIX Julian/ordinal, autumn fold and calendar boundaries" {
    const ny = try Posix.parse("EST5EDT,M3.2.0,M11.1.0");
    const fall = daysFromCivil(2050, 11, 6) * 86400 + 6 * 3600;
    try std.testing.expectEqual(@as(i32, -14400), ny.offset(fall - 1));
    try std.testing.expectEqual(@as(i32, -18000), ny.offset(fall));
    const julian = try Posix.parse("UTC0DST,J60/0,J300/0");
    const ordinal = try Posix.parse("UTC0DST,59/0,300/0");
    const feb29 = daysFromCivil(2024, 2, 29) * 86400;
    try std.testing.expectEqual(@as(i32, 0), julian.offset(feb29));
    try std.testing.expectEqual(@as(i32, 3600), ordinal.offset(feb29));
    for ([_]i32{ 1900, 1969, 1970, 2000, 2024, 2100, 2400 }) |year| {
        for (1..13) |month| {
            const c = calendar(daysFromCivil(year, @intCast(month), 1) * 86400, 0, 0);
            try std.testing.expectEqual(year, c.year);
            try std.testing.expectEqual(@as(u8, @intCast(month)), c.month);
            try std.testing.expectEqual(@as(u8, 1), c.day);
        }
    }
    for ([_][]const u8{ "A0", "ABC25", "ABC0DEF,M0.1.0,M11.1.0", "ABC0DEF,M3.0.0,M11.1.0", "ABC0DEF,J0,J300", "ABC0DEF,366,300", "ABC0DEF,M3.1.0/168,M10.1.0" }) |text| try std.testing.expectError(invalid, Posix.parse(text));
}
fn allocationProbe(a: Allocator, bytes: []const u8) !void {
    var zone = try Zone.parse(a, bytes);
    defer zone.deinit();
}
test "TZif allocation failures release all owned state" {
    const bytes = try fixture(std.testing.allocator, '4');
    defer std.testing.allocator.free(bytes);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{bytes});
}

test "calendar cache starts empty and reuses only the immediately preceding UTC second" {
    const zone = Zone.utc(std.testing.allocator);
    var cache: CalendarCache = .{};
    try std.testing.expectEqual(@as(?i64, null), cache.seconds);
    const seconds = [_]i64{ 0, 0, -1, -1, 86399, 86400, 100, 101, 100 };
    const conversions = [_]usize{ 1, 1, 2, 2, 3, 4, 5, 6, 7 };
    for (seconds, conversions) |epoch, count| {
        try std.testing.expectEqualDeep(zone.local(epoch, 0), cache.get(&zone, epoch));
        try std.testing.expectEqual(count, cache.conversions);
        try std.testing.expectEqual(@as(u32, 0), cache.value.microsecond);
    }
}

test "calendar cache follows fixed offsets and northern and southern future DST boundaries" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "UTC0", "CST-8", "EST5EDT,M3.2.0,M11.1.0", "AEST-10AEDT,M10.1.0,M4.1.0/3" }) |text| {
        const zone: Zone = .{ .allocator = a, .future = try Posix.parse(text) };
        var cache: CalendarCache = .{};
        const spring = daysFromCivil(2050, 3, 13) * 86400 + 7 * 3600;
        const fall = daysFromCivil(2050, 11, 6) * 86400 + 6 * 3600;
        const southern_start = if (zone.future.?.daylight != null) zone.future.?.start.transition(2050, zone.future.?.standard) else 0;
        const southern_end = if (zone.future.?.daylight) |dst| zone.future.?.end.transition(2050, dst) else 0;
        for ([_]i64{ -1, 0, spring - 1, spring, fall - 1, fall, southern_start - 1, southern_start, southern_end - 1, southern_end, 4102444800 }) |epoch| {
            const local = cache.get(&zone, epoch);
            try std.testing.expectEqualDeep(zone.local(epoch, 0), local);
            const count = cache.conversions;
            try std.testing.expectEqualDeep(local, cache.get(&zone, epoch));
            try std.testing.expectEqual(count, cache.conversions);
        }
    }
}

test "calendar cache follows a TZif offset transition and backward timestamps" {
    var bytes: [69]u8 = @splat(0);
    @memcpy(bytes[0..4], "TZif");
    std.mem.writeInt(u32, bytes[32..36], 1, .big);
    std.mem.writeInt(u32, bytes[36..40], 2, .big);
    std.mem.writeInt(u32, bytes[40..44], 8, .big);
    std.mem.writeInt(i32, bytes[44..48], 100, .big);
    bytes[48] = 1;
    std.mem.writeInt(i32, bytes[55..59], 3600, .big);
    bytes[59] = 1;
    bytes[60] = 4;
    @memcpy(bytes[61..69], "UTC\x00DST\x00");
    var zone = try Zone.parse(std.testing.allocator, &bytes);
    defer zone.deinit();
    var cache: CalendarCache = .{};
    for ([_]i64{ 99, 100, 101, 100, 99 }) |epoch| {
        const local = cache.get(&zone, epoch);
        try std.testing.expectEqualDeep(zone.local(epoch, 0), local);
        try std.testing.expectEqual(@as(u8, if (epoch < 100) 0 else 1), local.hour);
    }
    try std.testing.expectEqual(@as(usize, 5), cache.conversions);
}
