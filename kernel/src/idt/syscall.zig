const std = @import("std");
const cpu = @import("../cpu.zig");
pub export fn syscall_dispatch() callconv(.SysV) void {
    std.log.info("hi", .{});
}

pub fn syscall_handler() callconv(.Naked) void {
    asm volatile  (
        \\ swapgs
        \\ xchg %bx, %bx
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
    cpu.writeMsr(MSR_STAR, (0x0013000800000000)); // Kernel CS/SS = 0x08, user = 0x1B
    cpu.writeMsr(MSR_FMASK, 0x300); // Disable IF and TF during syscall
}
