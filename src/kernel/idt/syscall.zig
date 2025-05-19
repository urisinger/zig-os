const std = @import("std");
const log = std.log.scoped(.syscall);

const cpu = @import("../cpu.zig");

const syscalls = @import("../syscalls.zig");

var syscall_table: [3]?*const fn (u64, u64, u64, u64, u64, u64) callconv(.SysV) u64 = [3]?*const fn (u64, u64, u64, u64, u64, u64) callconv(.SysV) u64{
    &syscalls.testSyscall,
    &syscalls.testSyscall,
    &syscalls.testSyscall,
};

export const syscall_table_ptr: [*]?*const fn (u64, u64, u64, u64, u64, u64) u64 = @ptrCast(&syscall_table[0]);
export const syscall_table_len = syscall_table.len;

export fn fallback_syscall() callconv(.C) u64 {
    return 0xFFFFFFFFFFFFFFFF;
}

pub fn syscall_handler() callconv(.Naked) void {
    asm volatile (
        \\ swapgs
        \\ mov %rsp, %gs:16 // store user stack pointer
        \\ mov %gs:8, %rsp // load kernel stack 
        \\ sti
        \\ push %r11
        \\ push %rcx
        \\ mov %r10, %rcx
        // Bounds check: if rax >= syscall_table.len, jump to fallback
        \\ cmp syscall_table_len, %rax
        \\ jae .fallback

        // Load function pointer from syscall_table[rax]
        \\ mov syscall_table_ptr, %r11
        \\ mov (%r11, %rax, 8), %r11   // r11 = syscall_table[rax]

        // Check if it's null
        \\ test %r11, %r11
        \\ je .fallback

        // Jump to syscall function
        \\ call *%r11
        \\ jmp .done
        \\ .fallback:
        \\ call fallback_syscall
        \\ .done:
        \\ pop %rcx                 
        \\ pop %r11
        \\ cli
        \\ mov %gs:16, %rsp // load user stack pointer
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
