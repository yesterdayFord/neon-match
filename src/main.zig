const std = @import("std");
const engine = @import("engine.zig");
const journal = @import("journal.zig");

pub const CommandEvent = union(enum) {
    submit_limit: InstrumentedOrder,
    cancel: InstrumentedCancel,
};

pub const InstrumentId = u32;
pub const default_instrument_id: InstrumentId = 1;
pub const max_instruments = 4;

pub const InstrumentedOrder = struct {
    instrument_id: InstrumentId,
    order: engine.Order,
};

pub const InstrumentedCancel = struct {
    instrument_id: InstrumentId,
    order_id: engine.OrderId,
};

const BookSet = struct {
    books: [max_instruments]engine.OrderBook,

    fn init() BookSet {
        var books: [max_instruments]engine.OrderBook = undefined;
        for (&books) |*book| {
            book.* = engine.OrderBook.init();
        }
        return .{ .books = books };
    }

    fn bookFor(self: *BookSet, instrument_id: InstrumentId) !*engine.OrderBook {
        return &self.books[try instrumentIndex(instrument_id)];
    }
};

fn instrumentIndex(instrument_id: InstrumentId) !usize {
    if (instrument_id == 0 or instrument_id > max_instruments) return error.UnknownInstrument;
    return @intCast(instrument_id - 1);
}

const RunMode = union(enum) {
    live: []const u8,
    replay: []const u8,
};

const max_recovery_segments = 128;
const max_recovery_output_len = 32768;
const command_help = "commands: [INSTRUMENT id] BUY id price quantity | [INSTRUMENT id] SELL id price quantity | [INSTRUMENT id] CANCEL id\n";

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

    var books = BookSet.init();
    switch (mode) {
        .live => |journal_dir| try runLive(io, stdin, stdout, &books, journal_dir),
        .replay => |journal_path| try replayJournalPath(io, stdout, &books, journal_path),
    }
    try stdout.flush();
}

fn runLive(
    io: std.Io,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    books: *BookSet,
    journal_dir: []const u8,
) !void {
    var line_buffer: [256]u8 = undefined;
    try recoverJournalDir(io, books, journal_dir);
    var journal_segment = try journal.Segment.open(io, journal_dir);
    defer journal_segment.close();

    try stdout.writeAll(command_help);
    try stdout.flush();

    while (try readLine(stdin, &line_buffer)) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        const event = parseCommandEvent(trimmed) catch |err| {
            try stdout.print("ERROR {s}\n", .{@errorName(err)});
            try printState(stdout, books);
            try stdout.flush();
            continue;
        };

        try applyJournaledCommand(stdout, books, &journal_segment, event);

        try printInstrumentState(stdout, books, commandEventInstrumentId(event));
        try stdout.flush();
    }
}

fn recoverJournalDir(
    io: std.Io,
    books: *BookSet,
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
        try recoverJournalPath(io, books, segment.slice(), index + 1 == segment_count);
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
    books: *BookSet,
    path: []const u8,
    is_final_segment: bool,
) !void {
    var reader = try journal.Reader.open(io, path);
    defer reader.close();

    var output_buffer: [max_recovery_output_len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    while (try reader.next()) |record| {
        try applyCommandEvent(&writer, books, commandEventFromJournalRecord(record));
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
    books: *BookSet,
    segment: anytype,
    event: CommandEvent,
) !void {
    try appendJournalEvent(segment, event);
    try applyCommandEvent(writer, books, event);
}

fn appendJournalEvent(segment: anytype, event: CommandEvent) !void {
    switch (event) {
        .submit_limit => |instrumented| try segment.appendSubmitLimit(instrumented.instrument_id, instrumented.order),
        .cancel => |instrumented| try segment.appendCancel(instrumented.instrument_id, instrumented.order_id),
    }
}

pub fn replayJournalPath(
    io: std.Io,
    writer: *std.Io.Writer,
    books: *BookSet,
    path: []const u8,
) !void {
    var reader = try journal.Reader.open(io, path);
    defer reader.close();
    try replayJournal(writer, books, &reader);
}

pub fn replayJournal(
    writer: *std.Io.Writer,
    books: *BookSet,
    reader: *journal.Reader,
) !void {
    try writer.writeAll(command_help);
    while (try reader.next()) |record| {
        const event = commandEventFromJournalRecord(record);
        try applyCommandEvent(writer, books, event);
        try printInstrumentState(writer, books, commandEventInstrumentId(event));
    }
}

fn commandEventFromJournalRecord(record: journal.Record) CommandEvent {
    return switch (record) {
        .submit_limit => |instrumented| .{ .submit_limit = .{
            .instrument_id = instrumented.instrument_id,
            .order = instrumented.order,
        } },
        .cancel => |instrumented| .{ .cancel = .{
            .instrument_id = instrumented.instrument_id,
            .order_id = instrumented.order_id,
        } },
    };
}

fn commandEventInstrumentId(event: CommandEvent) InstrumentId {
    return switch (event) {
        .submit_limit => |instrumented| instrumented.instrument_id,
        .cancel => |instrumented| instrumented.instrument_id,
    };
}

pub fn applyCommandEvent(
    writer: *std.Io.Writer,
    books: *BookSet,
    event: CommandEvent,
) !void {
    switch (event) {
        .submit_limit => |instrumented| {
            const book = try books.bookFor(instrumented.instrument_id);
            const order = instrumented.order;
            if (!try canAccept(writer, instrumented.instrument_id, book, order)) return;
            const result = book.submitLimit(order);
            try printTrades(writer, instrumented.instrument_id, &result);
        },
        .cancel => |instrumented| {
            const book = try books.bookFor(instrumented.instrument_id);
            const id = instrumented.order_id;
            if (book.cancel(id)) {
                try writer.print("INSTRUMENT {d} CANCELED {d}\n", .{ instrumented.instrument_id, id });
            } else {
                try writer.print("INSTRUMENT {d} NOT_FOUND {d}\n", .{ instrumented.instrument_id, id });
            }
        },
    }
}

fn canAccept(
    writer: *std.Io.Writer,
    instrument_id: InstrumentId,
    book: *const engine.OrderBook,
    order: engine.Order,
) !bool {
    if (book.containsOrder(order.id)) {
        try writer.print("INSTRUMENT {d} ERROR DuplicateOrderId {d}\n", .{ instrument_id, order.id });
        return false;
    }
    if (book.restingQuantityAfterMatch(order) > 0 and !book.hasRoomFor(order.side)) {
        try writer.print("INSTRUMENT {d} ERROR BookFull\n", .{instrument_id});
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

    if (std.mem.eql(u8, verb, "INSTRUMENT")) {
        const instrument_text = tokens.next() orelse return error.MissingInstrumentId;
        const instrument_id = try parseInstrumentId(instrument_text);
        const routed_verb = tokens.next() orelse return error.MissingCommand;
        return parseRoutedCommandEvent(&tokens, routed_verb, instrument_id);
    }

    return parseRoutedCommandEvent(&tokens, verb, default_instrument_id);
}

fn parseRoutedCommandEvent(
    tokens: *std.mem.TokenIterator(u8, .any),
    verb: []const u8,
    instrument_id: InstrumentId,
) !CommandEvent {
    if (std.mem.eql(u8, verb, "BUY")) {
        const order = try parseInputOrder(tokens, .buy);
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .submit_limit = .{ .instrument_id = instrument_id, .order = order } };
    }

    if (std.mem.eql(u8, verb, "SELL")) {
        const order = try parseInputOrder(tokens, .sell);
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .submit_limit = .{ .instrument_id = instrument_id, .order = order } };
    }

    if (std.mem.eql(u8, verb, "CANCEL")) {
        const id_text = tokens.next() orelse return error.MissingOrderId;
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .cancel = .{
            .instrument_id = instrument_id,
            .order_id = try parsePositive(engine.OrderId, id_text),
        } };
    }

    return error.UnknownCommand;
}

fn parseInstrumentId(text: []const u8) !InstrumentId {
    const instrument_id = try std.fmt.parseInt(InstrumentId, text, 10);
    _ = try instrumentIndex(instrument_id);
    return instrument_id;
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

fn printTrades(writer: *std.Io.Writer, instrument_id: InstrumentId, result: *const engine.MatchResult) !void {
    var index: usize = 0;
    while (index < result.trade_count) : (index += 1) {
        const trade = result.trades[index];
        try writer.print(
            "INSTRUMENT {d} TRADE maker={d} taker={d} price={d} quantity={d}\n",
            .{ instrument_id, trade.maker_id, trade.taker_id, trade.price, trade.quantity },
        );
    }
}

fn printState(writer: *std.Io.Writer, books: *const BookSet) !void {
    var active_count: usize = 0;
    for (books.books) |book| {
        if (book.bid_count > 0 or book.ask_count > 0) active_count += 1;
    }
    if (active_count <= 1) {
        const default_index = instrumentIndex(default_instrument_id) catch unreachable;
        const active_index = if (active_count == 0)
            default_index
        else blk: {
            for (books.books, 0..) |book, index| {
                if (book.bid_count > 0 or book.ask_count > 0) break :blk index;
            }
            unreachable;
        };
        if (active_index != default_index) try writer.print("INSTRUMENT {d}\n", .{active_index + 1});
        try printSingleBookState(writer, &books.books[active_index]);
        return;
    }

    var index: usize = 0;
    while (index < books.books.len) : (index += 1) {
        const book = &books.books[index];
        if (book.bid_count == 0 and book.ask_count == 0) continue;
        try writer.print("INSTRUMENT {d}\n", .{index + 1});
        try printSingleBookState(writer, book);
    }
}

fn printInstrumentState(writer: *std.Io.Writer, books: *const BookSet, instrument_id: InstrumentId) !void {
    const index = try instrumentIndex(instrument_id);
    try writer.print("INSTRUMENT {d}\n", .{instrument_id});
    try printSingleBookState(writer, &books.books[index]);
}

fn printSingleBookState(writer: *std.Io.Writer, book: *const engine.OrderBook) !void {
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
    return instrumentBuy(default_instrument_id, id, price, quantity);
}

fn sell(id: engine.OrderId, price: engine.Price, quantity: engine.Quantity) CommandEvent {
    return instrumentSell(default_instrument_id, id, price, quantity);
}

fn cancel(id: engine.OrderId) CommandEvent {
    return instrumentCancel(default_instrument_id, id);
}

fn instrumentBuy(instrument_id: InstrumentId, id: engine.OrderId, price: engine.Price, quantity: engine.Quantity) CommandEvent {
    return .{ .submit_limit = .{
        .instrument_id = instrument_id,
        .order = .{ .id = id, .side = .buy, .price = price, .quantity = quantity },
    } };
}

fn instrumentSell(instrument_id: InstrumentId, id: engine.OrderId, price: engine.Price, quantity: engine.Quantity) CommandEvent {
    return .{ .submit_limit = .{
        .instrument_id = instrument_id,
        .order = .{ .id = id, .side = .sell, .price = price, .quantity = quantity },
    } };
}

fn instrumentCancel(instrument_id: InstrumentId, id: engine.OrderId) CommandEvent {
    return .{ .cancel = .{ .instrument_id = instrument_id, .order_id = id } };
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

fn expectBooksEqual(expected: *const BookSet, actual: *const BookSet) !void {
    for (expected.books, actual.books) |expected_book, actual_book| {
        try expectBookUnchanged(&expected_book, &actual_book);
    }
}

fn applySingleBookCommandEvent(
    writer: *std.Io.Writer,
    book: *engine.OrderBook,
    event: CommandEvent,
) !void {
    var books = BookSet.init();
    books.books[instrumentIndex(default_instrument_id) catch unreachable] = book.*;
    try applyCommandEvent(writer, &books, event);
    book.* = books.books[instrumentIndex(default_instrument_id) catch unreachable];
}

fn applyJournaledCommandToSingleBook(
    writer: *std.Io.Writer,
    book: *engine.OrderBook,
    segment: anytype,
    event: CommandEvent,
) !void {
    var books = BookSet.init();
    books.books[instrumentIndex(default_instrument_id) catch unreachable] = book.*;
    try applyJournaledCommand(writer, &books, segment, event);
    book.* = books.books[instrumentIndex(default_instrument_id) catch unreachable];
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
        try applySingleBookCommandEvent(writer, book, event);
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

fn journalRecordCount(io: std.Io, path: []const u8) !usize {
    var reader = try journal.Reader.open(io, path);
    defer reader.close();

    var count: usize = 0;
    while (try reader.next()) |_| {
        count += 1;
    }
    return count;
}

fn singleJournalPath(
    io: std.Io,
    tmp: *std.testing.TmpDir,
    journal_dir: []const u8,
    buffer: []u8,
) ![]const u8 {
    var it = tmp.dir.iterate();
    const entry = (try it.next(io)) orelse return error.MissingJournalSegment;
    try std.testing.expect((try it.next(io)) == null);
    return try std.fmt.bufPrint(buffer, "{s}/{s}", .{ journal_dir, entry.name });
}

fn encodeJournalEvent(writer: *std.Io.Writer, event: CommandEvent) !void {
    switch (event) {
        .submit_limit => |instrumented| {
            const order = instrumented.order;
            var payload: [29]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], instrumented.instrument_id, .little);
            payload[4] = switch (order.side) {
                .buy => 1,
                .sell => 2,
            };
            std.mem.writeInt(u64, payload[5..13], order.id, .little);
            std.mem.writeInt(u64, payload[13..21], order.price, .little);
            std.mem.writeInt(u64, payload[21..29], order.quantity, .little);
            try encodeJournalRecord(writer, 1, &payload);
        },
        .cancel => |instrumented| {
            var payload: [12]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], instrumented.instrument_id, .little);
            std.mem.writeInt(u64, payload[4..12], instrumented.order_id, .little);
            try encodeJournalRecord(writer, 2, &payload);
        },
    }
}

fn encodeJournalRecord(writer: *std.Io.Writer, kind: u8, payload: []const u8) !void {
    var header: [14]u8 = undefined;
    @memcpy(header[0..4], "NMJ1");
    header[4] = 2;
    header[5] = kind;
    std.mem.writeInt(u32, header[6..10], @intCast(payload.len), .little);
    std.mem.writeInt(u32, header[10..14], std.hash.Crc32.hash(payload), .little);
    try writer.writeAll(&header);
    try writer.writeAll(payload);
}

test "parse buy sell and cancel commands into command events" {
    const buy_event = try parseCommandEvent("BUY 1 100 10");
    const buy_order = buy_event.submit_limit.order;
    try std.testing.expectEqual(default_instrument_id, buy_event.submit_limit.instrument_id);
    try std.testing.expectEqual(engine.Side.buy, buy_order.side);
    try std.testing.expectEqual(@as(engine.OrderId, 1), buy_order.id);
    try std.testing.expectEqual(@as(engine.Price, 100), buy_order.price);
    try std.testing.expectEqual(@as(engine.Quantity, 10), buy_order.quantity);

    const sell_event = try parseCommandEvent("SELL 2 110 5");
    const sell_order = sell_event.submit_limit.order;
    try std.testing.expectEqual(default_instrument_id, sell_event.submit_limit.instrument_id);
    try std.testing.expectEqual(engine.Side.sell, sell_order.side);
    try std.testing.expectEqual(@as(engine.OrderId, 2), sell_order.id);
    try std.testing.expectEqual(@as(engine.Price, 110), sell_order.price);
    try std.testing.expectEqual(@as(engine.Quantity, 5), sell_order.quantity);

    const cancel_event = try parseCommandEvent("CANCEL 2");
    try std.testing.expectEqual(default_instrument_id, cancel_event.cancel.instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 2), cancel_event.cancel.order_id);
}

test "parse explicit instrument prefix into routed command events" {
    const buy_event = try parseCommandEvent("INSTRUMENT 2 BUY 1 100 10");
    try std.testing.expectEqual(@as(InstrumentId, 2), buy_event.submit_limit.instrument_id);
    try std.testing.expectEqual(engine.Side.buy, buy_event.submit_limit.order.side);
    try std.testing.expectEqual(@as(engine.OrderId, 1), buy_event.submit_limit.order.id);

    const cancel_event = try parseCommandEvent("INSTRUMENT 2 CANCEL 1");
    try std.testing.expectEqual(@as(InstrumentId, 2), cancel_event.cancel.instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 1), cancel_event.cancel.order_id);

    try std.testing.expectError(error.UnknownInstrument, parseCommandEvent("INSTRUMENT 0 BUY 1 100 10"));
    try std.testing.expectError(error.UnknownInstrument, parseCommandEvent("INSTRUMENT 5 BUY 1 100 10"));
}

test "buy sell and cancel events can be applied without stdin" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applySingleBookCommandEvent(&writer, &book, buy(1, 100, 10));
    try applySingleBookCommandEvent(&writer, &book, sell(2, 110, 5));
    try applySingleBookCommandEvent(&writer, &book, cancel(1));

    try std.testing.expect(!book.containsOrder(1));
    try std.testing.expect(book.containsOrder(2));
    try expectOutput(&writer, "INSTRUMENT 1 CANCELED 1\n");
}

test "direct command event replay matches stdin fixture output" {
    var book = engine.OrderBook.init();
    var output_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try writer.writeAll(command_help);

    const events = [_]CommandEvent{
        buy(1, 100, 10),
        sell(2, 110, 5),
        sell(3, 100, 4),
        buy(4, 110, 8),
        cancel(2),
    };
    for (events) |event| {
        try applySingleBookCommandEvent(&writer, &book, event);
        var books = BookSet.init();
        books.books[instrumentIndex(default_instrument_id) catch unreachable] = book;
        try printInstrumentState(&writer, &books, commandEventInstrumentId(event));
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

test "routed commands only match within the targeted instrument" {
    var books = BookSet.init();
    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applyCommandEvent(&writer, &books, instrumentSell(1, 1, 100, 5));
    try applyCommandEvent(&writer, &books, instrumentBuy(2, 1, 100, 5));
    try expectOutput(&writer, "");

    const book_1 = try books.bookFor(1);
    const book_2 = try books.bookFor(2);
    try std.testing.expectEqual(@as(usize, 1), book_1.ask_count);
    try std.testing.expectEqual(@as(usize, 1), book_2.bid_count);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book_1.asks[0].id);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book_2.bids[0].id);

    try applyCommandEvent(&writer, &books, instrumentBuy(1, 2, 100, 5));
    try expectOutput(&writer, "INSTRUMENT 1 TRADE maker=1 taker=2 price=100 quantity=5\n");
    try std.testing.expectEqual(@as(usize, 0), book_1.ask_count);
    try std.testing.expectEqual(@as(usize, 1), book_2.bid_count);
}

test "cancel only affects the targeted instrument" {
    var books = BookSet.init();
    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applyCommandEvent(&writer, &books, instrumentBuy(1, 1, 90, 1));
    try applyCommandEvent(&writer, &books, instrumentBuy(2, 1, 90, 1));
    try applyCommandEvent(&writer, &books, instrumentCancel(1, 1));

    const book_1 = try books.bookFor(1);
    const book_2 = try books.bookFor(2);
    try std.testing.expectEqual(@as(usize, 0), book_1.bid_count);
    try std.testing.expectEqual(@as(usize, 1), book_2.bid_count);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book_2.bids[0].id);
    try expectOutput(&writer, "INSTRUMENT 1 CANCELED 1\n");
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

    var live_books = BookSet.init();
    var live_output_buffer: [2048]u8 = undefined;
    var live_writer = std.Io.Writer.fixed(&live_output_buffer);
    var stdin = std.Io.Reader.fixed(commands);
    try runLive(io, &stdin, &live_writer, &live_books, journal_dir);

    var it = tmp.dir.iterate();
    const entry = (try it.next(io)) orelse return error.MissingJournalSegment;
    try std.testing.expect((try it.next(io)) == null);
    var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&journal_path_buffer, "{s}/{s}", .{ journal_dir, entry.name });

    var replay_books = BookSet.init();
    var replay_output_buffer: [2048]u8 = undefined;
    var replay_writer = std.Io.Writer.fixed(&replay_output_buffer);
    try replayJournalPath(io, &replay_writer, &replay_books, journal_path);

    try expectOutput(&replay_writer, live_writer.buffered());
    try expectBooksEqual(&live_books, &replay_books);
}

test "journal replay matches routed live input output and final book state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const commands =
        "INSTRUMENT 1 SELL 1 100 5\n" ++
        "INSTRUMENT 2 BUY 1 100 5\n" ++
        "INSTRUMENT 1 BUY 2 100 5\n" ++
        "INSTRUMENT 2 CANCEL 1\n";

    var live_books = BookSet.init();
    var live_output_buffer: [4096]u8 = undefined;
    var live_writer = std.Io.Writer.fixed(&live_output_buffer);
    var stdin = std.Io.Reader.fixed(commands);
    try runLive(io, &stdin, &live_writer, &live_books, journal_dir);

    var it = tmp.dir.iterate();
    const entry = (try it.next(io)) orelse return error.MissingJournalSegment;
    try std.testing.expect((try it.next(io)) == null);
    var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&journal_path_buffer, "{s}/{s}", .{ journal_dir, entry.name });

    var replay_books = BookSet.init();
    var replay_output_buffer: [4096]u8 = undefined;
    var replay_writer = std.Io.Writer.fixed(&replay_output_buffer);
    try replayJournalPath(io, &replay_writer, &replay_books, journal_path);

    try expectOutput(&replay_writer, live_writer.buffered());
    try expectBooksEqual(&live_books, &replay_books);
}

test "invalid routed instruments are not journaled and do not mutate books" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const commands =
        "INSTRUMENT 0 BUY 1 100 5\n" ++
        "INSTRUMENT 5 BUY 1 100 5\n";

    var books = BookSet.init();
    const before = books;
    var output_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var stdin = std.Io.Reader.fixed(commands);
    try runLive(io, &stdin, &writer, &books, journal_dir);

    var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal_path = try singleJournalPath(io, &tmp, journal_dir, &journal_path_buffer);
    try std.testing.expectEqual(@as(usize, 0), try journalRecordCount(io, journal_path));
    try expectBooksEqual(&before, &books);
    try expectOutput(
        &writer,
        command_help ++
            "ERROR UnknownInstrument\n" ++
            "BOOK\n" ++
            "  BIDS\n" ++
            "  ASKS\n" ++
            "ERROR UnknownInstrument\n" ++
            "BOOK\n" ++
            "  BIDS\n" ++
            "  ASKS\n",
    );
}

test "routed duplicate id rejection is journaled without mutating any book" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const commands =
        "INSTRUMENT 1 BUY 1 90 1\n" ++
        "INSTRUMENT 2 BUY 1 91 1\n" ++
        "INSTRUMENT 1 BUY 1 92 1\n";

    var live_books = BookSet.init();
    var live_output_buffer: [4096]u8 = undefined;
    var live_writer = std.Io.Writer.fixed(&live_output_buffer);
    var stdin = std.Io.Reader.fixed(commands);
    try runLive(io, &stdin, &live_writer, &live_books, journal_dir);

    const book_1 = try live_books.bookFor(1);
    const book_2 = try live_books.bookFor(2);
    try std.testing.expectEqual(@as(usize, 1), book_1.bid_count);
    try std.testing.expectEqual(@as(engine.Price, 90), book_1.bids[0].price);
    try std.testing.expectEqual(@as(usize, 1), book_2.bid_count);
    try std.testing.expectEqual(@as(engine.Price, 91), book_2.bids[0].price);
    try std.testing.expect(std.mem.indexOf(u8, live_writer.buffered(), "ERROR DuplicateOrderId 1\n") != null);

    var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal_path = try singleJournalPath(io, &tmp, journal_dir, &journal_path_buffer);
    try std.testing.expectEqual(@as(usize, 3), try journalRecordCount(io, journal_path));

    var replay_books = BookSet.init();
    var replay_output_buffer: [4096]u8 = undefined;
    var replay_writer = std.Io.Writer.fixed(&replay_output_buffer);
    try replayJournalPath(io, &replay_writer, &replay_books, journal_path);

    try expectOutput(&replay_writer, live_writer.buffered());
    try expectBooksEqual(&live_books, &replay_books);
}

test "routed book full rejection is journaled and isolated to the targeted book" {
    const CountingJournal = struct {
        append_count: usize = 0,

        fn appendSubmitLimit(self: *@This(), instrument_id: InstrumentId, order: engine.Order) !void {
            try std.testing.expectEqual(@as(InstrumentId, 2), instrument_id);
            try std.testing.expectEqual(@as(engine.OrderId, 200), order.id);
            self.append_count += 1;
        }

        fn appendCancel(_: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            return error.UnexpectedCancelAppend;
        }
    };

    var books = BookSet.init();
    var discard_buffer: [64]u8 = undefined;
    var discard_writer = std.Io.Writer.fixed(&discard_buffer);
    var id: engine.OrderId = 1;
    while (id <= engine.max_orders) : (id += 1) {
        discard_writer.end = 0;
        try applyCommandEvent(&discard_writer, &books, instrumentBuy(2, id, 90, 1));
    }
    discard_writer.end = 0;
    try applyCommandEvent(&discard_writer, &books, instrumentBuy(1, 1, 90, 1));
    const before = books;

    var journal_segment = CountingJournal{};
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try applyJournaledCommand(&writer, &books, &journal_segment, instrumentBuy(2, 200, 89, 1));

    try std.testing.expectEqual(@as(usize, 1), journal_segment.append_count);
    try expectBooksEqual(&before, &books);
    try expectOutput(&writer, "INSTRUMENT 2 ERROR BookFull\n");
}

test "startup recovery preserves routed journal state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try writeJournalSegment(
        tmp.dir,
        "journal-20260730T014500Z-000001.nmj",
        &.{
            instrumentSell(2, 1, 100, 5),
            instrumentBuy(1, 1, 100, 5),
        },
    );

    var recovered_books = BookSet.init();
    try recoverJournalDir(io, &recovered_books, journal_dir);

    const book_1 = try recovered_books.bookFor(1);
    const book_2 = try recovered_books.bookFor(2);
    try std.testing.expectEqual(@as(usize, 1), book_1.bid_count);
    try std.testing.expectEqual(@as(usize, 1), book_2.ask_count);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book_1.bids[0].id);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book_2.asks[0].id);
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

    var recovered_books = BookSet.init();
    var recovered_output_buffer: [1024]u8 = undefined;
    var recovered_writer = std.Io.Writer.fixed(&recovered_output_buffer);
    var stdin = std.Io.Reader.fixed("SELL 2 100 4\n");
    try runLive(io, &stdin, &recovered_writer, &recovered_books, journal_dir);

    var expected_books = BookSet.init();
    var expected_output_buffer: [1024]u8 = undefined;
    var expected_writer = std.Io.Writer.fixed(&expected_output_buffer);
    try expected_writer.writeAll(command_help);
    try applyCommandEvent(&expected_writer, &expected_books, buy(1, 100, 10));
    expected_writer.end = command_help.len;
    try applyCommandEvent(&expected_writer, &expected_books, sell(2, 100, 4));
    try printInstrumentState(&expected_writer, &expected_books, default_instrument_id);

    try expectOutput(&recovered_writer, expected_writer.buffered());
    try expectBooksEqual(&expected_books, &recovered_books);

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

    var recovered_books = BookSet.init();
    var recovered_output_buffer: [1024]u8 = undefined;
    var recovered_writer = std.Io.Writer.fixed(&recovered_output_buffer);
    var stdin = std.Io.Reader.fixed("SELL 2 100 1\n");
    try runLive(io, &stdin, &recovered_writer, &recovered_books, journal_dir);

    var expected_books = BookSet.init();
    var expected_output_buffer: [1024]u8 = undefined;
    var expected_writer = std.Io.Writer.fixed(&expected_output_buffer);
    try expected_writer.writeAll(command_help);
    try applyCommandEvent(&expected_writer, &expected_books, buy(1, 100, 10));
    try applyCommandEvent(&expected_writer, &expected_books, cancel(1));
    expected_writer.end = command_help.len;
    try applyCommandEvent(&expected_writer, &expected_books, sell(2, 100, 1));
    try printInstrumentState(&expected_writer, &expected_books, default_instrument_id);

    try expectOutput(&recovered_writer, expected_writer.buffered());
    try expectBooksEqual(&expected_books, &recovered_books);
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

    var recovered_books = BookSet.init();
    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var stdin = std.Io.Reader.fixed("");
    try runLive(io, &stdin, &writer, &recovered_books, journal_dir);

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

    var books = BookSet.init();
    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var stdin = std.Io.Reader.fixed("");
    try runLive(io, &stdin, &writer, &books, journal_dir);

    var bad_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer bad_tmp.cleanup();
    var bad_journal_dir_buffer: [64]u8 = undefined;
    const bad_journal_dir = try std.fmt.bufPrint(&bad_journal_dir_buffer, ".zig-cache/tmp/{s}", .{bad_tmp.sub_path[0..]});
    number = 1;
    while (number <= max_recovery_segments + 1) : (number += 1) {
        try writeEmptyJournalSegmentNumber(bad_tmp.dir, number);
    }

    var bad_books = BookSet.init();
    var bad_output_buffer: [1024]u8 = undefined;
    var bad_writer = std.Io.Writer.fixed(&bad_output_buffer);
    var bad_stdin = std.Io.Reader.fixed("");
    try std.testing.expectError(
        error.RecoverySegmentLimitExceeded,
        runLive(io, &bad_stdin, &bad_writer, &bad_books, bad_journal_dir),
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

    var recovered_books = BookSet.init();
    var recovered_output_buffer: [1024]u8 = undefined;
    var recovered_writer = std.Io.Writer.fixed(&recovered_output_buffer);
    var stdin = std.Io.Reader.fixed("SELL 2 100 4\n");
    try runLive(io, &stdin, &recovered_writer, &recovered_books, journal_dir);
    const recovered_book = try recovered_books.bookFor(default_instrument_id);
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

    var bad_books = BookSet.init();
    var bad_output_buffer: [1024]u8 = undefined;
    var bad_writer = std.Io.Writer.fixed(&bad_output_buffer);
    var bad_stdin = std.Io.Reader.fixed("");
    try std.testing.expectError(
        error.IncompleteJournalRecordBeforeFinalSegment,
        runLive(io, &bad_stdin, &bad_writer, &bad_books, bad_journal_dir),
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

    var books = BookSet.init();
    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var stdin = std.Io.Reader.fixed("");
    try std.testing.expectError(
        error.InvalidJournalChecksum,
        runLive(io, &stdin, &writer, &books, journal_dir),
    );
}

test "journal submit append failure prevents command application" {
    const FailingJournal = struct {
        fn appendSubmitLimit(_: *@This(), _: InstrumentId, _: engine.Order) !void {
            return error.JournalWriteFailed;
        }

        fn appendCancel(_: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            return error.JournalWriteFailed;
        }
    };

    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var failing_journal = FailingJournal{};

    try std.testing.expectError(
        error.JournalWriteFailed,
        applyJournaledCommandToSingleBook(&writer, &book, &failing_journal, buy(1, 100, 10)),
    );

    try std.testing.expect(!book.containsOrder(1));
    try expectOutput(&writer, "");
}

test "journal cancel append failure prevents command application" {
    const FailingJournal = struct {
        fn appendSubmitLimit(_: *@This(), _: InstrumentId, _: engine.Order) !void {
            return error.JournalWriteFailed;
        }

        fn appendCancel(_: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            return error.JournalWriteFailed;
        }
    };

    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    try applySingleBookCommandEvent(&writer, &book, buy(1, 100, 10));
    const before = book;
    writer.end = 0;

    var failing_journal = FailingJournal{};
    try std.testing.expectError(
        error.JournalWriteFailed,
        applyJournaledCommandToSingleBook(&writer, &book, &failing_journal, cancel(1)),
    );

    try expectBookUnchanged(&before, &book);
    try expectOutput(&writer, "");
}

test "applyCommandEvent reports duplicate ids and leaves book unchanged" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applySingleBookCommandEvent(&writer, &book, buy(1, 100, 10));
    const before = book;
    try applySingleBookCommandEvent(&writer, &book, buy(1, 99, 5));

    try expectBookUnchanged(&before, &book);
    try expectOutput(&writer, "INSTRUMENT 1 ERROR DuplicateOrderId 1\n");
}

test "applyCommandEvent reports missing cancels without changing the book" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applySingleBookCommandEvent(&writer, &book, sell(1, 110, 5));
    const before = book;
    try applySingleBookCommandEvent(&writer, &book, cancel(404));

    try expectBookUnchanged(&before, &book);
    try expectOutput(&writer, "INSTRUMENT 1 NOT_FOUND 404\n");
}

test "applyCommandEvent handles partial fills and fully filled orders" {
    var book = engine.OrderBook.init();
    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try applySingleBookCommandEvent(&writer, &book, sell(1, 100, 10));
    try applySingleBookCommandEvent(&writer, &book, buy(2, 100, 4));
    try std.testing.expect(book.containsOrder(1));
    try std.testing.expectEqual(@as(engine.Quantity, 6), book.asks[0].quantity);

    try applySingleBookCommandEvent(&writer, &book, buy(3, 100, 6));
    try std.testing.expect(!book.containsOrder(1));
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
    try expectOutput(
        &writer,
        "INSTRUMENT 1 TRADE maker=1 taker=2 price=100 quantity=4\n" ++
            "INSTRUMENT 1 TRADE maker=1 taker=3 price=100 quantity=6\n",
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
    try applySingleBookCommandEvent(&writer, &book, buy(200, 89, 1));
    try expectBookUnchanged(&before_bids, &book);
    try expectOutput(&writer, "INSTRUMENT 1 ERROR BookFull\n");

    writer.end = 0;
    book = engine.OrderBook.init();
    try fillSideWithRestingOrders(&writer, &book, .sell, 1);
    const before_asks = book;
    try applySingleBookCommandEvent(&writer, &book, sell(200, 111, 1));
    try expectBookUnchanged(&before_asks, &book);
    try expectOutput(&writer, "INSTRUMENT 1 ERROR BookFull\n");
}

test "full own side accepts an incoming order that fully crosses" {
    var book = engine.OrderBook.init();
    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try applySingleBookCommandEvent(&writer, &book, sell(200, 100, 1));
    try applySingleBookCommandEvent(&writer, &book, buy(201, 100, 1));

    try std.testing.expectEqual(@as(usize, engine.max_orders), book.bid_count);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
    try expectOutput(&writer, "INSTRUMENT 1 TRADE maker=200 taker=201 price=100 quantity=1\n");
}

test "crossing order with residual is rejected when residual cannot rest" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try applySingleBookCommandEvent(&writer, &book, sell(200, 100, 1));
    const before = book;
    try applySingleBookCommandEvent(&writer, &book, buy(201, 100, 2));

    try expectBookUnchanged(&before, &book);
    try expectOutput(&writer, "INSTRUMENT 1 ERROR BookFull\n");
}

test "canceling a resting order frees capacity for another order" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try applySingleBookCommandEvent(&writer, &book, cancel(1));
    try applySingleBookCommandEvent(&writer, &book, buy(200, 89, 1));

    try std.testing.expectEqual(@as(usize, engine.max_orders), book.bid_count);
    try std.testing.expect(!book.containsOrder(1));
    try std.testing.expect(book.containsOrder(200));
    try expectOutput(&writer, "INSTRUMENT 1 CANCELED 1\n");
}

test "fully filling a resting order frees capacity for another order" {
    var book = engine.OrderBook.init();
    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try fillSideWithRestingOrders(&writer, &book, .buy, 1);
    try applySingleBookCommandEvent(&writer, &book, sell(200, 90, 1));
    try applySingleBookCommandEvent(&writer, &book, buy(201, 89, 1));

    try std.testing.expectEqual(@as(usize, engine.max_orders), book.bid_count);
    try std.testing.expect(!book.containsOrder(1));
    try std.testing.expect(book.containsOrder(201));
    try expectOutput(&writer, "INSTRUMENT 1 TRADE maker=1 taker=200 price=90 quantity=1\n");
}
