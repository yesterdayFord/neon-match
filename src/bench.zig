const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const journal = @import("journal.zig");

const default_command_count: usize = 100_000;
const default_warmup_count: usize = 10_000;
const default_latency_sample_size: usize = 64;
const tsc_overhead_sample_count: usize = 256;
const default_journal_dir = ".zig-cache/bench-journal";
const missing_cancel_base: engine.OrderId = 1_000_000_000_000;
const benchmark_instrument_id: journal.InstrumentId = 1;

const Measurement = enum {
    throughput,
    latency,
};

const TimingMode = enum {
    nanoseconds,
    tsc_ticks,
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
    latency_sample_size: usize = default_latency_sample_size,
    timing: TimingMode = .nanoseconds,
    logical_cpu: ?usize = null,
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

const SampleHistogram = struct {
    bins: [64]usize = std.mem.zeroes([64]usize),
    count: usize = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,
    total: u128 = 0,

    fn observe(self: *SampleHistogram, value: u64) void {
        self.count += 1;
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
        self.total += value;
        self.bins[bucketIndex(value)] += 1;
    }

    fn average(self: *const SampleHistogram) u64 {
        if (self.count == 0) return 0;
        return @intCast(self.total / self.count);
    }

    fn percentileUpperBound(self: *const SampleHistogram, percentile: usize) u64 {
        if (self.count == 0) return 0;
        const rank = (self.count * percentile + 99) / 100;
        var seen: usize = 0;
        for (self.bins, 0..) |bin_count, index| {
            seen += bin_count;
            if (seen >= rank) return bucketUpperBound(index);
        }
        return self.max;
    }
};

const BenchmarkResult = struct {
    histogram: SampleHistogram = .{},
    tsc_batch_histogram: SampleHistogram = .{},
    tsc_overhead_histogram: SampleHistogram = .{},
    counters: Counters = .{},
    expected_counters: Counters = .{},
    elapsed_ns: u64 = 0,
    total_tsc_ticks: u64 = 0,
    checksum: u64 = 0,
    final_live_orders: usize = 0,
    affinity_applied: bool = false,
    selected_logical_cpu: ?usize = null,
    tsc_support_status: []const u8 = "not_requested",
    cpu_model: []const u8 = "not_recorded",
};

const TscContext = struct {
    affinity_applied: bool,
    selected_logical_cpu: usize,
    cpu_model_buffer: [64]u8,
    cpu_model_len: usize,

    fn cpuModel(self: *const TscContext) []const u8 {
        return self.cpu_model_buffer[0..self.cpu_model_len];
    }
};

const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
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
    const tsc_context: ?TscContext = if (args.timing == .tsc_ticks)
        try prepareTscTiming(args)
    else
        null;
    try runWarmup(io, args);
    const result = try runBenchmark(io, args, if (tsc_context) |*context| context else null);
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
        } else if (std.mem.eql(u8, arg, "--timing")) {
            parsed.timing = parseEnum(TimingMode, args.next() orelse return error.MissingTimingMode) orelse return error.UnknownTimingMode;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            parsed.mode = parseEnum(Mode, args.next() orelse return error.MissingMode) orelse return error.UnknownMode;
        } else if (std.mem.eql(u8, arg, "--workload")) {
            parsed.workload = parseEnum(Workload, args.next() orelse return error.MissingWorkload) orelse return error.UnknownWorkload;
        } else if (std.mem.eql(u8, arg, "--commands")) {
            parsed.command_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCommandCount, 10);
            if (parsed.command_count == 0) return error.CommandCountMustBePositive;
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            parsed.warmup_count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingWarmupCount, 10);
        } else if (std.mem.eql(u8, arg, "--latency-sample-size")) {
            parsed.latency_sample_size = try std.fmt.parseInt(usize, args.next() orelse return error.MissingLatencySampleSize, 10);
            if (parsed.latency_sample_size == 0) return error.LatencySampleSizeMustBePositive;
        } else if (std.mem.eql(u8, arg, "--logical-cpu")) {
            parsed.logical_cpu = try std.fmt.parseInt(usize, args.next() orelse return error.MissingLogicalCpu, 10);
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
    if (args.latency_sample_size > max_commands) return error.LatencySampleSizeTooLarge;
    if (args.timing == .tsc_ticks and args.measurement != .latency) return error.TscTimingRequiresLatencyMeasurement;
}

fn runWarmup(io: std.Io, args: Args) !void {
    if (args.warmup_count == 0) return;
    var warmup_args = args;
    warmup_args.command_count = args.warmup_count;
    const result = try runCommandLoop(io, warmup_args, false, null);
    std.mem.doNotOptimizeAway(result.checksum);
}

fn runBenchmark(io: std.Io, args: Args, tsc_context: ?*const TscContext) !BenchmarkResult {
    return switch (args.measurement) {
        .throughput => runCommandLoop(io, args, false, tsc_context),
        .latency => runCommandLoop(io, args, true, tsc_context),
    };
}

fn runCommandLoop(
    io: std.Io,
    args: Args,
    comptime record_latency: bool,
    tsc_context: ?*const TscContext,
) !BenchmarkResult {
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
        switch (args.timing) {
            .nanoseconds => try runLatencyLoop(io, &book, &workload_state, args, &segment, &result),
            .tsc_ticks => try runTscLatencyLoop(&book, &workload_state, args, &segment, &result, tsc_context orelse return error.BenchmarkTscContextMissing),
        }
    } else {
        try runThroughputLoop(&book, &workload_state, args, &segment, &result);
    }
    const benchmark_end = timestampNs(io);

    result.elapsed_ns = elapsedNs(benchmark_start, benchmark_end);
    if (result.elapsed_ns == 0) return error.BenchmarkTimestampResolutionTooCoarse;
    result.final_live_orders = book.bid_count + book.ask_count;
    result.checksum = checksumBook(&book) ^ @as(u64, @intCast(result.counters.trades));
    if (tsc_context) |context| {
        result.affinity_applied = context.affinity_applied;
        result.selected_logical_cpu = context.selected_logical_cpu;
        result.tsc_support_status = "supported_invariant_rdtscp";
        result.cpu_model = context.cpuModel();
    }
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
    while (index < args.command_count) {
        const sample_count = @min(args.latency_sample_size, args.command_count - index);
        const command_start = timestampNs(io);
        var sample_index: usize = 0;
        while (sample_index < sample_count) : (sample_index += 1) {
            const command = workload_state.next(args.workload);
            if (segment.*) |*open_segment| {
                try appendJournalCommand(open_segment, command);
            }
            applyCommand(book, command, &result.counters);
        }
        const command_end = timestampNs(io);
        const sample_elapsed = elapsedNs(command_start, command_end);
        if (sample_elapsed == 0) return error.BenchmarkTimestampResolutionTooCoarse;
        const per_command_ns = try batchAmortizedEstimate(sample_elapsed, sample_count);
        result.histogram.observe(per_command_ns);
        index += sample_count;
    }
}

fn runTscLatencyLoop(
    book: *engine.OrderBook,
    workload_state: *WorkloadState,
    args: Args,
    segment: *?journal.Segment,
    result: *BenchmarkResult,
    tsc_context: *const TscContext,
) !void {
    _ = tsc_context;
    result.tsc_overhead_histogram = try measureTscOverhead();

    var index: usize = 0;
    while (index < args.command_count) {
        const sample_count = @min(args.latency_sample_size, args.command_count - index);
        const command_start = readTscStart();
        var sample_index: usize = 0;
        while (sample_index < sample_count) : (sample_index += 1) {
            const command = workload_state.next(args.workload);
            if (segment.*) |*open_segment| {
                try appendJournalCommand(open_segment, command);
            }
            applyCommand(book, command, &result.counters);
        }
        const command_end = readTscEnd();
        if (command_end <= command_start) return error.BenchmarkTimestampResolutionTooCoarse;
        const batch_ticks = command_end - command_start;
        const per_command_ticks = try batchAmortizedEstimate(batch_ticks, sample_count);
        result.tsc_batch_histogram.observe(batch_ticks);
        result.histogram.observe(per_command_ticks);
        result.total_tsc_ticks +|= batch_ticks;
        index += sample_count;
    }
}

fn prepareTscTiming(args: Args) !TscContext {
    if (!isTscArchitecture(builtin.cpu.arch)) return error.BenchmarkTscUnsupportedArchitecture;

    const support = detectTscSupport();
    if (!support.rdtscp) return error.BenchmarkRdtscpUnsupported;
    if (!support.invariant_tsc) return error.BenchmarkInvariantTscUnsupported;

    const cpu_count = std.Thread.getCpuCount() catch return error.BenchmarkAffinityUnavailable;
    const selected_cpu = args.logical_cpu orelse 0;
    if (selected_cpu >= cpu_count) return error.BenchmarkLogicalCpuOutOfRange;
    try pinCurrentThreadToLogicalCpu(selected_cpu);

    return .{
        .affinity_applied = true,
        .selected_logical_cpu = selected_cpu,
        .cpu_model_buffer = support.cpu_model_buffer,
        .cpu_model_len = support.cpu_model_len,
    };
}

fn batchAmortizedEstimate(batch_total: u64, sample_count: usize) !u64 {
    if (batch_total == 0 or sample_count == 0) return error.BenchmarkTimestampResolutionTooCoarse;
    return (batch_total + sample_count - 1) / sample_count;
}

fn isTscArchitecture(arch: std.Target.Cpu.Arch) bool {
    return switch (arch) {
        .x86, .x86_64 => true,
        else => false,
    };
}

const TscSupport = struct {
    rdtscp: bool,
    invariant_tsc: bool,
    cpu_model_buffer: [64]u8,
    cpu_model_len: usize,
};

fn detectTscSupport() TscSupport {
    if (!isTscArchitecture(builtin.cpu.arch)) {
        return .{
            .rdtscp = false,
            .invariant_tsc = false,
            .cpu_model_buffer = emptyCpuModelBuffer(),
            .cpu_model_len = "unsupported_architecture".len,
        };
    }

    const max_extended = cpuid(0x80000000, 0).eax;
    const rdtscp = if (max_extended >= 0x80000001)
        (cpuid(0x80000001, 0).edx & (@as(u32, 1) << 27)) != 0
    else
        false;
    const invariant_tsc = if (max_extended >= 0x80000007)
        (cpuid(0x80000007, 0).edx & (@as(u32, 1) << 8)) != 0
    else
        false;

    var cpu_model_buffer = emptyCpuModelBuffer();
    var cpu_model_len = "unknown_cpu_model".len;
    if (max_extended >= 0x80000004) {
        cpu_model_len = cpuBrandString(&cpu_model_buffer);
    } else {
        @memcpy(cpu_model_buffer[0..cpu_model_len], "unknown_cpu_model");
    }

    return .{
        .rdtscp = rdtscp,
        .invariant_tsc = invariant_tsc,
        .cpu_model_buffer = cpu_model_buffer,
        .cpu_model_len = cpu_model_len,
    };
}

fn emptyCpuModelBuffer() [64]u8 {
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 0);
    return buffer;
}

fn cpuBrandString(buffer: *[64]u8) usize {
    var offset: usize = 0;
    var leaf: u32 = 0x80000002;
    while (leaf <= 0x80000004) : (leaf += 1) {
        const result = cpuid(leaf, 0);
        writeU32Bytes(buffer[offset..][0..4], result.eax);
        writeU32Bytes(buffer[offset + 4 ..][0..4], result.ebx);
        writeU32Bytes(buffer[offset + 8 ..][0..4], result.ecx);
        writeU32Bytes(buffer[offset + 12 ..][0..4], result.edx);
        offset += 16;
    }

    var start: usize = 0;
    while (start < offset and buffer[start] == ' ') : (start += 1) {}
    var end = offset;
    while (end > start and (buffer[end - 1] == ' ' or buffer[end - 1] == 0)) : (end -= 1) {}
    if (start > 0 and end > start) {
        std.mem.copyForwards(u8, buffer[0 .. end - start], buffer[start..end]);
    }
    return end - start;
}

fn writeU32Bytes(dest: []u8, value: u32) void {
    std.mem.writeInt(u32, dest[0..4], value, .little);
}

fn measureTscOverhead() !SampleHistogram {
    var histogram = SampleHistogram{};
    var index: usize = 0;
    while (index < tsc_overhead_sample_count) : (index += 1) {
        const start = readTscStart();
        const end = readTscEnd();
        if (end <= start) return error.BenchmarkTimestampResolutionTooCoarse;
        histogram.observe(end - start);
    }
    return histogram;
}

fn pinCurrentThreadToLogicalCpu(logical_cpu: usize) !void {
    if (comptime builtin.os.tag != .windows) return error.BenchmarkAffinityUnavailable;
    if (logical_cpu >= @bitSizeOf(usize)) return error.BenchmarkLogicalCpuOutOfRange;

    const current_thread = GetCurrentThread();
    const mask = @as(usize, 1) << @intCast(logical_cpu);
    if (SetThreadAffinityMask(current_thread, mask) == 0) return error.BenchmarkAffinityUnavailable;
}

extern "kernel32" fn GetCurrentThread() callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn SetThreadAffinityMask(thread: std.os.windows.HANDLE, mask: usize) callconv(.winapi) usize;

fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    if (comptime !isTscArchitecture(builtin.cpu.arch)) {
        return .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
    }

    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn readTscStart() u64 {
    if (comptime !isTscArchitecture(builtin.cpu.arch)) return 0;

    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile (
        \\lfence
        \\rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

fn readTscEnd() u64 {
    if (comptime !isTscArchitecture(builtin.cpu.arch)) return 0;

    var low: u32 = undefined;
    var high: u32 = undefined;
    var aux: u32 = undefined;
    asm volatile (
        \\rdtscp
        \\lfence
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
          [aux] "={ecx}" (aux),
    );
    std.mem.doNotOptimizeAway(aux);
    return (@as(u64, high) << 32) | low;
}

fn appendJournalCommand(segment: *journal.Segment, command: Command) !void {
    switch (command) {
        .submit_limit => |order| try segment.appendSubmitLimit(benchmark_instrument_id, order),
        .cancel => |id| try segment.appendCancel(benchmark_instrument_id, id),
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
    try writer.print("timing_mode: {s}\n", .{@tagName(args.timing)});
    try writer.print("mode: {s}\n", .{@tagName(args.mode)});
    try writer.print("workload: {s}\n", .{@tagName(args.workload)});
    try writer.print("commands: {d}\n", .{args.command_count});
    try writer.print("warmup_commands: {d}\n", .{args.warmup_count});
    if (args.measurement == .latency) {
        try writer.print("latency_sample_size: {d}\n", .{args.latency_sample_size});
    }
    try writer.print("command: zig build bench -Doptimize={s} -- --measurement {s} --timing {s} --mode {s} --workload {s} --commands {d} --warmup {d}", .{
        optimizeCliName(),
        @tagName(args.measurement),
        @tagName(args.timing),
        @tagName(args.mode),
        @tagName(args.workload),
        args.command_count,
        args.warmup_count,
    });
    if (args.measurement == .latency) {
        try writer.print(" --latency-sample-size {d}", .{args.latency_sample_size});
    }
    if (args.logical_cpu) |cpu| {
        try writer.print(" --logical-cpu {d}", .{cpu});
    }
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
    } else if (args.timing == .nanoseconds) {
        try writer.writeAll("throughput_commands_per_second: not_collected\n");
        try writer.print("service_time_samples: {d}\n", .{result.histogram.count});
        try writer.print("service_time_ns_min: {d}\n", .{if (result.histogram.count == 0) 0 else result.histogram.min});
        try writer.print("service_time_ns_avg: {d}\n", .{result.histogram.average()});
        try writer.print("service_time_ns_p50_upper_bound: {d}\n", .{result.histogram.percentileUpperBound(50)});
        try writer.print("service_time_ns_p90_upper_bound: {d}\n", .{result.histogram.percentileUpperBound(90)});
        try writer.print("service_time_ns_p99_upper_bound: {d}\n", .{result.histogram.percentileUpperBound(99)});
        try writer.print("service_time_ns_max: {d}\n", .{result.histogram.max});
    } else {
        try printTscTimingResult(writer, args, result);
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
    try writer.writeAll("coordinated_omission_note: latency mode reports isolated command service-time estimates from fixed-size batches and excludes ingress queueing; do not interpret these percentiles as end-to-end system latency under offered load\n");
}

fn printTscTimingResult(writer: *std.Io.Writer, args: Args, result: BenchmarkResult) !void {
    _ = args;
    try writer.writeAll("throughput_commands_per_second: not_collected\n");
    try writer.print("tsc_architecture_supported: {s}\n", .{if (isTscArchitecture(builtin.cpu.arch)) "true" else "false"});
    try writer.print("tsc_support_status: {s}\n", .{result.tsc_support_status});
    try writer.print("cpu_model: {s}\n", .{result.cpu_model});
    try writer.print("affinity_applied: {s}\n", .{if (result.affinity_applied) "true" else "false"});
    if (result.selected_logical_cpu) |cpu| {
        try writer.print("selected_logical_cpu: {d}\n", .{cpu});
    } else {
        try writer.writeAll("selected_logical_cpu: none\n");
    }
    try writer.print("service_time_samples: {d}\n", .{result.histogram.count});
    try writer.print("measurement_repetitions: {d}\n", .{result.histogram.count});
    try writer.print("total_tsc_ticks: {d}\n", .{result.total_tsc_ticks});
    try writer.print("batch_tsc_ticks_min: {d}\n", .{if (result.tsc_batch_histogram.count == 0) 0 else result.tsc_batch_histogram.min});
    try writer.print("batch_tsc_ticks_p50_upper_bound: {d}\n", .{result.tsc_batch_histogram.percentileUpperBound(50)});
    try writer.print("batch_tsc_ticks_p90_upper_bound: {d}\n", .{result.tsc_batch_histogram.percentileUpperBound(90)});
    try writer.print("batch_tsc_ticks_p99_upper_bound: {d}\n", .{result.tsc_batch_histogram.percentileUpperBound(99)});
    try writer.print("batch_tsc_ticks_max: {d}\n", .{result.tsc_batch_histogram.max});
    try writer.print("batch_amortized_tsc_ticks_per_command_min: {d}\n", .{if (result.histogram.count == 0) 0 else result.histogram.min});
    try writer.print("batch_amortized_tsc_ticks_per_command_avg: {d}\n", .{result.histogram.average()});
    try writer.print("batch_amortized_tsc_ticks_per_command_p50_upper_bound: {d}\n", .{result.histogram.percentileUpperBound(50)});
    try writer.print("batch_amortized_tsc_ticks_per_command_p90_upper_bound: {d}\n", .{result.histogram.percentileUpperBound(90)});
    try writer.print("batch_amortized_tsc_ticks_per_command_p99_upper_bound: {d}\n", .{result.histogram.percentileUpperBound(99)});
    try writer.print("batch_amortized_tsc_ticks_per_command_max: {d}\n", .{result.histogram.max});
    try writer.print("empty_interval_tsc_ticks_min: {d}\n", .{if (result.tsc_overhead_histogram.count == 0) 0 else result.tsc_overhead_histogram.min});
    try writer.print("empty_interval_tsc_ticks_p50_upper_bound: {d}\n", .{result.tsc_overhead_histogram.percentileUpperBound(50)});
    try writer.print("empty_interval_tsc_ticks_p99_upper_bound: {d}\n", .{result.tsc_overhead_histogram.percentileUpperBound(99)});
    try writer.print("empty_interval_tsc_ticks_max: {d}\n", .{result.tsc_overhead_histogram.max});
    try writer.writeAll("tsc_note: tsc_ticks are serialized timestamp-counter deltas, not literal executed core cycles; TSC may continue advancing while the thread is descheduled\n");
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

test "nanosecond benchmark formatting keeps existing timing fields" {
    var result = BenchmarkResult{
        .elapsed_ns = 1000,
        .expected_counters = .{ .accepted = 4, .trades = 2 },
        .counters = .{ .accepted = 4, .trades = 2 },
        .checksum = 2,
    };
    result.histogram.observe(10);
    result.histogram.observe(20);

    const args = Args{
        .measurement = .latency,
        .timing = .nanoseconds,
        .command_count = 4,
        .warmup_count = 0,
        .latency_sample_size = 2,
    };

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try printResult(&writer, args, result);
    const output = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "timing_mode: nanoseconds\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "service_time_ns_min: 10\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "service_time_samples: 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "batch_amortized_tsc_ticks_per_command_min") == null);
}

test "tsc benchmark formatting distinguishes batch per command and overhead fields" {
    var result = BenchmarkResult{
        .elapsed_ns = 1000,
        .total_tsc_ticks = 1800,
        .expected_counters = .{ .accepted = 4, .trades = 2 },
        .counters = .{ .accepted = 4, .trades = 2 },
        .checksum = 2,
        .affinity_applied = true,
        .selected_logical_cpu = 1,
        .tsc_support_status = "supported_invariant_rdtscp",
        .cpu_model = "Test CPU",
    };
    result.tsc_batch_histogram.observe(800);
    result.tsc_batch_histogram.observe(1000);
    result.histogram.observe(200);
    result.histogram.observe(250);
    result.tsc_overhead_histogram.observe(30);
    result.tsc_overhead_histogram.observe(40);

    const args = Args{
        .measurement = .latency,
        .timing = .tsc_ticks,
        .command_count = 8,
        .warmup_count = 0,
        .latency_sample_size = 4,
        .logical_cpu = 1,
    };

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try printResult(&writer, args, result);
    const output = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, output, "timing_mode: tsc_ticks\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "total_tsc_ticks: 1800\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "batch_tsc_ticks_min: 800\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "batch_amortized_tsc_ticks_per_command_min: 200\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "empty_interval_tsc_ticks_min: 30\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "affinity_applied: true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "selected_logical_cpu: 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cpu_cycles") == null);
}

test "latency batch normalization rounds up per command estimates" {
    const per_command = try batchAmortizedEstimate(101, 4);
    try std.testing.expectEqual(@as(u64, 26), per_command);
}

test "zero and invalid samples fail explicitly" {
    try std.testing.expectError(error.BenchmarkTimestampResolutionTooCoarse, batchAmortizedEstimate(0, 4));
    try std.testing.expectError(error.BenchmarkTimestampResolutionTooCoarse, batchAmortizedEstimate(10, 0));
}

test "tsc architecture gate excludes unsupported targets without hardware assumptions" {
    try std.testing.expect(isTscArchitecture(.x86_64));
    try std.testing.expect(!isTscArchitecture(.aarch64));
}

test "tsc timing requires explicit latency measurement" {
    try std.testing.expectError(error.TscTimingRequiresLatencyMeasurement, validateArgs(.{
        .measurement = .throughput,
        .timing = .tsc_ticks,
    }));
}

test "requested tsc timing is explicit and nanoseconds remain default" {
    try std.testing.expectEqual(TimingMode.nanoseconds, (Args{}).timing);
    try std.testing.expectEqual(TimingMode.tsc_ticks, parseEnum(TimingMode, "tsc_ticks").?);
    try std.testing.expect(parseEnum(TimingMode, "cpu_cycles") == null);
}
