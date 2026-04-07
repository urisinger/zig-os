const std = @import("std");

pub const OutputStep = struct {
    step: *std.Build.Step.Run,
    path: std.Build.LazyPath,
};

pub fn create(b: *std.Build, kernel_elf: std.Build.LazyPath, uefi: bool) OutputStep {
    const limine_bootloader_pkg = b.dependency("limine_bootloader", .{});

    const limine_make = b.addSystemCommand(&.{ "make", "-C" });
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
    xor_step.addArgs(&.{ "-as", "mkisofs" });

    // BIOS boot image inside iso
    xor_step.addArgs(&.{
        "-b", "boot/limine/limine-bios-cd.bin",
        "-no-emul-boot",
        "-boot-load-size", "4",
        "-boot-info-table",
    });

    // UEFI boot image
    xor_step.addArgs(&.{
        "--efi-boot", "boot/limine/limine-uefi-cd.bin",
        "-efi-boot-part",
        "--efi-boot-image",
        "--protective-msdos-label",
    });

    // input directory and output file
    xor_step.addDirectoryArg(wf.getDirectory());
    xor_step.addArg("-o");
    const iso_path = xor_step.addOutputFileArg("kernel.iso");

    return .{ .step = xor_step, .path = iso_path };
}
