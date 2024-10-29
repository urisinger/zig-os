const std = @import("std");

const image_name = "kernel-image";

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

    // Linker script
    kernel.setLinkerScriptPath(linker_script_path);

    // Disable LTO to prevent Limine requests from being optimized away
    kernel.want_lto = false;

    const limine = b.dependency("limine", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));
    const kernel_step = b.addInstallArtifact(kernel, .{});
    b.installArtifact(kernel);

    const iso_step = createIsoStep(b, &kernel_step.step, arch);

    const download_ovmf = switch (arch) {
        .x86_64 => b.addSystemCommand(&.{
            "sh", "-c", "mkdir -p ovmf-x86_64 && cd ovmf-x86_64 && curl -o OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd",
        }),
        .aarch64 => b.addSystemCommand(&.{
            "sh", "-c", "mkdir -p ovmf-aarch64 && cd ovmf-aarch64 && curl -o OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEAARCH64_QEMU_EFI.fd",
        }),
        .riscv64 => b.addSystemCommand(&.{
            "sh", "-c", "mkdir -p ovmf-riscv64 && cd ovmf-riscv64 && curl -o OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASERISCV64_VIRT_CODE.fd && dd if=/dev/zero of=OVMF.fd bs=1 count=0 seek=33554432",
        }),
        else => std.debug.panic("Unsupported architecture: {s}", .{@tagName(arch)}),
    };

    iso_step.dependOn(&download_ovmf.step);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const qemu_cmd = try std.fmt.allocPrint(allocator, "qemu-system-{s}", .{@tagName(arch)});
    defer allocator.free(qemu_cmd);

    const ovmf_path = try std.fmt.allocPrint(allocator, "ovmf-{s}/OVMF.fd", .{@tagName(arch)});
    defer allocator.free(ovmf_path);

    const run_cmd = b.addSystemCommand(&.{
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
    run_cmd.step.dependOn(iso_step);

    const run_step = b.step("run", "Run the app in QEMU");
    run_step.dependOn(&run_cmd.step);
}

fn createIsoStep(b: *std.Build, kernel_step: *std.Build.Step, arch: std.Target.Cpu.Arch) *std.Build.Step {
    const iso_root = "iso_root";
    const clean_iso_dir = b.addSystemCommand(&.{ "rm", "-rf", iso_root });
    const create_iso_dirs = b.addSystemCommand(&.{
        "mkdir", "-p", iso_root ++ "/boot/limine", iso_root ++ "/EFI/BOOT",
    });

    const clone_limine = b.addSystemCommand(&.{
        "sh",                                                                                                                        "-c",
        "if [ ! -d \"limine\" ]; then git clone https://github.com/limine-bootloader/limine.git --branch=v8.x-binary --depth=1; fi",
    });

    const build_limine = b.addSystemCommand(&.{ "make", "-C", "limine" });

    build_limine.step.dependOn(&clone_limine.step);

    create_iso_dirs.step.dependOn(&clean_iso_dir.step);
    const copy_efi_loader = b.addSystemCommand(&.{ "cp", "-v" });

    copy_efi_loader.step.dependOn(&create_iso_dirs.step);

    copy_efi_loader.step.dependOn(&build_limine.step);

    const copy_kernel = b.addSystemCommand(&.{ "cp", "-v", "zig-out/bin/kernel" });

    copy_kernel.step.dependOn(&create_iso_dirs.step);
    copy_kernel.step.dependOn(kernel_step);

    const copy_limine = b.addSystemCommand(&.{ "cp", "-v", "limine.conf" });

    copy_limine.step.dependOn(&create_iso_dirs.step);
    copy_limine.step.dependOn(&build_limine.step);

    const iso_step = b.step("build-iso", "Create ISO image");

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

            const limine_install = b.addSystemCommand(&.{ "./limine/limine", "bios-install", image_name ++ ".iso" });

            limine_install.step.dependOn(&create_iso.step);
            iso_step.dependOn(&limine_install.step);
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

    return iso_step;
}
