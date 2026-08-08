const std = @import("std");

const assert = std.debug.assert;

pub const max_orders = 128;

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
    trades: [max_orders]Trade = undefined,
    trade_count: usize = 0,
    resting_quantity: Quantity = 0,

    pub fn appendTrade(self: *MatchResult, trade: Trade) void {
        assert(self.trade_count < self.trades.len);
        self.trades[self.trade_count] = trade;
        self.trade_count += 1;
    }
};

pub const OrderBook = struct {
    bids: [max_orders]Order = undefined,
    bid_count: usize = 0,
    asks: [max_orders]Order = undefined,
    ask_count: usize = 0,

    pub fn init() OrderBook {
        return .{};
    }

    // Low-level primitive for prevalidated orders. Callers must ensure the id is
    // unique and any residual quantity can rest before invoking this mutating path.
    pub fn submitLimit(self: *OrderBook, order: Order) MatchResult {
        assert(order.quantity > 0);
        assert(self.findIndex(order.id) == null);

        var incoming = order;
        var result = MatchResult{};

        switch (incoming.side) {
            .buy => self.matchBuy(&incoming, &result),
            .sell => self.matchSell(&incoming, &result),
        }

        result.resting_quantity = incoming.quantity;
        if (incoming.quantity > 0) {
            switch (incoming.side) {
                .buy => self.insertBid(incoming),
                .sell => self.insertAsk(incoming),
            }
        }

        return result;
    }

    pub fn cancel(self: *OrderBook, id: OrderId) bool {
        if (findIn(self.bids[0..self.bid_count], id)) |index| {
            removeAt(&self.bids, &self.bid_count, index);
            return true;
        }
        if (findIn(self.asks[0..self.ask_count], id)) |index| {
            removeAt(&self.asks, &self.ask_count, index);
            return true;
        }
        return false;
    }

    pub fn containsOrder(self: *const OrderBook, id: OrderId) bool {
        return self.findIndex(id) != null;
    }

    pub fn hasRoomFor(self: *const OrderBook, side: Side) bool {
        return switch (side) {
            .buy => self.bid_count < self.bids.len,
            .sell => self.ask_count < self.asks.len,
        };
    }

    pub fn validate(self: *const OrderBook) !void {
        if (self.bid_count > self.bids.len) return error.InvalidOrderBookBidCount;
        if (self.ask_count > self.asks.len) return error.InvalidOrderBookAskCount;

        try validateSide(self.bids[0..self.bid_count], .buy);
        try validateSide(self.asks[0..self.ask_count], .sell);
        try validateUniqueIds(self.bids[0..self.bid_count], self.asks[0..self.ask_count]);

        if (self.bid_count > 0 and self.ask_count > 0 and self.bids[0].price >= self.asks[0].price) {
            return error.InvalidOrderBookCrossed;
        }
    }

    pub fn restingQuantityAfterMatch(self: *const OrderBook, order: Order) Quantity {
        assert(order.quantity > 0);

        var remaining = order.quantity;
        switch (order.side) {
            .buy => {
                var index: usize = 0;
                while (index < self.ask_count and remaining > 0) : (index += 1) {
                    const ask = self.asks[index];
                    if (ask.price > order.price) break;
                    remaining -= @min(remaining, ask.quantity);
                }
            },
            .sell => {
                var index: usize = 0;
                while (index < self.bid_count and remaining > 0) : (index += 1) {
                    const bid = self.bids[index];
                    if (bid.price < order.price) break;
                    remaining -= @min(remaining, bid.quantity);
                }
            },
        }

        return remaining;
    }

    fn matchBuy(self: *OrderBook, incoming: *Order, result: *MatchResult) void {
        var index: usize = 0;
        while (index < self.ask_count and incoming.quantity > 0) {
            const ask = &self.asks[index];
            if (ask.price > incoming.price) break;

            const filled = @min(incoming.quantity, ask.quantity);
            result.appendTrade(.{
                .maker_id = ask.id,
                .taker_id = incoming.id,
                .price = ask.price,
                .quantity = filled,
            });

            incoming.quantity -= filled;
            ask.quantity -= filled;

            if (ask.quantity == 0) {
                removeAt(&self.asks, &self.ask_count, index);
            } else {
                index += 1;
            }
        }
    }

    fn matchSell(self: *OrderBook, incoming: *Order, result: *MatchResult) void {
        var index: usize = 0;
        while (index < self.bid_count and incoming.quantity > 0) {
            const bid = &self.bids[index];
            if (bid.price < incoming.price) break;

            const filled = @min(incoming.quantity, bid.quantity);
            result.appendTrade(.{
                .maker_id = bid.id,
                .taker_id = incoming.id,
                .price = bid.price,
                .quantity = filled,
            });

            incoming.quantity -= filled;
            bid.quantity -= filled;

            if (bid.quantity == 0) {
                removeAt(&self.bids, &self.bid_count, index);
            } else {
                index += 1;
            }
        }
    }

    fn insertBid(self: *OrderBook, order: Order) void {
        assert(self.bid_count < self.bids.len);
        var index: usize = 0;
        while (index < self.bid_count and self.bids[index].price >= order.price) {
            index += 1;
        }
        insertAt(&self.bids, &self.bid_count, index, order);
    }

    fn insertAsk(self: *OrderBook, order: Order) void {
        assert(self.ask_count < self.asks.len);
        var index: usize = 0;
        while (index < self.ask_count and self.asks[index].price <= order.price) {
            index += 1;
        }
        insertAt(&self.asks, &self.ask_count, index, order);
    }

    fn findIndex(self: *const OrderBook, id: OrderId) ?usize {
        if (findIn(self.bids[0..self.bid_count], id)) |index| return index;
        if (findIn(self.asks[0..self.ask_count], id)) |index| return self.bid_count + index;
        return null;
    }
};

fn validateSide(orders: []const Order, side: Side) !void {
    for (orders, 0..) |order, index| {
        if (order.side != side) return error.InvalidOrderBookSide;
        if (order.quantity == 0) return error.InvalidOrderBookQuantity;

        if (index > 0) {
            const previous = orders[index - 1];
            switch (side) {
                .buy => if (previous.price < order.price) return error.InvalidOrderBookBidSort,
                .sell => if (previous.price > order.price) return error.InvalidOrderBookAskSort,
            }
        }
    }
}

fn validateUniqueIds(bids: []const Order, asks: []const Order) !void {
    for (bids, 0..) |order, index| {
        if (findIn(bids[index + 1 ..], order.id) != null) return error.InvalidOrderBookDuplicateId;
        if (findIn(asks, order.id) != null) return error.InvalidOrderBookDuplicateId;
    }

    for (asks, 0..) |order, index| {
        if (findIn(asks[index + 1 ..], order.id) != null) return error.InvalidOrderBookDuplicateId;
    }
}

fn findIn(orders: []const Order, id: OrderId) ?usize {
    for (orders, 0..) |order, index| {
        if (order.id == id) return index;
    }
    return null;
}

fn insertAt(orders: *[max_orders]Order, count: *usize, index: usize, order: Order) void {
    assert(index <= count.*);
    assert(count.* < orders.len);

    var move_index = count.*;
    while (move_index > index) : (move_index -= 1) {
        orders[move_index] = orders[move_index - 1];
    }
    orders[index] = order;
    count.* += 1;
}

fn removeAt(orders: *[max_orders]Order, count: *usize, index: usize) void {
    assert(index < count.*);

    var move_index = index;
    while (move_index + 1 < count.*) : (move_index += 1) {
        orders[move_index] = orders[move_index + 1];
    }
    count.* -= 1;
}

test "limit orders rest when they do not cross" {
    var book = OrderBook.init();

    const result = book.submitLimit(.{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });

    try std.testing.expectEqual(@as(usize, 0), result.trade_count);
    try std.testing.expectEqual(@as(Quantity, 10), result.resting_quantity);
    try std.testing.expectEqual(@as(usize, 1), book.bid_count);
}

test "crossing limit orders trade at maker price" {
    var book = OrderBook.init();

    _ = book.submitLimit(.{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    const result = book.submitLimit(.{ .id = 2, .side = .sell, .price = 90, .quantity = 4 });

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try std.testing.expectEqual(@as(OrderId, 1), result.trades[0].maker_id);
    try std.testing.expectEqual(@as(OrderId, 2), result.trades[0].taker_id);
    try std.testing.expectEqual(@as(Price, 100), result.trades[0].price);
    try std.testing.expectEqual(@as(Quantity, 4), result.trades[0].quantity);
    try std.testing.expectEqual(@as(Quantity, 0), result.resting_quantity);
    try std.testing.expectEqual(@as(Quantity, 6), book.bids[0].quantity);
}

test "cancel removes one resting order" {
    var book = OrderBook.init();

    _ = book.submitLimit(.{ .id = 1, .side = .buy, .price = 100, .quantity = 10 });
    _ = book.submitLimit(.{ .id = 2, .side = .sell, .price = 110, .quantity = 5 });

    try std.testing.expect(book.cancel(1));
    try std.testing.expect(!book.cancel(1));
    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
    try std.testing.expectEqual(@as(usize, 1), book.ask_count);
}
