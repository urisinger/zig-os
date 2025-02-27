const std = @import("std");
const utils = @import("../utils.zig");

const exceptions = @import("interrupts/exceptions.zig");

const cpu = @import("../cpu.zig");

pub fn init() void {
    registerExeptions();
    const idtr = Lidr{
        .size = @intCast((idt.len * @sizeOf(IdtEntry))),
        .offset = @intFromPtr(&idt),
    };

    cpu.lidt(@intFromPtr(&idtr));
}

fn registerExeptions() void {
    registerInterrupt(0x0, exceptions.divisionError, .int, .user);
    registerInterrupt(0x1, exceptions.debugException, .int, .user);
    registerInterrupt(0x2, exceptions.nonMaskableInterrupt, .int, .user);
    registerInterrupt(0x3, exceptions.breakpoint, .trap, .user);
    registerInterrupt(0x5, exceptions.boundRangeExceeded, .int, .user);
    registerInterrupt(0x6, exceptions.invalidOpcode, .int, .user);
    registerInterrupt(0x7, exceptions.deviceNotAvailable, .int, .user);
    registerInterrupt(0x8, exceptions.doubleFault, .int, .user);
    registerInterrupt(0x9, exceptions.coprocessorSegmentOverrun, .int, .user);
    registerInterrupt(0xA, exceptions.invalidTSS, .int, .user);
    registerInterrupt(0xB, exceptions.segmentNotPresent, .int, .user);
    registerInterrupt(0xC, exceptions.stackSegmentFault, .int, .user);
    registerInterrupt(0xD, exceptions.generalProtectionFault, .int, .user);
    registerInterrupt(0xE, exceptions.pageFault, .int, .user);
    registerInterrupt(0x10, exceptions.x87FloatingPoint, .int, .user);
    registerInterrupt(0x11, exceptions.alignmentCheck, .int, .user);
    registerInterrupt(0x12, exceptions.machineCheck, .int, .user);
    registerInterrupt(0x13, exceptions.simdFloatingPoint, .int, .user);
    registerInterrupt(0x14, exceptions.virtualizationException, .int, .user);
    registerInterrupt(0x1E, exceptions.securityException, .int, .user);
}

const Lidr = packed struct {
    size: u16 = 0,
    offset: u64 = 0,
};

pub const GateType = enum(u1) {
    int = 0,
    trap = 1,
};

pub const Ring = enum(u2) {
    supervisor = 0,
    one = 1,
    two = 2,
    user = 3,
};

pub const IdtEntry = packed struct(u128) {
    offset_1: u16 = 0,
    selector: u16 = 0,
    ist: u3 = 0,
    _reserved1: u5 = 0,
    gate_type: GateType = .int,
    _reserved2: u3 = ~@as(u3, 0),
    _reserved3: u1 = 0, // on x86_64 the upper bits of gate arent used
    ring: Ring = .supervisor,
    present: bool = false,
    offset_2: u48 = 0,
    _reserved4: u32 = 0,

    pub fn new(address: u64, gate_type: GateType, ring: Ring) IdtEntry {
        return IdtEntry{
            .offset_1 = @intCast(address & 0xffff),
            .offset_2 = @intCast((address >> 16) & 0xffffffffffff), // Mask to 48 bits
            .selector = 0x28, // This is correct for your GDT setup
            .gate_type = gate_type,
            .ring = ring,
            .present = true,
        };
    }
};

export var context: *volatile Context = undefined;

const idt_size = 256;

var handlers: [idt_size]?*const fn (*volatile Context) void = init: {
    var initial_value: [idt_size]?*const fn (*volatile Context) void = undefined;
    for (0..idt_size) |index| {
        initial_value[index] = null;
    }
    break :init initial_value;
};

export fn interruptDispatch() void {
    if (handlers[context.interrupt_num]) |handler| {
        handler(context);
    } else {
        std.log.err("Unhandled expetion 0x{X} err=0b{b}", .{ context.interrupt_num, @as(u32, @intCast(context.error_code)) });
        @panic("Unhandled exeption");
    }
}

pub const Registers = packed struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    r10: u64 = 0,
    r9: u64 = 0,
    r8: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rbp: u64 = 0,
    rsp: u64 = 0,
    rdx: u64 = 0,
    rcx: u64 = 0,
    rbx: u64 = 0,
    rax: u64 = 0,
};

pub const Context = packed struct {
    registers: Registers,
    // this will be pushed by macro isrGenerate
    interrupt_num: u64,
    // this will be pushed by macro isrGenerate
    error_code: u64,
    // In Long Mode, the error code is padded with zeros to form a 64-bit push, so that it can be popped like any other value.

    // CPU status
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64, // note: this will only be stored when privilege-level change
    ss: u64, // note: this will only be stored when privilege-level change

};

pub var idt: [idt_size]IdtEntry = undefined;

pub fn registerInterrupt(comptime num: u8, handlerFn: fn (*volatile Context) void, gate_type: GateType, ring: Ring) void {
    handlers[num] = handlerFn;

    const handler = comptime scope: {
        const error_code_list = [_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 };

        const push_error = if (for (error_code_list) |value| {
            if (value == num) {
                break true;
            }
        } else false)
            ""
        else
            \\     push $0b10000000000000000
            \\
            ;

        const push_registers = std.fmt.comptimePrint(
            \\     push ${}     // First push the int number
            \\     push %rax    // then push general purpose registers
            \\     push %rbx
            \\     push %rcx
            \\     push %rdx
            \\     push %rsp
            \\     push %rbp
            \\     push %rsi
            \\     push %rdi
            \\     push %r8
            \\     push %r9
            \\     push %r10
            \\     push %r11
            \\     push %r12
            \\     push %r13
            \\     push %r14
            \\     push %r15
            \\     mov %rsp, context
        , .{num});

        const save_status = push_error ++ push_registers;

        const restore_status =
            \\     mov context, %rsp
            \\     pop %r15
            \\     pop %r14
            \\     pop %r13
            \\     pop %r12
            \\     pop %r11
            \\     pop %r10
            \\     pop %r9
            \\     pop %r8
            \\     pop %rdi
            \\     pop %rsi
            \\     pop %rbp
            \\     pop %rsp
            \\     pop %rdx
            \\     pop %rcx
            \\     pop %rbx
            \\     pop %rax
            \\     add $16, %rsp
            \\     iretq
        ;

        break :scope struct {
            fn handle() callconv(.Naked) void {
                asm volatile (save_status ::: "memory");
                asm volatile ("call interruptDispatch");
                asm volatile (restore_status ::: "memory");
            }
        }.handle;
    };

    idt[num] = IdtEntry.new(@intFromPtr(&handler), gate_type, ring);
}
