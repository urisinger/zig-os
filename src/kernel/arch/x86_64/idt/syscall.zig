const std = @import("std");
const root = @import("root");
const log = std.log.scoped(.syscall);

const instr = @import("../instr.zig");

const core = root.core;
const syscalls = core.syscall;

var syscall_table: [3]?*const fn (u64, u64, u64, u64, u64, u64) callconv(.{ .x86_64_sysv = .{} }) u64 = [3]?*const fn (u64, u64, u64, u64, u64, u64) callconv(.{ .x86_64_sysv = .{} }) u64{
    &syscalls.testSyscall,
    &syscalls.testSyscall,
    &syscalls.testSyscall,
};

export const syscall_table_ptr: [*]?*const fn (u64, u64, u64, u64, u64, u64) u64 = @ptrCast(&syscall_table[0]);
export const syscall_table_len = syscall_table.len;

export fn fallback_syscall() callconv(.c) u64 {
    return 0xFFFFFFFFFFFFFFFF;
}

const pcpu = @import("../pcpu.zig");

pub fn syscall_handler() callconv(.naked) void {
    asm volatile (std.fmt.comptimePrint(
        \\ swapgs
        \\ mov %rsp, %gs:{d} // store user stack pointer
        \\ mov %gs:{d}, %rsp // load kernel stack 
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
        \\ mov %gs:{d}, %rsp // load user stack pointer
        \\ swapgs
        \\ sysretq
        , .{
            @offsetOf(pcpu.CoreContext, "user_stack"),
            @offsetOf(pcpu.CoreContext, "kernel_stack"),
            @offsetOf(pcpu.CoreContext, "user_stack"),
        }));
}


pub fn init() void {
    const MSR_EFER: u32 = 0xC0000080;
    const MSR_LSTAR: u32 = 0xC0000082;
    const MSR_STAR: u32 = 0xC0000081;
    const MSR_FMASK: u32 = 0xC0000084;

    const EFER_SCE: u64 = 1;

    // Enable syscall/sysret
    instr.writeMsr(MSR_EFER, instr.readMsr(MSR_EFER) | EFER_SCE);
    instr.writeMsr(MSR_LSTAR, @intFromPtr(&syscall_handler));
    instr.writeMsr(MSR_STAR, 0x13 << 48 | 0x8 << 32); // Kernel CS/SS = 0x08, user = 0x1B
    instr.writeMsr(MSR_FMASK, 0x300); // Disable IF and TF during syscall
}
