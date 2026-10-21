const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single process owns the active file and its backups exclusively.
pub const FileSink = struct {
    allocator: Allocator,
    io: std.Io,
    paths: [][]const u8,
    file: ?std.Io.File = null,
    limit: usize,
    size: u64 = 0,
    offset: u64 = 0,
    buffer: [8192]u8 = undefined,
    used: usize = 0,

    pub fn init(a: Allocator, io: std.Io, path: []const u8, size_mb: usize, backups: usize, rotate_on_open: bool) !FileSink {
        const paths = try a.alloc([]const u8, backups + 1);
        var count: usize = 0;
        errdefer {
            for (paths[0..count]) |name| a.free(name);
            a.free(paths);
        }
        paths[0] = try a.dupe(u8, path);
        count += 1;
        const ext = std.fs.path.extension(path);
        for (paths[1..], 1..) |*name, i| {
            name.* = try a.print("{s}.{d}{s}", .{ path[0 .. path.len - ext.len], i, ext });
            count += 1;
        }
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        var sink: FileSink = .{ .allocator = a, .io = io, .paths = paths, .limit = size_mb * 1024 * 1024 };
        sink.file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        errdefer if (sink.file) |file| file.close(io);
        sink.size = (try sink.file.?.stat(io)).size;
        sink.offset = sink.size;
        if (rotate_on_open and sink.size > 0) try sink.rotate();
        return sink;
    }
    pub fn deinit(s: *FileSink) void {
        if (s.file) |file| file.close(s.io);
        for (s.paths) |path| s.allocator.free(path);
        s.allocator.free(s.paths);
        s.* = undefined;
    }
    pub fn flush(s: *FileSink) !void {
        const file = s.file orelse return error.OutputClosed;
        if (s.used == 0) return;
        // On a partial write failure disable this sink; never replay a prefix.
        file.writePositionalAll(s.io, s.buffer[0..s.used], s.offset) catch |err| {
            file.close(s.io);
            s.file = null;
            s.used = 0;
            return err;
        };
        s.offset += s.used;
        s.used = 0;
    }
    fn rotate(s: *FileSink) !void {
        try s.flush();
        s.file.?.close(s.io);
        s.file = null;
        var i = s.paths.len - 1;
        while (i > 0) : (i -= 1) {
            std.Io.Dir.cwd().rename(s.paths[i - 1], .cwd(), s.paths[i], s.io) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        s.file = try std.Io.Dir.cwd().createFile(s.io, s.paths[0], .{ .truncate = true });
        s.size = 0;
        s.offset = 0;
    }
    pub fn write(s: *FileSink, bytes: []const u8) !void {
        if (s.file == null) return error.OutputClosed;
        if (s.size > 0 and (s.size >= s.limit or bytes.len > s.limit - s.size)) try s.rotate();
        var remaining = bytes;
        while (remaining.len > 0) {
            const n = @min(remaining.len, s.buffer.len - s.used);
            @memcpy(s.buffer[s.used..][0..n], remaining[0..n]);
            s.used += n;
            remaining = remaining[n..];
            if (s.used == s.buffer.len) try s.flush();
        }
        s.size += bytes.len;
    }
};
