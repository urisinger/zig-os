const std = @import("std");
const idt = @import("../idt.zig");

pub fn divisionError(ctx: *volatile idt.Context) void {
    dumpRegisters(@volatileCast(ctx));
    @panic("Unhandled division error.");
}

pub fn debugException(_: *volatile idt.Context) void {
    @panic("Unhandled debug exception.");
}

pub fn nonMaskableInterrupt(_: *volatile idt.Context) void {
    @panic("Unhandled non-maskable interrupt.");
}

pub fn breakpoint(_: *volatile idt.Context) void {
    @panic("Unhandled breakpoint exception.");
}

pub fn boundRangeExceeded(_: *volatile idt.Context) void {
    @panic("Unhandled bound range exceeded.");
}

pub fn invalidOpcode(ctx: *volatile idt.Context) void {
    const ip = ctx.ret_frame.rip;
    const opcode_ptr: [*]const u8 = @ptrFromInt(ip);

    // Read a few bytes from the faulting instruction pointer
    const opcode0 = opcode_ptr[0];
    const opcode1 = opcode_ptr[1];
    const opcode2 = opcode_ptr[2];

    std.log.err("Invalid opcode at RIP=0x{x}: 0x{x} 0x{x} 0x{x}", .{
        ip,
        opcode0,
        opcode1,
        opcode2,
    });

    @panic("Unhandled invalid opcode.");
}

pub fn deviceNotAvailable(_: *volatile idt.Context) void {
    @panic("Unhandled device not available.");
}

pub fn doubleFault(_: *volatile idt.Context) void {
    @panic("Unhandled double fault.");
}

pub fn coprocessorSegmentOverrun(_: *volatile idt.Context) void {
    @panic("Unhandled coprocessor segment overrun.");
}

pub fn invalidTSS(_: *volatile idt.Context) void {
    @panic("Unhandled invalid TSS.");
}

pub fn segmentNotPresent(_: *volatile idt.Context) void {
    @panic("Unhandled segment not present.");
}

pub fn stackSegmentFault(_: *volatile idt.Context) void {
    @panic("Unhandled stack segment fault.");
}

pub fn generalProtectionFault(_: *volatile idt.Context) void {
    @panic("Unhandled general protection fault.");
}

pub fn pageFault(_: *volatile idt.Context) void {
    @panic("Unhandled page fault.");
}

pub fn x87FloatingPoint(_: *volatile idt.Context) void {
    @panic("Unhandled x87 floating point exception.");
}

pub fn alignmentCheck(_: *volatile idt.Context) void {
    @panic("Unhandled alignment check.");
}

pub fn machineCheck(_: *volatile idt.Context) void {
    @panic("Unhandled machine check.");
}

pub fn simdFloatingPoint(_: *volatile idt.Context) void {
    @panic("Unhandled SIMD floating point exception.");
}

pub fn virtualizationException(_: *volatile idt.Context) void {
    @panic("Unhandled virtualization exception.");
}

pub fn securityException(_: *volatile idt.Context) void {
    @panic("Unhandled security exception.");
}


pub fn dumpRegisters(ctx: *const idt.Context) void {
    std.log.err("------ Register Dump ------", .{});
    std.log.err("RAX=0x{x} RBX=0x{x} RCX=0x{x} RDX=0x{x}", .{
        ctx.registers.rax, ctx.registers.rbx, ctx.registers.rcx, ctx.registers.rdx
    });
    std.log.err("RSI=0x{x} RDI=0x{x} RBP=0x{x} RSP=0x{x}", .{
        ctx.registers.rsi, ctx.registers.rdi, ctx.registers.rbp, ctx.ret_frame.rsp
    });
    std.log.err("R8 =0x{x} R9 =0x{x} R10=0x{x} R11=0x{x}", .{
        ctx.registers.r8, ctx.registers.r9, ctx.registers.r10, ctx.registers.r11
    });
    std.log.err("R12=0x{x} R13=0x{x} R14=0x{x} R15=0x{x}", .{
        ctx.registers.r12, ctx.registers.r13, ctx.registers.r14, ctx.registers.r15
    });
    std.log.err("RIP=0x{x} CS=0x{x} RFLAGS=0x{x}", .{
        ctx.ret_frame.rip, ctx.ret_frame.cs, ctx.ret_frame.rflags
    });
    std.log.err("SS=0x{x} (only valid on CPL change)", .{ctx.ret_frame.ss});
    std.log.err("Interrupt=0x{x}  Error Code=0x{x}", .{
        ctx.interrupt_num, ctx.error_code
    });
    std.log.err("---------------------------", .{});
}
