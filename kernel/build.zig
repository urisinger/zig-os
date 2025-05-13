const std = @import("std");

const image_name = "kernel-image";
const iso_root = "iso_root";

pub fn build(b: *std.Build) !void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target kernel architecture") orelse .x86_64;

    var code_model: std.builtin.CodeModel = .default;
    var linker_script_path: std.Build.LazyPath = undefined;
    var target_query: std.Target.Query = .{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

    switch (arch) {
        .x86_64 => {
            const Feature = std.Target.x86.Feature;

            target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));

            code_model = .kernel;
            linker_script_path = b.path("linker-x86_64.ld");
        },
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.fp_armv8));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.crypto));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.neon));

            linker_script_path = b.path("linker-aarch64.ld");
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.d));

            linker_script_path = b.path("linker-riscv64.ld");
        },
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
    });

    kernel.setLinkerScriptPath(linker_script_path);

    kernel.want_lto = false;

    const limine = b.dependency("limine", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));

    b.installArtifact(kernel);

    const kernel_check = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
    });

    kernel_check.setLinkerScriptPath(linker_script_path);

    kernel_check.want_lto = false;
    kernel_check.root_module.addImport("limine", limine.module("limine"));

    const check = b.step("check", "Check if kernel compiles");
    check.dependOn(&kernel_check.step);
}
