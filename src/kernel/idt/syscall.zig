const std = @import("std");
const log = std.log.scoped(.syscall);

const cpu = @import("../cpu.zig");

pub export fn syscall_dispatch() callconv(.SysV) void {
    log.info("hi", .{});
}

pub fn syscall_handler() callconv(.Naked) void {
    asm volatile (
        \\ swapgs
        \\ mov %gs:8, %rsp // load kernel stack 
        \\ sti
        \\ push %r11
        \\ push %rcx
        \\ call syscall_dispatch
        \\ pop %rcx                 
        \\ pop %r11                
        \\ swapgs
        \\ sysretq
    );
}

pub fn init() void {
    const MSR_EFER: u32 = 0xC0000080;
    const MSR_LSTAR: u32 = 0xC0000082;
    const MSR_STAR: u32 = 0xC0000081;
    const MSR_FMASK: u32 = 0xC0000084;

    const EFER_SCE: u64 = 1;

    // Enable syscall/sysret
    cpu.writeMsr(MSR_EFER, cpu.readMsr(MSR_EFER) | EFER_SCE);
    cpu.writeMsr(MSR_LSTAR, @intFromPtr(&syscall_handler));
    cpu.writeMsr(MSR_STAR, 0x13 << 48 | 0x8 << 32); // Kernel CS/SS = 0x08, user = 0x1B
    cpu.writeMsr(MSR_FMASK, 0x300); // Disable IF and TF during syscall
}
