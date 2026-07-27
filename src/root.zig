const std = @import("std");

pub const OrderId = u64;
pub const Price = u64;
pub const Quantity = u64;

pub const Side = enum {
    buy,
    sell,
};

pub const Order = struct {
    id: OrderId,
    side: Side,
    price: Price,
    quantity: Quantity,
};

pub const Trade = struct {
    maker_id: OrderId,
    taker_id: OrderId,
    price: Price,
    quantity: Quantity,
};

pub const MatchResult = struct {
    allocator: std.mem.Allocator,
    trades: std.ArrayList(Trade),
    resting_quantity: Quantity,

    pub fn deinit(self: *MatchResult) void {
        self.trades.deinit(self.allocator);
    }
};

pub const OrderBook = struct {
    allocator: std.mem.Allocator,
    bids: std.ArrayList(Order),
    asks: std.ArrayList(Order),

    pub fn init(allocator: std.mem.Allocator) OrderBook {
        return .{
            .allocator = allocator,
            .bids = .empty,
            .asks = .empty,
        };
    }

    pub fn deinit(self: *OrderBook) void {
        self.bids.deinit(self.allocator);
        self.asks.deinit(self.allocator);
    }

    pub fn submitLimit(self: *OrderBook, order: Order) !MatchResult {
        var incoming = order;
        var result = MatchResult{
            .allocator = self.allocator,
            .trades = .empty,
            .resting_quantity = 0,
        };

        switch (incoming.side) {
            .buy => try self.matchBuy(&incoming, &result.trades),
            .sell => try self.matchSell(&incoming, &result.trades),
        }

        result.resting_quantity = incoming.quantity;

        if (incoming.quantity > 0) {
            switch (incoming.side) {
                .buy => try self.insertBid(incoming),
                .sell => try self.insertAsk(incoming),
            }
        }

        return result;
    }

    fn matchBuy(self: *OrderBook, incoming: *Order, trades: *std.ArrayList(Trade)) !void {
        var index: usize = 0;
        while (index < self.asks.items.len and incoming.quantity > 0) {
            const ask = &self.asks.items[index];
            if (ask.price > incoming.price) break;

            const filled = @min(incoming.quantity, ask.quantity);
            try trades.append(self.allocator, .{
                .maker_id = ask.id,
                .taker_id = incoming.id,
                .price = ask.price,
                .quantity = filled,
            });

            incoming.quantity -= filled;
            ask.quantity -= filled;

            if (ask.quantity == 0) {
                _ = self.asks.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    fn matchSell(self: *OrderBook, incoming: *Order, trades: *std.ArrayList(Trade)) !void {
        var index: usize = 0;
        while (index < self.bids.items.len and incoming.quantity > 0) {
            const bid = &self.bids.items[index];
            if (bid.price < incoming.price) break;

            const filled = @min(incoming.quantity, bid.quantity);
            try trades.append(self.allocator, .{
                .maker_id = bid.id,
                .taker_id = incoming.id,
                .price = bid.price,
                .quantity = filled,
            });

            incoming.quantity -= filled;
            bid.quantity -= filled;

            if (bid.quantity == 0) {
                _ = self.bids.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    fn insertBid(self: *OrderBook, order: Order) !void {
        var index: usize = 0;
        while (index < self.bids.items.len and self.bids.items[index].price >= order.price) {
            index += 1;
        }
        try self.bids.insert(self.allocator, index, order);
    }

    fn insertAsk(self: *OrderBook, order: Order) !void {
        var index: usize = 0;
        while (index < self.asks.items.len and self.asks.items[index].price <= order.price) {
            index += 1;
        }
        try self.asks.insert(self.allocator, index, order);
    }
};

test "limit orders rest when they do not cross" {
    var book = OrderBook.init(std.testing.allocator);
    defer book.deinit();

    var result = try book.submitLimit(.{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.trades.items.len);
    try std.testing.expectEqual(@as(Quantity, 10), result.resting_quantity);
    try std.testing.expectEqual(@as(usize, 1), book.bids.items.len);
}

test "crossing limit orders trade at maker price" {
    var book = OrderBook.init(std.testing.allocator);
    defer book.deinit();

    var bid_result = try book.submitLimit(.{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    defer bid_result.deinit();

    var ask_result = try book.submitLimit(.{ .id = 2, .side = .sell, .price = 90, .quantity = 4 });
    defer ask_result.deinit();

    try std.testing.expectEqual(@as(usize, 1), ask_result.trades.items.len);
    try std.testing.expectEqual(@as(OrderId, 1), ask_result.trades.items[0].maker_id);
    try std.testing.expectEqual(@as(OrderId, 2), ask_result.trades.items[0].taker_id);
    try std.testing.expectEqual(@as(Price, 100), ask_result.trades.items[0].price);
    try std.testing.expectEqual(@as(Quantity, 4), ask_result.trades.items[0].quantity);
    try std.testing.expectEqual(@as(Quantity, 0), ask_result.resting_quantity);
    try std.testing.expectEqual(@as(Quantity, 6), book.bids.items[0].quantity);
}
