// SPDX-License-Identifier: GPL-3.0-or-later

//! Deterministic pure-Zig two-peer lockstep network benchmark.

const std = @import("std");
const input = @import("input");
const lockstep = @import("lockstep");
const match_mod = @import("match");
const online_session = @import("online_session");
const protocol = @import("protocol");

const default_frames: usize = 600;
const default_batch_target: u8 = 1;
const default_batch_hold: u8 = 0;
const default_max_steps: usize = 4;
const tick_ms: f64 = 1000.0 / 60.0;
const bench_match_id: u64 = 0x6c6f_636b_7374_6570;

const Scenario = enum {
    custom,
    clean,
    lan,
    wifi,
    regional,
    bad,
};

const StartPolicy = enum {
    simultaneous,
    current_ack,
    immediate_start,
    guarded_start,
};

const StartTicks = struct {
    p1: u64 = 0,
    p2: u64 = 0,

    fn max(self: StartTicks) u64 {
        return @max(self.p1, self.p2);
    }
};

const SampleSkewStats = struct {
    paired: u64 = 0,
    first: i64 = 0,
    last: i64 = 0,
    min: i64 = 0,
    max: i64 = 0,

    fn add(self: *SampleSkewStats, skew: i64) void {
        if (self.paired == 0) {
            self.first = skew;
            self.min = skew;
            self.max = skew;
        } else {
            self.min = @min(self.min, skew);
            self.max = @max(self.max, skew);
        }
        self.last = skew;
        self.paired += 1;
    }

    fn isZero(self: SampleSkewStats) bool {
        return self.paired > 0 and self.min == 0 and self.max == 0;
    }
};

const Params = struct {
    scenario: Scenario = .custom,
    frames: usize = default_frames,
    input_delay: u16 = online_session.DefaultInputDelayFrames,
    batch_target: u8 = default_batch_target,
    batch_hold: u8 = default_batch_hold,
    resend_window: u8 = online_session.DefaultInputResendFrames,
    max_steps: usize = default_max_steps,
    delay_p1_p2: u64 = 0,
    delay_p2_p1: u64 = 0,
    jitter: u64 = 0,
    drop_every: u64 = 0,
    start_policy: StartPolicy = .simultaneous,
    ack_delay: u64 = 0,
    start_delay: u64 = 0,
    start_guard: u64 = 0,
    json: bool = false,
    expect_complete: bool = false,
    expect_zero_start_skew: bool = false,
};

const PlayerSide = enum {
    p1,
    p2,
};

const Direction = enum {
    p1_to_p2,
    p2_to_p1,
};

const SampleRecord = struct {
    sample_tick: u64,
    target_frame: u64,
};

const LatencyStats = struct {
    values: ?[]u64 = null,
    count: u64 = 0,
    sum: u128 = 0,
    min: u64 = 0,
    max: u64 = 0,

    fn init(values: []u64) LatencyStats {
        return .{ .values = values };
    }

    fn add(self: *LatencyStats, latency: u64) void {
        if (self.values) |values| {
            if (self.count < @as(u64, @intCast(values.len))) values[@intCast(self.count)] = latency;
        }
        if (self.count == 0) {
            self.min = latency;
            self.max = latency;
        } else {
            self.min = @min(self.min, latency);
            self.max = @max(self.max, latency);
        }
        self.count += 1;
        self.sum += latency;
    }

    fn avg(self: LatencyStats) u64 {
        if (self.count == 0) return 0;
        return @intCast(self.sum / @as(u128, self.count));
    }

    fn percentile(self: *LatencyStats, percentile_rank: u8) u64 {
        if (self.count == 0) return 0;
        const values = self.values orelse return self.max;
        const observed_count: usize = @intCast(self.count);
        std.debug.assert(observed_count <= values.len);
        const observed = values[0..observed_count];
        std.mem.sort(u64, observed, {}, std.sort.asc(u64));
        const rank = (@as(u128, self.count) * percentile_rank + 99) / 100;
        return observed[@intCast(rank - 1)];
    }
};

const PlayerSamples = struct {
    records: []SampleRecord,
    count: usize = 0,
    next_local: usize = 0,
    next_opponent: usize = 0,
    local_latency: LatencyStats = .{},
    opponent_latency: LatencyStats = .{},

    fn add(self: *PlayerSamples, tick: u64, target_frame: u64) !void {
        if (self.count >= self.records.len) return error.TooManySamples;
        self.records[self.count] = .{
            .sample_tick = tick,
            .target_frame = target_frame,
        };
        self.count += 1;
    }

    fn observeLocalThrough(self: *PlayerSamples, frame_cursor_after: u64, tick: u64) void {
        while (self.next_local < self.count and self.records[self.next_local].target_frame < frame_cursor_after) {
            const sample = self.records[self.next_local];
            self.local_latency.add(tick - sample.sample_tick);
            self.next_local += 1;
        }
    }

    fn observeOpponentThrough(self: *PlayerSamples, frame_cursor_after: u64, tick: u64) void {
        while (self.next_opponent < self.count and self.records[self.next_opponent].target_frame < frame_cursor_after) {
            const sample = self.records[self.next_opponent];
            self.opponent_latency.add(tick - sample.sample_tick);
            self.next_opponent += 1;
        }
    }
};

const PeerStepMetrics = struct {
    stalled_ticks: u64 = 0,
    longest_stall: u64 = 0,
    current_stall: u64 = 0,

    fn noteAppStep(self: *PeerStepMetrics, advanced: usize, peer: *const lockstep.Peer) void {
        if (advanced == 0 and peer.match.outcome == null and peer.isOk()) {
            self.stalled_ticks += 1;
            self.current_stall += 1;
            self.longest_stall = @max(self.longest_stall, self.current_stall);
        } else {
            self.current_stall = 0;
        }
    }
};

const DirectionStats = struct {
    sent: u64 = 0,
    input_frames_sent: u64 = 0,
    dropped: u64 = 0,
    delivered: u64 = 0,
};

const QueuedPacket = struct {
    deliver_at: u64,
    direction: Direction,
    packet: lockstep.EncodedPacket,
};

const Network = struct {
    queue: []QueuedPacket,
    count: usize = 0,
    stats: [2]DirectionStats = .{ .{}, .{} },

    fn send(self: *Network, params: Params, now: u64, direction: Direction, packet: lockstep.EncodedPacket, input_frames_sent: u8) !void {
        const index = directionIndex(direction);
        self.stats[index].sent += 1;
        self.stats[index].input_frames_sent += input_frames_sent;
        const sequence = self.stats[index].sent;

        if (params.drop_every != 0 and sequence % params.drop_every == 0) {
            self.stats[index].dropped += 1;
            return;
        }

        if (self.count >= self.queue.len) return error.NetworkQueueFull;

        const base_delay = switch (direction) {
            .p1_to_p2 => params.delay_p1_p2,
            .p2_to_p1 => params.delay_p2_p1,
        };
        const jitter_delay = deterministicJitter(direction, sequence, params.jitter);
        const deliver_at = try addTicks(try addTicks(try addTicks(now, 1), base_delay), jitter_delay);

        self.queue[self.count] = .{
            .deliver_at = deliver_at,
            .direction = direction,
            .packet = packet,
        };
        self.count += 1;
    }

    fn deliverDue(self: *Network, now: u64, p1: *lockstep.Peer, p2: *lockstep.Peer) !usize {
        var delivered: usize = 0;
        var index: usize = 0;
        while (index < self.count) {
            if (self.queue[index].deliver_at <= now) {
                const queued = self.queue[index];
                var shift = index;
                while (shift + 1 < self.count) : (shift += 1) {
                    self.queue[shift] = self.queue[shift + 1];
                }
                self.count -= 1;

                switch (queued.direction) {
                    .p1_to_p2 => try p2.receiveBytes(queued.packet.slice()),
                    .p2_to_p1 => try p1.receiveBytes(queued.packet.slice()),
                }
                self.stats[directionIndex(queued.direction)].delivered += 1;
                delivered += 1;
            } else {
                index += 1;
            }
        }
        return delivered;
    }

    fn nextDue(self: *const Network) ?u64 {
        if (self.count == 0) return null;
        var next = self.queue[0].deliver_at;
        for (self.queue[1..self.count]) |queued| {
            next = @min(next, queued.deliver_at);
        }
        return next;
    }
};

const PeerDriver = struct {
    peer: lockstep.Peer,
    batcher: online_session.InputBatcher = .{},
};

const PlayerResult = struct {
    samples_created: u64,
    local_latency: LatencyStats,
    opponent_latency: LatencyStats,
    stalled_ticks: u64,
    longest_stall: u64,
    final_cursor: u64,
    final_hash: u64,
};

const BenchResult = struct {
    players: [2]PlayerResult,
    directions: [2]DirectionStats,
    start_ticks: StartTicks,
    sample_start_skew: SampleSkewStats,
    expected_samples: u64,
    expected_cursor: u64,
    drain_ticks: u64,
    complete: bool,
    hashes_match: bool,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const params = parseArgs(args, stdout, stderr) catch |err| switch (err) {
        error.HelpRequested => return,
        else => return err,
    };

    const result = try runBench(arena, params);
    if (params.json) {
        try printJson(stdout, params, result);
    } else {
        try printHuman(stdout, params, result);
    }
    try stdout.flush();
    if (params.expect_complete and !result.complete) {
        try stderr.print("bench-lockstep did not complete all measured samples\n", .{});
        try stderr.flush();
        std.process.exit(2);
    }
    if (params.expect_zero_start_skew and !result.sample_start_skew.isZero()) {
        try stderr.print("bench-lockstep observed nonzero start skew: min={} max={}\n", .{ result.sample_start_skew.min, result.sample_start_skew.max });
        try stderr.flush();
        std.process.exit(3);
    }
}

fn parseArgs(args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !Params {
    var params = Params{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--scenario")) {
            const value = nextArg(args, &index, stderr, arg);
            params = applyScenario(params, parseScenario(value) orelse failCli(stderr, "invalid --scenario value: {s}", .{value}));
        } else if (std.mem.eql(u8, arg, "--frames")) {
            const value = nextArg(args, &index, stderr, arg);
            params.frames = std.fmt.parseUnsigned(usize, value, 10) catch failCli(stderr, "invalid --frames value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--input-delay")) {
            const value = nextArg(args, &index, stderr, arg);
            params.input_delay = std.fmt.parseUnsigned(u16, value, 10) catch failCli(stderr, "invalid --input-delay value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--batch-target")) {
            const value = nextArg(args, &index, stderr, arg);
            params.batch_target = std.fmt.parseUnsigned(u8, value, 10) catch failCli(stderr, "invalid --batch-target value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--batch-hold")) {
            const value = nextArg(args, &index, stderr, arg);
            params.batch_hold = std.fmt.parseUnsigned(u8, value, 10) catch failCli(stderr, "invalid --batch-hold value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--resend-window")) {
            const value = nextArg(args, &index, stderr, arg);
            params.resend_window = std.fmt.parseUnsigned(u8, value, 10) catch failCli(stderr, "invalid --resend-window value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--max-steps")) {
            const value = nextArg(args, &index, stderr, arg);
            params.max_steps = std.fmt.parseUnsigned(usize, value, 10) catch failCli(stderr, "invalid --max-steps value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--delay-p1-p2")) {
            const value = nextArg(args, &index, stderr, arg);
            params.delay_p1_p2 = std.fmt.parseUnsigned(u64, value, 10) catch failCli(stderr, "invalid --delay-p1-p2 value: {s}", .{value});
            params.scenario = .custom;
        } else if (std.mem.eql(u8, arg, "--delay-p2-p1")) {
            const value = nextArg(args, &index, stderr, arg);
            params.delay_p2_p1 = std.fmt.parseUnsigned(u64, value, 10) catch failCli(stderr, "invalid --delay-p2-p1 value: {s}", .{value});
            params.scenario = .custom;
        } else if (std.mem.eql(u8, arg, "--jitter")) {
            const value = nextArg(args, &index, stderr, arg);
            params.jitter = std.fmt.parseUnsigned(u64, value, 10) catch failCli(stderr, "invalid --jitter value: {s}", .{value});
            params.scenario = .custom;
        } else if (std.mem.eql(u8, arg, "--drop-every")) {
            const value = nextArg(args, &index, stderr, arg);
            params.drop_every = std.fmt.parseUnsigned(u64, value, 10) catch failCli(stderr, "invalid --drop-every value: {s}", .{value});
            params.scenario = .custom;
        } else if (std.mem.eql(u8, arg, "--start-policy")) {
            const value = nextArg(args, &index, stderr, arg);
            params.start_policy = parseStartPolicy(value) orelse failCli(stderr, "invalid --start-policy value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--ack-delay")) {
            const value = nextArg(args, &index, stderr, arg);
            params.ack_delay = std.fmt.parseUnsigned(u64, value, 10) catch failCli(stderr, "invalid --ack-delay value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--start-delay")) {
            const value = nextArg(args, &index, stderr, arg);
            params.start_delay = std.fmt.parseUnsigned(u64, value, 10) catch failCli(stderr, "invalid --start-delay value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--start-guard")) {
            const value = nextArg(args, &index, stderr, arg);
            params.start_guard = std.fmt.parseUnsigned(u64, value, 10) catch failCli(stderr, "invalid --start-guard value: {s}", .{value});
        } else if (std.mem.eql(u8, arg, "--json")) {
            params.json = true;
        } else if (std.mem.eql(u8, arg, "--expect-complete")) {
            params.expect_complete = true;
        } else if (std.mem.eql(u8, arg, "--expect-zero-start-skew")) {
            params.expect_zero_start_skew = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            try stdout.flush();
            return error.HelpRequested;
        } else {
            failCli(stderr, "unknown argument: {s}", .{arg});
        }
    }

    if (@as(usize, params.input_delay) >= lockstep.MaxBufferedFrames) {
        failCli(stderr, "--input-delay must be less than {}", .{lockstep.MaxBufferedFrames});
    }
    if (params.resend_window == 0 or params.resend_window > protocol.MaxInputBatchCount) {
        failCli(stderr, "--resend-window must be between 1 and {}", .{protocol.MaxInputBatchCount});
    }
    if (params.frames > (std.math.maxInt(usize) - 8) / 2) {
        failCli(stderr, "--frames is too large", .{});
    }
    const starts = computeStartTicks(params) catch failCli(stderr, "start-policy tick values are too large", .{});
    if (params.frames > std.math.maxInt(u64) - starts.max()) {
        failCli(stderr, "--frames plus start delay is too large", .{});
    }
    if (starts.max() > @as(u64, @intCast(std.math.maxInt(usize) - params.frames))) {
        failCli(stderr, "--frames plus start delay is too large for this host", .{});
    }

    return params;
}

fn parseScenario(name: []const u8) ?Scenario {
    if (std.mem.eql(u8, name, "clean")) return .clean;
    if (std.mem.eql(u8, name, "lan")) return .lan;
    if (std.mem.eql(u8, name, "wifi")) return .wifi;
    if (std.mem.eql(u8, name, "regional")) return .regional;
    if (std.mem.eql(u8, name, "bad")) return .bad;
    return null;
}

fn parseStartPolicy(name: []const u8) ?StartPolicy {
    if (std.mem.eql(u8, name, "simultaneous")) return .simultaneous;
    if (std.mem.eql(u8, name, "current-ack")) return .current_ack;
    if (std.mem.eql(u8, name, "immediate-start")) return .immediate_start;
    if (std.mem.eql(u8, name, "guarded-start")) return .guarded_start;
    return null;
}

fn applyScenario(params: Params, scenario: Scenario) Params {
    var next = params;
    next.scenario = scenario;
    next.drop_every = 0;
    switch (scenario) {
        .custom => {},
        .clean => {
            next.delay_p1_p2 = 0;
            next.delay_p2_p1 = 0;
            next.jitter = 0;
        },
        .lan => {
            next.delay_p1_p2 = 1;
            next.delay_p2_p1 = 1;
            next.jitter = 1;
        },
        .wifi => {
            next.delay_p1_p2 = 3;
            next.delay_p2_p1 = 3;
            next.jitter = 2;
        },
        .regional => {
            next.delay_p1_p2 = 6;
            next.delay_p2_p1 = 6;
            next.jitter = 4;
        },
        .bad => {
            next.delay_p1_p2 = 9;
            next.delay_p2_p1 = 9;
            next.jitter = 6;
        },
    }
    return next;
}

fn scenarioName(scenario: Scenario) []const u8 {
    return switch (scenario) {
        .custom => "custom",
        .clean => "clean",
        .lan => "lan",
        .wifi => "wifi",
        .regional => "regional",
        .bad => "bad",
    };
}

fn startPolicyName(policy: StartPolicy) []const u8 {
    return switch (policy) {
        .simultaneous => "simultaneous",
        .current_ack => "current-ack",
        .immediate_start => "immediate-start",
        .guarded_start => "guarded-start",
    };
}

fn computeStartTicks(params: Params) !StartTicks {
    return switch (params.start_policy) {
        .simultaneous => .{},
        // Current runtime behavior: the joiner begins sampling after it sends
        // ACK, while the host waits for that ACK to arrive.
        .current_ack => .{ .p1 = params.ack_delay, .p2 = 0 },
        // Naive START behavior: the host begins when ACK arrives and the
        // joiner begins when the host's START reaches it. This can merely move
        // persistent skew from one player to the other.
        .immediate_start => .{
            .p1 = params.ack_delay,
            .p2 = try addTicks(params.ack_delay, params.start_delay),
        },
        // Idealized guarded START behavior in a shared wall-clock model. If the
        // guard covers host->joiner delivery, both peers begin together; if not,
        // the joiner misses the deadline and residual skew remains.
        .guarded_start => guarded: {
            const host_start = try addTicks(params.ack_delay, params.start_guard);
            const joiner_receives_start = try addTicks(params.ack_delay, params.start_delay);
            break :guarded .{
                .p1 = host_start,
                .p2 = if (params.start_delay <= params.start_guard) host_start else joiner_receives_start,
            };
        },
    };
}

fn nextArg(args: []const [:0]const u8, index: *usize, stderr: *std.Io.Writer, flag: []const u8) []const u8 {
    index.* += 1;
    if (index.* >= args.len) failCli(stderr, "missing value for {s}", .{flag});
    return args[index.*];
}

fn failCli(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    stderr.print(fmt, args) catch {};
    stderr.print("\n\n", .{}) catch {};
    printUsage(stderr) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\usage: zig build bench-lockstep -- [options]
        \\
        \\options:
        \\  --scenario NAME     clean, lan, wifi, regional, or bad; later flags override it
        \\  --frames N          app ticks to sample (default 600)
        \\  --input-delay N     lockstep input delay frames (default 8)
        \\  --batch-target N    input batch target count (default 1)
        \\  --batch-hold N      max held app ticks before flush (default 0)
        \\  --resend-window N   recent local frames per input packet, including new input (default 8)
        \\  --max-steps N       max simulated frames per app tick (default 4)
        \\  --delay-p1-p2 N     extra deterministic packet delay P1->P2 in app ticks (default 0)
        \\  --delay-p2-p1 N     extra deterministic packet delay P2->P1 in app ticks (default 0)
        \\  --jitter N          deterministic extra packet delay in [0,N] app ticks (default 0)
        \\  --drop-every N      drop every Nth packet per direction; 0 disables (default 0)
        \\  --start-policy NAME simultaneous, current-ack, immediate-start, guarded-start (default simultaneous)
        \\  --ack-delay N       ACK transit delay for start-policy modeling (default 0)
        \\  --start-delay N     START transit delay for start-policy modeling (default 0)
        \\  --start-guard N     future start guard for guarded-start modeling (default 0)
        \\  --expect-complete   exit nonzero unless all measured samples complete
        \\  --expect-zero-start-skew exit nonzero unless paired sample start skew is exactly zero
        \\  --json              emit JSON
        \\  -h, --help          show this help
        \\
    , .{});
}

fn runBench(allocator: std.mem.Allocator, params: Params) !BenchResult {
    const start_ticks = try computeStartTicks(params);
    const end_tick = try addTicks(@intCast(params.frames), start_ticks.max());
    const queue_capacity = params.frames * 2 + protocol.MaxInputBatchCount * 2 + 8;
    var network = Network{
        .queue = try allocator.alloc(QueuedPacket, queue_capacity),
    };

    var samples = [2]PlayerSamples{
        .{
            .records = try allocator.alloc(SampleRecord, params.frames),
            .local_latency = LatencyStats.init(try allocator.alloc(u64, params.frames)),
            .opponent_latency = LatencyStats.init(try allocator.alloc(u64, params.frames)),
        },
        .{
            .records = try allocator.alloc(SampleRecord, params.frames),
            .local_latency = LatencyStats.init(try allocator.alloc(u64, params.frames)),
            .opponent_latency = LatencyStats.init(try allocator.alloc(u64, params.frames)),
        },
    };
    var step_metrics = [2]PeerStepMetrics{ .{}, .{} };

    const settings = benchSettings();
    var p1 = PeerDriver{ .peer = try lockstep.Peer.init(settings, .p1, params.input_delay, bench_match_id) };
    var p2 = PeerDriver{ .peer = try lockstep.Peer.init(settings, .p2, params.input_delay, bench_match_id) };

    const end_tick_usize: usize = @intCast(end_tick);
    var last_app_advanced = [2]usize{ 0, 0 };
    for (0..end_tick_usize) |tick_index| {
        const tick: u64 = @intCast(tick_index);
        _ = try network.deliverDue(tick, &p1.peer, &p2.peer);
        last_app_advanced[0] = try drivePeerWindow(.p1, &p1, start_ticks.p1, scriptedInput(.p1, tick), tick, params, &network, &samples, &step_metrics[0]);
        last_app_advanced[1] = try drivePeerWindow(.p2, &p2, start_ticks.p2, scriptedInput(.p2, tick), tick, params, &network, &samples, &step_metrics[1]);
    }

    const flush_tick: u64 = end_tick;
    const boundary_delivered = try network.deliverDue(flush_tick, &p1.peer, &p2.peer);
    var boundary_advanced = [2]usize{ 0, 0 };
    const boundary_should_step = boundary_delivered > 0 or needsMoreStep(params, last_app_advanced);
    if (boundary_should_step) {
        boundary_advanced[0] = try stepPeerOnly(.p1, &p1, flush_tick, params, &samples);
        boundary_advanced[1] = try stepPeerOnly(.p2, &p2, flush_tick, params, &samples);
    }

    try flushPendingInput(.p1, &p1, params, &network, flush_tick);
    try flushPendingInput(.p2, &p2, params, &network, flush_tick);
    const drain_ticks = (if (boundary_should_step) @as(u64, 1) else 0) + try drain(&p1, &p2, params, &network, &samples, flush_tick, boundary_advanced);
    const players = [2]PlayerResult{
        .{
            .samples_created = @intCast(samples[0].count),
            .local_latency = samples[0].local_latency,
            .opponent_latency = samples[0].opponent_latency,
            .stalled_ticks = step_metrics[0].stalled_ticks,
            .longest_stall = step_metrics[0].longest_stall,
            .final_cursor = p1.peer.frameCursor(),
            .final_hash = p1.peer.stateHash(),
        },
        .{
            .samples_created = @intCast(samples[1].count),
            .local_latency = samples[1].local_latency,
            .opponent_latency = samples[1].opponent_latency,
            .stalled_ticks = step_metrics[1].stalled_ticks,
            .longest_stall = step_metrics[1].longest_stall,
            .final_cursor = p2.peer.frameCursor(),
            .final_hash = p2.peer.stateHash(),
        },
    };
    const expected_cursor = try addTicks(@as(u64, @intCast(params.frames)), params.input_delay);
    const hashes_match = p1.peer.frameCursor() == p2.peer.frameCursor() and p1.peer.stateHash() == p2.peer.stateHash();

    return .{
        .players = players,
        .directions = network.stats,
        .start_ticks = start_ticks,
        .sample_start_skew = try computeSampleStartSkew(samples[0].records[0..samples[0].count], samples[1].records[0..samples[1].count]),
        .expected_samples = @intCast(params.frames),
        .expected_cursor = expected_cursor,
        .drain_ticks = drain_ticks,
        .complete = benchComplete(players, @intCast(params.frames), expected_cursor, hashes_match),
        .hashes_match = hashes_match,
    };
}

fn drivePeerWindow(
    side: PlayerSide,
    driver: *PeerDriver,
    start_tick: u64,
    frame_input: input.FrameInput,
    tick: u64,
    params: Params,
    network: *Network,
    samples: *[2]PlayerSamples,
    metrics: *PeerStepMetrics,
) !usize {
    if (tick < start_tick) return 0;
    if (samples[playerIndex(side)].count >= params.frames) {
        return stepPeerOnly(side, driver, tick, params, samples);
    }
    return drivePeer(side, driver, frame_input, tick, params, network, samples, metrics);
}

fn drivePeer(
    side: PlayerSide,
    driver: *PeerDriver,
    frame_input: input.FrameInput,
    tick: u64,
    params: Params,
    network: *Network,
    samples: *[2]PlayerSamples,
    metrics: *PeerStepMetrics,
) !usize {
    if (driver.peer.match.outcome != null or !driver.peer.isOk()) return 0;

    driver.batcher.noteFrameHeld();
    if (driver.batcher.isFull()) {
        try flushPendingInput(side, driver, params, network, tick);
    }

    if (driver.peer.canSampleLocalInput() and !driver.batcher.isFull()) {
        const sample = try driver.peer.sampleLocalInputFrame(frame_input);
        try samples[playerIndex(side)].add(tick, sample.frame);
        try driver.batcher.append(sample);
    }

    if (driver.batcher.shouldFlush(params.batch_target, params.batch_hold)) {
        try flushPendingInput(side, driver, params, network, tick);
    }

    const advanced = try stepPeerOnly(side, driver, tick, params, samples);
    metrics.noteAppStep(advanced, &driver.peer);
    return advanced;
}

fn flushPendingInput(side: PlayerSide, driver: *PeerDriver, params: Params, network: *Network, tick: u64) !void {
    if (!driver.batcher.hasPending()) return;
    const encoded = try driver.batcher.encodeWithRecent(params.resend_window);
    try network.send(params, tick, sendDirection(side), encoded, try inputBatchCount(encoded.slice()));
    driver.batcher.clearPending();
}

fn sendRecentInput(side: PlayerSide, driver: *PeerDriver, params: Params, network: *Network, tick: u64) !void {
    if (params.resend_window <= 1) return;
    const encoded = driver.batcher.encodeRecent(params.resend_window) catch |err| switch (err) {
        error.InputBatchEmpty => return,
        else => return err,
    };
    try network.send(params, tick, sendDirection(side), encoded, try inputBatchCount(encoded.slice()));
}

fn inputBatchCount(bytes: []const u8) !u8 {
    return switch (try protocol.decode(bytes)) {
        .input_batch => |batch| batch.count,
        else => error.UnexpectedPacketType,
    };
}

fn drain(
    p1: *PeerDriver,
    p2: *PeerDriver,
    params: Params,
    network: *Network,
    samples: *[2]PlayerSamples,
    start_tick: u64,
    last_app_advanced: [2]usize,
) !u64 {
    var tick = start_tick;
    var drain_ticks: u64 = 0;
    var tail_resends_left = if (params.resend_window > 1) params.resend_window else 0;
    var needs_step = needsMoreStep(params, last_app_advanced);

    while (network.count > 0 or needs_step or (tail_resends_left > 0 and hasIncompleteMeasuredSamples(samples))) {
        const previous_tick = tick;
        if (!needs_step) {
            if (network.nextDue()) |next_due| {
                tick = if (next_due > tick) next_due else try addTicks(tick, 1);
            } else {
                tick = try addTicks(tick, 1);
            }
        } else {
            tick = try addTicks(tick, 1);
        }
        drain_ticks += tick - previous_tick;

        if (!needs_step and network.count == 0 and tail_resends_left > 0 and hasIncompleteMeasuredSamples(samples)) {
            try sendRecentInput(.p1, p1, params, network, tick);
            try sendRecentInput(.p2, p2, params, network, tick);
            tail_resends_left -= 1;
        }

        _ = try network.deliverDue(tick, &p1.peer, &p2.peer);
        const advanced_p1 = try stepPeerOnly(.p1, p1, tick, params, samples);
        const advanced_p2 = try stepPeerOnly(.p2, p2, tick, params, samples);
        needs_step = needsMoreStep(params, .{ advanced_p1, advanced_p2 });
    }

    return drain_ticks;
}

fn hasIncompleteMeasuredSamples(samples: *const [2]PlayerSamples) bool {
    for (samples) |player_samples| {
        if (player_samples.next_local < player_samples.count) return true;
        if (player_samples.next_opponent < player_samples.count) return true;
    }
    return false;
}

fn needsMoreStep(params: Params, advanced: [2]usize) bool {
    return params.max_steps > 0 and (advanced[0] == params.max_steps or advanced[1] == params.max_steps);
}

fn benchComplete(players: [2]PlayerResult, expected_samples: u64, expected_cursor: u64, hashes_match: bool) bool {
    if (!hashes_match) return false;
    for (players) |player| {
        if (player.samples_created != expected_samples) return false;
        if (player.local_latency.count != expected_samples) return false;
        if (player.opponent_latency.count != expected_samples) return false;
        if (player.final_cursor < expected_cursor) return false;
    }
    return true;
}

fn computeSampleStartSkew(p1: []const SampleRecord, p2: []const SampleRecord) !SampleSkewStats {
    var stats = SampleSkewStats{};
    var p1_index: usize = 0;
    var p2_index: usize = 0;
    while (p1_index < p1.len and p2_index < p2.len) {
        const p1_sample = p1[p1_index];
        const p2_sample = p2[p2_index];
        if (p1_sample.target_frame == p2_sample.target_frame) {
            stats.add(try signedTickDelta(p2_sample.sample_tick, p1_sample.sample_tick));
            p1_index += 1;
            p2_index += 1;
        } else if (p1_sample.target_frame < p2_sample.target_frame) {
            p1_index += 1;
        } else {
            p2_index += 1;
        }
    }
    return stats;
}

fn signedTickDelta(a: u64, b: u64) !i64 {
    if (a >= b) {
        const delta = a - b;
        if (delta > std.math.maxInt(i64)) return error.TickOverflow;
        return @intCast(delta);
    }
    const delta = b - a;
    if (delta > std.math.maxInt(i64)) return error.TickOverflow;
    return -@as(i64, @intCast(delta));
}

fn stepPeerOnly(side: PlayerSide, driver: *PeerDriver, tick: u64, params: Params, samples: *[2]PlayerSamples) !usize {
    if (driver.peer.match.outcome != null or !driver.peer.isOk()) return 0;
    const before = driver.peer.frameCursor();
    const advanced = try driver.peer.stepAvailableMax(params.max_steps);
    const after = driver.peer.frameCursor();
    if (after > before) observeAdvanced(side, after, tick, samples);
    return advanced;
}

fn observeAdvanced(observer: PlayerSide, frame_cursor_after: u64, tick: u64, samples: *[2]PlayerSamples) void {
    switch (observer) {
        .p1 => {
            samples[0].observeLocalThrough(frame_cursor_after, tick);
            samples[1].observeOpponentThrough(frame_cursor_after, tick);
        },
        .p2 => {
            samples[1].observeLocalThrough(frame_cursor_after, tick);
            samples[0].observeOpponentThrough(frame_cursor_after, tick);
        },
    }
}

fn scriptedInput(side: PlayerSide, tick: u64) input.FrameInput {
    return switch (side) {
        .p1 => scriptedP1Input(tick),
        .p2 => scriptedP2Input(tick),
    };
}

fn scriptedP1Input(tick: u64) input.FrameInput {
    var frame = input.FrameInput{};
    if (tick % 60 == 5) {
        frame.left_down = true;
        frame.left_pressed = true;
    }
    if (tick % 90 == 30) frame.rotate_cw_pressed = true;
    if (tick % 150 >= 10 and tick % 150 < 18) frame.right_down = true;
    return frame;
}

fn scriptedP2Input(tick: u64) input.FrameInput {
    var frame = input.FrameInput{};
    if (tick % 64 == 9) {
        frame.right_down = true;
        frame.right_pressed = true;
    }
    if (tick % 96 == 42) frame.rotate_ccw_pressed = true;
    if (tick % 128 == 80) frame.hold_pressed = true;
    if (tick % 160 >= 24 and tick % 160 < 30) frame.left_down = true;
    return frame;
}

fn benchSettings() match_mod.MatchSettings {
    return .{
        .player_seeds = .{ 0x1111_2222_3333_4444, 0x5555_6666_7777_8888 },
        .ruleset = .{ .modern = .{ .garbage_seed = 0x1234_5678_9abc_def0 } },
    };
}

fn printHuman(writer: *std.Io.Writer, params: Params, result: BenchResult) !void {
    try writer.print(
        "lockstep net bench: scenario={s} frames={} tick_ms~={d:.2} input_delay={} batch_target={} batch_hold={} resend_window={} max_steps={} delay_p1_p2={} delay_p2_p1={} jitter={} drop_every={} start_policy={s} ack_delay={} start_delay={} start_guard={}\n",
        .{ scenarioName(params.scenario), params.frames, tick_ms, params.input_delay, params.batch_target, params.batch_hold, params.resend_window, params.max_steps, params.delay_p1_p2, params.delay_p2_p1, params.jitter, params.drop_every, startPolicyName(params.start_policy), params.ack_delay, params.start_delay, params.start_guard },
    );
    try printPlayerHuman(writer, "P1 host", result.players[0]);
    try printPlayerHuman(writer, "P2 joiner", result.players[1]);
    try writer.print(
        "packets: P1->P2 sent={} input_frames={} dropped={} delivered={}; P2->P1 sent={} input_frames={} dropped={} delivered={}\n",
        .{ result.directions[0].sent, result.directions[0].input_frames_sent, result.directions[0].dropped, result.directions[0].delivered, result.directions[1].sent, result.directions[1].input_frames_sent, result.directions[1].dropped, result.directions[1].delivered },
    );
    try writer.print(
        "start: p1_tick={} p2_tick={} paired_sample_skew_ticks={} first={} last={} min={} max={} zero={}\n",
        .{ result.start_ticks.p1, result.start_ticks.p2, result.sample_start_skew.paired, result.sample_start_skew.first, result.sample_start_skew.last, result.sample_start_skew.min, result.sample_start_skew.max, result.sample_start_skew.isZero() },
    );
    try writer.print(
        "completion: complete={} expected_samples={} expected_cursor={}\n",
        .{ result.complete, result.expected_samples, result.expected_cursor },
    );
    try writer.print(
        "final: p1_cursor={} p2_cursor={} p1_hash=0x{x} p2_hash=0x{x} hashes_match={} drain_ticks={}\n",
        .{ result.players[0].final_cursor, result.players[1].final_cursor, result.players[0].final_hash, result.players[1].final_hash, result.hashes_match, result.drain_ticks },
    );
}

fn printPlayerHuman(writer: *std.Io.Writer, name: []const u8, player: PlayerResult) !void {
    try writer.print("{s}: samples={} cursor={} stalls={} longest_stall={}\n", .{ name, player.samples_created, player.final_cursor, player.stalled_ticks, player.longest_stall });
    try writer.print("  local sample->sim latency ticks: ", .{});
    try printLatencyHuman(writer, player.samples_created, player.local_latency);
    try writer.print("\n  opponent-visible sample->sim latency ticks: ", .{});
    try printLatencyHuman(writer, player.samples_created, player.opponent_latency);
    try writer.print("\n", .{});
}

fn printLatencyHuman(writer: *std.Io.Writer, samples_created: u64, stats: LatencyStats) !void {
    var latency = stats;
    const p95 = latency.percentile(95);
    const p99 = latency.percentile(99);
    const pending = samples_created - stats.count;
    try writer.print(
        "observed={} pending={} observed_only={} min={} (~{d:.0}ms) avg={} (~{d:.0}ms) p95={} (~{d:.0}ms) p99={} (~{d:.0}ms) max={} (~{d:.0}ms)",
        .{ stats.count, pending, pending > 0, stats.min, ticksToMs(stats.min), stats.avg(), ticksToMs(stats.avg()), p95, ticksToMs(p95), p99, ticksToMs(p99), stats.max, ticksToMs(stats.max) },
    );
}

fn ticksToMs(ticks: u64) f64 {
    return @as(f64, @floatFromInt(ticks)) * tick_ms;
}

fn printJson(writer: *std.Io.Writer, params: Params, result: BenchResult) !void {
    try writer.print("{{\n", .{});
    try writer.print(
        "  \"params\": {{\"scenario\":\"{s}\",\"frames\":{},\"tick_ms\":{d:.4},\"input_delay\":{},\"batch_target\":{},\"batch_hold\":{},\"resend_window\":{},\"max_steps\":{},\"delay_p1_p2\":{},\"delay_p2_p1\":{},\"jitter\":{},\"drop_every\":{},\"start_policy\":\"{s}\",\"ack_delay\":{},\"start_delay\":{},\"start_guard\":{},\"expect_complete\":{},\"expect_zero_start_skew\":{}}},\n",
        .{ scenarioName(params.scenario), params.frames, tick_ms, params.input_delay, params.batch_target, params.batch_hold, params.resend_window, params.max_steps, params.delay_p1_p2, params.delay_p2_p1, params.jitter, params.drop_every, startPolicyName(params.start_policy), params.ack_delay, params.start_delay, params.start_guard, params.expect_complete, params.expect_zero_start_skew },
    );
    try printPlayerJson(writer, "p1", result.players[0], true);
    try printPlayerJson(writer, "p2", result.players[1], true);
    try writer.print(
        "  \"packets\": {{\"p1_to_p2\":{{\"sent\":{},\"input_frames_sent\":{},\"dropped\":{},\"delivered\":{}}},\"p2_to_p1\":{{\"sent\":{},\"input_frames_sent\":{},\"dropped\":{},\"delivered\":{}}}}},\n",
        .{ result.directions[0].sent, result.directions[0].input_frames_sent, result.directions[0].dropped, result.directions[0].delivered, result.directions[1].sent, result.directions[1].input_frames_sent, result.directions[1].dropped, result.directions[1].delivered },
    );
    try writer.print(
        "  \"start\": {{\"p1_tick\":{},\"p2_tick\":{},\"sample_skew\":{{\"paired\":{},\"first\":{},\"last\":{},\"min\":{},\"max\":{},\"zero\":{}}}}},\n",
        .{ result.start_ticks.p1, result.start_ticks.p2, result.sample_start_skew.paired, result.sample_start_skew.first, result.sample_start_skew.last, result.sample_start_skew.min, result.sample_start_skew.max, result.sample_start_skew.isZero() },
    );
    try writer.print(
        "  \"completion\": {{\"complete\":{},\"expected_samples\":{},\"expected_cursor\":{}}},\n",
        .{ result.complete, result.expected_samples, result.expected_cursor },
    );
    try writer.print(
        "  \"final\": {{\"p1_cursor\":{},\"p2_cursor\":{},\"p1_hash\":{},\"p2_hash\":{},\"hashes_match\":{},\"drain_ticks\":{}}}\n",
        .{ result.players[0].final_cursor, result.players[1].final_cursor, result.players[0].final_hash, result.players[1].final_hash, result.hashes_match, result.drain_ticks },
    );
    try writer.print("}}\n", .{});
}

fn printPlayerJson(writer: *std.Io.Writer, name: []const u8, player: PlayerResult, comma: bool) !void {
    try writer.print("  \"{s}\": {{", .{name});
    try writer.print("\"samples\":{},\"final_cursor\":{},\"final_hash\":{},\"stalled_ticks\":{},\"longest_stall\":{},", .{ player.samples_created, player.final_cursor, player.final_hash, player.stalled_ticks, player.longest_stall });
    try writer.print("\"local_latency\":", .{});
    try printLatencyJson(writer, player.samples_created, player.local_latency);
    try writer.print(",\"opponent_visible_latency\":", .{});
    try printLatencyJson(writer, player.samples_created, player.opponent_latency);
    try writer.print("}}{s}\n", .{if (comma) "," else ""});
}

fn printLatencyJson(writer: *std.Io.Writer, samples_created: u64, stats: LatencyStats) !void {
    var latency = stats;
    const p95 = latency.percentile(95);
    const p99 = latency.percentile(99);
    const pending = samples_created - stats.count;
    try writer.print("{{\"observed\":{},\"pending\":{},\"observed_only\":{},\"min\":{},\"avg\":{},\"p95\":{},\"p99\":{},\"max\":{}}}", .{ stats.count, pending, pending > 0, stats.min, stats.avg(), p95, p99, stats.max });
}

fn playerIndex(side: PlayerSide) usize {
    return switch (side) {
        .p1 => 0,
        .p2 => 1,
    };
}

fn sendDirection(side: PlayerSide) Direction {
    return switch (side) {
        .p1 => .p1_to_p2,
        .p2 => .p2_to_p1,
    };
}

fn directionIndex(direction: Direction) usize {
    return switch (direction) {
        .p1_to_p2 => 0,
        .p2_to_p1 => 1,
    };
}

fn deterministicJitter(direction: Direction, sequence: u64, max_jitter: u64) u64 {
    if (max_jitter == 0) return 0;
    var value = sequence ^ switch (direction) {
        .p1_to_p2 => @as(u64, 0x9e37_79b9_7f4a_7c15),
        .p2_to_p1 => @as(u64, 0xbf58_476d_1ce4_e5b9),
    };
    value ^= value >> 30;
    value *%= 0xbf58_476d_1ce4_e5b9;
    value ^= value >> 27;
    value *%= 0x94d0_49bb_1331_11eb;
    value ^= value >> 31;
    const modulus = max_jitter +% 1;
    if (modulus == 0) return value;
    return value % modulus;
}

fn addTicks(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b) catch error.TickOverflow;
}
