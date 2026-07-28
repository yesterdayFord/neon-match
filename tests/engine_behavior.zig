const std = @import("std");
const engine = @import("engine");

const Order = engine.Order;
const OrderBook = engine.OrderBook;

fn buy(id: engine.OrderId, price: engine.Price, quantity: engine.Quantity) Order {
    return .{ .id = id, .side = .buy, .price = price, .quantity = quantity };
}

fn sell(id: engine.OrderId, price: engine.Price, quantity: engine.Quantity) Order {
    return .{ .id = id, .side = .sell, .price = price, .quantity = quantity };
}

fn expectTrade(
    trade: engine.Trade,
    maker_id: engine.OrderId,
    taker_id: engine.OrderId,
    price: engine.Price,
    quantity: engine.Quantity,
) !void {
    try std.testing.expectEqual(maker_id, trade.maker_id);
    try std.testing.expectEqual(taker_id, trade.taker_id);
    try std.testing.expectEqual(price, trade.price);
    try std.testing.expectEqual(quantity, trade.quantity);
}

test "new book starts empty" {
    const book = OrderBook.init();

    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
}

test "nonmarketable buy rests as bid" {
    var book = OrderBook.init();

    const result = book.submitLimit(buy(1, 100, 10));

    try std.testing.expectEqual(@as(usize, 0), result.trade_count);
    try std.testing.expectEqual(@as(engine.Quantity, 10), result.resting_quantity);
    try std.testing.expectEqual(@as(usize, 1), book.bid_count);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book.bids[0].id);
}

test "nonmarketable sell rests as ask" {
    var book = OrderBook.init();

    const result = book.submitLimit(sell(1, 100, 10));

    try std.testing.expectEqual(@as(usize, 0), result.trade_count);
    try std.testing.expectEqual(@as(engine.Quantity, 10), result.resting_quantity);
    try std.testing.expectEqual(@as(usize, 1), book.ask_count);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book.asks[0].id);
}

test "buy below best ask does not cross" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 101, 5));
    const result = book.submitLimit(buy(2, 100, 5));

    try std.testing.expectEqual(@as(usize, 0), result.trade_count);
    try std.testing.expectEqual(@as(usize, 1), book.bid_count);
    try std.testing.expectEqual(@as(usize, 1), book.ask_count);
}

test "sell above best bid does not cross" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 5));
    const result = book.submitLimit(sell(2, 101, 5));

    try std.testing.expectEqual(@as(usize, 0), result.trade_count);
    try std.testing.expectEqual(@as(usize, 1), book.bid_count);
    try std.testing.expectEqual(@as(usize, 1), book.ask_count);
}

test "marketable sell fully fills bid" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 5));
    const result = book.submitLimit(sell(2, 100, 5));

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try expectTrade(result.trades[0], 1, 2, 100, 5);
    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
}

test "marketable buy fully fills ask" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 5));
    const result = book.submitLimit(buy(2, 100, 5));

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try expectTrade(result.trades[0], 1, 2, 100, 5);
    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
}

test "sell partial fill leaves bid remainder" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 10));
    const result = book.submitLimit(sell(2, 100, 4));

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try expectTrade(result.trades[0], 1, 2, 100, 4);
    try std.testing.expectEqual(@as(engine.Quantity, 6), book.bids[0].quantity);
}

test "buy partial fill leaves ask remainder" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 10));
    const result = book.submitLimit(buy(2, 100, 4));

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try expectTrade(result.trades[0], 1, 2, 100, 4);
    try std.testing.expectEqual(@as(engine.Quantity, 6), book.asks[0].quantity);
}

test "sell residual rests after consuming bid" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 4));
    const result = book.submitLimit(sell(2, 100, 10));

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try std.testing.expectEqual(@as(engine.Quantity, 6), result.resting_quantity);
    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
    try std.testing.expectEqual(@as(usize, 1), book.ask_count);
    try std.testing.expectEqual(@as(engine.Quantity, 6), book.asks[0].quantity);
}

test "buy residual rests after consuming ask" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 4));
    const result = book.submitLimit(buy(2, 100, 10));

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try std.testing.expectEqual(@as(engine.Quantity, 6), result.resting_quantity);
    try std.testing.expectEqual(@as(usize, 1), book.bid_count);
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
    try std.testing.expectEqual(@as(engine.Quantity, 6), book.bids[0].quantity);
}

test "sell matches multiple bids at same price FIFO" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 3));
    _ = book.submitLimit(buy(2, 100, 4));
    const result = book.submitLimit(sell(3, 100, 7));

    try std.testing.expectEqual(@as(usize, 2), result.trade_count);
    try expectTrade(result.trades[0], 1, 3, 100, 3);
    try expectTrade(result.trades[1], 2, 3, 100, 4);
}

test "buy matches multiple asks at same price FIFO" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 3));
    _ = book.submitLimit(sell(2, 100, 4));
    const result = book.submitLimit(buy(3, 100, 7));

    try std.testing.expectEqual(@as(usize, 2), result.trade_count);
    try expectTrade(result.trades[0], 1, 3, 100, 3);
    try expectTrade(result.trades[1], 2, 3, 100, 4);
}

test "higher bid has priority over earlier lower bid" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 99, 5));
    _ = book.submitLimit(buy(2, 101, 5));
    const result = book.submitLimit(sell(3, 99, 5));

    try expectTrade(result.trades[0], 2, 3, 101, 5);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book.bids[0].id);
}

test "lower ask has priority over earlier higher ask" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 101, 5));
    _ = book.submitLimit(sell(2, 99, 5));
    const result = book.submitLimit(buy(3, 101, 5));

    try expectTrade(result.trades[0], 2, 3, 99, 5);
    try std.testing.expectEqual(@as(engine.OrderId, 1), book.asks[0].id);
}

test "bids sort descending by price" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 1));
    _ = book.submitLimit(buy(2, 102, 1));
    _ = book.submitLimit(buy(3, 101, 1));

    try std.testing.expectEqual(@as(engine.Price, 102), book.bids[0].price);
    try std.testing.expectEqual(@as(engine.Price, 101), book.bids[1].price);
    try std.testing.expectEqual(@as(engine.Price, 100), book.bids[2].price);
}

test "asks sort ascending by price" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 1));
    _ = book.submitLimit(sell(2, 98, 1));
    _ = book.submitLimit(sell(3, 99, 1));

    try std.testing.expectEqual(@as(engine.Price, 98), book.asks[0].price);
    try std.testing.expectEqual(@as(engine.Price, 99), book.asks[1].price);
    try std.testing.expectEqual(@as(engine.Price, 100), book.asks[2].price);
}

test "same price bids preserve FIFO while resting" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 1));
    _ = book.submitLimit(buy(2, 100, 1));
    _ = book.submitLimit(buy(3, 100, 1));

    try std.testing.expectEqual(@as(engine.OrderId, 1), book.bids[0].id);
    try std.testing.expectEqual(@as(engine.OrderId, 2), book.bids[1].id);
    try std.testing.expectEqual(@as(engine.OrderId, 3), book.bids[2].id);
}

test "same price asks preserve FIFO while resting" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 1));
    _ = book.submitLimit(sell(2, 100, 1));
    _ = book.submitLimit(sell(3, 100, 1));

    try std.testing.expectEqual(@as(engine.OrderId, 1), book.asks[0].id);
    try std.testing.expectEqual(@as(engine.OrderId, 2), book.asks[1].id);
    try std.testing.expectEqual(@as(engine.OrderId, 3), book.asks[2].id);
}

test "sell crosses multiple bid price levels" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 101, 2));
    _ = book.submitLimit(buy(2, 100, 3));
    _ = book.submitLimit(buy(3, 99, 4));
    const result = book.submitLimit(sell(4, 99, 6));

    try std.testing.expectEqual(@as(usize, 3), result.trade_count);
    try expectTrade(result.trades[0], 1, 4, 101, 2);
    try expectTrade(result.trades[1], 2, 4, 100, 3);
    try expectTrade(result.trades[2], 3, 4, 99, 1);
    try std.testing.expectEqual(@as(engine.Quantity, 3), book.bids[0].quantity);
}

test "buy crosses multiple ask price levels" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 99, 2));
    _ = book.submitLimit(sell(2, 100, 3));
    _ = book.submitLimit(sell(3, 101, 4));
    const result = book.submitLimit(buy(4, 101, 6));

    try std.testing.expectEqual(@as(usize, 3), result.trade_count);
    try expectTrade(result.trades[0], 1, 4, 99, 2);
    try expectTrade(result.trades[1], 2, 4, 100, 3);
    try expectTrade(result.trades[2], 3, 4, 101, 1);
    try std.testing.expectEqual(@as(engine.Quantity, 3), book.asks[0].quantity);
}

test "sell stops at bid price below limit" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 101, 2));
    _ = book.submitLimit(buy(2, 99, 3));
    const result = book.submitLimit(sell(3, 100, 4));

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try expectTrade(result.trades[0], 1, 3, 101, 2);
    try std.testing.expectEqual(@as(engine.Quantity, 2), result.resting_quantity);
    try std.testing.expectEqual(@as(engine.OrderId, 2), book.bids[0].id);
    try std.testing.expectEqual(@as(engine.OrderId, 3), book.asks[0].id);
}

test "buy stops at ask price above limit" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 99, 2));
    _ = book.submitLimit(sell(2, 101, 3));
    const result = book.submitLimit(buy(3, 100, 4));

    try std.testing.expectEqual(@as(usize, 1), result.trade_count);
    try expectTrade(result.trades[0], 1, 3, 99, 2);
    try std.testing.expectEqual(@as(engine.Quantity, 2), result.resting_quantity);
    try std.testing.expectEqual(@as(engine.OrderId, 3), book.bids[0].id);
    try std.testing.expectEqual(@as(engine.OrderId, 2), book.asks[0].id);
}

test "cancel missing order returns false" {
    var book = OrderBook.init();

    try std.testing.expect(!book.cancel(404));
}

test "cancel existing bid returns true and removes it" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 5));

    try std.testing.expect(book.cancel(1));
    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
}

test "cancel existing ask returns true and removes it" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 5));

    try std.testing.expect(book.cancel(1));
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
}

test "cancel partially filled bid removes remainder" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 10));
    _ = book.submitLimit(sell(2, 100, 4));

    try std.testing.expect(book.cancel(1));
    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
}

test "cancel partially filled ask removes remainder" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 10));
    _ = book.submitLimit(buy(2, 100, 4));

    try std.testing.expect(book.cancel(1));
    try std.testing.expectEqual(@as(usize, 0), book.ask_count);
}

test "containsOrder finds resting bid and ask" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 1));
    _ = book.submitLimit(sell(2, 101, 1));

    try std.testing.expect(book.containsOrder(1));
    try std.testing.expect(book.containsOrder(2));
    try std.testing.expect(!book.containsOrder(3));
}

test "fully filled maker is no longer present" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 1));
    _ = book.submitLimit(buy(2, 100, 1));

    try std.testing.expect(!book.containsOrder(1));
}

test "partially filled maker remains present" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 5));
    _ = book.submitLimit(buy(2, 100, 2));

    try std.testing.expect(book.containsOrder(1));
    try std.testing.expectEqual(@as(engine.Quantity, 3), book.asks[0].quantity);
}

test "restingQuantityAfterMatch is zero for full cross" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 5));

    try std.testing.expectEqual(@as(engine.Quantity, 0), book.restingQuantityAfterMatch(buy(2, 100, 5)));
}

test "restingQuantityAfterMatch reports residual" {
    var book = OrderBook.init();

    _ = book.submitLimit(sell(1, 100, 5));

    try std.testing.expectEqual(@as(engine.Quantity, 3), book.restingQuantityAfterMatch(buy(2, 100, 8)));
}

test "bid side reports full at max orders" {
    var book = OrderBook.init();

    var id: engine.OrderId = 1;
    while (id <= engine.max_orders) : (id += 1) {
        _ = book.submitLimit(buy(id, 100, 1));
    }

    try std.testing.expect(!book.hasRoomFor(.buy));
    try std.testing.expect(book.hasRoomFor(.sell));
}

test "ask side reports full at max orders" {
    var book = OrderBook.init();

    var id: engine.OrderId = 1;
    while (id <= engine.max_orders) : (id += 1) {
        _ = book.submitLimit(sell(id, 100, 1));
    }

    try std.testing.expect(!book.hasRoomFor(.sell));
    try std.testing.expect(book.hasRoomFor(.buy));
}

test "full bid side still allows fully crossing buy by residual check" {
    var book = OrderBook.init();

    var id: engine.OrderId = 1;
    while (id <= engine.max_orders) : (id += 1) {
        _ = book.submitLimit(buy(id, 90, 1));
    }
    _ = book.submitLimit(sell(200, 100, 1));

    try std.testing.expectEqual(@as(engine.Quantity, 0), book.restingQuantityAfterMatch(buy(201, 100, 1)));
}

test "duplicate order id can be detected before submit" {
    var book = OrderBook.init();

    _ = book.submitLimit(buy(1, 100, 1));

    try std.testing.expect(book.containsOrder(1));
}
