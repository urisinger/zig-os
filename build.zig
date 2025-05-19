const std = @import("std");
fn configureArchFeatures(arch: std.Target.Cpu.Arch, target_query: *std.Target.Query) void {
    switch (arch) {
        .x86_64 => {
            const Feature = std.Target.x86.Feature;
            target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
        },
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.fp_armv8));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.crypto));
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.neon));
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;
            target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.d));
        },
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    }
}

fn getLinkerScript(b: *std.Build, arch: std.Target.Cpu.Arch) std.Build.LazyPath {
    return switch (arch) {
        .x86_64 => b.path("linker-x86_64.ld"),
        .aarch64 => b.path("linker-aarch64.ld"),
        .riscv64 => b.path("linker-riscv64.ld"),
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    };
}

fn createKernelExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, code_model: std.builtin.CodeModel, linker_script: std.Build.LazyPath) *std.Build.Step.Compile {
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
    });

    kernel.setLinkerScript(linker_script);
    kernel.want_lto = false;
    return kernel;
}

fn setupKernelModules(b: *std.Build, kernel: *std.Build.Step.Compile, user_module: *std.Build.Module) void {
    const limine = b.dependency("limine", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));
    kernel.root_module.addImport("user_elf", user_module);
}

pub fn build(b: *std.Build) !void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target kernel architecture") orelse .x86_64;

    var code_model: std.builtin.CodeModel = .default;
    var target_query: std.Target.Query = .{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

    configureArchFeatures(arch, &target_query);
    const linker_script_path = getLinkerScript(b, arch);
    if (arch == .x86_64) {
        code_model = .kernel;
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const user = b.addExecutable(.{
        .name = "user_elf",
        .root_source_file = b.path("src/user/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .default,
    });

    const kernel = createKernelExecutable(b, target, optimize, code_model, linker_script_path);
    const user_module = b.createModule(.{ .root_source_file = user.getEmittedBin() });
    setupKernelModules(b, kernel, user_module);

    kernel.step.dependOn(&user.step);
    b.installArtifact(kernel);

    // Setup kernel check
    const kernel_check = createKernelExecutable(b, target, optimize, code_model, linker_script_path);
    const user_check_module = b.createModule(.{ .root_source_file = b.path("src/user/main.zig") });
    setupKernelModules(b, kernel_check, user_check_module);

    const check = b.step("check", "Check if kernel compiles");
    check.dependOn(&kernel_check.step);
}
