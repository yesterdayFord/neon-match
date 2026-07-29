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

test "stdin command produces a command event" {
    const event = try parseCommandEvent("BUY 1 100 10");
    const order = event.submit_limit;

    try std.testing.expectEqual(engine.Side.buy, order.side);
    try std.testing.expectEqual(@as(engine.OrderId, 1), order.id);
    try std.testing.expectEqual(@as(engine.Price, 100), order.price);
    try std.testing.expectEqual(@as(engine.Quantity, 10), order.quantity);
}

test "command event can be applied without stdin" {
    var book = engine.OrderBook.init();
    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    const event: CommandEvent = .{ .submit_limit = .{
        .id = 1,
        .side = .buy,
        .price = 100,
        .quantity = 10,
    } };
    try applyCommandEvent(&writer, &book, event);

    try std.testing.expect(book.containsOrder(1));
}

test "full bid side does not reject buy that fully crosses an ask" {
    var book = engine.OrderBook.init();

    var id: engine.OrderId = 1;
    while (id <= engine.max_orders) : (id += 1) {
        _ = book.submitLimit(.{ .id = id, .side = .buy, .price = 90, .quantity = 1 });
    }
    _ = book.submitLimit(.{ .id = 200, .side = .sell, .price = 100, .quantity = 1 });

    var output_buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try std.testing.expect(try canAccept(&writer, &book, .{
        .id = 201,
        .side = .buy,
        .price = 100,
        .quantity = 1,
    }));
}
