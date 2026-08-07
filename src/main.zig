const std = @import("std");
const engine = @import("engine.zig");
const journal = @import("journal.zig");

pub const CommandEvent = union(enum) {
    submit_limit: engine.Order,
    cancel: engine.OrderId,
};

const RunMode = union(enum) {
    live: []const u8,
    replay: []const u8,
};

const max_recovery_segments = 128;
const max_recovery_output_len = 32768;

const JournalSegmentPath = struct {
    bytes: [std.Io.Dir.max_path_bytes]u8,
    len: usize,
    number: u32,

    fn slice(self: *const JournalSegmentPath) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdin = &stdin_reader.interface;
    const stdout = &stdout_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    const mode = try parseArgs(&args);

    var book = engine.OrderBook.init();
    switch (mode) {
        .live => |journal_dir| try runLive(io, stdin, stdout, &book, journal_dir),
        .replay => |journal_path| try replayJournalPath(io, stdout, &book, journal_path),
    }
    try stdout.flush();
}

fn runLive(
    io: std.Io,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    book: *engine.OrderBook,
    journal_dir: []const u8,
) !void {
    var line_buffer: [256]u8 = undefined;
    try recoverJournalDir(io, book, journal_dir);
    var journal_segment = try journal.Segment.open(io, journal_dir);
    defer journal_segment.close();

    try stdout.writeAll("commands: BUY id price quantity | SELL id price quantity | CANCEL id\n");
    try stdout.flush();

    while (try readLine(stdin, &line_buffer)) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        const event = parseCommandEvent(trimmed) catch |err| {
            try stdout.print("ERROR {s}\n", .{@errorName(err)});
            try printState(stdout, book);
            try stdout.flush();
            continue;
        };

        try applyJournaledCommand(stdout, book, &journal_segment, event);

        try printState(stdout, book);
        try stdout.flush();
    }
}

fn recoverJournalDir(
    io: std.Io,
    book: *engine.OrderBook,
    journal_dir: []const u8,
) !void {
    var created_dir = try std.Io.Dir.cwd().createDirPathOpen(io, journal_dir, .{});
    created_dir.close(io);

    var dir = try std.Io.Dir.cwd().openDir(io, journal_dir, .{ .iterate = true });
    defer dir.close(io);

    var segments: [max_recovery_segments]JournalSegmentPath = undefined;
    var segment_count: usize = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const segment_number = journal.segmentNumberFromName(entry.name) orelse continue;
        if (segment_count == segments.len) return error.RecoverySegmentLimitExceeded;
        const path = try std.fmt.bufPrint(
            &segments[segment_count].bytes,
            "{s}/{s}",
            .{ journal_dir, entry.name },
        );
        segments[segment_count].len = path.len;
        segments[segment_count].number = segment_number;
        segment_count += 1;
    }

    sortJournalSegmentPaths(segments[0..segment_count]);
    try validateUniqueSegmentNumbers(segments[0..segment_count]);

    for (segments[0..segment_count], 0..) |*segment, index| {
        try recoverJournalPath(io, book, segment.slice(), index + 1 == segment_count);
    }
}

fn sortJournalSegmentPaths(segments: []JournalSegmentPath) void {
    var index: usize = 1;
    while (index < segments.len) : (index += 1) {
        const current = segments[index];
        var move_index = index;
        while (move_index > 0 and journalSegmentPathLessThan(current, segments[move_index - 1])) : (move_index -= 1) {
            segments[move_index] = segments[move_index - 1];
        }
        segments[move_index] = current;
    }
}

fn journalSegmentPathLessThan(lhs: JournalSegmentPath, rhs: JournalSegmentPath) bool {
    return lhs.number < rhs.number;
}

fn validateUniqueSegmentNumbers(segments: []const JournalSegmentPath) !void {
    if (segments.len == 0) return;

    var index: usize = 1;
    while (index < segments.len) : (index += 1) {
        if (segments[index - 1].number == segments[index].number) {
            return error.DuplicateJournalSegmentNumber;
        }
    }
}

fn recoverJournalPath(
    io: std.Io,
    book: *engine.OrderBook,
    path: []const u8,
    is_final_segment: bool,
) !void {
    var reader = try journal.Reader.open(io, path);
    defer reader.close();

    var output_buffer: [max_recovery_output_len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    while (try reader.next()) |record| {
        try applyCommandEvent(&writer, book, commandEventFromJournalRecord(record));
        writer.end = 0;
    }

    if (reader.recoveredTail() and !is_final_segment) {
        return error.IncompleteJournalRecordBeforeFinalSegment;
    }
}

fn parseArgs(args: *std.process.Args.Iterator) !RunMode {
    var first = args.next() orelse return .{ .live = journal.default_dir };
    if (isExecutableArg(first)) {
        first = args.next() orelse return .{ .live = journal.default_dir };
    }

    if (std.mem.eql(u8, first, "--journal-dir")) {
        const journal_dir = args.next() orelse return error.MissingJournalDir;
        if (args.next() != null) return error.TooManyArguments;
        return .{ .live = journal_dir };
    }

    if (std.mem.eql(u8, first, "replay")) {
        const journal_path = args.next() orelse return error.MissingJournalPath;
        if (args.next() != null) return error.TooManyArguments;
        return .{ .replay = journal_path };
    }

    return error.UnknownArgument;
}

fn isExecutableArg(arg: []const u8) bool {
    const basename = std.fs.path.basename(arg);
    return std.mem.eql(u8, basename, "neon-match") or
        std.mem.eql(u8, basename, "neon-match.exe");
}

fn applyJournaledCommand(
    writer: *std.Io.Writer,
    book: *engine.OrderBook,
    segment: anytype,
    event: CommandEvent,
) !void {
    try appendJournalEvent(segment, event);
    try applyCommandEvent(writer, book, event);
}

fn appendJournalEvent(segment: anytype, event: CommandEvent) !void {
    switch (event) {
        .submit_limit => |order| try segment.appendSubmitLimit(order),
        .cancel => |id| try segment.appendCancel(id),
    }
}

pub fn replayJournalPath(
    io: std.Io,
    writer: *std.Io.Writer,
    book: *engine.OrderBook,
    path: []const u8,
) !void {
    var reader = try journal.Reader.open(io, path);
    defer reader.close();
    try replayJournal(writer, book, &reader);
}

pub fn replayJournal(
    writer: *std.Io.Writer,
    book: *engine.OrderBook,
    reader: *journal.Reader,
) !void {
    try writer.writeAll("commands: BUY id price quantity | SELL id price quantity | CANCEL id\n");
    while (try reader.next()) |record| {
        try applyCommandEvent(writer, book, commandEventFromJournalRecord(record));
        try printState(writer, book);
    }
}

fn commandEventFromJournalRecord(record: journal.Record) CommandEvent {
    return switch (record) {
        .submit_limit => |order| .{ .submit_limit = order },
        .cancel => |id| .{ .cancel = id },
    };
}

pub fn applyCommandEvent(
    writer: *std.Io.Writer,
    book: *engine.OrderBook,
    event: CommandEvent,
) !void {
    switch (event) {
        .submit_limit => |order| {
            if (!try canAccept(writer, book, order)) return;
            const result = book.submitLimit(order);
            try printTrades(writer, &result);
        },
        .cancel => |id| {
            if (book.cancel(id)) {
                try writer.print("CANCELED {d}\n", .{id});
            } else {
                try writer.print("NOT_FOUND {d}\n", .{id});
            }
        },
    }
}

fn canAccept(
    writer: *std.Io.Writer,
    book: *const engine.OrderBook,
    order: engine.Order,
) !bool {
    if (book.containsOrder(order.id)) {
        try writer.print("ERROR DuplicateOrderId {d}\n", .{order.id});
        return false;
    }
    if (book.restingQuantityAfterMatch(order) > 0 and !book.hasRoomFor(order.side)) {
        try writer.writeAll("ERROR BookFull\n");
        return false;
    }
    return true;
}

fn readLine(reader: *std.Io.Reader, buffer: []u8) !?[]const u8 {
    var len: usize = 0;
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (len == 0) return null;
                return buffer[0..len];
            },
            else => return err,
        };

        if (byte == '\n') return buffer[0..len];
        if (len == buffer.len) return error.LineTooLong;
        buffer[len] = byte;
        len += 1;
    }
}

fn parseCommandEvent(line: []const u8) !CommandEvent {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n");
    const verb = tokens.next() orelse return error.EmptyCommand;

    if (std.mem.eql(u8, verb, "BUY")) {
        const order = try parseInputOrder(&tokens, .buy);
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .submit_limit = order };
    }

    if (std.mem.eql(u8, verb, "SELL")) {
        const order = try parseInputOrder(&tokens, .sell);
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .submit_limit = order };
    }

    if (std.mem.eql(u8, verb, "CANCEL")) {
        const id_text = tokens.next() orelse return error.MissingOrderId;
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .cancel = try parsePositive(engine.OrderId, id_text) };
    }

    return error.UnknownCommand;
}

fn parseInputOrder(tokens: *std.mem.TokenIterator(u8, .any), side: engine.Side) !engine.Order {
    const id_text = tokens.next() orelse return error.MissingOrderId;
    const price_text = tokens.next() orelse return error.MissingPrice;
    const quantity_text = tokens.next() orelse return error.MissingQuantity;

    return .{
        .id = try parsePositive(engine.OrderId, id_text),
        .side = side,
        .price = try parsePositive(engine.Price, price_text),
        .quantity = try parsePositive(engine.Quantity, quantity_text),
    };
}

fn parsePositive(comptime T: type, text: []const u8) !T {
    const value = try std.fmt.parseInt(T, text, 10);
    if (value == 0) return error.MustBePositive;
    return value;
}

fn printTrades(writer: *std.Io.Writer, result: *const engine.MatchResult) !void {
    var index: usize = 0;
    while (index < result.trade_count) : (index += 1) {
        const trade = result.trades[index];
        try writer.print(
            "TRADE maker={d} taker={d} price={d} quantity={d}\n",
            .{ trade.maker_id, trade.taker_id, trade.price, trade.quantity },
        );
    }
}

fn printState(writer: *std.Io.Writer, book: *const engine.OrderBook) !void {
    try writer.writeAll("BOOK\n");
    try writer.writeAll("  BIDS\n");
    var bid_index: usize = 0;
    while (bid_index < book.bid_count) : (bid_index += 1) {
        const bid = book.bids[bid_index];
        try writer.print("    id={d} price={d} quantity={d}\n", .{ bid.id, bid.price, bid.quantity });
    }

    try writer.writeAll("  ASKS\n");
    var ask_index: usize = 0;
    while (ask_index < book.ask_count) : (ask_index += 1) {
        const ask = book.asks[ask_index];
        try writer.print("    id={d} price={d} quantity={d}\n", .{ ask.id, ask.price, ask.quantity });
    }
}

fn buy(id: engine.OrderId, price: engine.Price, quantity: engine.Quantity) CommandEvent {
    return .{ .submit_limit = .{ .id = id, .side = .buy, .price = price, .quantity = quantity } };
}

fn sell(id: engine.OrderId, price: engine.Price, quantity: engine.Quantity) CommandEvent {
    return .{ .submit_limit = .{ .id = id, .side = .sell, .price = price, .quantity = quantity } };
}

fn cancel(id: engine.OrderId) CommandEvent {
    return .{ .cancel = id };
}

fn expectOutput(writer: *const std.Io.Writer, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

fn expectBookUnchanged(before: *const engine.OrderBook, after: *const engine.OrderBook) !void {
    try std.testing.expectEqual(before.bid_count, after.bid_count);
    try std.testing.expectEqual(before.ask_count, after.ask_count);
    try std.testing.expectEqualSlices(engine.Order, before.bids[0..before.bid_count], after.bids[0..after.bid_count]);
    try std.testing.expectEqualSlices(engine.Order, before.asks[0..before.ask_count], after.asks[0..after.ask_count]);
}

fn expectBooksEqual(expected: *const engine.OrderBook, actual: *const engine.OrderBook) !void {
    try expectBookUnchanged(expected, actual);
}

fn fillSideWithRestingOrders(
    writer: *std.Io.Writer,
    book: *engine.OrderBook,
    side: engine.Side,
    start_id: engine.OrderId,
) !void {
    var offset: engine.OrderId = 0;
    while (offset < engine.max_orders) : (offset += 1) {
        const id = start_id + offset;
        const event = switch (side) {
            .buy => buy(id, 90, 1),
            .sell => sell(id, 110, 1),
        };
        try applyCommandEvent(writer, book, event);
    }
}

fn writeJournalSegment(
    dir: std.Io.Dir,
    name: []const u8,
    events: []const CommandEvent,
) !void {
    var bytes: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    for (events) |event| try encodeJournalEvent(&writer, event);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = writer.buffered() });
}

fn writeEmptyJournalSegmentNumber(dir: std.Io.Dir, number: u32) !void {
    var name_buffer: [40]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buffer,
        "journal-20260730T014500Z-{d:0>6}.nmj",
        .{number},
    );
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "" });
}

fn writeJournalSegmentWithTail(
    dir: std.Io.Dir,
    name: []const u8,
    events: []const CommandEvent,
) !void {
    var bytes: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    for (events) |event| try encodeJournalEvent(&writer, event);
    try writer.writeAll("NMJ");
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = writer.buffered() });
}

fn writeCorruptJournalSegment(
    dir: std.Io.Dir,
    name: []const u8,
    events: []const CommandEvent,
) !void {
    var bytes: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    for (events) |event| try encodeJournalEvent(&writer, event);
    bytes[10] ^= 0xff;
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = writer.buffered() });
}

fn encodeJournalEvent(writer: *std.Io.Writer, event: CommandEvent) !void {
    switch (event) {
        .submit_limit => |order| {
            var payload: [25]u8 = undefined;
            payload[0] = switch (order.side) {
                .buy => 1,
                .sell => 2,
            };
            std.mem.writeInt(u64, payload[1..9], order.id, .little);
            std.mem.writeInt(u64, payload[9..17], order.price, .little);
            std.mem.writeInt(u64, payload[17..25], order.quantity, .little);
            try encodeJournalRecord(writer, 1, &payload);
        },
        .cancel => |id| {
            var payload: [8]u8 = undefined;
            std.mem.writeInt(u64, &payload, id, .little);
            try encodeJournalRecord(writer, 2, &payload);
        },
    }
}

fn encodeJournalRecord(writer: *std.Io.Writer, kind: u8, payload: []const u8) !void {
    var header: [14]u8 = undefined;
    @memcpy(header[0..4], "NMJ1");
    header[4] = 1;
    header[5] = kind;
    std.mem.writeInt(u32, header[6..10], @intCast(payload.len), .little);
    std.mem.writeInt(u32, header[10..14], std.hash.Crc32.hash(payload), .little);
    try writer.writeAll(&header);
    try writer.writeAll(payload);
}

test "parse buy sell and cancel commands into command events" {
    const buy_event = try parseCommandEvent("BUY 1 100 10");
    const buy_order = buy_event.submit_limit;
    try std.testing.expectEqual(engine.Side.buy, buy_order.side);
    try std.testing.expectEqual(@as(engine.OrderId, 1), buy_order.id);
    try std.testing.expectEqual(@as(engine.Price, 100), buy_order.price);
    try std.testing.expectEqual(@as(engine.Quantity, 10), buy_order.quantity);

    const sell_event = try parseCommandEvent("SELL 2 110 5");
    const sell_order = sell_event.submit_limit;
    try std.testing.expectEqual(engine.Side.sell, sell_order.side);
    try std.testing.expectEqual(@as(engine.OrderId, 2), sell_order.id);
    try std.testing.expectEqual(@as(engine.Price, 110), sell_order.price);
    try std.testing.expectEqual(@as(engine.Quantity, 5), sell_order.quantity);

    const cancel_event = try parseCommandEvent("CANCEL 2");
    try std.testing.expectEqual(@as(engine.OrderId, 2), cancel_event.cancel);
}

test "buy sell and cancel events can be applied without stdin" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applyCommandEvent(&writer, &book, buy(1, 100, 10));
    try applyCommandEvent(&writer, &book, sell(2, 110, 5));
    try applyCommandEvent(&writer, &book, cancel(1));

    try std.testing.expect(!book.containsOrder(1));
    try std.testing.expect(book.containsOrder(2));
    try expectOutput(&writer, "CANCELED 1\n");
}

test "direct command event replay matches stdin fixture output" {
    var book = engine.OrderBook.init();
    var output_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try writer.writeAll("commands: BUY id price quantity | SELL id price quantity | CANCEL id\n");

    const events = [_]CommandEvent{
        buy(1, 100, 10),
        sell(2, 110, 5),
        sell(3, 100, 4),
        buy(4, 110, 8),
        cancel(2),
    };
    for (events) |event| {
        try applyCommandEvent(&writer, &book, event);
        try printState(&writer, &book);
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var expected_buffer: [2048]u8 = undefined;
    const expected_file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/basic.stdout", .{});
    defer expected_file.close(io);
    const expected_len = try expected_file.readPositionalAll(io, &expected_buffer, 0);
    try expectOutput(&writer, expected_buffer[0..expected_len]);
    try std.testing.expectEqual(@as(usize, 2), book.bid_count);
    try std.testing.expectEqual(@as(engine.OrderId, 4), book.bids[0].id);
    try std.testing.expectEqual(@as(engine.Quantity, 3), book.bids[0].quantity);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book.bids[1].id);
    try std.testing.expectEqual(@as(engine.Quantity, 6), book.bids[1].quantity);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
}

test "journal replay matches live input output and final book state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const commands =
        "BUY 1 100 10\n" ++
        "SELL 2 110 5\n" ++
        "SELL 3 100 4\n" ++
        "BUY 4 110 8\n" ++
        "CANCEL 2\n";

    var live_book = engine.OrderBook.init();
    var live_output_buffer: [2048]u8 = undefined;
    var live_writer = std.Io.Writer.fixed(&live_output_buffer);
    var stdin = std.Io.Reader.fixed(commands);
    try runLive(io, &stdin, &live_writer, &live_book, journal_dir);

    var it = tmp.dir.iterate();
    const entry = (try it.next(io)) orelse return error.MissingJournalSegment;
    try std.testing.expect((try it.next(io)) == null);
    var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&journal_path_buffer, "{s}/{s}", .{ journal_dir, entry.name });

    var replay_book = engine.OrderBook.init();
    var replay_output_buffer: [2048]u8 = undefined;
    var replay_writer = std.Io.Writer.fixed(&replay_output_buffer);
    try replayJournalPath(io, &replay_writer, &replay_book, journal_path);

    try expectOutput(&replay_writer, live_writer.buffered());
    try expectBooksEqual(&live_book, &replay_book);
}

test "live startup recovers existing journal segment before accepting commands" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try writeJournalSegment(
        tmp.dir,
        "journal-20260730T014500Z-000001.nmj",
        &.{buy(1, 100, 10)},
    );

    var recovered_book = engine.OrderBook.init();
    var recovered_output_buffer: [1024]u8 = undefined;
    var recovered_writer = std.Io.Writer.fixed(&recovered_output_buffer);
    var stdin = std.Io.Reader.fixed("SELL 2 100 4\n");
    try runLive(io, &stdin, &recovered_writer, &recovered_book, journal_dir);

    var expected_book = engine.OrderBook.init();
    var expected_output_buffer: [1024]u8 = undefined;
    var expected_writer = std.Io.Writer.fixed(&expected_output_buffer);
    try expected_writer.writeAll("commands: BUY id price quantity | SELL id price quantity | CANCEL id\n");
    try applyCommandEvent(&expected_writer, &expected_book, buy(1, 100, 10));
    expected_writer.end = "commands: BUY id price quantity | SELL id price quantity | CANCEL id\n".len;
    try applyCommandEvent(&expected_writer, &expected_book, sell(2, 100, 4));
    try printState(&expected_writer, &expected_book);

    try expectOutput(&recovered_writer, expected_writer.buffered());
    try expectBooksEqual(&expected_book, &recovered_book);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "live startup recovers existing journal segments in segment number order when timestamps move backward" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try writeJournalSegment(
        tmp.dir,
        "journal-20260730T014501Z-000001.nmj",
        &.{buy(1, 100, 10)},
    );
    try writeJournalSegment(
        tmp.dir,
        "journal-20260730T014500Z-000002.nmj",
        &.{cancel(1)},
    );

    var recovered_book = engine.OrderBook.init();
    var recovered_output_buffer: [1024]u8 = undefined;
    var recovered_writer = std.Io.Writer.fixed(&recovered_output_buffer);
    var stdin = std.Io.Reader.fixed("SELL 2 100 1\n");
    try runLive(io, &stdin, &recovered_writer, &recovered_book, journal_dir);

    var expected_book = engine.OrderBook.init();
    var expected_output_buffer: [1024]u8 = undefined;
    var expected_writer = std.Io.Writer.fixed(&expected_output_buffer);
    try expected_writer.writeAll("commands: BUY id price quantity | SELL id price quantity | CANCEL id\n");
    try applyCommandEvent(&expected_writer, &expected_book, buy(1, 100, 10));
    try applyCommandEvent(&expected_writer, &expected_book, cancel(1));
    expected_writer.end = "commands: BUY id price quantity | SELL id price quantity | CANCEL id\n".len;
    try applyCommandEvent(&expected_writer, &expected_book, sell(2, 100, 1));
    try printState(&expected_writer, &expected_book);

    try expectOutput(&recovered_writer, expected_writer.buffered());
    try expectBooksEqual(&expected_book, &recovered_book);
}

test "live startup creates the next segment number after recovery without reusing a gap" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try writeJournalSegment(
        tmp.dir,
        "journal-20260730T014501Z-000001.nmj",
        &.{buy(1, 100, 10)},
    );
    try writeJournalSegment(
        tmp.dir,
        "journal-20260730T014500Z-000003.nmj",
        &.{cancel(1)},
    );

    var recovered_book = engine.OrderBook.init();
    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var stdin = std.Io.Reader.fixed("");
    try runLive(io, &stdin, &writer, &recovered_book, journal_dir);

    var found_1 = false;
    var found_2 = false;
    var found_3 = false;
    var found_4 = false;
    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        const segment_number = journal.segmentNumberFromName(entry.name) orelse continue;
        count += 1;
        switch (segment_number) {
            1 => found_1 = true,
            2 => found_2 = true,
            3 => found_3 = true,
            4 => found_4 = true,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(found_1);
    try std.testing.expect(!found_2);
    try std.testing.expect(found_3);
    try std.testing.expect(found_4);
}

test "live startup enforces the fixed recovery segment limit boundary" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var number: u32 = 1;
    while (number <= max_recovery_segments) : (number += 1) {
        try writeEmptyJournalSegmentNumber(tmp.dir, number);
    }

    var book = engine.OrderBook.init();
    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var stdin = std.Io.Reader.fixed("");
    try runLive(io, &stdin, &writer, &book, journal_dir);

    var bad_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer bad_tmp.cleanup();
    var bad_journal_dir_buffer: [64]u8 = undefined;
    const bad_journal_dir = try std.fmt.bufPrint(&bad_journal_dir_buffer, ".zig-cache/tmp/{s}", .{bad_tmp.sub_path[0..]});
    number = 1;
    while (number <= max_recovery_segments + 1) : (number += 1) {
        try writeEmptyJournalSegmentNumber(bad_tmp.dir, number);
    }

    var bad_book = engine.OrderBook.init();
    var bad_output_buffer: [1024]u8 = undefined;
    var bad_writer = std.Io.Writer.fixed(&bad_output_buffer);
    var bad_stdin = std.Io.Reader.fixed("");
    try std.testing.expectError(
        error.RecoverySegmentLimitExceeded,
        runLive(io, &bad_stdin, &bad_writer, &bad_book, bad_journal_dir),
    );
}

test "live startup tolerates incomplete final record only in final segment" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try writeJournalSegmentWithTail(
        tmp.dir,
        "journal-20260730T014500Z-000001.nmj",
        &.{buy(1, 100, 10)},
    );

    var recovered_book = engine.OrderBook.init();
    var recovered_output_buffer: [1024]u8 = undefined;
    var recovered_writer = std.Io.Writer.fixed(&recovered_output_buffer);
    var stdin = std.Io.Reader.fixed("SELL 2 100 4\n");
    try runLive(io, &stdin, &recovered_writer, &recovered_book, journal_dir);
    try std.testing.expectEqual(@as(usize, 1), recovered_book.bid_count);
    try std.testing.expectEqual(@as(engine.Quantity, 6), recovered_book.bids[0].quantity);

    var bad_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer bad_tmp.cleanup();
    var bad_journal_dir_buffer: [64]u8 = undefined;
    const bad_journal_dir = try std.fmt.bufPrint(&bad_journal_dir_buffer, ".zig-cache/tmp/{s}", .{bad_tmp.sub_path[0..]});
    try writeJournalSegmentWithTail(
        bad_tmp.dir,
        "journal-20260730T014500Z-000001.nmj",
        &.{buy(1, 100, 10)},
    );
    try writeJournalSegment(
        bad_tmp.dir,
        "journal-20260730T014501Z-000002.nmj",
        &.{sell(2, 110, 5)},
    );

    var bad_book = engine.OrderBook.init();
    var bad_output_buffer: [1024]u8 = undefined;
    var bad_writer = std.Io.Writer.fixed(&bad_output_buffer);
    var bad_stdin = std.Io.Reader.fixed("");
    try std.testing.expectError(
        error.IncompleteJournalRecordBeforeFinalSegment,
        runLive(io, &bad_stdin, &bad_writer, &bad_book, bad_journal_dir),
    );
}

test "live startup rejects corruption in existing complete journal record" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try writeCorruptJournalSegment(
        tmp.dir,
        "journal-20260730T014500Z-000001.nmj",
        &.{buy(1, 100, 10)},
    );

    var book = engine.OrderBook.init();
    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var stdin = std.Io.Reader.fixed("");
    try std.testing.expectError(
        error.InvalidJournalChecksum,
        runLive(io, &stdin, &writer, &book, journal_dir),
    );
}

test "journal submit append failure prevents command application" {
    const FailingJournal = struct {
        fn appendSubmitLimit(_: *@This(), _: engine.Order) !void {
            return error.JournalWriteFailed;
        }

        fn appendCancel(_: *@This(), _: engine.OrderId) !void {
            return error.JournalWriteFailed;
        }
    };

    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var failing_journal = FailingJournal{};

    try std.testing.expectError(
        error.JournalWriteFailed,
        applyJournaledCommand(&writer, &book, &failing_journal, buy(1, 100, 10)),
    );

    try std.testing.expect(!book.containsOrder(1));
    try expectOutput(&writer, "");
}

test "journal cancel append failure prevents command application" {
    const FailingJournal = struct {
        fn appendSubmitLimit(_: *@This(), _: engine.Order) !void {
            return error.JournalWriteFailed;
        }

        fn appendCancel(_: *@This(), _: engine.OrderId) !void {
            return error.JournalWriteFailed;
        }
    };

    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try applyCommandEvent(&writer, &book, buy(1, 100, 10));
    const before = book;
    writer.end = 0;

    var failing_journal = FailingJournal{};
    try std.testing.expectError(
        error.JournalWriteFailed,
        applyJournaledCommand(&writer, &book, &failing_journal, cancel(1)),
    );

    try expectBookUnchanged(&before, &book);
    try expectOutput(&writer, "");
}

test "applyCommandEvent reports duplicate ids and leaves book unchanged" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applyCommandEvent(&writer, &book, buy(1, 100, 10));
    const before = book;
    try applyCommandEvent(&writer, &book, buy(1, 99, 5));

    try expectBookUnchanged(&before, &book);
    try expectOutput(&writer, "ERROR DuplicateOrderId 1\n");
}

test "applyCommandEvent reports missing cancels without changing the book" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applyCommandEvent(&writer, &book, sell(1, 110, 5));
    const before = book;
    try applyCommandEvent(&writer, &book, cancel(404));

    try expectBookUnchanged(&before, &book);
    try expectOutput(&writer, "NOT_FOUND 404\n");
}

test "applyCommandEvent handles partial fills and fully filled orders" {
    var book = engine.OrderBook.init();
    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applyCommandEvent(&writer, &book, sell(1, 100, 10));
    try applyCommandEvent(&writer, &book, buy(2, 100, 4));
    try std.testing.expect(book.containsOrder(1));
    try std.testing.expectEqual(@as(engine.Quantity, 6), book.asks[0].quantity);

    try applyCommandEvent(&writer, &book, buy(3, 100, 6));
    try std.testing.expect(!book.containsOrder(1));
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
    try expectOutput(
        &writer,
        "TRADE maker=1 taker=2 price=100 quantity=4\n" ++
            "TRADE maker=1 taker=3 price=100 quantity=6\n",
    );
}

test "exactly max resting orders per side can be applied" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try fillSideWithRestingOrders(&writer, &book, .sell, 1000);

    try std.testing.expectEqual(@as(usize, engine.max_orders), book.bid_count);
    try std.testing.expectEqual(@as(usize, engine.max_orders), book.ask_count);
    try expectOutput(&writer, "");
}

test "a resting order beyond side capacity is rejected without changing the book" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    const before_bids = book;
    try applyCommandEvent(&writer, &book, buy(200, 89, 1));
    try expectBookUnchanged(&before_bids, &book);
    try expectOutput(&writer, "ERROR BookFull\n");

    writer.end = 0;
    book = engine.OrderBook.init();
    try fillSideWithRestingOrders(&writer, &book, .sell, 1);
    const before_asks = book;
    try applyCommandEvent(&writer, &book, sell(200, 111, 1));
    try expectBookUnchanged(&before_asks, &book);
    try expectOutput(&writer, "ERROR BookFull\n");
}

test "full own side accepts an incoming order that fully crosses" {
    var book = engine.OrderBook.init();
    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try applyCommandEvent(&writer, &book, sell(200, 100, 1));
    try applyCommandEvent(&writer, &book, buy(201, 100, 1));

    try std.testing.expectEqual(@as(usize, engine.max_orders), book.bid_count);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
    try expectOutput(&writer, "TRADE maker=200 taker=201 price=100 quantity=1\n");
}

test "crossing order with residual is rejected when residual cannot rest" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try applyCommandEvent(&writer, &book, sell(200, 100, 1));
    const before = book;
    try applyCommandEvent(&writer, &book, buy(201, 100, 2));

    try expectBookUnchanged(&before, &book);
    try expectOutput(&writer, "ERROR BookFull\n");
}

test "canceling a resting order frees capacity for another order" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try applyCommandEvent(&writer, &book, cancel(1));
    try applyCommandEvent(&writer, &book, buy(200, 89, 1));

    try std.testing.expectEqual(@as(usize, engine.max_orders), book.bid_count);
    try std.testing.expect(!book.containsOrder(1));
    try std.testing.expect(book.containsOrder(200));
    try expectOutput(&writer, "CANCELED 1\n");
}

test "fully filling a resting order frees capacity for another order" {
    var book = engine.OrderBook.init();
    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try applyCommandEvent(&writer, &book, sell(200, 90, 1));
    try applyCommandEvent(&writer, &book, buy(201, 89, 1));

    try std.testing.expectEqual(@as(usize, engine.max_orders), book.bid_count);
    try std.testing.expect(!book.containsOrder(1));
    try std.testing.expect(book.containsOrder(201));
    try expectOutput(&writer, "TRADE maker=1 taker=200 price=90 quantity=1\n");
}
