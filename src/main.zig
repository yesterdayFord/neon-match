const std = @import("std");
const engine = @import("engine.zig");

const Command = union(enum) {
    buy: InputOrder,
    sell: InputOrder,
    cancel: engine.OrderId,
};

const InputOrder = struct {
    id: engine.OrderId,
    price: engine.Price,
    quantity: engine.Quantity,
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

        const parsed = parseCommand(trimmed) catch |err| {
            try stdout.print("ERROR {s}\n", .{@errorName(err)});
            try printState(stdout, &book);
            try stdout.flush();
            continue;
        };

        switch (parsed) {
            .buy => |input| {
                const order: engine.Order = .{
                    .id = input.id,
                    .side = .buy,
                    .price = input.price,
                    .quantity = input.quantity,
                };
                if (!try canAccept(stdout, &book, order)) {
                    try printState(stdout, &book);
                    try stdout.flush();
                    continue;
                }
                const result = book.submitLimit(order);
                try printTrades(stdout, &result);
            },
            .sell => |input| {
                const order: engine.Order = .{
                    .id = input.id,
                    .side = .sell,
                    .price = input.price,
                    .quantity = input.quantity,
                };
                if (!try canAccept(stdout, &book, order)) {
                    try printState(stdout, &book);
                    try stdout.flush();
                    continue;
                }
                const result = book.submitLimit(order);
                try printTrades(stdout, &result);
            },
            .cancel => |id| {
                if (book.cancel(id)) {
                    try stdout.print("CANCELED {d}\n", .{id});
                } else {
                    try stdout.print("NOT_FOUND {d}\n", .{id});
                }
            },
        }

        try printState(stdout, &book);
        try stdout.flush();
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

fn parseCommand(line: []const u8) !Command {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n");
    const verb = tokens.next() orelse return error.EmptyCommand;

    if (std.mem.eql(u8, verb, "BUY")) {
        const order = try parseInputOrder(&tokens);
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .buy = order };
    }

    if (std.mem.eql(u8, verb, "SELL")) {
        const order = try parseInputOrder(&tokens);
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .sell = order };
    }

    if (std.mem.eql(u8, verb, "CANCEL")) {
        const id_text = tokens.next() orelse return error.MissingOrderId;
        if (tokens.next() != null) return error.TooManyFields;
        return .{ .cancel = try parsePositive(engine.OrderId, id_text) };
    }

    return error.UnknownCommand;
}

fn parseInputOrder(tokens: *std.mem.TokenIterator(u8, .any)) !InputOrder {
    const id_text = tokens.next() orelse return error.MissingOrderId;
    const price_text = tokens.next() orelse return error.MissingPrice;
    const quantity_text = tokens.next() orelse return error.MissingQuantity;

    return .{
        .id = try parsePositive(engine.OrderId, id_text),
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

test "parse buy command" {
    const command = try parseCommand("BUY 1 100 10");
    try std.testing.expectEqual(@as(engine.OrderId, 1), command.buy.id);
    try std.testing.expectEqual(@as(engine.Price, 100), command.buy.price);
    try std.testing.expectEqual(@as(engine.Quantity, 10), command.buy.quantity);
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
