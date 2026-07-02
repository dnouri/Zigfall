// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const rlz = @import("raylib_zig");

const emsdk = rlz.emsdk;

const InstallCopy = struct {
    src_path: []const u8,
    dest_path: []const u8,
};

const third_party_license_artifacts = [_]InstallCopy{
    .{ .src_path = "third_party/licenses/README.md", .dest_path = "README.md" },
    .{ .src_path = "third_party/licenses/AUTHORS-emscripten.txt", .dest_path = "AUTHORS-emscripten.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-emsdk.txt", .dest_path = "LICENSE-emsdk.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-emscripten.txt", .dest_path = "LICENSE-emscripten.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-emscripten-compiler-rt.txt", .dest_path = "LICENSE-emscripten-compiler-rt.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-emscripten-musl.txt", .dest_path = "LICENSE-emscripten-musl.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-raygui.txt", .dest_path = "LICENSE-raygui.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-raylib.txt", .dest_path = "LICENSE-raylib.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-raylib-external.txt", .dest_path = "LICENSE-raylib-external.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-raylib-zig.txt", .dest_path = "LICENSE-raylib-zig.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-zemscripten.txt", .dest_path = "LICENSE-zemscripten.txt" },
    .{ .src_path = "third_party/licenses/LICENSE-zig.txt", .dest_path = "LICENSE-zig.txt" },
};

const browser_vendor_notice_artifacts = [_]InstallCopy{
    .{ .src_path = "web/vendor/README.md", .dest_path = "README.md" },
    .{ .src_path = "web/vendor/LICENSE-trystero.txt", .dest_path = "LICENSE-trystero.txt" },
    .{ .src_path = "web/vendor/LICENSE-noble-secp256k1.txt", .dest_path = "LICENSE-noble-secp256k1.txt" },
    .{ .src_path = "web/vendor/LICENSE-esbuild.txt", .dest_path = "LICENSE-esbuild.txt" },
};

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
    const profile_mod = b.addModule("profile", .{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol_mod = b.addModule("protocol", .{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "input", .module = input_mod },
            .{ .name = "profile", .module = profile_mod },
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
    const lockstep_mod = b.addModule("lockstep", .{
        .root_source_file = b.path("src/lockstep.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "input", .module = input_mod },
            .{ .name = "match", .module = match_mod },
            .{ .name = "protocol", .module = protocol_mod },
        },
    });
    const online_session_mod = b.addModule("online_session", .{
        .root_source_file = b.path("src/online_session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "input", .module = input_mod },
            .{ .name = "lockstep", .module = lockstep_mod },
            .{ .name = "match", .module = match_mod },
            .{ .name = "profile", .module = profile_mod },
            .{ .name = "protocol", .module = protocol_mod },
        },
    });
    const app_controls_mod = b.addModule("app_controls", .{
        .root_source_file = b.path("src/app_controls.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "input", .module = input_mod },
            .{ .name = "match", .module = match_mod },
        },
    });
    const web_transport_mod = b.addModule("web_transport", .{
        .root_source_file = b.path("src/web_transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });
    const web_invite_mod = b.addModule("web_invite", .{
        .root_source_file = b.path("src/web_invite.zig"),
        .target = target,
        .optimize = optimize,
    });
    const web_profile_mod = b.addModule("web_profile", .{
        .root_source_file = b.path("src/web_profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "profile", .module = profile_mod },
        },
    });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_controls", .module = app_controls_mod },
            .{ .name = "game", .module = game_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "lockstep", .module = lockstep_mod },
            .{ .name = "match", .module = match_mod },
            .{ .name = "online_session", .module = online_session_mod },
            .{ .name = "profile", .module = profile_mod },
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "raylib", .module = raylib },
            .{ .name = "web_invite", .module = web_invite_mod },
            .{ .name = "web_profile", .module = web_profile_mod },
            .{ .name = "web_transport", .module = web_transport_mod },
        },
    });

    const bench_lockstep_step = b.step("bench-lockstep", "Run the deterministic two-peer lockstep network benchmark");
    if (!target.query.isNative()) {
        bench_lockstep_step.dependOn(&b.addFail("bench-lockstep is a native host CLI tool; omit -Dtarget or use a native target").step);
    } else {
        const bench_lockstep_mod = b.createModule(.{
            .root_source_file = b.path("tools/bench_lockstep_net.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "input", .module = input_mod },
                .{ .name = "lockstep", .module = lockstep_mod },
                .{ .name = "match", .module = match_mod },
                .{ .name = "online_session", .module = online_session_mod },
                .{ .name = "protocol", .module = protocol_mod },
            },
        });
        const bench_lockstep_exe = b.addExecutable(.{
            .name = "bench_lockstep_net",
            .root_module = bench_lockstep_mod,
        });
        const bench_lockstep_cmd = b.addRunArtifact(bench_lockstep_exe);
        if (b.args) |args| {
            bench_lockstep_cmd.addArgs(args);
        }
        bench_lockstep_step.dependOn(&bench_lockstep_cmd.step);
    }

    const run_step = b.step("run", "Run the app");

    if (target.result.os.tag == .emscripten) {
        const web_lib = b.addLibrary(.{
            .name = "zigfall",
            .root_module = app_mod,
        });
        const raylib_artifact = raylib_dep.artifact("raylib");
        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        var emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{
            .optimize = optimize,
            .asyncify = false,
        });
        const transport_shim_path = "web/zigfall_transport_emscripten.js";
        const invite_shim_path = "web/zigfall_invite_emscripten.js";
        const profile_shim_path = "web/zigfall_profile_emscripten.js";
        emcc_flags.put(b.fmt("--js-library={s}", .{b.path(transport_shim_path).getPath(b)}), {}) catch unreachable;
        emcc_flags.put(b.fmt("--js-library={s}", .{b.path(invite_shim_path).getPath(b)}), {}) catch unreachable;
        emcc_flags.put(b.fmt("--js-library={s}", .{b.path(profile_shim_path).getPath(b)}), {}) catch unreachable;
        // zemscripten 0.2's StepOptions cannot add a JS-library LazyPath as a
        // tracked input. Put a content hash on the emcc command line so shim
        // edits invalidate the link step, while the --js-library path still
        // makes a missing shim fail clearly.
        emcc_flags.put(b.fmt("-DZF_TRANSPORT_SHIM_SHA256={s}", .{fileSha256Hex(b, transport_shim_path)}), {}) catch unreachable;
        emcc_flags.put(b.fmt("-DZF_INVITE_SHIM_SHA256={s}", .{fileSha256Hex(b, invite_shim_path)}), {}) catch unreachable;
        emcc_flags.put(b.fmt("-DZF_PROFILE_SHIM_SHA256={s}", .{fileSha256Hex(b, profile_shim_path)}), {}) catch unreachable;
        // Online mode embeds the deterministic match/lockstep state in the app
        // state. Emscripten's small default stack can overflow while copying the
        // first web Session into place, especially with debug/sanitizer builds.
        emcc_flags.put("-sSTACK_SIZE=1048576", {}) catch unreachable;
        var emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
        });
        // Preserve the default C/WASM entry points while exposing one read-only
        // JSON snapshot function for the query-gated browser debug facade.
        emcc_settings.put("EXPORTED_FUNCTIONS", "['_main','_malloc','_free','_zigfall_debug_snapshot_json']") catch unreachable;
        const emcc_step = emsdk.emccStep(b, raylib_artifact, web_lib, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .shell_file_path = b.path("web/shell.html"),
            .install_dir = install_dir,
        });
        b.getInstallStep().dependOn(emcc_step);
        installFileArtifact(b, install_dir, "web/zigfall_transport.mjs", "zigfall_transport.mjs");
        installFileArtifact(b, install_dir, "web/zigfall_invite.mjs", "zigfall_invite.mjs");
        installFileArtifact(b, install_dir, "web/zigfall_profile.mjs", "zigfall_profile.mjs");
        installFileArtifact(b, install_dir, "web/vendor/trystero-nostr.bundle.mjs", "vendor/trystero-nostr.bundle.mjs");
        installFileArtifact(b, install_dir, "web/vendor/trystero-nostr.bundle.mjs.sha256", "vendor/trystero-nostr.bundle.mjs.sha256");
        installLegalArtifacts(b, install_dir, "");

        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, "zigfall.html"),
            b.args orelse &.{},
        );
        emrun_step.dependOn(b.getInstallStep());
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
        installLegalArtifacts(b, .prefix, "share/zigfall");

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
    const protocol_tests = b.addTest(.{
        .root_module = protocol_mod,
    });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const profile_tests = b.addTest(.{
        .root_module = profile_mod,
    });
    const run_profile_tests = b.addRunArtifact(profile_tests);
    const match_tests = b.addTest(.{
        .root_module = match_mod,
    });
    const run_match_tests = b.addRunArtifact(match_tests);
    const lockstep_tests = b.addTest(.{
        .root_module = lockstep_mod,
    });
    const run_lockstep_tests = b.addRunArtifact(lockstep_tests);
    const online_session_tests = b.addTest(.{
        .root_module = online_session_mod,
    });
    const run_online_session_tests = b.addRunArtifact(online_session_tests);
    const app_controls_tests = b.addTest(.{
        .root_module = app_controls_mod,
    });
    const run_app_controls_tests = b.addRunArtifact(app_controls_tests);
    const web_transport_tests = b.addTest(.{
        .root_module = web_transport_mod,
    });
    const run_web_transport_tests = b.addRunArtifact(web_transport_tests);
    const web_invite_tests = b.addTest(.{
        .root_module = web_invite_mod,
    });
    const run_web_invite_tests = b.addRunArtifact(web_invite_tests);
    const web_profile_tests = b.addTest(.{
        .root_module = web_profile_mod,
    });
    const run_web_profile_tests = b.addRunArtifact(web_profile_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_game_tests.step);
    test_step.dependOn(&run_input_tests.step);
    test_step.dependOn(&run_protocol_tests.step);
    test_step.dependOn(&run_profile_tests.step);
    test_step.dependOn(&run_match_tests.step);
    test_step.dependOn(&run_lockstep_tests.step);
    test_step.dependOn(&run_online_session_tests.step);
    test_step.dependOn(&run_app_controls_tests.step);
    test_step.dependOn(&run_web_transport_tests.step);
    test_step.dependOn(&run_web_invite_tests.step);
    test_step.dependOn(&run_web_profile_tests.step);
}

fn installLegalArtifacts(b: *std.Build, install_dir: std.Build.InstallDir, dest_root: []const u8) void {
    installFileArtifact(b, install_dir, "LICENSE", joinInstallPath(b, dest_root, "LICENSE"));
    installFileArtifact(b, install_dir, "THIRD_PARTY_NOTICES.md", joinInstallPath(b, dest_root, "THIRD_PARTY_NOTICES.md"));

    const licenses_dest = joinInstallPath(b, dest_root, "licenses");
    for (third_party_license_artifacts) |artifact| {
        installFileArtifact(b, install_dir, artifact.src_path, joinInstallPath(b, licenses_dest, artifact.dest_path));
    }

    const vendor_dest = joinInstallPath(b, dest_root, "vendor");
    for (browser_vendor_notice_artifacts) |artifact| {
        installFileArtifact(b, install_dir, artifact.src_path, joinInstallPath(b, vendor_dest, artifact.dest_path));
    }
}

fn installFileArtifact(
    b: *std.Build,
    install_dir: std.Build.InstallDir,
    src_path: []const u8,
    dest_path: []const u8,
) void {
    const install_file = b.addInstallFileWithDir(b.path(src_path), install_dir, dest_path);
    b.getInstallStep().dependOn(&install_file.step);
}

fn joinInstallPath(b: *std.Build, prefix: []const u8, suffix: []const u8) []const u8 {
    if (prefix.len == 0) return suffix;
    return b.fmt("{s}/{s}", .{ prefix, suffix });
}

fn fileSha256Hex(b: *std.Build, path: []const u8) []const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch |err| {
        std.debug.panic("failed to read {s}: {s}", .{ path, @errorName(err) });
    };
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return b.allocator.dupe(u8, &hex) catch unreachable;
}
