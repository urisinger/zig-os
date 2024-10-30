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
    const kernel_step = b.addInstallArtifact(kernel, .{});
    b.installArtifact(kernel);

    const clone_limine = b.addSystemCommand(&.{
        "sh",                                                                                                                        "-c",
        "if [ ! -d \"limine\" ]; then git clone https://github.com/limine-bootloader/limine.git --branch=v8.x-binary --depth=1; fi",
    });

    const build_limine = b.addSystemCommand(&.{ "make", "-C", "limine" });

    build_limine.step.dependOn(&clone_limine.step);

    const download_ovmf = switch (arch) {
        .x86_64 => b.addSystemCommand(&.{
            "sh", "-c", "mkdir -p ovmf-x86_64 && cd ovmf-x86_64 && if [ ! -f \"OVMF.fd\" ]; then curl -o OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd; fi",
        }),
        .aarch64 => b.addSystemCommand(&.{
            "sh", "-c", "mkdir -p ovmf-aarch64 && cd ovmf-aarch64 && if [ ! -f \"OVMF.fd\" ]; then curl -o OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd fi",
        }),
        .riscv64 => b.addSystemCommand(&.{
            "sh", "-c", "mkdir -p ovmf-riscv64 && cd ovmf-riscv64 && if [ ! -f \"OVMF.fd\" ]; then curl -o OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT_CODE.fd && dd if=/dev/zero of=OVMF.fd bs=1 count=0 seek=33554432 fi",
        }),
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    };

    const run_hdd = b.step("run-hdd", "Run the iso image in QEMU");
    run_hdd.dependOn(try runHddStep(b, &kernel_step.step, &build_limine.step, &download_ovmf.step, arch));

    const run_iso = b.step("run-iso", "Run the iso image in QEMU");
    run_iso.dependOn(try runIsoStep(b, &kernel_step.step, &build_limine.step, &download_ovmf.step, arch));

    const run_step = b.step("run", "Run the app in QEMU");

    run_step.dependOn(run_iso);
}

fn runIsoStep(
    b: *std.Build,
    kernel_step: *std.Build.Step,
    build_limine: *std.Build.Step,
    download_ovmf: *std.Build.Step,
    arch: std.Target.Cpu.Arch,
) !*std.Build.Step {
    const clean_iso_dir = b.addSystemCommand(&.{ "rm", "-rf", iso_root });
    const create_iso_dirs = b.addSystemCommand(&.{
        "mkdir", "-p", iso_root ++ "/boot/limine", iso_root ++ "/EFI/BOOT",
    });

    create_iso_dirs.step.dependOn(&clean_iso_dir.step);
    const copy_efi_loader = b.addSystemCommand(&.{
        "cp",
        "-v",
    });

    copy_efi_loader.step.dependOn(&create_iso_dirs.step);
    copy_efi_loader.step.dependOn(build_limine);

    const copy_kernel = b.addSystemCommand(&.{
        "cp",
        "-v",
        "zig-out/bin/kernel",
    });

    copy_kernel.step.dependOn(&create_iso_dirs.step);
    copy_kernel.step.dependOn(kernel_step);

    const copy_limine = b.addSystemCommand(&.{
        "cp",
        "-v",
        "limine.conf",
    });

    copy_limine.step.dependOn(&create_iso_dirs.step);
    copy_limine.step.dependOn(build_limine);

    const create_iso = b.addSystemCommand(&.{
        "xorriso",
        "-as",
        "mkisofs",
        "-b",
        "boot/limine/limine-bios-cd.bin",
        "-no-emul-boot",
        "-boot-load-size",
        "4",
        "-boot-info-table",
        "--efi-boot",
        "boot/limine/limine-uefi-cd.bin",
        "-efi-boot-part",
        "--efi-boot-image",
        "--protective-msdos-label",
        iso_root,
        "-o",
        image_name ++ ".iso",
    });

    create_iso.step.dependOn(&copy_efi_loader.step);
    create_iso.step.dependOn(&copy_kernel.step);
    create_iso.step.dependOn(&copy_limine.step);

    switch (arch) {
        .x86_64 => {
            copy_efi_loader.addArgs(&.{ "limine/BOOTX64.EFI", "limine/BOOTIA32.EFI", iso_root ++ "/EFI/BOOT/" });
            copy_limine.addArgs(&.{ "limine/limine-bios.sys", "limine/limine-bios-cd.bin", "limine/limine-uefi-cd.bin" });
            create_iso.addArg(iso_root ++ "/boot/limine/limine-bios-cd.bin");

            const bios_install = b.addSystemCommand(&.{ "./limine/limine", "bios-install", image_name ++ ".iso" });

            bios_install.step.dependOn(&create_iso_dirs.step);
            create_iso.step.dependOn(&bios_install.step);
        },
        .aarch64 => {
            copy_kernel.addArg("limine/BOOTAA64.EFI");
            create_iso.addArg(iso_root ++ "/EFI/BOOT/BOOTAA64.EFI");
        },
        .riscv64 => {
            copy_kernel.addArg("limine/BOOTRISCV64.EFI");
            create_iso.addArg(iso_root ++ "/EFI/BOOT/BOOTRISCV64.EFI");
        },
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    }

    copy_kernel.addArg(iso_root ++ "/boot/");
    copy_limine.addArg(iso_root ++ "/boot/limine/");

    const iso_step = b.step("iso", "Create ISO image");

    iso_step.dependOn(&create_iso.step);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const qemu_cmd = try std.fmt.allocPrint(allocator, "qemu-system-{s}", .{@tagName(arch)});
    defer allocator.free(qemu_cmd);

    const ovmf_path = try std.fmt.allocPrint(allocator, "ovmf-{s}/OVMF.fd", .{@tagName(arch)});
    defer allocator.free(ovmf_path);

    const run_step = b.addSystemCommand(&.{
        qemu_cmd,
        "-M",
        "q35",
        "-serial",
        "stdio",
        "-m",
        "2G",
        "-bios",
        ovmf_path,
        "-cdrom",
        image_name ++ ".iso",
        "-boot",
        "d",
    });

    run_step.step.dependOn(download_ovmf);
    run_step.step.dependOn(iso_step);

    return &run_step.step;
}

fn runHddStep(
    b: *std.Build,
    kernel_step: *std.Build.Step,
    build_limine: *std.Build.Step,
    download_ovmf: *std.Build.Step,
    arch: std.Target.Cpu.Arch,
) !*std.Build.Step {
    const clean_hdd = b.addSystemCommand(&.{
        "rm", "-f", image_name ++ ".hdd",
    });

    // Create empty 64MB file
    const create_hdd = b.addSystemCommand(&.{
        "dd",
        "if=/dev/zero",
        "bs=1M",
        "count=0",
        "seek=64",
        "of=" ++ image_name ++ ".hdd",
    });
    create_hdd.step.dependOn(&clean_hdd.step);

    // Create GPT partition
    const create_partition = b.addSystemCommand(&.{
        "sgdisk",
        image_name ++ ".hdd",
        "-n",
        "1:2048",
        "-t",
        "1:ef00",
    });
    create_partition.step.dependOn(&create_hdd.step);

    // Format the partition
    const format_partition = b.addSystemCommand(&.{
        "mformat",
        "-i",
        image_name ++ ".hdd@@1M",
    });
    format_partition.step.dependOn(&create_partition.step);

    // Create directories
    const create_dirs = b.addSystemCommand(&.{
        "mmd",
        "-i",
        image_name ++ ".hdd@@1M",
        "::/EFI",
        "::/EFI/BOOT",
        "::/boot",
        "::/boot/limine",
    });
    create_dirs.step.dependOn(&format_partition.step);

    // Copy kernel
    const copy_kernel = b.addSystemCommand(&.{
        "mcopy",
        "-i",
        image_name ++ ".hdd@@1M",
        "zig-out/bin/kernel",
        "::/boot",
    });
    copy_kernel.step.dependOn(&create_dirs.step);
    copy_kernel.step.dependOn(kernel_step);

    // Copy limine config
    const copy_limine_conf = b.addSystemCommand(&.{
        "mcopy",
        "-i",
        image_name ++ ".hdd@@1M",
        "limine.conf",
        "::/boot/limine",
    });
    copy_limine_conf.step.dependOn(&create_dirs.step);

    const hdd_step = b.step("hdd", "Create HDD image");

    switch (arch) {
        .x86_64 => {
            // Copy BIOS bootloader files
            const copy_bios = b.addSystemCommand(&.{
                "mcopy",
                "-i",
                image_name ++ ".hdd@@1M",
                "limine/limine-bios.sys",
                "::/boot/limine",
            });
            copy_bios.step.dependOn(&create_dirs.step);
            copy_bios.step.dependOn(build_limine);

            const copy_efi = b.addSystemCommand(&.{
                "mcopy",
                "-i",
                image_name ++ ".hdd@@1M",
                "limine/BOOTX64.EFI",
                "limine/BOOTIA32.EFI",
                "::/EFI/BOOT",
            });
            copy_efi.step.dependOn(&create_dirs.step);

            copy_efi.step.dependOn(build_limine);

            hdd_step.dependOn(&copy_bios.step);
            hdd_step.dependOn(&copy_efi.step);
        },
        .aarch64 => {
            const copy_efi = b.addSystemCommand(&.{
                "mcopy",
                "-i",
                image_name ++ ".hdd@@1M",
                "limine/BOOTAA64.EFI",
                "::/EFI/BOOT",
            });

            copy_efi.step.dependOn(build_limine);
            copy_efi.step.dependOn(&create_dirs.step);
            hdd_step.dependOn(&copy_efi.step);
        },
        .riscv64 => {
            const copy_efi = b.addSystemCommand(&.{
                "mcopy",
                "-i",
                image_name ++ ".hdd@@1M",
                "limine/BOOTRISCV64.EFI",
                "::/EFI/BOOT",
            });

            copy_efi.step.dependOn(build_limine);
            copy_efi.step.dependOn(&create_dirs.step);
            hdd_step.dependOn(&copy_efi.step);
        },
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    }

    hdd_step.dependOn(&copy_kernel.step);
    hdd_step.dependOn(&copy_limine_conf.step);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const qemu_cmd = try std.fmt.allocPrint(allocator, "qemu-system-{s}", .{@tagName(arch)});
    defer allocator.free(qemu_cmd);

    const ovmf_path = try std.fmt.allocPrint(allocator, "ovmf-{s}/OVMF.fd", .{@tagName(arch)});
    defer allocator.free(ovmf_path);

    const run_step = b.addSystemCommand(&.{
        qemu_cmd,
        "-M",
        "q35",
        "-serial",
        "stdio",
        "-m",
        "2G",
        "-bios",
        ovmf_path,
        "-hda",
        image_name ++ ".hdd",
    });

    run_step.step.dependOn(download_ovmf);
    run_step.step.dependOn(hdd_step);

    return &run_step.step;
}
