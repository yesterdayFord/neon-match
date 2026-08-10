const std = @import("std");
const engine = @import("engine.zig");

const magic = "NMJ1";
const version: u8 = 2;
const header_len = 14;
const submit_limit_payload_len = 29;
const cancel_payload_len = 12;
const legacy_version: u8 = 1;
const legacy_submit_limit_payload_len = 25;
const legacy_cancel_payload_len = 8;
const legacy_default_instrument_id: InstrumentId = 1;

pub const default_dir = "journal";
pub const max_segment_number: u32 = 999999;

pub const RecordKind = enum(u8) {
    submit_limit = 1,
    cancel = 2,
};

pub const Record = union(RecordKind) {
    submit_limit: InstrumentedOrder,
    cancel: InstrumentedCancel,
};

pub const InstrumentId = u32;

pub const InstrumentedOrder = struct {
    instrument_id: InstrumentId,
    order: engine.Order,
};

pub const InstrumentedCancel = struct {
    instrument_id: InstrumentId,
    order_id: engine.OrderId,
};

pub const Segment = struct {
    io: std.Io,
    file: std.Io.File,
    path: [max_segment_path_len]u8,
    path_len: usize,

    const max_segment_path_len = std.Io.Dir.max_path_bytes;

    pub fn open(io: std.Io, journal_dir: []const u8) !Segment {
        var created_dir = try std.Io.Dir.cwd().createDirPathOpen(io, journal_dir, .{});
        created_dir.close(io);

        var dir = try std.Io.Dir.cwd().openDir(io, journal_dir, .{ .iterate = true });
        defer dir.close(io);

        var timestamp_buffer: [16]u8 = undefined;
        const timestamp = formatUtcTimestamp(&timestamp_buffer, std.Io.Timestamp.now(io, .real));

        var filename_buffer: [40]u8 = undefined;
        var segment_number = try nextSegmentNumber(io, &dir);
        while (segment_number <= max_segment_number) : (segment_number += 1) {
            const filename = try std.fmt.bufPrint(
                &filename_buffer,
                "journal-{s}-{d:0>6}.nmj",
                .{ timestamp, segment_number },
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

    pub fn appendSubmitLimit(self: *Segment, instrument_id: InstrumentId, order: engine.Order) !void {
        var payload: [submit_limit_payload_len]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], instrument_id, .little);
        payload[4] = switch (order.side) {
            .buy => 1,
            .sell => 2,
        };
        std.mem.writeInt(u64, payload[5..13], order.id, .little);
        std.mem.writeInt(u64, payload[13..21], order.price, .little);
        std.mem.writeInt(u64, payload[21..29], order.quantity, .little);
        try self.appendRecord(.submit_limit, &payload);
    }

    pub fn appendCancel(self: *Segment, instrument_id: InstrumentId, id: engine.OrderId) !void {
        var payload: [cancel_payload_len]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], instrument_id, .little);
        std.mem.writeInt(u64, payload[4..12], id, .little);
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

pub fn segmentNumberFromName(name: []const u8) ?u32 {
    const prefix = "journal-";
    const suffix = ".nmj";
    const number_len = 6;

    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    if (name.len < prefix.len + 1 + number_len + suffix.len) return null;

    const number_start = name.len - suffix.len - number_len;
    if (name[number_start - 1] != '-') return null;
    const number_text = name[number_start .. number_start + number_len];
    for (number_text) |byte| {
        if (byte < '0' or byte > '9') return null;
    }

    const number = std.fmt.parseInt(u32, number_text, 10) catch return null;
    if (number == 0 or number > max_segment_number) return null;
    return number;
}

fn nextSegmentNumber(io: std.Io, dir: *std.Io.Dir) !u32 {
    var max_number: u32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const number = segmentNumberFromName(entry.name) orelse continue;
        max_number = @max(max_number, number);
    }
    if (max_number == max_segment_number) return error.JournalSegmentSequenceExhausted;
    return max_number + 1;
}

pub const Reader = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    size: u64,
    recovered_tail: bool = false,

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
        if (remaining < header_len) {
            self.recovered_tail = true;
            return null;
        }

        var header: [header_len]u8 = undefined;
        try self.readExact(&header);

        if (!std.mem.eql(u8, header[0..4], magic)) return error.InvalidJournalMagic;
        const record_version = header[4];
        if (record_version != version and record_version != legacy_version) return error.UnsupportedJournalVersion;

        const kind: RecordKind = switch (header[5]) {
            @backingInt(RecordKind.submit_limit) => .submit_limit,
            @backingInt(RecordKind.cancel) => .cancel,
            else => return error.InvalidJournalRecordKind,
        };
        const payload_len = std.mem.readInt(u32, header[6..10], .little);
        const checksum = std.mem.readInt(u32, header[10..14], .little);
        const expected_len: u32 = expectedPayloadLen(record_version, kind);
        if (payload_len != expected_len) return error.InvalidJournalRecordLength;

        if (self.size - self.offset < payload_len) {
            self.recovered_tail = true;
            return null;
        }

        var payload: [submit_limit_payload_len]u8 = undefined;
        const payload_slice = payload[0..payload_len];
        try self.readExact(payload_slice);
        if (std.hash.Crc32.hash(payload_slice) != checksum) return error.InvalidJournalChecksum;

        return switch (kind) {
            .submit_limit => .{ .submit_limit = try decodeSubmitLimit(record_version, payload_slice) },
            .cancel => .{ .cancel = try decodeCancel(record_version, payload_slice) },
        };
    }

    pub fn recoveredTail(self: *const Reader) bool {
        return self.recovered_tail;
    }

    fn readExact(self: *Reader, buffer: []u8) !void {
        const read_len = try self.file.readPositionalAll(self.io, buffer, self.offset);
        if (read_len != buffer.len) return error.TruncatedJournalRead;
        self.offset += read_len;
    }
};

fn expectedPayloadLen(record_version: u8, kind: RecordKind) u32 {
    if (record_version == legacy_version) {
        return switch (kind) {
            .submit_limit => legacy_submit_limit_payload_len,
            .cancel => legacy_cancel_payload_len,
        };
    }

    return switch (kind) {
        .submit_limit => submit_limit_payload_len,
        .cancel => cancel_payload_len,
    };
}

fn decodeSubmitLimit(record_version: u8, payload: []const u8) !InstrumentedOrder {
    if (record_version == legacy_version) {
        const id = std.mem.readInt(u64, payload[1..9], .little);
        const price = std.mem.readInt(u64, payload[9..17], .little);
        const quantity = std.mem.readInt(u64, payload[17..25], .little);
        return .{
            .instrument_id = legacy_default_instrument_id,
            .order = .{
                .side = switch (payload[0]) {
                    1 => .buy,
                    2 => .sell,
                    else => return error.InvalidJournalSide,
                },
                .id = try validateJournalOrderId(id),
                .price = try validateJournalPrice(price),
                .quantity = try validateJournalQuantity(quantity),
            },
        };
    }

    const id = std.mem.readInt(u64, payload[5..13], .little);
    const price = std.mem.readInt(u64, payload[13..21], .little);
    const quantity = std.mem.readInt(u64, payload[21..29], .little);
    return .{
        .instrument_id = std.mem.readInt(u32, payload[0..4], .little),
        .order = .{
            .side = switch (payload[4]) {
                1 => .buy,
                2 => .sell,
                else => return error.InvalidJournalSide,
            },
            .id = try validateJournalOrderId(id),
            .price = try validateJournalPrice(price),
            .quantity = try validateJournalQuantity(quantity),
        },
    };
}

fn decodeCancel(record_version: u8, payload: []const u8) !InstrumentedCancel {
    if (record_version == legacy_version) {
        return .{
            .instrument_id = legacy_default_instrument_id,
            .order_id = try validateJournalOrderId(std.mem.readInt(u64, payload[0..8], .little)),
        };
    }

    return .{
        .instrument_id = std.mem.readInt(u32, payload[0..4], .little),
        .order_id = try validateJournalOrderId(std.mem.readInt(u64, payload[4..12], .little)),
    };
}

fn validateJournalOrderId(id: engine.OrderId) !engine.OrderId {
    if (id == 0) return error.InvalidJournalOrderId;
    return id;
}

fn validateJournalPrice(price: engine.Price) !engine.Price {
    if (price == 0) return error.InvalidJournalPrice;
    return price;
}

fn validateJournalQuantity(quantity: engine.Quantity) !engine.Quantity {
    if (quantity == 0) return error.InvalidJournalQuantity;
    return quantity;
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
    try segment.appendSubmitLimit(1, .{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    try segment.appendCancel(1, 1);
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
    try segment.appendSubmitLimit(2, .{ .id = 7, .side = .sell, .price = 101, .quantity = 3 });
    try segment.appendCancel(2, 7);
    segment.close();

    var reader = try Reader.open(io, path_buffer[0..path_len]);
    defer reader.close();

    const first = (try reader.next()).?.submit_limit;
    try std.testing.expectEqual(@as(InstrumentId, 2), first.instrument_id);
    try std.testing.expectEqual(engine.Side.sell, first.order.side);
    try std.testing.expectEqual(@as(engine.OrderId, 7), first.order.id);
    try std.testing.expectEqual(@as(engine.Price, 101), first.order.price);
    try std.testing.expectEqual(@as(engine.Quantity, 3), first.order.quantity);
    const cancel_record = (try reader.next()).?.cancel;
    try std.testing.expectEqual(@as(InstrumentId, 2), cancel_record.instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 7), cancel_record.order_id);
    try std.testing.expect((try reader.next()) == null);
}

test "reader maps legacy records to the default instrument" {
    var bytes: [legacy_header_and_submit_len + legacy_header_and_cancel_len]u8 = undefined;
    encodeLegacySubmitLimitRecord(bytes[0..legacy_header_and_submit_len], .{ .id = 7, .side = .sell, .price = 101, .quantity = 3 });
    encodeLegacyCancelRecord(bytes[legacy_header_and_submit_len..], 7);

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.nmj", .data = &bytes });
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/legacy.nmj", .{tmp.sub_path[0..]});
    var reader = try Reader.open(io, path);
    defer reader.close();

    const first = (try reader.next()).?.submit_limit;
    try std.testing.expectEqual(legacy_default_instrument_id, first.instrument_id);
    try std.testing.expectEqual(engine.Side.sell, first.order.side);
    try std.testing.expectEqual(@as(engine.OrderId, 7), first.order.id);

    const second = (try reader.next()).?.cancel;
    try std.testing.expectEqual(legacy_default_instrument_id, second.instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 7), second.order_id);
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
    const cancel_record = (try reader.next()).?.cancel;
    try std.testing.expectEqual(@as(InstrumentId, 1), cancel_record.instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 9), cancel_record.order_id);
    try std.testing.expect((try reader.next()) == null);
}

test "reader treats an incomplete final payload as a recoverable tail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var final_record: [header_len + cancel_payload_len]u8 = undefined;
    encodeCancelRecord(&final_record, 10);

    var bytes: [header_len + cancel_payload_len + header_len + 3]u8 = undefined;
    encodeCancelRecord(bytes[0 .. header_len + cancel_payload_len], 9);
    @memcpy(bytes[header_len + cancel_payload_len ..][0..header_len], final_record[0..header_len]);
    @memcpy(bytes[header_len + cancel_payload_len + header_len ..], final_record[header_len .. header_len + 3]);

    try tmp.dir.writeFile(io, .{ .sub_path = "tail-payload.nmj", .data = &bytes });
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/tail-payload.nmj", .{tmp.sub_path[0..]});
    var reader = try Reader.open(io, path);
    defer reader.close();
    const cancel_record = (try reader.next()).?.cancel;
    try std.testing.expectEqual(@as(InstrumentId, 1), cancel_record.instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 9), cancel_record.order_id);
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

test "reader validates magic version kind expected length checksum and side" {
    var bytes: [header_len + submit_limit_payload_len]u8 = undefined;
    encodeSubmitLimitRecord(&bytes, .{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });

    bytes[0] = 'X';
    try expectReaderError(&bytes, error.InvalidJournalMagic);

    encodeSubmitLimitRecord(&bytes, .{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    bytes[4] = version + 1;
    try expectReaderError(&bytes, error.UnsupportedJournalVersion);

    encodeSubmitLimitRecord(&bytes, .{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    bytes[5] = 99;
    try expectReaderError(&bytes, error.InvalidJournalRecordKind);

    encodeSubmitLimitRecord(&bytes, .{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    std.mem.writeInt(u32, bytes[6..10], submit_limit_payload_len - 1, .little);
    try expectReaderError(&bytes, error.InvalidJournalRecordLength);

    encodeSubmitLimitRecord(&bytes, .{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    std.mem.writeInt(u32, bytes[10..14], 0, .little);
    try expectReaderError(&bytes, error.InvalidJournalChecksum);

    encodeSubmitLimitRecord(&bytes, .{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    bytes[header_len + 4] = 99;
    std.mem.writeInt(u32, bytes[10..14], std.hash.Crc32.hash(bytes[header_len..]), .little);
    try expectReaderError(&bytes, error.InvalidJournalSide);
}

test "reader rejects checksum-valid semantic payload corruption" {
    var submit_bytes: [header_len + submit_limit_payload_len]u8 = undefined;
    encodeSubmitLimitRecord(&submit_bytes, .{ .id = 0, .side = .buy, .price = 100, .quantity = 10 });
    try expectReaderError(&submit_bytes, error.InvalidJournalOrderId);

    encodeSubmitLimitRecord(&submit_bytes, .{ .id = 1, .side = .buy, .price = 0, .quantity = 10 });
    try expectReaderError(&submit_bytes, error.InvalidJournalPrice);

    encodeSubmitLimitRecord(&submit_bytes, .{ .id = 1, .side = .buy, .price = 100, .quantity = 0 });
    try expectReaderError(&submit_bytes, error.InvalidJournalQuantity);

    var cancel_bytes: [header_len + cancel_payload_len]u8 = undefined;
    encodeCancelRecord(&cancel_bytes, 0);
    try expectReaderError(&cancel_bytes, error.InvalidJournalOrderId);

    var legacy_submit_bytes: [legacy_header_and_submit_len]u8 = undefined;
    encodeLegacySubmitLimitRecord(&legacy_submit_bytes, .{ .id = 1, .side = .sell, .price = 101, .quantity = 0 });
    try expectReaderError(&legacy_submit_bytes, error.InvalidJournalQuantity);

    var legacy_cancel_bytes: [legacy_header_and_cancel_len]u8 = undefined;
    encodeLegacyCancelRecord(&legacy_cancel_bytes, 0);
    try expectReaderError(&legacy_cancel_bytes, error.InvalidJournalOrderId);
}

test "reader treats truncated headers and payloads as recoverable final tails" {
    var full_record: [header_len + submit_limit_payload_len]u8 = undefined;
    encodeSubmitLimitRecord(&full_record, .{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });

    const truncations = [_]usize{
        1,
        header_len - 1,
        header_len,
        header_len + 1,
        full_record.len - 1,
    };

    inline for (truncations) |len| {
        try expectReaderTail(full_record[0..len]);
    }
}

fn encodeCancelRecord(buffer: []u8, id: engine.OrderId) void {
    std.debug.assert(buffer.len == header_len + cancel_payload_len);
    @memcpy(buffer[0..4], magic);
    buffer[4] = version;
    buffer[5] = @backingInt(RecordKind.cancel);
    std.mem.writeInt(u32, buffer[6..10], cancel_payload_len, .little);
    std.mem.writeInt(u32, buffer[header_len .. header_len + 4], 1, .little);
    std.mem.writeInt(u64, buffer[header_len + 4 .. header_len + cancel_payload_len], id, .little);
    std.mem.writeInt(u32, buffer[10..14], std.hash.Crc32.hash(buffer[header_len .. header_len + cancel_payload_len]), .little);
}

fn encodeSubmitLimitRecord(buffer: []u8, order: engine.Order) void {
    std.debug.assert(buffer.len == header_len + submit_limit_payload_len);
    @memcpy(buffer[0..4], magic);
    buffer[4] = version;
    buffer[5] = @backingInt(RecordKind.submit_limit);
    std.mem.writeInt(u32, buffer[6..10], submit_limit_payload_len, .little);
    std.mem.writeInt(u32, buffer[header_len .. header_len + 4], 1, .little);
    buffer[header_len + 4] = switch (order.side) {
        .buy => 1,
        .sell => 2,
    };
    std.mem.writeInt(u64, buffer[header_len + 5 .. header_len + 13], order.id, .little);
    std.mem.writeInt(u64, buffer[header_len + 13 .. header_len + 21], order.price, .little);
    std.mem.writeInt(u64, buffer[header_len + 21 .. header_len + 29], order.quantity, .little);
    std.mem.writeInt(u32, buffer[10..14], std.hash.Crc32.hash(buffer[header_len..]), .little);
}

const legacy_header_and_submit_len = header_len + legacy_submit_limit_payload_len;
const legacy_header_and_cancel_len = header_len + legacy_cancel_payload_len;

fn encodeLegacyCancelRecord(buffer: []u8, id: engine.OrderId) void {
    std.debug.assert(buffer.len == legacy_header_and_cancel_len);
    @memcpy(buffer[0..4], magic);
    buffer[4] = legacy_version;
    buffer[5] = @backingInt(RecordKind.cancel);
    std.mem.writeInt(u32, buffer[6..10], legacy_cancel_payload_len, .little);
    std.mem.writeInt(u64, buffer[header_len .. header_len + legacy_cancel_payload_len], id, .little);
    std.mem.writeInt(u32, buffer[10..14], std.hash.Crc32.hash(buffer[header_len .. header_len + legacy_cancel_payload_len]), .little);
}

fn encodeLegacySubmitLimitRecord(buffer: []u8, order: engine.Order) void {
    std.debug.assert(buffer.len == legacy_header_and_submit_len);
    @memcpy(buffer[0..4], magic);
    buffer[4] = legacy_version;
    buffer[5] = @backingInt(RecordKind.submit_limit);
    std.mem.writeInt(u32, buffer[6..10], legacy_submit_limit_payload_len, .little);
    buffer[header_len] = switch (order.side) {
        .buy => 1,
        .sell => 2,
    };
    std.mem.writeInt(u64, buffer[header_len + 1 .. header_len + 9], order.id, .little);
    std.mem.writeInt(u64, buffer[header_len + 9 .. header_len + 17], order.price, .little);
    std.mem.writeInt(u64, buffer[header_len + 17 .. header_len + 25], order.quantity, .little);
    std.mem.writeInt(u32, buffer[10..14], std.hash.Crc32.hash(buffer[header_len..]), .little);
}

fn expectReaderError(data: []const u8, expected: anyerror) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "record.nmj", .data = data });
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/record.nmj", .{tmp.sub_path[0..]});
    var reader = try Reader.open(io, path);
    defer reader.close();

    try std.testing.expectError(expected, reader.next());
}

fn expectReaderTail(data: []const u8) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "tail.nmj", .data = data });
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/tail.nmj", .{tmp.sub_path[0..]});
    var reader = try Reader.open(io, path);
    defer reader.close();

    try std.testing.expect((try reader.next()) == null);
    try std.testing.expect(reader.recoveredTail());
}
