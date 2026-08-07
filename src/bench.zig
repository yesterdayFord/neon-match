const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const journal = @import("journal.zig");

const default_command_count: usize = 100_000;
const default_warmup_count: usize = 10_000;
const default_journal_dir = ".zig-cache/bench-journal";
const missing_cancel_base: engine.OrderId = 1_000_000_000_000;

const Measurement = enum {
    throughput,
    latency,
};

const Mode = enum {
    matcher,
    journal,
};

const Workload = enum {
    matching,
    resting,
    cancel_heavy,
    full_capacity,
};

const Args = struct {
    measurement: Measurement = .throughput,
    mode: Mode = .matcher,
    workload: Workload = .matching,
    command_count: usize = default_command_count,
    warmup_count: usize = default_warmup_count,
    journal_dir: []const u8 = default_journal_dir,
};

const Command = union(enum) {
    submit_limit: engine.Order,
    cancel: engine.OrderId,
};

const WorkloadSpec = struct {
    max_live_orders: usize,
    price_min: engine.Price,
    price_max: engine.Price,
    id_min: engine.OrderId,
    id_max: engine.OrderId,
    description: []const u8,
};

const Counters = struct {
    accepted: usize = 0,
    rejected: usize = 0,
    canceled: usize = 0,
    not_found: usize = 0,
    trades: usize = 0,

    fn expectEqual(self: Counters, expected: Counters) !void {
        if (self.accepted != expected.accepted) return error.BenchmarkCounterMismatch;
        if (self.rejected != expected.rejected) return error.BenchmarkCounterMismatch;
        if (self.canceled != expected.canceled) return error.BenchmarkCounterMismatch;
        if (self.not_found != expected.not_found) return error.BenchmarkCounterMismatch;
        if (self.trades != expected.trades) return error.BenchmarkCounterMismatch;
    }
};

const WorkloadState = struct {
    next_id: engine.OrderId = 1,
    phase: usize = 0,

    fn prepare(self: *WorkloadState, book: *engine.OrderBook, workload: Workload) void {
        switch (workload) {
            .full_capacity => {
                var id: engine.OrderId = 1;
                while (id <= engine.max_orders) : (id += 1) {
                    _ = book.submitLimit(.{
                        .id = id,
                        .side = .buy,
                        .price = 100,
                        .quantity = 1,
                    });
                }
                self.next_id = engine.max_orders + 1;
            },
            else => {},
        }
    }

    fn next(self: *WorkloadState, workload: Workload) Command {
        return switch (workload) {
            .matching => self.nextMatching(),
            .resting => self.nextResting(),
            .cancel_heavy => self.nextCancelHeavy(),
            .full_capacity => self.nextFullCapacity(),
        };
    }

    fn nextMatching(self: *WorkloadState) Command {
        const id = self.takeId();
        const slot = self.phase % 2;
        self.phase += 1;
        if (slot == 0) return submit(id, .sell, 100, 1);
        return submit(id, .buy, 100, 1);
    }

    fn nextResting(self: *WorkloadState) Command {
        const slot = self.phase % (engine.max_orders * 2);
        const cycle = self.phase / (engine.max_orders * 2);
        self.phase += 1;

        const order_id = @as(engine.OrderId, @intCast(cycle * engine.max_orders + slot % engine.max_orders + 1));
        if (slot < engine.max_orders) {
            return submit(order_id, .buy, 90 + @as(engine.Price, @intCast(slot % 8)), 1);
        }
        return .{ .cancel = order_id };
    }

    fn nextCancelHeavy(self: *WorkloadState) Command {
        const slot = self.phase % 4;
        const cycle = self.phase / 4;
        self.phase += 1;

        const order_id = @as(engine.OrderId, @intCast(cycle + 1));
        return switch (slot) {
            0 => submit(order_id, .buy, 90, 1),
            1 => .{ .cancel = order_id },
            2, 3 => .{ .cancel = missing_cancel_base + @as(engine.OrderId, @intCast(self.phase)) },
            else => unreachable,
        };
    }

    fn nextFullCapacity(self: *WorkloadState) Command {
        return submit(self.takeId(), .buy, 90, 1);
    }

    fn takeId(self: *WorkloadState) engine.OrderId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

const LatencyHistogram = struct {
    bins: [64]usize = std.mem.zeroes([64]usize),
    count: usize = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    total_ns: u128 = 0,

    fn observe(self: *LatencyHistogram, duration_ns: u64) void {
        self.count += 1;
        self.min_ns = @min(self.min_ns, duration_ns);
        self.max_ns = @max(self.max_ns, duration_ns);
        self.total_ns += duration_ns;
        self.bins[bucketIndex(duration_ns)] += 1;
    }

    fn averageNs(self: *const LatencyHistogram) u64 {
        if (self.count == 0) return 0;
        return @intCast(self.total_ns / self.count);
    }

    fn percentileUpperBoundNs(self: *const LatencyHistogram, percentile: usize) u64 {
        if (self.count == 0) return 0;
        const rank = (self.count * percentile + 99) / 100;
        var seen: usize = 0;
        for (self.bins, 0..) |bin_count, index| {
            seen += bin_count;
            if (seen >= rank) return bucketUpperBound(index);
        }
        return self.max_ns;
    }
};

const BenchmarkResult = struct {
    histogram: LatencyHistogram = .{},
    counters: Counters = .{},
    expected_counters: Counters = .{},
    elapsed_ns: u64 = 0,
    checksum: u64 = 0,
    final_live_orders: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var args_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iterator.deinit();
    const args = try parseArgs(&args_iterator);

    try validateArgs(args);
    try runWarmup(io, args);
    const result = try runBenchmark(io, args);
    try result.counters.expectEqual(result.expected_counters);
    if (result.final_live_orders > workloadSpec(args.workload, args.command_count).max_live_orders) {
        return error.BenchmarkLiveOrderBoundExceeded;
    }
    try printResult(stdout, args, result);
    try stdout.flush();
}

fn parseArgs(args: *std.process.Args.Iterator) !Args {
    var parsed = Args{};
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--measurement")) {
            parsed.measurement = parseEnum(Measurement, args.next() orelse return error.MissingMeasurement) orelse return error.UnknownMeasurement;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            parsed.mode = parseEnum(Mode, args.next() orelse return error.MissingMode) orelse return error.UnknownMode;
        } else if (std.mem.eql(u8, arg, "--workload")) {
            parsed.workload = parseEnum(Workload, args.next() orelse return error.MissingWorkload) orelse return error.UnknownWorkload;
        } else if (std.mem.eql(u8, arg, "--commands")) {
            parsed.command_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCommandCount, 10);
            if (parsed.command_count == 0) return error.CommandCountMustBePositive;
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            parsed.warmup_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingWarmupCount, 10);
        } else if (std.mem.eql(u8, arg, "--journal-dir")) {
            parsed.journal_dir = args.next() orelse return error.MissingJournalDir;
        } else {
            return error.UnknownArgument;
        }
    }

    return parsed;
}

fn parseEnum(comptime T: type, text: []const u8) ?T {
    const enum_info = @typeInfo(T).@"enum";
    inline for (enum_info.field_names, enum_info.field_values) |field_name, field_value| {
        if (std.mem.eql(u8, text, field_name)) return @fromBackingInt(@intCast(field_value));
    }
    return null;
}

fn validateArgs(args: Args) !void {
    const max_commands = @as(usize, std.math.maxInt(u32));
    if (args.command_count > max_commands) return error.CommandCountTooLarge;
    if (args.warmup_count > max_commands) return error.WarmupCountTooLarge;
}

fn runWarmup(io: std.Io, args: Args) !void {
    if (args.warmup_count == 0) return;
    var warmup_args = args;
    warmup_args.command_count = args.warmup_count;
    const result = try runCommandLoop(io, warmup_args, false);
    std.mem.doNotOptimizeAway(result.checksum);
}

fn runBenchmark(io: std.Io, args: Args) !BenchmarkResult {
    return switch (args.measurement) {
        .throughput => runCommandLoop(io, args, false),
        .latency => runCommandLoop(io, args, true),
    };
}

fn runCommandLoop(io: std.Io, args: Args, comptime record_latency: bool) !BenchmarkResult {
    var book = engine.OrderBook.init();
    var workload_state = WorkloadState{};
    workload_state.prepare(&book, args.workload);

    var result = BenchmarkResult{
        .expected_counters = expectedCounters(args.workload, args.command_count),
    };

    var segment: ?journal.Segment = null;
    if (args.mode == .journal) {
        segment = try journal.Segment.open(io, args.journal_dir);
    }
    defer if (segment) |*open_segment| open_segment.close();

    const benchmark_start = timestampNs(io);
    if (record_latency) {
        try runLatencyLoop(io, &book, &workload_state, args, &segment, &result);
    } else {
        try runThroughputLoop(&book, &workload_state, args, &segment, &result);
    }
    const benchmark_end = timestampNs(io);

    result.elapsed_ns = elapsedNs(benchmark_start, benchmark_end);
    result.final_live_orders = book.bid_count + book.ask_count;
    result.checksum = checksumBook(&book) ^ @as(u64, @intCast(result.counters.trades));
    std.mem.doNotOptimizeAway(result.checksum);
    return result;
}

fn runThroughputLoop(
    book: *engine.OrderBook,
    workload_state: *WorkloadState,
    args: Args,
    segment: *?journal.Segment,
    result: *BenchmarkResult,
) !void {
    var index: usize = 0;
    while (index < args.command_count) : (index += 1) {
        const command = workload_state.next(args.workload);
        if (segment.*) |*open_segment| {
            try appendJournalCommand(open_segment, command);
        }
        applyCommand(book, command, &result.counters);
    }
}

fn runLatencyLoop(
    io: std.Io,
    book: *engine.OrderBook,
    workload_state: *WorkloadState,
    args: Args,
    segment: *?journal.Segment,
    result: *BenchmarkResult,
) !void {
    var index: usize = 0;
    while (index < args.command_count) : (index += 1) {
        const command = workload_state.next(args.workload);
        const command_start = timestampNs(io);
        if (segment.*) |*open_segment| {
            try appendJournalCommand(open_segment, command);
        }
        applyCommand(book, command, &result.counters);
        const command_end = timestampNs(io);
        result.histogram.observe(elapsedNs(command_start, command_end));
    }
}

fn appendJournalCommand(segment: *journal.Segment, command: Command) !void {
    switch (command) {
        .submit_limit => |order| try segment.appendSubmitLimit(order),
        .cancel => |id| try segment.appendCancel(id),
    }
}

fn applyCommand(book: *engine.OrderBook, command: Command, counters: *Counters) void {
    switch (command) {
        .submit_limit => |order| {
            if (book.containsOrder(order.id)) {
                counters.rejected += 1;
                return;
            }
            if (book.restingQuantityAfterMatch(order) > 0 and !book.hasRoomFor(order.side)) {
                counters.rejected += 1;
                return;
            }
            const match_result = book.submitLimit(order);
            counters.accepted += 1;
            counters.trades += match_result.trade_count;
        },
        .cancel => |id| {
            if (book.cancel(id)) {
                counters.canceled += 1;
            } else {
                counters.not_found += 1;
            }
        },
    }
}

fn expectedCounters(workload: Workload, command_count: usize) Counters {
    return switch (workload) {
        .matching => .{
            .accepted = command_count,
            .trades = command_count / 2,
        },
        .resting => blk: {
            const cycle_len = engine.max_orders * 2;
            const full_cycles = command_count / cycle_len;
            const remainder = command_count % cycle_len;
            break :blk .{
                .accepted = full_cycles * engine.max_orders + @min(remainder, engine.max_orders),
                .canceled = full_cycles * engine.max_orders + if (remainder > engine.max_orders) remainder - engine.max_orders else 0,
            };
        },
        .cancel_heavy => blk: {
            const full_cycles = command_count / 4;
            const remainder = command_count % 4;
            break :blk .{
                .accepted = full_cycles + if (remainder > 0) @as(usize, 1) else 0,
                .canceled = full_cycles + if (remainder > 1) @as(usize, 1) else 0,
                .not_found = full_cycles * 2 + if (remainder > 2) remainder - 2 else 0,
            };
        },
        .full_capacity => .{
            .rejected = command_count,
        },
    };
}

fn workloadSpec(workload: Workload, command_count: usize) WorkloadSpec {
    return switch (workload) {
        .matching => .{
            .max_live_orders = 1,
            .price_min = 100,
            .price_max = 100,
            .id_min = 1,
            .id_max = @intCast(command_count),
            .description = "alternates one resting sell with one crossing buy; live orders stay at 0 or 1",
        },
        .resting => .{
            .max_live_orders = engine.max_orders,
            .price_min = 90,
            .price_max = 97,
            .id_min = 1,
            .id_max = @intCast((command_count + 1) / 2 + engine.max_orders),
            .description = "cycles 128 non-crossing buys followed by cancels for those same ids",
        },
        .cancel_heavy => .{
            .max_live_orders = 1,
            .price_min = 90,
            .price_max = 90,
            .id_min = 1,
            .id_max = missing_cancel_base + @as(engine.OrderId, @intCast(command_count)),
            .description = "repeats submit, cancel existing, cancel missing, cancel missing",
        },
        .full_capacity => .{
            .max_live_orders = engine.max_orders,
            .price_min = 90,
            .price_max = 100,
            .id_min = 1,
            .id_max = @intCast(command_count + engine.max_orders),
            .description = "prefills the bid side to capacity, then submits non-crossing buys expected to reject",
        },
    };
}

fn printResult(writer: *std.Io.Writer, args: Args, result: BenchmarkResult) !void {
    const spec = workloadSpec(args.workload, args.command_count);
    try writer.writeAll("neon-match benchmark\n");
    try writer.print("zig_version: {s}\n", .{builtin.zig_version_string});
    try writer.print("target: {s}-{s}-{s}\n", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
    });
    try writer.print("logical_cpu_count: {d}\n", .{std.Thread.getCpuCount() catch 0});
    try writer.print("optimize: {s}\n", .{@tagName(builtin.mode)});
    try writer.print("measurement: {s}\n", .{@tagName(args.measurement)});
    try writer.print("mode: {s}\n", .{@tagName(args.mode)});
    try writer.print("workload: {s}\n", .{@tagName(args.workload)});
    try writer.print("commands: {d}\n", .{args.command_count});
    try writer.print("warmup_commands: {d}\n", .{args.warmup_count});
    try writer.print("command: zig build bench -Doptimize={s} -- --measurement {s} --mode {s} --workload {s} --commands {d} --warmup {d}", .{
        optimizeCliName(),
        @tagName(args.measurement),
        @tagName(args.mode),
        @tagName(args.workload),
        args.command_count,
        args.warmup_count,
    });
    if (args.mode == .journal) {
        try writer.print(" --journal-dir {s}", .{args.journal_dir});
    }
    try writer.writeAll("\n");

    try writer.print("workload_description: {s}\n", .{spec.description});
    try writer.print("workload_max_live_orders: {d}\n", .{spec.max_live_orders});
    try writer.print("workload_price_range: {d}..{d}\n", .{ spec.price_min, spec.price_max });
    try writer.print("workload_id_range: {d}..{d}\n", .{ spec.id_min, spec.id_max });
    try writer.print("elapsed_ns: {d}\n", .{result.elapsed_ns});
    if (args.measurement == .throughput) {
        const throughput = if (result.elapsed_ns == 0)
            0
        else
            (@as(u128, args.command_count) * std.time.ns_per_s) / result.elapsed_ns;
        try writer.print("throughput_commands_per_second: {d}\n", .{throughput});
        try writer.writeAll("service_time_percentiles: not_collected_in_throughput_measurement\n");
    } else {
        try writer.writeAll("throughput_commands_per_second: not_collected\n");
        try writer.print("service_time_ns_min: {d}\n", .{if (result.histogram.count == 0) 0 else result.histogram.min_ns});
        try writer.print("service_time_ns_avg: {d}\n", .{result.histogram.averageNs()});
        try writer.print("service_time_ns_p50_upper_bound: {d}\n", .{result.histogram.percentileUpperBoundNs(50)});
        try writer.print("service_time_ns_p90_upper_bound: {d}\n", .{result.histogram.percentileUpperBoundNs(90)});
        try writer.print("service_time_ns_p99_upper_bound: {d}\n", .{result.histogram.percentileUpperBoundNs(99)});
        try writer.print("service_time_ns_max: {d}\n", .{result.histogram.max_ns});
    }
    try writer.print("accepted: {d}\n", .{result.counters.accepted});
    try writer.print("rejected: {d}\n", .{result.counters.rejected});
    try writer.print("canceled: {d}\n", .{result.counters.canceled});
    try writer.print("not_found: {d}\n", .{result.counters.not_found});
    try writer.print("trades: {d}\n", .{result.counters.trades});
    try writer.print("expected_accepted: {d}\n", .{result.expected_counters.accepted});
    try writer.print("expected_rejected: {d}\n", .{result.expected_counters.rejected});
    try writer.print("expected_canceled: {d}\n", .{result.expected_counters.canceled});
    try writer.print("expected_not_found: {d}\n", .{result.expected_counters.not_found});
    try writer.print("expected_trades: {d}\n", .{result.expected_counters.trades});
    try writer.print("final_live_orders: {d}\n", .{result.final_live_orders});
    try writer.print("checksum: {d}\n", .{result.checksum});
    switch (args.mode) {
        .matcher => try writer.writeAll("allocation_note: matcher mode uses fixed OrderBook storage and no allocator in warm-up or measurement command loops\n"),
        .journal => try writer.writeAll("journal_note: journal mode measures serialization, checksum work, and buffered writes accepted by the OS page cache; it does not measure stable-storage durability because there is no per-command fsync or fdatasync\n"),
    }
    try writer.writeAll("coordinated_omission_note: latency mode reports isolated command service time and excludes ingress queueing; do not interpret these percentiles as end-to-end system latency under offered load\n");
}

fn submit(id: engine.OrderId, side: engine.Side, price: engine.Price, quantity: engine.Quantity) Command {
    return .{ .submit_limit = .{
        .id = id,
        .side = side,
        .price = price,
        .quantity = quantity,
    } };
}

fn elapsedNs(start: i128, end: i128) u64 {
    return @intCast(@max(end - start, 0));
}

fn timestampNs(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn optimizeCliName() []const u8 {
    return switch (builtin.mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

fn bucketIndex(value: u64) usize {
    if (value == 0) return 0;
    return @min(63, 64 - @clz(value));
}

fn bucketUpperBound(index: usize) u64 {
    if (index == 0) return 0;
    if (index >= 63) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(index)) - 1;
}

fn checksumBook(book: *const engine.OrderBook) u64 {
    var checksum: u64 = @intCast(book.bid_count ^ (book.ask_count << 16));
    for (book.bids[0..book.bid_count]) |order| {
        checksum ^= order.id;
        checksum *%= 1_099_511_628_211;
        checksum ^= order.price;
        checksum *%= 1_099_511_628_211;
        checksum ^= order.quantity;
    }
    for (book.asks[0..book.ask_count]) |order| {
        checksum ^= order.id;
        checksum *%= 1_099_511_628_211;
        checksum ^= order.price;
        checksum *%= 1_099_511_628_211;
        checksum ^= order.quantity;
    }
    return checksum;
}
