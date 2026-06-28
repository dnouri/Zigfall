// SPDX-License-Identifier: GPL-3.0-or-later

//! Stable little-endian helpers for deterministic simulation hashing.
//!
//! These helpers intentionally feed explicit scalar values into XxHash64. They
//! must not grow helpers that hash raw Zig structs or native memory layout.

const std = @import("std");

pub const Hasher = std.hash.XxHash64;

pub fn feedBytes(hasher: *Hasher, bytes: []const u8) void {
    hasher.update(bytes);
}

pub fn feedBool(hasher: *Hasher, value: bool) void {
    feedU8(hasher, if (value) 1 else 0);
}

pub fn feedU8(hasher: *Hasher, value: u8) void {
    const bytes = [1]u8{value};
    hasher.update(&bytes);
}

pub fn feedU16(hasher: *Hasher, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hasher.update(&bytes);
}

pub fn feedU32(hasher: *Hasher, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hasher.update(&bytes);
}

pub fn feedU64(hasher: *Hasher, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

pub fn feedI32(hasher: *Hasher, value: i32) void {
    const bits: u32 = @bitCast(value);
    feedU32(hasher, bits);
}

test "scalar helpers feed stable little-endian bytes" {
    var helper_hash = Hasher.init(0);
    feedBool(&helper_hash, true);
    feedU8(&helper_hash, 0xab);
    feedU16(&helper_hash, 0x1234);
    feedU32(&helper_hash, 0x1234_5678);
    feedU64(&helper_hash, 0x0123_4567_89ab_cdef);
    feedI32(&helper_hash, -2);

    var manual_hash = Hasher.init(0);
    const bytes = [_]u8{
        1,
        0xab,
        0x34,
        0x12,
        0x78,
        0x56,
        0x34,
        0x12,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        0xfe,
        0xff,
        0xff,
        0xff,
    };
    manual_hash.update(&bytes);

    try std.testing.expectEqual(manual_hash.final(), helper_hash.final());
}
