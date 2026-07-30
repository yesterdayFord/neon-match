const std = @import("std");
const engine = @import("engine.zig");

const magic = "NMJ1";
const version: u8 = 1;
const header_len = 14;
const submit_limit_payload_len = 25;
const cancel_payload_len = 8;

pub const default_dir = "journal";

pub const RecordKind = enum(u8) {
    submit_limit = 1,
    cancel = 2,
};

pub const Record = union(RecordKind) {
    submit_limit: engine.Order,
    cancel: engine.OrderId,
};

pub const Segment = struct {
    io: std.Io,
    file: std.Io.File,
    path: [max_segment_path_len]u8,
    path_len: usize,

    const max_segment_path_len = std.Io.Dir.max_path_bytes;

    pub fn open(io: std.Io, journal_dir: []const u8) !Segment {
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, journal_dir, .{});
        defer dir.close(io);

        var timestamp_buffer: [16]u8 = undefined;
        const timestamp = formatUtcTimestamp(&timestamp_buffer, std.Io.Timestamp.now(io, .real));

        var filename_buffer: [40]u8 = undefined;
        var sequence: u32 = 1;
        while (sequence <= 999999) : (sequence += 1) {
            const filename = try std.fmt.bufPrint(
                &filename_buffer,
                "journal-{s}-{d:0>6}.nmj",
                .{ timestamp, sequence },
            );
            const file = dir.createFile(io, filename, .{
                .truncate = false,
                .exclusive = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };

            var path_buffer: [max_segment_path_len]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ journal_dir, filename });
            return .{
                .io = io,
                .file = file,
                .path = path_buffer,
                .path_len = path.len,
            };
        }

        return error.JournalSegmentSequenceExhausted;
    }

    pub fn close(self: *Segment) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn segmentPath(self: *const Segment) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn appendSubmitLimit(self: *Segment, order: engine.Order) !void {
        var payload: [submit_limit_payload_len]u8 = undefined;
        payload[0] = switch (order.side) {
            .buy => 1,
            .sell => 2,
        };
        std.mem.writeInt(u64, payload[1..9], order.id, .little);
        std.mem.writeInt(u64, payload[9..17], order.price, .little);
        std.mem.writeInt(u64, payload[17..25], order.quantity, .little);
        try self.appendRecord(.submit_limit, &payload);
    }

    pub fn appendCancel(self: *Segment, id: engine.OrderId) !void {
        var payload: [cancel_payload_len]u8 = undefined;
        std.mem.writeInt(u64, &payload, id, .little);
        try self.appendRecord(.cancel, &payload);
    }

    // Appending means the complete record was accepted by the OS-managed file
    // path. It is not a per-command stable-storage sync.
    fn appendRecord(self: *Segment, kind: RecordKind, payload: []const u8) !void {
        var header: [header_len]u8 = undefined;
        @memcpy(header[0..4], magic);
        header[4] = version;
        header[5] = @backingInt(kind);
        std.mem.writeInt(u32, header[6..10], @intCast(payload.len), .little);
        std.mem.writeInt(u32, header[10..14], std.hash.Crc32.hash(payload), .little);

        try self.file.writeStreamingAll(self.io, &header);
        try self.file.writeStreamingAll(self.io, payload);
    }
};

pub const Reader = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    size: u64,

    pub fn open(io: std.Io, path: []const u8) !Reader {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        const stat = try file.stat(io);
        return .{
            .io = io,
            .file = file,
            .size = stat.size,
        };
    }

    pub fn close(self: *Reader) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn next(self: *Reader) !?Record {
        const remaining = self.size - self.offset;
        if (remaining == 0) return null;
        if (remaining < header_len) return null;

        var header: [header_len]u8 = undefined;
        try self.readExact(&header);

        if (!std.mem.eql(u8, header[0..4], magic)) return error.InvalidJournalMagic;
        if (header[4] != version) return error.UnsupportedJournalVersion;

        const kind: RecordKind = switch (header[5]) {
            @backingInt(RecordKind.submit_limit) => .submit_limit,
            @backingInt(RecordKind.cancel) => .cancel,
            else => return error.InvalidJournalRecordKind,
        };
        const payload_len = std.mem.readInt(u32, header[6..10], .little);
        const checksum = std.mem.readInt(u32, header[10..14], .little);
        const expected_len: u32 = switch (kind) {
            .submit_limit => submit_limit_payload_len,
            .cancel => cancel_payload_len,
        };
        if (payload_len != expected_len) return error.InvalidJournalRecordLength;

        if (self.size - self.offset < payload_len) return null;

        var payload: [submit_limit_payload_len]u8 = undefined;
        const payload_slice = payload[0..payload_len];
        try self.readExact(payload_slice);
        if (std.hash.Crc32.hash(payload_slice) != checksum) return error.InvalidJournalChecksum;

        return switch (kind) {
            .submit_limit => .{ .submit_limit = try decodeSubmitLimit(payload_slice) },
            .cancel => .{ .cancel = std.mem.readInt(u64, payload_slice[0..8], .little) },
        };
    }

    fn readExact(self: *Reader, buffer: []u8) !void {
        const read_len = try self.file.readPositionalAll(self.io, buffer, self.offset);
        if (read_len != buffer.len) return error.TruncatedJournalRead;
        self.offset += read_len;
    }
};

fn decodeSubmitLimit(payload: []const u8) !engine.Order {
    return .{
        .side = switch (payload[0]) {
            1 => .buy,
            2 => .sell,
            else => return error.InvalidJournalSide,
        },
        .id = std.mem.readInt(u64, payload[1..9], .little),
        .price = std.mem.readInt(u64, payload[9..17], .little),
        .quantity = std.mem.readInt(u64, payload[17..25], .little),
    };
}

fn formatUtcTimestamp(buffer: *[16]u8, timestamp: std.Io.Timestamp) []const u8 {
    const seconds: u64 = @intCast(@max(timestamp.toSeconds(), 0));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    ) catch unreachable;
}

test "formats UTC segment timestamps" {
    var buffer: [16]u8 = undefined;
    const ts = std.Io.Timestamp.fromNanoseconds(1785375900 * std.time.ns_per_s);
    try std.testing.expectEqualStrings("20260730T014500Z", formatUtcTimestamp(&buffer, ts));
}

test "segment appends command records in a temporary directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    var segment = try Segment.open(io, journal_dir);
    const path = segment.segmentPath();
    try std.testing.expect(std.mem.endsWith(u8, path, ".nmj"));
    try std.testing.expect(std.mem.startsWith(u8, path, journal_dir));
    try segment.appendSubmitLimit(.{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    try segment.appendCancel(1);
    segment.close();

    var it = tmp.dir.iterate();
    const entry = (try it.next(io)) orelse return error.MissingJournalSegment;
    try std.testing.expectEqual(std.Io.File.Kind.file, entry.kind);
    try std.testing.expect(std.mem.startsWith(u8, entry.name, "journal-"));
    try std.testing.expect(std.mem.endsWith(u8, entry.name, ".nmj"));
    try std.testing.expect((try it.next(io)) == null);

    var file = try tmp.dir.openFile(io, entry.name, .{});
    defer file.close(io);

    var bytes: [header_len + submit_limit_payload_len + header_len + cancel_payload_len]u8 = undefined;
    const read_len = try file.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqual(bytes.len, read_len);
    try std.testing.expectEqualStrings(magic, bytes[0..4]);
    try std.testing.expectEqual(version, bytes[4]);
    try std.testing.expectEqual(@backingInt(RecordKind.submit_limit), bytes[5]);
    try std.testing.expectEqual(@as(u32, submit_limit_payload_len), std.mem.readInt(u32, bytes[6..10], .little));
    try std.testing.expectEqual(std.hash.Crc32.hash(bytes[header_len .. header_len + submit_limit_payload_len]), std.mem.readInt(u32, bytes[10..14], .little));

    const second_header = header_len + submit_limit_payload_len;
    try std.testing.expectEqualStrings(magic, bytes[second_header .. second_header + 4]);
    try std.testing.expectEqual(@backingInt(RecordKind.cancel), bytes[second_header + 5]);
    try std.testing.expectEqual(@as(u32, cancel_payload_len), std.mem.readInt(u32, bytes[second_header + 6 .. second_header + 10], .little));
}

test "reader decodes valid command records" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    var segment = try Segment.open(io, journal_dir);
    const path_buffer = segment.path;
    const path_len = segment.path_len;
    try segment.appendSubmitLimit(.{ .id = 7, .side = .sell, .price = 101, .quantity = 3 });
    try segment.appendCancel(7);
    segment.close();

    var reader = try Reader.open(io, path_buffer[0..path_len]);
    defer reader.close();

    const first = (try reader.next()).?.submit_limit;
    try std.testing.expectEqual(engine.Side.sell, first.side);
    try std.testing.expectEqual(@as(engine.OrderId, 7), first.id);
    try std.testing.expectEqual(@as(engine.Price, 101), first.price);
    try std.testing.expectEqual(@as(engine.Quantity, 3), first.quantity);
    try std.testing.expectEqual(@as(engine.OrderId, 7), (try reader.next()).?.cancel);
    try std.testing.expect((try reader.next()) == null);
}

test "reader treats only an incomplete final record as a recoverable tail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [header_len + cancel_payload_len + 3]u8 = undefined;
    encodeCancelRecord(bytes[0 .. header_len + cancel_payload_len], 9);
    @memcpy(bytes[header_len + cancel_payload_len ..], "NMJ");
    try tmp.dir.writeFile(io, .{ .sub_path = "tail.nmj", .data = &bytes });
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/tail.nmj", .{tmp.sub_path[0..]});
    var reader = try Reader.open(io, path);
    defer reader.close();
    try std.testing.expectEqual(@as(engine.OrderId, 9), (try reader.next()).?.cancel);
    try std.testing.expect((try reader.next()) == null);
}

test "reader rejects corruption before the final record" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [(header_len + cancel_payload_len) * 2]u8 = undefined;
    encodeCancelRecord(bytes[0 .. header_len + cancel_payload_len], 9);
    std.mem.writeInt(u32, bytes[10..14], 0, .little);
    encodeCancelRecord(bytes[header_len + cancel_payload_len ..], 10);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.nmj", .data = &bytes });

    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/bad.nmj", .{tmp.sub_path[0..]});
    var reader = try Reader.open(io, path);
    defer reader.close();
    try std.testing.expectError(error.InvalidJournalChecksum, reader.next());
}

fn encodeCancelRecord(buffer: []u8, id: engine.OrderId) void {
    std.debug.assert(buffer.len == header_len + cancel_payload_len);
    @memcpy(buffer[0..4], magic);
    buffer[4] = version;
    buffer[5] = @backingInt(RecordKind.cancel);
    std.mem.writeInt(u32, buffer[6..10], cancel_payload_len, .little);
    std.mem.writeInt(u64, buffer[header_len .. header_len + cancel_payload_len], id, .little);
    std.mem.writeInt(u32, buffer[10..14], std.hash.Crc32.hash(buffer[header_len .. header_len + cancel_payload_len]), .little);
}
