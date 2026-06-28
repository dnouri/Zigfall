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
};

pub const ModeHotkeys = struct {
    one_pressed: bool = false,
    two_pressed: bool = false,
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

pub fn initialMode() AppMode {
    return .single;
}

pub fn selectedModeForHotkey(hotkeys: ModeHotkeys) ?AppMode {
    if (hotkeys.one_pressed) return .single;
    if (hotkeys.two_pressed) return .local_versus;
    return null;
}

pub fn selectedModeChangeForHotkey(current: AppMode, hotkeys: ModeHotkeys) ?AppMode {
    const selected = selectedModeForHotkey(hotkeys) orelse return null;
    if (selected == current) return null;
    return selected;
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

test "one-player mode is the initial app mode" {
    try std.testing.expectEqual(AppMode.single, initialMode());
}

test "mode hotkeys select one-player and local versus" {
    try std.testing.expectEqual(AppMode.single, selectedModeForHotkey(.{ .one_pressed = true }).?);
    try std.testing.expectEqual(AppMode.local_versus, selectedModeForHotkey(.{ .two_pressed = true }).?);
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeForHotkey(.{}));
}

test "mode hotkeys only switch to a different mode" {
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeChangeForHotkey(.single, .{ .one_pressed = true }));
    try std.testing.expectEqual(AppMode.local_versus, selectedModeChangeForHotkey(.single, .{ .two_pressed = true }).?);
    try std.testing.expectEqual(AppMode.single, selectedModeChangeForHotkey(.local_versus, .{ .one_pressed = true }).?);
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeChangeForHotkey(.local_versus, .{ .two_pressed = true }));
    try std.testing.expectEqual(@as(?AppMode, null), selectedModeChangeForHotkey(.single, .{}));
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
