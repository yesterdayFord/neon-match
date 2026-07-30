const std = @import("std");
const engine = @import("engine.zig");

pub const CommandEvent = union(enum) {
    submit_limit: engine.Order,
    cancel: engine.OrderId,
};

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdin = &stdin_reader.interface;
    const stdout = &stdout_writer.interface;

    var book = engine.OrderBook.init();
    var line_buffer: [256]u8 = undefined;

    try stdout.writeAll("commands: BUY id price quantity | SELL id price quantity | CANCEL id\n");
    try stdout.flush();

    while (try readLine(stdin, &line_buffer)) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        const event = parseCommandEvent(trimmed) catch |err| {
            try stdout.print("ERROR {s}\n", .{@errorName(err)});
            try printState(stdout, &book);
            try stdout.flush();
            continue;
        };

        try applyCommandEvent(stdout, &book, event);

        try printState(stdout, &book);
        try stdout.flush();
    }
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

    try expectOutput(
        &writer,
        "commands: BUY id price quantity | SELL id price quantity | CANCEL id\n" ++
            "BOOK\n" ++
            "  BIDS\n" ++
            "    id=1 price=100 quantity=10\n" ++
            "  ASKS\n" ++
            "BOOK\n" ++
            "  BIDS\n" ++
            "    id=1 price=100 quantity=10\n" ++
            "  ASKS\n" ++
            "    id=2 price=110 quantity=5\n" ++
            "TRADE maker=1 taker=3 price=100 quantity=4\n" ++
            "BOOK\n" ++
            "  BIDS\n" ++
            "    id=1 price=100 quantity=6\n" ++
            "  ASKS\n" ++
            "    id=2 price=110 quantity=5\n" ++
            "TRADE maker=2 taker=4 price=110 quantity=5\n" ++
            "BOOK\n" ++
            "  BIDS\n" ++
            "    id=4 price=110 quantity=3\n" ++
            "    id=1 price=100 quantity=6\n" ++
            "  ASKS\n" ++
            "NOT_FOUND 2\n" ++
            "BOOK\n" ++
            "  BIDS\n" ++
            "    id=4 price=110 quantity=3\n" ++
            "    id=1 price=100 quantity=6\n" ++
            "  ASKS\n",
    );
    try std.testing.expectEqual(@as(usize, 2), book.bid_count);
    try std.testing.expectEqual(@as(engine.OrderId, 4), book.bids[0].id);
    try std.testing.expectEqual(@as(engine.Quantity, 3), book.bids[0].quantity);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book.bids[1].id);
    try std.testing.expectEqual(@as(engine.Quantity, 6), book.bids[1].quantity);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
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
