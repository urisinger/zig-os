const std = @import("std");
const log = std.log.scoped(.exeptions);
const idt = @import("../idt.zig");
const cpu = @import("../../cpu.zig");

const exception_names: [32]?[]const u8 = [_]?[]const u8{
    "Division Error",
    "Debug Exception",
    "Non-Maskable Interrupt",
    "Breakpoint",
    null, // 0x4 is reserved
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack Segment Fault",
    "General Protection Fault",
    "Page Fault",
    null, // 0xF is reserved
    "x87 Floating Point Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating Point Exception",
    "Virtualization Exception",
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    "Security Exception", // 0x1E
    null,
};

pub fn handleException(ctx: *volatile idt.Context) void {
    const interrupt_num = ctx.interrupt_num;
    const name = if (interrupt_num < exception_names.len and exception_names[interrupt_num] != null)
        exception_names[interrupt_num].?
    else
        "Unknown Exception";

    if (interrupt_num == 0x6) {
        const ip = ctx.ret_frame.rip;
        const opcode_ptr: [*]const u8 = @ptrFromInt(ip);
        const opcode0 = opcode_ptr[0];
        const opcode1 = opcode_ptr[1];
        const opcode2 = opcode_ptr[2];
        log.err("Invalid opcode at RIP=0x{x}: 0x{x} 0x{x} 0x{x}", .{
            ip,
            opcode0,
            opcode1,
            opcode2,
        });
    }

    dumpRegisters(@volatileCast(ctx));
    log.err("Unhandled Exception {} (0x{x}): {s}", .{ interrupt_num, interrupt_num, name });
    log.err("CPU exception occurred.", .{});
    cpu.halt();
}

pub fn dumpRegisters(ctx: *const idt.Context) void {
    log.err("------ Register Dump ------", .{});
    log.err("RAX=0x{x} RBX=0x{x} RCX=0x{x} RDX=0x{x}", .{ ctx.registers.rax, ctx.registers.rbx, ctx.registers.rcx, ctx.registers.rdx });
    log.err("RSI=0x{x} RDI=0x{x} RBP=0x{x} RSP=0x{x}", .{ ctx.registers.rsi, ctx.registers.rdi, ctx.registers.rbp, ctx.ret_frame.rsp });
    log.err("R8 =0x{x} R9 =0x{x} R10=0x{x} R11=0x{x}", .{ ctx.registers.r8, ctx.registers.r9, ctx.registers.r10, ctx.registers.r11 });
    log.err("R12=0x{x} R13=0x{x} R14=0x{x} R15=0x{x}", .{ ctx.registers.r12, ctx.registers.r13, ctx.registers.r14, ctx.registers.r15 });
    log.err("RIP=0x{x} CS=0x{x} RFLAGS=0x{x}", .{ ctx.ret_frame.rip, ctx.ret_frame.cs, ctx.ret_frame.rflags });
    log.err("SS=0x{x} (only valid on CPL change)", .{ctx.ret_frame.ss});
    log.err("Interrupt=0x{x}  Error Code=0x{x}", .{ ctx.interrupt_num, ctx.error_code });
    log.err("---------------------------", .{});
}
