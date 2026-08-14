const engine = @import("engine.zig");
const journal = @import("journal.zig");

pub const InstrumentId = u32;
pub const default_instrument_id: InstrumentId = 1;
pub const max_instruments = 4;

pub const CommandEvent = union(enum) {
    submit_limit: InstrumentedOrder,
    cancel: InstrumentedCancel,
};

pub const InstrumentedOrder = struct {
    instrument_id: InstrumentId,
    order: engine.Order,
};

pub const InstrumentedCancel = struct {
    instrument_id: InstrumentId,
    order_id: engine.OrderId,
};

pub const BookSet = struct {
    books: [max_instruments]engine.OrderBook,

    pub fn init() BookSet {
        var books: [max_instruments]engine.OrderBook = undefined;
        for (&books) |*book| {
            book.* = engine.OrderBook.init();
        }
        return .{ .books = books };
    }

    pub fn bookFor(self: *BookSet, instrument_id: InstrumentId) !*engine.OrderBook {
        return &self.books[try instrumentIndex(instrument_id)];
    }
};

pub const CommandResult = union(enum) {
    submitted: SubmittedResult,
    canceled: InstrumentedCancel,
    not_found: InstrumentedCancel,
    rejected: RejectedCommand,
};

pub const SubmittedResult = struct {
    instrument_id: InstrumentId,
    order: engine.Order,
    match_result: engine.MatchResult,
};

pub const RejectReason = enum {
    DuplicateOrderId,
    BookFull,
};

pub const RejectedCommand = struct {
    instrument_id: InstrumentId,
    order_id: engine.OrderId,
    reason: RejectReason,
};

pub const SequencedCommandResult = struct {
    authoritative_sequence: u64,
    result: CommandResult,
};

pub const AuthoritativeSequencer = struct {
    next_sequence: u64 = 1,

    pub fn submit(
        self: *AuthoritativeSequencer,
        books: *BookSet,
        segment: anytype,
        event: CommandEvent,
    ) !SequencedCommandResult {
        const sequence = self.next_sequence;
        try appendJournalEvent(segment, event);
        self.next_sequence += 1;
        return .{
            .authoritative_sequence = sequence,
            .result = try applyCommandEventStructured(books, event),
        };
    }
};

pub fn instrumentIndex(instrument_id: InstrumentId) !usize {
    if (instrument_id == 0 or instrument_id > max_instruments) return error.UnknownInstrument;
    return @intCast(instrument_id - 1);
}

pub fn appendJournalEvent(segment: anytype, event: CommandEvent) !void {
    switch (event) {
        .submit_limit => |instrumented| try segment.appendSubmitLimit(instrumented.instrument_id, instrumented.order),
        .cancel => |instrumented| try segment.appendCancel(instrumented.instrument_id, instrumented.order_id),
    }
}

pub fn commandEventFromJournalRecord(record: journal.Record) CommandEvent {
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

pub fn commandEventInstrumentId(event: CommandEvent) InstrumentId {
    return switch (event) {
        .submit_limit => |instrumented| instrumented.instrument_id,
        .cancel => |instrumented| instrumented.instrument_id,
    };
}

pub fn applyCommandEventStructured(
    books: *BookSet,
    event: CommandEvent,
) !CommandResult {
    switch (event) {
        .submit_limit => |instrumented| {
            const book = try books.bookFor(instrumented.instrument_id);
            const order = instrumented.order;
            if (commandReject(instrumented.instrument_id, book, order)) |rejected| return .{ .rejected = rejected };
            const result = book.submitLimit(order);
            return .{ .submitted = .{
                .instrument_id = instrumented.instrument_id,
                .order = order,
                .match_result = result,
            } };
        },
        .cancel => |instrumented| {
            const book = try books.bookFor(instrumented.instrument_id);
            const id = instrumented.order_id;
            if (book.cancel(id)) {
                return .{ .canceled = instrumented };
            }
            return .{ .not_found = instrumented };
        },
    }
}

fn commandReject(
    instrument_id: InstrumentId,
    book: *const engine.OrderBook,
    order: engine.Order,
) ?RejectedCommand {
    if (book.containsOrder(order.id)) {
        return .{ .instrument_id = instrument_id, .order_id = order.id, .reason = .DuplicateOrderId };
    }
    if (book.restingQuantityAfterMatch(order) > 0 and !book.hasRoomFor(order.side)) {
        return .{ .instrument_id = instrument_id, .order_id = order.id, .reason = .BookFull };
    }
    return null;
}
