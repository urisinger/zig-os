const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Options
    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target architecture") orelse .x86_64;
    const uefi = b.option(bool, "uefi", "Use UEFI to boot") orelse true;
    const ovmf_fd = b.option([]const u8, "ovmf", "OVMF.fd path") orelse b: {
        break :b (std.process.getEnvVarOwned(b.allocator, "OVMF_FD")) catch {
            break :b "/usr/share/ovmf/x64/OVMF.4m.fd";
        };
    };

    const qemu_gui = b.option(bool, "gui", "Enable QEMU GUI") orelse true;
    const qemu_debug_level = b.option(u2, "debug-level", "QEMU debug level (0-3)") orelse 1;
    const qemu_monitor = b.option(bool, "monitor", "Enable QEMU monitor via unix socket") orelse false;
    const qemu_extra_args = b.option([]const u8, "qemu-args", "Extra arguments to pass to QEMU") orelse "";

    // Target configuration (Freestanding OS)
    const kernel_target = b.resolveTargetQuery(getTarget(arch));

    // 1. Build User Space ELF
    const user_elf = b.addExecutable(.{
        .name = "user_elf",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
        }),
    });

    // 2. Build Kernel ELF
    var code_model: std.builtin.CodeModel = .default;
    if (arch == .x86_64) {
        code_model = .kernel;
    }

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = code_model,
        }),
    });

    kernel.setLinkerScript(getLinkerScript(b, arch));
    kernel.want_lto = false;

    // Imports
    const limine = b.dependency("limine", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));

    const user_module = b.createModule(.{
        .root_source_file = user_elf.getEmittedBin(),
    });
    kernel.root_module.addImport("user_elf", user_module);

    // Install artifacts
    b.installArtifact(kernel);
    b.installArtifact(user_elf);

    // 3. Create ISO
    const iso_step = createIso(b, kernel.getEmittedBin(), uefi);

    const iso_install = b.addInstallFile(iso_step.path, "kernel.iso");
    b.getInstallStep().dependOn(&iso_install.step);

    // 4. Run Step
    const run_step = b.step("run", "Run the OS in QEMU");
    const qemu_run_cmd = createQemuCommand(b, arch, iso_install, uefi, ovmf_fd, qemu_gui, qemu_debug_level, qemu_monitor, qemu_extra_args, false);
    run_step.dependOn(&qemu_run_cmd.step);

    // 5. Debug Step (QEMU with GDB server)
    const debug_step = b.step("debug", "Run the OS in QEMU with GDB server (-S -s)");
    const qemu_debug_cmd = createQemuCommand(b, arch, iso_install, uefi, ovmf_fd, qemu_gui, qemu_debug_level, qemu_monitor, qemu_extra_args, true);
    debug_step.dependOn(&qemu_debug_cmd.step);

    // 6. GDB Step (GDB client)
    const gdb_step = b.step("gdb", "Run GDB client");
    const gdb_cmd = b.addSystemCommand(&.{"gdb"});

    // Add the kernel executable as the primary file for symbols
    gdb_cmd.addArtifactArg(kernel);

    // Add the commands to connect to the QEMU GDB stub
    gdb_cmd.addArgs(&.{
        "-ex", "target remote localhost:1234",
        // Optional: layout src is great for seeing code while debugging
        "-ex", "layout src",
    });

    gdb_step.dependOn(&gdb_cmd.step);
    // Ensure the kernel is actually built before GDB tries to open it
    gdb_step.dependOn(b.getInstallStep());

    // 7. Test Step
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/common/bitmap_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}

fn createQemuCommand(
    b: *std.Build,
    arch: std.Target.Cpu.Arch,
    iso_install: *std.Build.Step.InstallFile,
    uefi: bool,
    ovmf_fd: []const u8,
    gui: bool,
    debug_level: u2,
    monitor: bool,
    extra_args: []const u8,
    gdb_server: bool,
) *std.Build.Step.Run {
    const qemu_bin = switch (arch) {
        .x86_64 => "qemu-system-x86_64",
        .aarch64 => "qemu-system-aarch64",
        .riscv64 => "qemu-system-riscv64",
        else => std.debug.panic("Unsupported architecture for QEMU: {s}", .{@tagName(arch)}),
    };

    const qemu_cmd = b.addSystemCommand(&.{qemu_bin});
    qemu_cmd.step.dependOn(&iso_install.step);

    qemu_cmd.addArgs(&.{
        "-machine", "q35",
        "-m",       "2G",
        "-serial",  "stdio",
        "-device",  "isa-debug-exit,iobase=0x501,iosize=0x04",
    });

    if (monitor) {
        qemu_cmd.addArgs(&.{ "-monitor", "unix:qemu-monitor.sock,server,nowait" });
    }

    const iso_path = b.getInstallPath(.prefix, iso_install.dest_rel_path);
    qemu_cmd.addArg("-drive");
    qemu_cmd.addArg(b.fmt("format=raw,file={s}", .{iso_path}));

    if (!gui) {
        qemu_cmd.addArgs(&.{ "-display", "none" });
    } else {
        qemu_cmd.addArgs(&.{ "-display", "gtk,show-cursor=off" });
    }

    switch (debug_level) {
        0 => {},
        1 => qemu_cmd.addArgs(&.{ "-d", "guest_errors" }),
        2 => qemu_cmd.addArgs(&.{ "-d", "cpu_reset,guest_errors" }),
        3 => qemu_cmd.addArgs(&.{ "-d", "int,cpu_reset,guest_errors" }),
    }

    if (uefi) {
        qemu_cmd.addArgs(&.{ "-bios", ovmf_fd });
    }

    if (gdb_server) {
        qemu_cmd.addArgs(&.{ "-S", "-s" });
    }

    if (extra_args.len > 0) {
        var it = std.mem.tokenizeAny(u8, extra_args, " ");
        while (it.next()) |arg| {
            qemu_cmd.addArg(arg);
        }
    }
    // Treat exit code 33 (from shutdownSuccess) as a successful run.
    qemu_cmd.expectExitCode(33);

    return qemu_cmd;
}

fn getTarget(arch: std.Target.Cpu.Arch) std.Target.Query {
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

fn getLinkerScript(b: *std.Build, arch: std.Target.Cpu.Arch) std.Build.LazyPath {
    return switch (arch) {
        .x86_64 => b.path("linker-x86_64.ld"),
        .aarch64 => b.path("linker-aarch64.ld"),
        .riscv64 => b.path("linker-riscv64.ld"),
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    };
}

const OutputStep = struct {
    step: *std.Build.Step.Run,
    path: std.Build.LazyPath,
};

fn createIso(b: *std.Build, kernel_elf: std.Build.LazyPath, uefi: bool) OutputStep {
    const limine_bootloader_pkg = b.dependency("limine_bootloader", .{});

    const limine_make = b.addSystemCommand(&.{
        "make", "-C",
    });
    limine_make.addDirectoryArg(limine_bootloader_pkg.path("."));

    const wf = b.addNamedWriteFiles("iso_root");
    _ = wf.addCopyFile(kernel_elf, "boot/kernel");
    _ = wf.addCopyFile(b.path("limine.conf"), "boot/limine/limine.conf");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios.sys"), "boot/limine/limine-bios.sys");
    _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-bios-cd.bin"), "boot/limine/limine-bios-cd.bin");
    if (uefi) {
        _ = wf.addCopyFile(limine_bootloader_pkg.path("limine-uefi-cd.bin"), "boot/limine/limine-uefi-cd.bin");
        _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
        _ = wf.addCopyFile(limine_bootloader_pkg.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");
    }

    const xor_step = b.addSystemCommand(&.{"xorriso"});
    xor_step.step.dependOn(&limine_make.step);
    xor_step.step.dependOn(&wf.step);

    // mkisofs mode
    xor_step.addArg("-as");
    xor_step.addArg("mkisofs");

    // BIOS boot image inside iso
    xor_step.addArg("-b");
    xor_step.addArg("boot/limine/limine-bios-cd.bin");
    xor_step.addArg("-no-emul-boot");
    xor_step.addArg("-boot-load-size");
    xor_step.addArg("4");
    xor_step.addArg("-boot-info-table");

    // UEFI boot image
    xor_step.addArg("--efi-boot");
    xor_step.addArg("boot/limine/limine-uefi-cd.bin");
    xor_step.addArg("-efi-boot-part");
    xor_step.addArg("--efi-boot-image");

    // protective label
    xor_step.addArg("--protective-msdos-label");

    // input directory (our staged iso_root)
    xor_step.addDirectoryArg(wf.getDirectory());

    // output file
    xor_step.addArg("-o");
    const iso_path = xor_step.addOutputFileArg("kernel.iso");

    return .{ .step = xor_step, .path = iso_path };
}
