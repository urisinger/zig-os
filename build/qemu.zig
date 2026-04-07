const std = @import("std");

pub const QemuOptions = struct {
    arch: std.Target.Cpu.Arch,
    iso_install: *std.Build.Step.InstallFile,
    uefi: bool,
    ovmf_fd: []const u8,
    gui: bool,
    debug_level: u2,
    monitor: bool,
    extra_args: []const u8,
    gdb_server: bool,
};

pub fn createCommand(b: *std.Build, opts: QemuOptions) *std.Build.Step.Run {
    const qemu_bin = switch (opts.arch) {
        .x86_64 => "qemu-system-x86_64",
        .aarch64 => "qemu-system-aarch64",
        .riscv64 => "qemu-system-riscv64",
        else => std.debug.panic("Unsupported architecture for QEMU: {s}", .{@tagName(opts.arch)}),
    };

    const qemu_cmd = b.addSystemCommand(&.{qemu_bin});
    qemu_cmd.step.dependOn(&opts.iso_install.step);

    qemu_cmd.addArgs(&.{
        "-machine", "q35",
        "-m", "2G",
        "-serial", "stdio",
        "-device", "isa-debug-exit,iobase=0x501,iosize=0x04",
    });

    if (opts.monitor) {
        qemu_cmd.addArgs(&.{ "-monitor", "unix:qemu-monitor.sock,server,nowait" });
    }

    const iso_path = b.getInstallPath(.prefix, opts.iso_install.dest_rel_path);
    qemu_cmd.addArg("-drive");
    qemu_cmd.addArg(b.fmt("format=raw,file={s}", .{iso_path}));

    if (!opts.gui) {
        qemu_cmd.addArgs(&.{ "-display", "none" });
    } else {
        qemu_cmd.addArgs(&.{ "-display", "gtk,show-cursor=off" });
    }

    switch (opts.debug_level) {
        0 => {},
        1 => qemu_cmd.addArgs(&.{ "-d", "guest_errors" }),
        2 => qemu_cmd.addArgs(&.{ "-d", "cpu_reset,guest_errors" }),
        3 => qemu_cmd.addArgs(&.{ "-d", "int,cpu_reset,guest_errors" }),
    }

    if (opts.uefi) {
        qemu_cmd.addArgs(&.{ "-bios", opts.ovmf_fd });
    }

    if (opts.gdb_server) {
        qemu_cmd.addArgs(&.{ "-S", "-s" });
    }

    if (opts.extra_args.len > 0) {
        var it = std.mem.tokenizeAny(u8, opts.extra_args, " ");
        while (it.next()) |arg| {
            qemu_cmd.addArg(arg);
        }
    }

    qemu_cmd.expectExitCode(33);
    qemu_cmd.stdio = .inherit;
    qemu_cmd.step.dependOn(b.getInstallStep());

    return qemu_cmd;
}
