const std = @import("std");

const Opts = struct {
    arch: std.Target.Cpu.Arch,
    ovmf_fd: []const u8,
    uefi: bool,
    qemu: bool,
    debug: u2,

    display: bool,
};

fn options(b: *std.Build) Opts {
    return .{
        .arch = b.option(std.Target.Cpu.Arch, "arch", "The target kernel architecture") orelse .x86_64,
        .ovmf_fd = b.option([]const u8, "ovmf", "OVMF.fd path") orelse b: {
            break :b (std.process.getEnvVarOwned(b.allocator, "OVMF_FD")) catch {
                break :b "/usr/share/ovmf/x64/OVMF.4m.fd";
            };
        },
        .uefi = b.option(bool, "uefi", "use UEFI to boot in QEMU (default: true)") orelse
            true,

        .qemu = b.option(bool, "qemu", "run QEMU") orelse false,
        .debug = b.option(u2, "debug", "QEMU debug level") orelse
            1,
        .display = b.option(bool, "display", "QEMU gui true/false") orelse
            true,
    };
}

pub fn build(b: *std.Build) !void {
    const opts = options(b);

    const target = b.resolveTargetQuery(getTarget(opts.arch));

    const kernel = createKernelElf(b, &opts, target);
    const iso = createIso(b, kernel.getEmittedBin(), opts.uefi);
    _ = runQemu(b, &opts, iso.path);
}

fn getTarget(arch: std.Target.Cpu.Arch) std.Target.Query  {
    const Target = std.Target;

    var enabled_features = Target.Cpu.Feature.Set.empty;
    var disabled_features = Target.Cpu.Feature.Set.empty;
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

fn createKernelElf(b: *std.Build, opts: *const Opts, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const linker_script = getLinkerScript(b, opts.arch);

    var code_model: std.builtin.CodeModel = .default;
    if (opts.arch == .x86_64) {
        code_model = .kernel;
    }

    const optimize = b.standardOptimizeOption(.{});

    const user = b.addExecutable(.{
        .name = "user_elf",
        .root_source_file = b.path("src/user/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .default,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
    });


    kernel.setLinkerScript(linker_script);
    kernel.want_lto = false;
    const user_module = b.createModule(.{ .root_source_file = user.getEmittedBin() });

    const limine = b.dependency("limine", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));
    kernel.root_module.addImport("user_elf", user_module);

    kernel.step.dependOn(&user.step);

    return kernel;
}


fn getLinkerScript(b: *std.Build, arch: std.Target.Cpu.Arch) std.Build.LazyPath {
    return switch (arch) {
        .x86_64 => b.path("linker-x86_64.ld"),
        .aarch64 => b.path("linker-aarch64.ld"),
        .riscv64 => b.path("linker-riscv64.ld"),
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    };
}

fn runQemu(b: *std.Build, opts: *const Opts, os_iso: std.Build.LazyPath) *std.Build.Step.Run {
    const qemu_step = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-machine",
        "q35",
        "-m",
        "2G",
        "-serial", 
        "stdio",
        "-drive",
    });

    qemu_step.addPrefixedFileArg("format=raw,file=", os_iso);


    if (opts.display) {
        qemu_step.addArgs(&.{
            "-display",
            "gtk,show-cursor=off",
        });
    } else {
        qemu_step.addArgs(&.{
            "-display",
            "none",
        });
    }

    switch (opts.debug) {
        0 => {},
        1 => qemu_step.addArgs(&.{ "-d", "guest_errors" }),
        2 => qemu_step.addArgs(&.{ "-d", "cpu_reset,guest_errors" }),
        3 => qemu_step.addArgs(&.{ "-d", "int,cpu_reset,guest_errors" }),
    }

    if (opts.uefi) {
        const ovmf_fd = opts.ovmf_fd;
        qemu_step.addArgs(&.{ "-bios", ovmf_fd });
    }

    const run_step = b.step("run", "Run in QEMU");
    run_step.dependOn(&qemu_step.step);
    run_step.dependOn(b.getInstallStep());
    return qemu_step;
}

const OutputStep = struct {step: *std.Build.Step.Run, path: std.Build.LazyPath,};

fn createIso(
    b: *std.Build,
    kernel_elf: std.Build.LazyPath,
    uefi: bool
) OutputStep {
    const limine_bootloader_pkg = b.dependency("limine_bootloader", .{});

    const limine_make = b.addSystemCommand(&.{
        "make", "-C",
    });
    limine_make.addDirectoryArg(limine_bootloader_pkg.path("."));

    const wf = b.addNamedWriteFiles("create virtual iso root");
    _ = wf.addCopyFile(kernel_elf, "boot/kernel");
    _ = wf.addCopyFile(b.path("limine.conf"), "boot/limine/limine.conf");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios.sys"), "boot/limine/limine-bios.sys");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios-cd.bin"), "boot/limine/limine-bios-cd.bin");
    if (uefi){
        _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-uefi-cd.bin"), "boot/limine/limine-uefi-cd.bin");
        _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
        _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");
    } 

    const xor_step = xorrisoStep(b, wf, "kernel.iso");
    xor_step.step.step.dependOn(&limine_make.step);
    xor_step.step.step.dependOn(&wf.step);

    return xor_step;
}

fn xorrisoStep(
    b: *std.Build,
    isoRoot: *std.Build.Step.WriteFile,
    outputIso: []const u8,
) OutputStep {
    const step = b.addSystemCommand(&.{"xorriso"});
    step.step.dependOn(&isoRoot.step);

    // mkisofs mode
    step.addArg("-as");
    step.addArg("mkisofs");

    // BIOS boot image inside iso
    step.addArg("-b");
    step.addArg("boot/limine/limine-bios-cd.bin");
    step.addArg("-no-emul-boot");
    step.addArg("-boot-load-size");
    step.addArg("4");
    step.addArg("-boot-info-table");

    // UEFI boot image
    step.addArg("--efi-boot");
    step.addArg("boot/limine/limine-uefi-cd.bin");
    step.addArg("-efi-boot-part");
    step.addArg("--efi-boot-image");

    // protective label
    step.addArg("--protective-msdos-label");

    // input directory (our staged iso_root)
    step.addDirectoryArg(isoRoot.getDirectory());

    // output file
    step.addArg("-o");

    return .{.step = step, .path = step.addOutputFileArg(outputIso)};
}
