// SPDX-License-Identifier: GPL-3.0-or-later

//! Raylib-free app shell control helpers.
//!
//! `src/main.zig` owns polling concrete keyboard APIs. This module keeps mode
//! selection and local-versus input mapping testable without opening a window.

const std = @import("std");
const input = @import("input");
const match_mod = @import("match");

pub const AppMode = enum {
    single,
    local_versus,
    online,
};

pub const ModeHotkeys = struct {
    one_pressed: bool = false,
    two_pressed: bool = false,
    three_pressed: bool = false,
};

pub const InitialJoinState = enum {
    none,
    valid_join_room,
    invalid_join_room,
};

pub const ModeTransition = union(enum) {
    unchanged,
    changed_mode: AppMode,
};

pub const KeyState = struct {
    down: bool = false,
    pressed: bool = false,
};

pub const LocalVersusKeys = struct {
    global_p: KeyState = .{},
    global_r: KeyState = .{},

    p1_a: KeyState = .{},
    p1_d: KeyState = .{},
    p1_s: KeyState = .{},
    p1_space: KeyState = .{},
    p1_w: KeyState = .{},
    p1_q: KeyState = .{},
    p1_e: KeyState = .{},
    p1_left_shift: KeyState = .{},

    p2_left_arrow: KeyState = .{},
    p2_right_arrow: KeyState = .{},
    p2_down_arrow: KeyState = .{},
    p2_enter: KeyState = .{},
    p2_up_arrow: KeyState = .{},
    p2_period: KeyState = .{},
    p2_slash: KeyState = .{},
    p2_right_shift: KeyState = .{},
};

pub const OnlineKeys = struct {
    global_p: KeyState = .{},
    global_r: KeyState = .{},
    copy_c: KeyState = .{},

    left_arrow: KeyState = .{},
    right_arrow: KeyState = .{},
    down_arrow: KeyState = .{},
    space: KeyState = .{},
    x: KeyState = .{},
    up_arrow: KeyState = .{},
    z: KeyState = .{},
    a: KeyState = .{},
    left_shift: KeyState = .{},
};

pub const OnlineInput = struct {
    frame: input.FrameInput = .{},
    copy_link_pressed: bool = false,
    restart_pressed: bool = false,
};

pub fn initialMode() AppMode {
    return .single;
}

pub fn initialModeForJoinState(join_state: InitialJoinState) AppMode {
    return switch (join_state) {
        .none => .single,
        .valid_join_room, .invalid_join_room => .online,
    };
}

pub fn selectedModeForHotkey(hotkeys: ModeHotkeys) ?AppMode {
    if (hotkeys.one_pressed) return .single;
    if (hotkeys.two_pressed) return .local_versus;
    if (hotkeys.three_pressed) return .online;
    return null;
}

pub fn modeTransitionForHotkey(current: AppMode, hotkeys: ModeHotkeys) ModeTransition {
    const selected = selectedModeForHotkey(hotkeys) orelse return .unchanged;
    if (selected == current) return .unchanged;
    return .{ .changed_mode = selected };
}

pub fn selectedModeChangeForHotkey(current: AppMode, hotkeys: ModeHotkeys) ?AppMode {
    return switch (modeTransitionForHotkey(current, hotkeys)) {
        .unchanged => null,
        .changed_mode => |selected| selected,
    };
}

pub fn localVersusMatchInputFromKeys(keys: LocalVersusKeys) match_mod.MatchInput {
    var p1 = localVersusP1FrameInputFromKeys(keys);
    p1.pause_pressed = keys.global_p.pressed;
    p1.restart_pressed = keys.global_r.pressed;

    return .{ .players = .{ p1, localVersusP2FrameInputFromKeys(keys) } };
}

pub fn localVersusP1FrameInputFromKeys(keys: LocalVersusKeys) input.FrameInput {
    return .{
        .left_down = keys.p1_a.down,
        .right_down = keys.p1_d.down,
        .down_down = keys.p1_s.down,
        .left_pressed = keys.p1_a.pressed,
        .right_pressed = keys.p1_d.pressed,
        .rotate_cw_pressed = keys.p1_w.pressed,
        .rotate_ccw_pressed = keys.p1_q.pressed,
        .rotate_180_pressed = keys.p1_e.pressed,
        .hold_pressed = keys.p1_left_shift.pressed,
        .hard_drop_pressed = keys.p1_space.pressed,
    };
}

pub fn localVersusP2FrameInputFromKeys(keys: LocalVersusKeys) input.FrameInput {
    return .{
        .left_down = keys.p2_left_arrow.down,
        .right_down = keys.p2_right_arrow.down,
        .down_down = keys.p2_down_arrow.down,
        .left_pressed = keys.p2_left_arrow.pressed,
        .right_pressed = keys.p2_right_arrow.pressed,
        .rotate_cw_pressed = keys.p2_up_arrow.pressed,
        .rotate_ccw_pressed = keys.p2_period.pressed,
        .rotate_180_pressed = keys.p2_slash.pressed,
        .hold_pressed = keys.p2_right_shift.pressed,
        .hard_drop_pressed = keys.p2_enter.pressed,
    };
}

pub fn onlineInputFromKeys(keys: OnlineKeys) OnlineInput {
    return .{
        .frame = .{
            .left_down = keys.left_arrow.down,
            .right_down = keys.right_arrow.down,
            .down_down = keys.down_arrow.down,
            .left_pressed = keys.left_arrow.pressed,
            .right_pressed = keys.right_arrow.pressed,
            .rotate_cw_pressed = keys.x.pressed or keys.up_arrow.pressed,
            .rotate_ccw_pressed = keys.z.pressed,
            .rotate_180_pressed = keys.a.pressed,
            .hold_pressed = keys.left_shift.pressed,
            .hard_drop_pressed = keys.space.pressed,
            .pause_pressed = keys.global_p.pressed,
            .restart_pressed = false,
        },
        .copy_link_pressed = keys.copy_c.pressed,
        .restart_pressed = keys.global_r.pressed,
    };
}

test "one-player mode is the initial app mode" {
    try std.testing.expectEqual(AppMode.single, initialMode());
    try std.testing.expectEqual(AppMode.single, initialModeForJoinState(.none));
    try std.testing.expectEqual(AppMode.online, initialModeForJoinState(.valid_join_room));
    try std.testing.expectEqual(AppMode.online, initialModeForJoinState(.invalid_join_room));
}

test "mode hotkeys select one-player local versus and online" {
    try std.testing.expectEqual(AppMode.single, selectedModeForHotkey(.{ .one_pressed = true }).?);
    try std.testing.expectEqual(AppMode.local_versus, selectedModeForHotkey(.{ .two_pressed = true }).?);
    try std.testing.expectEqual(AppMode.online, selectedModeForHotkey(.{ .three_pressed = true }).?);
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeForHotkey(.{}));
}

test "mode hotkeys only switch to a different mode" {
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeChangeForHotkey(.single, .{ .one_pressed = true }));
    try std.testing.expectEqual(AppMode.local_versus, selectedModeChangeForHotkey(.single, .{ .two_pressed = true }).?);
    try std.testing.expectEqual(AppMode.online, selectedModeChangeForHotkey(.single, .{ .three_pressed = true }).?);
    try std.testing.expectEqual(AppMode.single, selectedModeChangeForHotkey(.local_versus, .{ .one_pressed = true }).?);
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeChangeForHotkey(.local_versus, .{ .two_pressed = true }));
    try std.testing.expectEqual(AppMode.online, selectedModeChangeForHotkey(.local_versus, .{ .three_pressed = true }).?);
    try std.testing.expectEqual(AppMode.single, selectedModeChangeForHotkey(.online, .{ .one_pressed = true }).?);
    try std.testing.expectEqual(AppMode.local_versus, selectedModeChangeForHotkey(.online, .{ .two_pressed = true }).?);
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeChangeForHotkey(.online, .{ .three_pressed = true }));
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeChangeForHotkey(.single, .{}));
}

test "mode hotkeys report explicit changed-mode transitions" {
    try std.testing.expectEqualDeep(ModeTransition{ .unchanged = {} }, modeTransitionForHotkey(.single, .{ .one_pressed = true }));
    try std.testing.expectEqualDeep(ModeTransition{ .changed_mode = .local_versus }, modeTransitionForHotkey(.single, .{ .two_pressed = true }));
    try std.testing.expectEqualDeep(ModeTransition{ .changed_mode = .online }, modeTransitionForHotkey(.single, .{ .three_pressed = true }));
    try std.testing.expectEqualDeep(ModeTransition{ .changed_mode = .single }, modeTransitionForHotkey(.local_versus, .{ .one_pressed = true }));
    try std.testing.expectEqualDeep(ModeTransition{ .unchanged = {} }, modeTransitionForHotkey(.local_versus, .{ .two_pressed = true }));
    try std.testing.expectEqualDeep(ModeTransition{ .unchanged = {} }, modeTransitionForHotkey(.online, .{ .three_pressed = true }));
    try std.testing.expectEqualDeep(ModeTransition{ .unchanged = {} }, modeTransitionForHotkey(.single, .{}));
}

test "local versus P1 keys map one at a time to exact frame input fields" {
    const cases = [_]struct {
        keys: LocalVersusKeys,
        expected: input.FrameInput,
    }{
        .{ .keys = .{ .p1_a = .{ .down = true } }, .expected = .{ .left_down = true } },
        .{ .keys = .{ .p1_a = .{ .pressed = true } }, .expected = .{ .left_pressed = true } },
        .{ .keys = .{ .p1_d = .{ .down = true } }, .expected = .{ .right_down = true } },
        .{ .keys = .{ .p1_d = .{ .pressed = true } }, .expected = .{ .right_pressed = true } },
        .{ .keys = .{ .p1_s = .{ .down = true } }, .expected = .{ .down_down = true } },
        .{ .keys = .{ .p1_space = .{ .pressed = true } }, .expected = .{ .hard_drop_pressed = true } },
        .{ .keys = .{ .p1_w = .{ .pressed = true } }, .expected = .{ .rotate_cw_pressed = true } },
        .{ .keys = .{ .p1_q = .{ .pressed = true } }, .expected = .{ .rotate_ccw_pressed = true } },
        .{ .keys = .{ .p1_e = .{ .pressed = true } }, .expected = .{ .rotate_180_pressed = true } },
        .{ .keys = .{ .p1_left_shift = .{ .pressed = true } }, .expected = .{ .hold_pressed = true } },
    };

    for (cases) |fixture| {
        const match_input = localVersusMatchInputFromKeys(fixture.keys);
        try std.testing.expectEqualDeep(fixture.expected, match_input.players[0]);
        try std.testing.expectEqualDeep(input.FrameInput{}, match_input.players[1]);
    }
}

test "local versus P2 keys map one at a time to exact frame input fields" {
    const cases = [_]struct {
        keys: LocalVersusKeys,
        expected: input.FrameInput,
    }{
        .{ .keys = .{ .p2_left_arrow = .{ .down = true } }, .expected = .{ .left_down = true } },
        .{ .keys = .{ .p2_left_arrow = .{ .pressed = true } }, .expected = .{ .left_pressed = true } },
        .{ .keys = .{ .p2_right_arrow = .{ .down = true } }, .expected = .{ .right_down = true } },
        .{ .keys = .{ .p2_right_arrow = .{ .pressed = true } }, .expected = .{ .right_pressed = true } },
        .{ .keys = .{ .p2_down_arrow = .{ .down = true } }, .expected = .{ .down_down = true } },
        .{ .keys = .{ .p2_enter = .{ .pressed = true } }, .expected = .{ .hard_drop_pressed = true } },
        .{ .keys = .{ .p2_up_arrow = .{ .pressed = true } }, .expected = .{ .rotate_cw_pressed = true } },
        .{ .keys = .{ .p2_period = .{ .pressed = true } }, .expected = .{ .rotate_ccw_pressed = true } },
        .{ .keys = .{ .p2_slash = .{ .pressed = true } }, .expected = .{ .rotate_180_pressed = true } },
        .{ .keys = .{ .p2_right_shift = .{ .pressed = true } }, .expected = .{ .hold_pressed = true } },
    };

    for (cases) |fixture| {
        const match_input = localVersusMatchInputFromKeys(fixture.keys);
        try std.testing.expectEqualDeep(input.FrameInput{}, match_input.players[0]);
        try std.testing.expectEqualDeep(fixture.expected, match_input.players[1]);
    }
}

test "global pause and restart are carried once on P1 input" {
    const cases = [_]struct {
        keys: LocalVersusKeys,
        expected_p1: input.FrameInput,
    }{
        .{ .keys = .{ .global_p = .{ .pressed = true } }, .expected_p1 = .{ .pause_pressed = true } },
        .{ .keys = .{ .global_r = .{ .pressed = true } }, .expected_p1 = .{ .restart_pressed = true } },
    };

    for (cases) |fixture| {
        const match_input = localVersusMatchInputFromKeys(fixture.keys);
        try std.testing.expectEqualDeep(fixture.expected_p1, match_input.players[0]);
        try std.testing.expectEqualDeep(input.FrameInput{}, match_input.players[1]);
    }
}

test "online controls use one local control set and reserve C/R for shell actions" {
    const cases = [_]struct {
        keys: OnlineKeys,
        expected: input.FrameInput,
    }{
        .{ .keys = .{ .left_arrow = .{ .down = true } }, .expected = .{ .left_down = true } },
        .{ .keys = .{ .left_arrow = .{ .pressed = true } }, .expected = .{ .left_pressed = true } },
        .{ .keys = .{ .right_arrow = .{ .down = true } }, .expected = .{ .right_down = true } },
        .{ .keys = .{ .right_arrow = .{ .pressed = true } }, .expected = .{ .right_pressed = true } },
        .{ .keys = .{ .down_arrow = .{ .down = true } }, .expected = .{ .down_down = true } },
        .{ .keys = .{ .space = .{ .pressed = true } }, .expected = .{ .hard_drop_pressed = true } },
        .{ .keys = .{ .x = .{ .pressed = true } }, .expected = .{ .rotate_cw_pressed = true } },
        .{ .keys = .{ .up_arrow = .{ .pressed = true } }, .expected = .{ .rotate_cw_pressed = true } },
        .{ .keys = .{ .z = .{ .pressed = true } }, .expected = .{ .rotate_ccw_pressed = true } },
        .{ .keys = .{ .a = .{ .pressed = true } }, .expected = .{ .rotate_180_pressed = true } },
        .{ .keys = .{ .left_shift = .{ .pressed = true } }, .expected = .{ .hold_pressed = true } },
        .{ .keys = .{ .global_p = .{ .pressed = true } }, .expected = .{ .pause_pressed = true } },
    };

    for (cases) |fixture| {
        const online = onlineInputFromKeys(fixture.keys);
        try std.testing.expectEqualDeep(fixture.expected, online.frame);
        try std.testing.expect(!online.copy_link_pressed);
        try std.testing.expect(!online.restart_pressed);
    }

    const copy = onlineInputFromKeys(.{ .copy_c = .{ .pressed = true } });
    try std.testing.expectEqualDeep(input.FrameInput{}, copy.frame);
    try std.testing.expect(copy.copy_link_pressed);
    try std.testing.expect(!copy.restart_pressed);

    const restart = onlineInputFromKeys(.{ .global_r = .{ .pressed = true } });
    try std.testing.expectEqualDeep(input.FrameInput{}, restart.frame);
    try std.testing.expect(!restart.copy_link_pressed);
    try std.testing.expect(restart.restart_pressed);
}
