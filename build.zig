// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const rlz = @import("raylib_zig");

const emsdk = rlz.emsdk;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib");

    const game_mod = b.addModule("game", .{
        .root_source_file = b.path("src/game.zig"),
        .target = target,
        .optimize = optimize,
    });
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "game", .module = game_mod },
        },
    });
    const match_mod = b.addModule("match", .{
        .root_source_file = b.path("src/match.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "game", .module = game_mod },
            .{ .name = "input", .module = input_mod },
        },
    });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "game", .module = game_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "raylib", .module = raylib },
        },
    });

    const run_step = b.step("run", "Run the app");

    if (target.result.os.tag == .emscripten) {
        const web_lib = b.addLibrary(.{
            .name = "zigfall",
            .root_module = app_mod,
        });
        const raylib_artifact = raylib_dep.artifact("raylib");
        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{
            .optimize = optimize,
            .asyncify = false,
        });
        const emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
        });
        const emcc_step = emsdk.emccStep(b, raylib_artifact, web_lib, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .shell_file_path = b.path("web/shell.html"),
            .install_dir = install_dir,
        });
        b.getInstallStep().dependOn(emcc_step);

        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, "zigfall.html"),
            b.args orelse &.{},
        );
        emrun_step.dependOn(emcc_step);
        run_step.dependOn(emrun_step);
    } else {
        const exe = b.addExecutable(.{
            .name = "zigfall",
            .root_module = app_mod,
        });
        // Optimized native Linux raylib static builds make LLD warn about
        // system-library archive members; Zig treats that stderr as a link failure.
        // Keep LLD enabled for cross targets, where the platform linker may be
        // unavailable or inappropriate.
        if (target.query.isNative() and target.result.os.tag == .linux and optimize != .Debug) {
            exe.use_lld = false;
        }
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        run_step.dependOn(&run_cmd.step);
    }

    const game_tests = b.addTest(.{
        .root_module = game_mod,
    });
    const run_game_tests = b.addRunArtifact(game_tests);
    const input_tests = b.addTest(.{
        .root_module = input_mod,
    });
    const run_input_tests = b.addRunArtifact(input_tests);
    const match_tests = b.addTest(.{
        .root_module = match_mod,
    });
    const run_match_tests = b.addRunArtifact(match_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_game_tests.step);
    test_step.dependOn(&run_input_tests.step);
    test_step.dependOn(&run_match_tests.step);
}
