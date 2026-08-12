const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const Target = std.Target.x86;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = Target.featureSet(&.{.soft_float}),
        .cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx }),
    });

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
        }),
    });
    kernel.setLinkerScript(b.path("src/linker.ld"));
    b.installArtifact(kernel);

    const kernel_path = kernel.getEmittedBin();
    const qemu_cmd = b.addSystemCommand(&[_][]const u8{
        // zig fmt: off
        "qemu-system-x86_64",
        "-m", "1G",
        "-serial", "stdio",
    });
    // zig fmt: on
    qemu_cmd.addArg("-kernel");
    qemu_cmd.addFileArg(kernel_path);
    qemu_cmd.step.dependOn(b.getInstallStep());

    const run_cmd = b.addRunArtifact(kernel);
    run_cmd.step.dependOn(&qemu_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run kernel with qemu");
    run_step.dependOn(&run_cmd.step);
}
