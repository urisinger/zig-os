const std = @import("std");

pub fn get(arch: std.Target.Cpu.Arch) std.Target.Query {
    var enabled_features = std.Target.Cpu.Feature.Set.empty;
    var disabled_features = std.Target.Cpu.Feature.Set.empty;

    switch (arch) {
        .x86_64 => {
            const Feature = std.Target.x86.Feature;
            enabled_features.addFeature(@intFromEnum(Feature.soft_float));
            disabled_features.addFeature(@intFromEnum(Feature.mmx));
            disabled_features.addFeature(@intFromEnum(Feature.sse));
            disabled_features.addFeature(@intFromEnum(Feature.sse2));
            disabled_features.addFeature(@intFromEnum(Feature.avx));
            disabled_features.addFeature(@intFromEnum(Feature.avx2));
        },
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;
            disabled_features.addFeature(@intFromEnum(Feature.fp_armv8));
            disabled_features.addFeature(@intFromEnum(Feature.crypto));
            disabled_features.addFeature(@intFromEnum(Feature.neon));
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;
            disabled_features.addFeature(@intFromEnum(Feature.d));
        },
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    }

    return .{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = enabled_features,
        .cpu_features_sub = disabled_features,
    };
}

pub fn getLinkerScript(b: *std.Build, arch: std.Target.Cpu.Arch) std.Build.LazyPath {
    return switch (arch) {
        .x86_64 => b.path("linker-x86_64.ld"),
        .aarch64 => b.path("linker-aarch64.ld"),
        .riscv64 => b.path("linker-riscv64.ld"),
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    };
}
