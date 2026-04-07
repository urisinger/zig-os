const std = @import("std");
const targets = @import("build/targets.zig");
const iso = @import("build/iso.zig");
const qemu = @import("build/qemu.zig");
const utils = @import("build/utils.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    // --- 1. Resolve Options ---
    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target architecture") orelse .x86_64;
    const uefi = b.option(bool, "uefi", "Use UEFI to boot") orelse true;
    const qemu_gui = b.option(bool, "gui", "Enable QEMU GUI") orelse true;
    const qemu_debug = b.option(u2, "debug-level", "QEMU debug level (0-3)") orelse 1;
    const qemu_monitor = b.option(bool, "monitor", "Enable QEMU monitor") orelse false;
    const qemu_args = b.option([]const u8, "qemu-args", "Extra QEMU args") orelse "";
    const ovmf_fd = b.option([]const u8, "ovmf", "OVMF.fd path") orelse 
        std.process.getEnvVarOwned(b.allocator, "OVMF_FD") catch "/usr/share/ovmf/x64/OVMF.4m.fd";

    const kernel_target = b.resolveTargetQuery(targets.get(arch));

    // --- 2. Build User Space ELF ---
    const user_module = b.createModule(.{
        .root_source_file = b.path("src/user/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    const user_elf = b.addExecutable(.{
        .name = "user_elf",
        .use_llvm = true,
        .root_module = user_module,
    });
    b.installArtifact(user_elf);

    // --- 3. Build Kernel ELF ---
    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = if (arch == .x86_64) .kernel else .default,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .use_llvm = true,
        .root_module = kernel_module,
    });
    
    kernel.setLinkerScript(targets.getLinkerScript(b, arch));
    kernel.want_lto = false;

    // Kernel Imports & Configs
    const limine = b.dependency("limine", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));
    
    const config = b.addOptions();
    config.addOption([]const []const u8, "sources", try utils.getKernelSources(b));
    kernel.root_module.addOptions("config", config);

    const user_elf_bin_module = b.createModule(.{ .root_source_file = user_elf.getEmittedBin() });
    kernel.root_module.addImport("user_elf", user_elf_bin_module);
    
    b.installArtifact(kernel);

    // --- 4. Check Step (ZLS) ---
    const check_step = b.step("check", "Check if the project compiles");
    
    const user_elf_check = b.addExecutable(.{
        .name = "user_elf",
        .root_module = user_module,
    });
    check_step.dependOn(&user_elf_check.step);

    const kernel_check = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_module,
    });
    kernel_check.setLinkerScript(targets.getLinkerScript(b, arch));
    kernel_check.root_module.addImport("limine", limine.module("limine"));
    kernel_check.root_module.addOptions("config", config);
    kernel_check.root_module.addImport("user_elf", user_elf_bin_module);
    
    check_step.dependOn(&kernel_check.step);

    // --- 5. Create ISO ---
    const iso_step = iso.create(b, kernel.getEmittedBin(), uefi);
    const iso_install = b.addInstallFile(iso_step.path, "kernel.iso");
    
    iso_step.step.step.dependOn(&kernel.step); 
    b.getInstallStep().dependOn(&iso_install.step);

    // --- 5. Run & Debug Steps (QEMU) ---
    const qemu_opts = qemu.QemuOptions{
        .arch = arch,
        .iso_install = iso_install,
        .uefi = uefi,
        .ovmf_fd = ovmf_fd,
        .gui = qemu_gui,
        .debug_level = qemu_debug,
        .monitor = qemu_monitor,
        .extra_args = qemu_args,
        .gdb_server = false,
    };

    const run_step = b.step("run", "Run the OS in QEMU");
    run_step.dependOn(&qemu.createCommand(b, qemu_opts).step);

    const debug_step = b.step("debug", "Run the OS in QEMU with GDB server (-S -s)");
    var debug_opts = qemu_opts;
    debug_opts.gdb_server = true;
    debug_step.dependOn(&qemu.createCommand(b, debug_opts).step);

    // --- 6. GDB Step ---
    const gdb_step = b.step("gdb", "Run GDB client");
    const gdb_cmd = b.addSystemCommand(&.{"gdb"});
    gdb_cmd.addArtifactArg(kernel);
    gdb_cmd.addArgs(&.{ "-ex", "target remote localhost:1234", "-ex", "layout src" });
    gdb_cmd.stdio = .inherit;
    
    gdb_step.dependOn(&gdb_cmd.step);
    gdb_step.dependOn(b.getInstallStep());

    // --- 7. Test Step ---
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/common/bitmap_test.zig"),
            // Assuming tests run natively or on a specified test target
            .target = b.standardTargetOptions(.{}), 
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
