const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm = b.addExecutable(.{
        .name = "suplex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/game.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = false;
    wasm.export_memory = true;
    wasm.initial_memory = 2 * 1024 * 1024;
    wasm.max_memory = 2 * 1024 * 1024;
    wasm.stack_size = 64 * 1024;

    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });

    const copy_web = b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .prefix,
        .install_subdir = "web",
    });

    const wasm_step = b.step("wasm", "Build suplex.wasm into zig-out/web");
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&copy_web.step);

    b.getInstallStep().dependOn(wasm_step);
}
