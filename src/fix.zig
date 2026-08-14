const std = @import("std");
const engine = @import("engine.zig");
const exchange = @import("exchange.zig");
const journal = @import("journal.zig");

const CommandEvent = exchange.CommandEvent;
const InstrumentId = exchange.InstrumentId;
const max_instruments = exchange.max_instruments;
const BookSet = exchange.BookSet;
const CommandResult = exchange.CommandResult;
const SequencedCommandResult = exchange.SequencedCommandResult;
const AuthoritativeSequencer = exchange.AuthoritativeSequencer;
const fix_version = "FIX.4.4";
const fix_begin_string = "8=FIX.4.4";
const fix_exchange_id = "NEONMATCH";
const max_fix_fields = 32;
const max_fix_cl_ord_id_len = 32;
const max_fix_clord_mappings = engine.max_orders * max_instruments;

const FixField = struct {
    tag: u16,
    value: []const u8,
};

const FixMessage = struct {
    fields: [max_fix_fields]FixField = undefined,
    field_count: usize = 0,

    fn parse(bytes: []const u8) !FixMessage {
        var message = FixMessage{};
        var index: usize = 0;
        while (index < bytes.len) {
            while (index < bytes.len and isFixDelimiter(bytes[index])) : (index += 1) {}
            if (index == bytes.len) break;

            const start = index;
            while (index < bytes.len and !isFixDelimiter(bytes[index])) : (index += 1) {}
            const field = bytes[start..index];
            const equals_index = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidFixField;
            if (equals_index == 0 or equals_index + 1 == field.len) return error.InvalidFixField;
            if (message.field_count == message.fields.len) return error.TooManyFixFields;
            message.fields[message.field_count] = .{
                .tag = try std.fmt.parseInt(u16, field[0..equals_index], 10),
                .value = field[equals_index + 1 ..],
            };
            message.field_count += 1;
        }
        if (message.field_count == 0) return error.EmptyFixMessage;
        return message;
    }

    fn required(self: *const FixMessage, tag: u16) ![]const u8 {
        return self.get(tag) orelse error.MissingFixField;
    }

    fn get(self: *const FixMessage, tag: u16) ?[]const u8 {
        var index: usize = 0;
        while (index < self.field_count) : (index += 1) {
            if (self.fields[index].tag == tag) return self.fields[index].value;
        }
        return null;
    }
};

fn isFixDelimiter(byte: u8) bool {
    return byte == 1 or byte == '|' or byte == '\r' or byte == '\n';
}

const FixClOrdMapping = struct {
    cl_ord_id: [max_fix_cl_ord_id_len]u8,
    cl_ord_id_len: usize,
    instrument_id: InstrumentId,
    order_id: engine.OrderId,

    fn clOrdId(self: *const FixClOrdMapping) []const u8 {
        return self.cl_ord_id[0..self.cl_ord_id_len];
    }
};

const FixSession = struct {
    expected_in_seq: u64 = 1,
    next_out_seq: u64 = 1,
    next_exec_id: u64 = 1,
    logged_on: bool = false,
    sender: []const u8 = "",
    target: []const u8 = fix_exchange_id,
    mappings: [max_fix_clord_mappings]FixClOrdMapping = undefined,
    mapping_count: usize = 0,

    pub fn handle(
        self: *FixSession,
        writer: *std.Io.Writer,
        books: *BookSet,
        sequencer: *AuthoritativeSequencer,
        segment: anytype,
        bytes: []const u8,
    ) !void {
        const message = try self.validateSession(bytes);
        const msg_type = try message.required(35);
        if (std.mem.eql(u8, msg_type, "A")) return self.handleLogon(writer);
        if (std.mem.eql(u8, msg_type, "5")) return self.handleLogout(writer);
        if (std.mem.eql(u8, msg_type, "0")) return self.handleHeartbeat(writer);
        if (std.mem.eql(u8, msg_type, "1")) return self.handleTestRequest(writer, &message);
        if (!self.logged_on) return error.FixSessionNotLoggedOn;
        if (std.mem.eql(u8, msg_type, "D")) return self.handleNewOrderSingle(writer, books, sequencer, segment, &message);
        if (std.mem.eql(u8, msg_type, "F")) return self.handleOrderCancelRequest(writer, books, sequencer, segment, &message);
        return error.UnsupportedFixMsgType;
    }

    fn validateSession(self: *FixSession, bytes: []const u8) !FixMessage {
        const message = try FixMessage.parse(bytes);
        if (!std.mem.eql(u8, try message.required(8), fix_version)) return error.UnsupportedFixVersion;
        const seq = try parsePositive(u64, try message.required(34));
        if (seq != self.expected_in_seq) return error.InvalidFixMsgSeqNum;
        const sender = try message.required(49);
        const target = try message.required(56);
        if (!std.mem.eql(u8, target, fix_exchange_id)) return error.InvalidFixTargetCompID;
        if (self.expected_in_seq == 1) {
            self.sender = sender;
        } else if (!std.mem.eql(u8, sender, self.sender)) {
            return error.InvalidFixSenderCompID;
        }
        self.expected_in_seq += 1;
        return message;
    }

    fn handleLogon(self: *FixSession, writer: *std.Io.Writer) !void {
        self.logged_on = true;
        try self.writeSessionMessage(writer, "A", null);
    }

    fn handleLogout(self: *FixSession, writer: *std.Io.Writer) !void {
        self.logged_on = false;
        try self.writeSessionMessage(writer, "5", null);
    }

    fn handleHeartbeat(self: *FixSession, writer: *std.Io.Writer) !void {
        try self.writeSessionMessage(writer, "0", null);
    }

    fn handleTestRequest(self: *FixSession, writer: *std.Io.Writer, message: *const FixMessage) !void {
        const test_req_id = try message.required(112);
        try self.writeSessionMessage(writer, "0", .{ .tag = 112, .value = test_req_id });
    }

    fn handleNewOrderSingle(
        self: *FixSession,
        writer: *std.Io.Writer,
        books: *BookSet,
        sequencer: *AuthoritativeSequencer,
        segment: anytype,
        message: *const FixMessage,
    ) !void {
        const cl_ord_id = try message.required(11);
        if (self.findMapping(cl_ord_id) != null) return error.DuplicateFixClOrdID;
        try self.ensureCanStoreMapping(cl_ord_id);
        const instrument_id = try symbolToInstrumentId(try message.required(55));
        const side = try fixSideToEngineSide(try message.required(54));
        const order_id = try parsePositive(engine.OrderId, cl_ord_id);
        const order: engine.Order = .{
            .id = order_id,
            .side = side,
            .price = try parsePositive(engine.Price, try message.required(44)),
            .quantity = try parsePositive(engine.Quantity, try message.required(38)),
        };
        const event = CommandEvent{ .submit_limit = .{ .instrument_id = instrument_id, .order = order } };
        const sequenced = try self.applyAuthoritative(books, sequencer, segment, event);
        try self.storeMapping(cl_ord_id, instrument_id, order_id);
        try self.writeExecutionReports(writer, cl_ord_id, sequenced.authoritative_sequence, &sequenced.result);
    }

    fn handleOrderCancelRequest(
        self: *FixSession,
        writer: *std.Io.Writer,
        books: *BookSet,
        sequencer: *AuthoritativeSequencer,
        segment: anytype,
        message: *const FixMessage,
    ) !void {
        const cl_ord_id = try message.required(11);
        if (self.findMapping(cl_ord_id) != null) return error.DuplicateFixClOrdID;
        try self.ensureCanStoreMapping(cl_ord_id);
        const orig_cl_ord_id = try message.required(41);
        const mapping = self.findMapping(orig_cl_ord_id) orelse return error.UnknownOrigClOrdID;
        const event = CommandEvent{ .cancel = .{
            .instrument_id = mapping.instrument_id,
            .order_id = mapping.order_id,
        } };
        const sequenced = try self.applyAuthoritative(books, sequencer, segment, event);
        try self.storeMapping(cl_ord_id, mapping.instrument_id, mapping.order_id);
        try self.writeExecutionReports(writer, cl_ord_id, sequenced.authoritative_sequence, &sequenced.result);
    }

    fn applyAuthoritative(
        _: *FixSession,
        books: *BookSet,
        sequencer: *AuthoritativeSequencer,
        segment: anytype,
        event: CommandEvent,
    ) !SequencedCommandResult {
        return sequencer.submit(books, segment, event);
    }

    fn writeExecutionReports(
        self: *FixSession,
        writer: *std.Io.Writer,
        cl_ord_id: []const u8,
        authoritative_sequence: u64,
        result: *const CommandResult,
    ) !void {
        switch (result.*) {
            .submitted => |submitted| {
                if (submitted.match_result.trade_count == 0 and submitted.match_result.resting_quantity > 0) {
                    try self.writeExecutionReport(writer, cl_ord_id, submitted.order.id, "0", "0", submitted.order.quantity, "New", authoritative_sequence);
                }
                var index: usize = 0;
                while (index < submitted.match_result.trade_count) : (index += 1) {
                    const trade = submitted.match_result.trades[index];
                    const ord_status = if (index + 1 == submitted.match_result.trade_count and submitted.match_result.resting_quantity == 0) "2" else "1";
                    try self.writeExecutionReport(writer, cl_ord_id, submitted.order.id, "F", ord_status, trade.quantity, "Fill", authoritative_sequence);
                }
            },
            .canceled => |instrumented| try self.writeExecutionReport(writer, cl_ord_id, instrumented.order_id, "4", "4", 0, "Canceled", authoritative_sequence),
            .not_found => |instrumented| try self.writeExecutionReport(writer, cl_ord_id, instrumented.order_id, "8", "8", 0, "NotFound", authoritative_sequence),
            .rejected => |rejected| try self.writeExecutionReport(
                writer,
                cl_ord_id,
                rejected.order_id,
                "8",
                "8",
                0,
                @tagName(rejected.reason),
                authoritative_sequence,
            ),
        }
    }

    fn writeExecutionReport(
        self: *FixSession,
        writer: *std.Io.Writer,
        cl_ord_id: []const u8,
        order_id: engine.OrderId,
        exec_type: []const u8,
        ord_status: []const u8,
        last_qty: engine.Quantity,
        text: []const u8,
        authoritative_sequence: u64,
    ) !void {
        const exec_id = self.next_exec_id;
        self.next_exec_id += 1;
        try self.writeMessagePrefix(writer, "8");
        try writer.print(
            "11={s}|37={d}|17={d}.{d}|150={s}|39={s}|32={d}|58={s}|\n",
            .{ cl_ord_id, order_id, authoritative_sequence, exec_id, exec_type, ord_status, last_qty, text },
        );
    }

    fn writeSessionMessage(self: *FixSession, writer: *std.Io.Writer, msg_type: []const u8, extra: ?FixField) !void {
        try self.writeMessagePrefix(writer, msg_type);
        if (extra) |field| try writer.print("{d}={s}|", .{ field.tag, field.value });
        try writer.writeByte('\n');
    }

    fn writeMessagePrefix(self: *FixSession, writer: *std.Io.Writer, msg_type: []const u8) !void {
        const seq = self.next_out_seq;
        self.next_out_seq += 1;
        try writer.print(
            "{s}|35={s}|34={d}|49={s}|56={s}|",
            .{ fix_begin_string, msg_type, seq, fix_exchange_id, self.sender },
        );
    }

    fn findMapping(self: *const FixSession, cl_ord_id: []const u8) ?FixClOrdMapping {
        var index: usize = 0;
        while (index < self.mapping_count) : (index += 1) {
            const mapping = self.mappings[index];
            if (std.mem.eql(u8, mapping.clOrdId(), cl_ord_id)) return mapping;
        }
        return null;
    }

    fn ensureCanStoreMapping(self: *const FixSession, cl_ord_id: []const u8) !void {
        if (cl_ord_id.len > max_fix_cl_ord_id_len) return error.FixClOrdIDTooLong;
        if (self.mapping_count == self.mappings.len) return error.FixClOrdMapFull;
    }

    fn storeMapping(self: *FixSession, cl_ord_id: []const u8, instrument_id: InstrumentId, order_id: engine.OrderId) !void {
        try self.ensureCanStoreMapping(cl_ord_id);
        var mapping = FixClOrdMapping{
            .cl_ord_id = undefined,
            .cl_ord_id_len = cl_ord_id.len,
            .instrument_id = instrument_id,
            .order_id = order_id,
        };
        @memcpy(mapping.cl_ord_id[0..cl_ord_id.len], cl_ord_id);
        self.mappings[self.mapping_count] = mapping;
        self.mapping_count += 1;
    }
};

fn symbolToInstrumentId(symbol: []const u8) !InstrumentId {
    if (symbol.len == 3 and symbol[0] == 'N' and symbol[1] == 'M') {
        const digit = symbol[2];
        if (digit >= '1' and digit <= '0' + max_instruments) {
            return @intCast(digit - '0');
        }
    }
    return error.UnknownInstrument;
}

fn fixSideToEngineSide(value: []const u8) !engine.Side {
    if (std.mem.eql(u8, value, "1")) return .buy;
    if (std.mem.eql(u8, value, "2")) return .sell;
    return error.InvalidFixSide;
}
pub const Session = FixSession;

fn parsePositive(comptime T: type, text: []const u8) !T {
    const value = try std.fmt.parseInt(T, text, 10);
    if (value == 0) return error.MustBePositive;
    return value;
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

fn replayJournalPath(
    io: std.Io,
    books: *BookSet,
    path: []const u8,
) !void {
    var reader = try journal.Reader.open(io, path);
    defer reader.close();
    while (try reader.next()) |record| {
        _ = try exchange.applyCommandEventStructured(books, exchange.commandEventFromJournalRecord(record));
    }
}

fn instrumentBuy(instrument_id: InstrumentId, id: engine.OrderId, price: engine.Price, quantity: engine.Quantity) CommandEvent {
    return .{ .submit_limit = .{
        .instrument_id = instrument_id,
        .order = .{ .id = id, .side = .buy, .price = price, .quantity = quantity },
    } };
}

fn applyCommandEvent(books: *BookSet, event: CommandEvent) !void {
    _ = try exchange.applyCommandEventStructured(books, event);
}

test "FIX session handles logon heartbeat test request and logout" {
    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    const NoJournal = struct {
        pub fn appendSubmitLimit(_: *@This(), _: InstrumentId, _: engine.Order) !void {
            return error.UnexpectedJournalAppend;
        }

        pub fn appendCancel(_: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            return error.UnexpectedJournalAppend;
        }
    };
    var no_journal = NoJournal{};

    try session.handle(&writer, &books, &sequencer, &no_journal, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    try session.handle(&writer, &books, &sequencer, &no_journal, "8=FIX.4.4|35=1|34=2|49=CLIENT1|56=NEONMATCH|112=T1|");
    try session.handle(&writer, &books, &sequencer, &no_journal, "8=FIX.4.4|35=0|34=3|49=CLIENT1|56=NEONMATCH|");
    try session.handle(&writer, &books, &sequencer, &no_journal, "8=FIX.4.4|35=5|34=4|49=CLIENT1|56=NEONMATCH|");

    try expectOutput(
        &writer,
        "8=FIX.4.4|35=A|34=1|49=NEONMATCH|56=CLIENT1|\n" ++
            "8=FIX.4.4|35=0|34=2|49=NEONMATCH|56=CLIENT1|112=T1|\n" ++
            "8=FIX.4.4|35=0|34=3|49=NEONMATCH|56=CLIENT1|\n" ++
            "8=FIX.4.4|35=5|34=4|49=NEONMATCH|56=CLIENT1|\n",
    );
    try expectBooksEqual(&BookSet.init(), &books);
}

test "FIX NewOrderSingle maps through journaled authoritative command and emits execution reports" {
    const CountingJournal = struct {
        append_count: usize = 0,
        last_instrument_id: InstrumentId = 0,
        last_order: engine.Order = undefined,

        pub fn appendSubmitLimit(self: *@This(), instrument_id: InstrumentId, order: engine.Order) !void {
            self.append_count += 1;
            self.last_instrument_id = instrument_id;
            self.last_order = order;
        }

        pub fn appendCancel(_: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            return error.UnexpectedCancelAppend;
        }
    };

    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var journal_segment = CountingJournal{};
    var output_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    writer.end = 0;
    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=101|55=NM2|54=1|44=100|38=5|");

    try std.testing.expectEqual(@as(usize, 1), journal_segment.append_count);
    try std.testing.expectEqual(@as(InstrumentId, 2), journal_segment.last_instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 101), journal_segment.last_order.id);
    const book = try books.bookFor(2);
    try std.testing.expectEqual(@as(usize, 1), book.bid_count);
    try expectOutput(
        &writer,
        "8=FIX.4.4|35=8|34=2|49=NEONMATCH|56=CLIENT1|11=101|37=101|17=1.1|150=0|39=0|32=5|58=New|\n",
    );
}

test "FIX order-entry semantic rejects are journaled and reported without mutation" {
    const CountingJournal = struct {
        append_count: usize = 0,

        pub fn appendSubmitLimit(self: *@This(), _: InstrumentId, _: engine.Order) !void {
            self.append_count += 1;
        }

        pub fn appendCancel(_: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            return error.UnexpectedCancelAppend;
        }
    };

    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var journal_segment = CountingJournal{};
    var output_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var discard_buffer: [64]u8 = undefined;
    var discard_writer = std.Io.Writer.fixed(&discard_buffer);

    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    var id: engine.OrderId = 1;
    while (id <= engine.max_orders) : (id += 1) {
        discard_writer.end = 0;
        try applyCommandEvent(&books, instrumentBuy(1, id, 100, 1));
    }
    writer.end = 0;
    const before = books;
    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=1000|55=NM1|54=1|44=99|38=1|");

    try std.testing.expectEqual(@as(usize, 1), journal_segment.append_count);
    try expectBooksEqual(&before, &books);
    try expectOutput(
        &writer,
        "8=FIX.4.4|35=8|34=2|49=NEONMATCH|56=CLIENT1|11=1000|37=1000|17=1.1|150=8|39=8|32=0|58=BookFull|\n",
    );
}

test "FIX malformed or untranslatable messages do not journal or mutate" {
    const CountingJournal = struct {
        append_count: usize = 0,

        pub fn appendSubmitLimit(self: *@This(), _: InstrumentId, _: engine.Order) !void {
            self.append_count += 1;
        }

        pub fn appendCancel(self: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            self.append_count += 1;
        }
    };

    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var journal_segment = CountingJournal{};
    var output_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    writer.end = 0;
    const before = books;
    try std.testing.expectError(
        error.UnknownInstrument,
        session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=101|55=BAD|54=1|44=100|38=5|"),
    );

    try std.testing.expectEqual(@as(usize, 0), journal_segment.append_count);
    try expectBooksEqual(&before, &books);
    try expectOutput(&writer, "");
}

test "FIX cancel resolves OrigClOrdID and reaches the journaled cancel path" {
    const CountingJournal = struct {
        submit_count: usize = 0,
        cancel_count: usize = 0,
        cancel_instrument_id: InstrumentId = 0,
        cancel_order_id: engine.OrderId = 0,

        pub fn appendSubmitLimit(self: *@This(), _: InstrumentId, _: engine.Order) !void {
            self.submit_count += 1;
        }

        pub fn appendCancel(self: *@This(), instrument_id: InstrumentId, order_id: engine.OrderId) !void {
            self.cancel_count += 1;
            self.cancel_instrument_id = instrument_id;
            self.cancel_order_id = order_id;
        }
    };

    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var journal_segment = CountingJournal{};
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=101|55=NM3|54=1|44=100|38=5|");
    writer.end = 0;
    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=F|34=3|49=CLIENT1|56=NEONMATCH|11=102|41=101|");

    try std.testing.expectEqual(@as(usize, 1), journal_segment.submit_count);
    try std.testing.expectEqual(@as(usize, 1), journal_segment.cancel_count);
    try std.testing.expectEqual(@as(InstrumentId, 3), journal_segment.cancel_instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 101), journal_segment.cancel_order_id);
    const book = try books.bookFor(3);
    try std.testing.expectEqual(@as(usize, 0), book.bid_count);
    try expectOutput(
        &writer,
        "8=FIX.4.4|35=8|34=3|49=NEONMATCH|56=CLIENT1|11=102|37=101|17=2.2|150=4|39=4|32=0|58=Canceled|\n",
    );
}

test "FIX ExecutionReport distinguishes partial fill full fill and cancel not found" {
    const CountingJournal = struct {
        append_count: usize = 0,

        pub fn appendSubmitLimit(self: *@This(), _: InstrumentId, _: engine.Order) !void {
            self.append_count += 1;
        }

        pub fn appendCancel(self: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            self.append_count += 1;
        }
    };

    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var journal_segment = CountingJournal{};
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=201|55=NM1|54=2|44=100|38=5|");
    writer.end = 0;
    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=3|49=CLIENT1|56=NEONMATCH|11=202|55=NM1|54=1|44=100|38=2|");
    try expectOutput(
        &writer,
        "8=FIX.4.4|35=8|34=3|49=NEONMATCH|56=CLIENT1|11=202|37=202|17=2.2|150=F|39=2|32=2|58=Fill|\n",
    );

    writer.end = 0;
    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=4|49=CLIENT1|56=NEONMATCH|11=203|55=NM1|54=1|44=100|38=5|");
    try expectOutput(
        &writer,
        "8=FIX.4.4|35=8|34=4|49=NEONMATCH|56=CLIENT1|11=203|37=203|17=3.3|150=F|39=1|32=3|58=Fill|\n",
    );

    writer.end = 0;
    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=F|34=5|49=CLIENT1|56=NEONMATCH|11=204|41=201|");
    try expectOutput(
        &writer,
        "8=FIX.4.4|35=8|34=5|49=NEONMATCH|56=CLIENT1|11=204|37=201|17=4.4|150=8|39=8|32=0|58=NotFound|\n",
    );
    try std.testing.expectEqual(@as(usize, 4), journal_segment.append_count);
}

test "FIX journaled commands replay to the same book state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var journal_dir_buffer: [64]u8 = undefined;
    const journal_dir = try std.fmt.bufPrint(&journal_dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var segment = try journal.Segment.open(io, journal_dir);
    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var live_books = BookSet.init();
    var live_output_buffer: [4096]u8 = undefined;
    var live_writer = std.Io.Writer.fixed(&live_output_buffer);

    try session.handle(&live_writer, &live_books, &sequencer, &segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    try session.handle(&live_writer, &live_books, &sequencer, &segment, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=101|55=NM1|54=2|44=100|38=5|");
    try session.handle(&live_writer, &live_books, &sequencer, &segment, "8=FIX.4.4|35=D|34=3|49=CLIENT1|56=NEONMATCH|11=102|55=NM1|54=1|44=100|38=2|");
    segment.close();

    var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal_path = try singleJournalPath(io, &tmp, journal_dir, &journal_path_buffer);
    var replay_books = BookSet.init();
    try replayJournalPath(io, &replay_books, journal_path);

    try expectBooksEqual(&live_books, &replay_books);
}

test "FIX sessions share one authoritative command sequencing boundary" {
    const CountingJournal = struct {
        append_count: usize = 0,

        pub fn appendSubmitLimit(self: *@This(), _: InstrumentId, _: engine.Order) !void {
            self.append_count += 1;
        }

        pub fn appendCancel(self: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            self.append_count += 1;
        }
    };

    var sequencer = AuthoritativeSequencer{};
    var session_a = FixSession{};
    var session_b = FixSession{};
    var books = BookSet.init();
    var journal_segment = CountingJournal{};
    var output_a_buffer: [4096]u8 = undefined;
    var output_b_buffer: [4096]u8 = undefined;
    var writer_a = std.Io.Writer.fixed(&output_a_buffer);
    var writer_b = std.Io.Writer.fixed(&output_b_buffer);

    try session_a.handle(&writer_a, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    try session_b.handle(&writer_b, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT2|56=NEONMATCH|");
    writer_a.end = 0;
    writer_b.end = 0;

    try session_a.handle(&writer_a, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=101|55=NM1|54=1|44=100|38=5|");
    try session_b.handle(&writer_b, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=2|49=CLIENT2|56=NEONMATCH|11=201|55=NM2|54=1|44=101|38=5|");
    try session_a.handle(&writer_a, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=3|49=CLIENT1|56=NEONMATCH|11=102|55=NM1|54=2|44=100|38=2|");

    try std.testing.expectEqual(@as(usize, 3), journal_segment.append_count);
    try std.testing.expectEqual(@as(u64, 4), sequencer.next_sequence);
    try expectOutput(
        &writer_a,
        "8=FIX.4.4|35=8|34=2|49=NEONMATCH|56=CLIENT1|11=101|37=101|17=1.1|150=0|39=0|32=5|58=New|\n" ++
            "8=FIX.4.4|35=8|34=3|49=NEONMATCH|56=CLIENT1|11=102|37=102|17=3.2|150=F|39=2|32=2|58=Fill|\n",
    );
    try expectOutput(
        &writer_b,
        "8=FIX.4.4|35=8|34=2|49=NEONMATCH|56=CLIENT2|11=201|37=201|17=2.1|150=0|39=0|32=5|58=New|\n",
    );
}

test "FIX append failure prevents sequencing application mapping and output" {
    const FailingJournal = struct {
        append_count: usize = 0,

        pub fn appendSubmitLimit(self: *@This(), _: InstrumentId, _: engine.Order) !void {
            self.append_count += 1;
            return error.JournalWriteFailed;
        }

        pub fn appendCancel(self: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            self.append_count += 1;
            return error.JournalWriteFailed;
        }
    };

    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var failing_journal = FailingJournal{};
    var output_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try session.handle(&writer, &books, &sequencer, &failing_journal, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    writer.end = 0;
    const before = books;
    try std.testing.expectError(
        error.JournalWriteFailed,
        session.handle(&writer, &books, &sequencer, &failing_journal, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=101|55=NM1|54=1|44=100|38=5|"),
    );

    try std.testing.expectEqual(@as(usize, 1), failing_journal.append_count);
    try std.testing.expectEqual(@as(u64, 1), sequencer.next_sequence);
    try std.testing.expectEqual(@as(usize, 0), session.mapping_count);
    try expectBooksEqual(&before, &books);
    try expectOutput(&writer, "");
}

test "FIX output failure preserves committed command mapping state" {
    const CountingJournal = struct {
        append_count: usize = 0,

        pub fn appendSubmitLimit(self: *@This(), _: InstrumentId, _: engine.Order) !void {
            self.append_count += 1;
        }

        pub fn appendCancel(self: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            self.append_count += 1;
        }
    };

    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var journal_segment = CountingJournal{};
    var logon_output_buffer: [128]u8 = undefined;
    var logon_writer = std.Io.Writer.fixed(&logon_output_buffer);

    try session.handle(&logon_writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");

    var tiny_output_buffer: [1]u8 = undefined;
    var tiny_writer = std.Io.Writer.fixed(&tiny_output_buffer);
    session.handle(&tiny_writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=D|34=2|49=CLIENT1|56=NEONMATCH|11=101|55=NM1|54=1|44=100|38=5|") catch |err| switch (err) {
        error.WriteFailed => {},
        else => return err,
    };

    try std.testing.expectEqual(@as(usize, 1), journal_segment.append_count);
    try std.testing.expectEqual(@as(u64, 2), sequencer.next_sequence);
    const book = try books.bookFor(1);
    try std.testing.expect(book.containsOrder(101));
    const mapping = session.findMapping("101") orelse return error.MissingFixClOrdMapping;
    try std.testing.expectEqual(@as(InstrumentId, 1), mapping.instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 101), mapping.order_id);
}

test "FIX ClOrdID mappings copy incoming message bytes" {
    const CountingJournal = struct {
        append_count: usize = 0,

        pub fn appendSubmitLimit(self: *@This(), _: InstrumentId, _: engine.Order) !void {
            self.append_count += 1;
        }

        pub fn appendCancel(self: *@This(), _: InstrumentId, _: engine.OrderId) !void {
            self.append_count += 1;
        }
    };

    var session = FixSession{};
    var sequencer = AuthoritativeSequencer{};
    var books = BookSet.init();
    var journal_segment = CountingJournal{};
    var output_buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    var message_buffer = [_]u8{ '8', '=', 'F', 'I', 'X', '.', '4', '.', '4', '|', '3', '5', '=', 'D', '|', '3', '4', '=', '2', '|', '4', '9', '=', 'C', 'L', 'I', 'E', 'N', 'T', '1', '|', '5', '6', '=', 'N', 'E', 'O', 'N', 'M', 'A', 'T', 'C', 'H', '|', '1', '1', '=', '3', '0', '1', '|', '5', '5', '=', 'N', 'M', '1', '|', '5', '4', '=', '1', '|', '4', '4', '=', '1', '0', '0', '|', '3', '8', '=', '5', '|' };

    try session.handle(&writer, &books, &sequencer, &journal_segment, "8=FIX.4.4|35=A|34=1|49=CLIENT1|56=NEONMATCH|");
    writer.end = 0;
    try session.handle(&writer, &books, &sequencer, &journal_segment, message_buffer[0..]);
    @memset(message_buffer[0..], 'X');

    const mapping = session.findMapping("301") orelse return error.MissingFixClOrdMapping;
    try std.testing.expectEqual(@as(InstrumentId, 1), mapping.instrument_id);
    try std.testing.expectEqual(@as(engine.OrderId, 301), mapping.order_id);
    try std.testing.expectEqualStrings("301", mapping.clOrdId());
}
