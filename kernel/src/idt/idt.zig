const std = @import("std");
const utils = @import("../utils.zig");
const gdt = @import("../gdt.zig");

const exceptions = @import("interrupts/exceptions.zig");

const cpu = @import("../cpu.zig");

const irq = @import("interrupts/irq.zig");
const scheduler = @import("../scheduler/scheduler.zig");

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
    registerInterrupt(0x3, exceptions.breakpoint, .int, .user);
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

    registerInterrupt(0x20, irq.irq1, .int, .user);
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
            .offset_1 = @truncate(address),
            .offset_2 = @truncate((address >> 16)), // Mask to 48 bits
            .selector = 0x8, 
            .gate_type = gate_type,
            .ring = ring,
            .present = true,
        };
    }
};

const idt_size = 256;

var handlers: [idt_size]?*const fn (*volatile Context) void = init: {
    var initial_value: [idt_size]?*const fn (*volatile Context) void = undefined;
    for (0..idt_size) |index| {
        initial_value[index] = null;
    }
    break :init initial_value;
};

export fn interruptDispatch(context: *Context) callconv(.SysV) *Context {
    scheduler.saveContext(context);
    if (handlers[context.interrupt_num]) |handler| {
        handler(context);
    } else {
        std.log.err("Unhandled expetion 0x{X} err=0b{b}", .{ context.interrupt_num, @as(u32, @intCast(context.error_code)) });
        @panic("Unhandled exeption");
    }
    return scheduler.schedulerTick();
}

pub const Registers = packed struct {
    r15: u64 = 15,
    r14: u64 = 14,
    r13: u64 = 13,
    r12: u64 = 12,
    r11: u64 = 11,
    r10: u64 = 10,
    r9: u64 = 9,
    r8: u64 = 8,
    rdi: u64 = 7,
    rsi: u64 = 6,
    rbp: u64 = 5,
    rdx: u64 = 4,
    rcx: u64 = 3,
    rbx: u64 = 2,
    rax: u64 = 1,
};

const IretFrame = packed struct {
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const Context = packed struct {
    registers: Registers,
    // this will be pushed by macro isrGenerate
    interrupt_num: u64,
    // this will be pushed by macro isrGenerate
    error_code: u64,
    // In Long Mode, the error code is padded with zeros to form a 64-bit push, so that it can be popped like any other value.

    // CPU status
    ret_frame: IretFrame,
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
            "push $0b10000000000000000\n";

        const push_num = std.fmt.comptimePrint(
            "push ${} \n"
        , .{num});

        break :scope struct {
            fn handle() callconv(.Naked) void {
                cpu.swapgs_if_necessary();

                asm volatile (push_error ++ push_num);
                cpu.push_gpr();

                asm volatile (
                    \\ xchg %bx, %bx
                   \\ mov $0x10, %ax 
                   \\ mov %ax, %ds
                   \\ mov %ax, %es

                   \\ mov %rsp, %rdi
                   \\ call interruptDispatch
                   \\ mov %rax, %rsp

                   \\ mov $0x1B, %ax 
                   \\ mov %ax, %ds
                   \\ mov %ax, %es 
                );

                cpu.pop_gpr(); 
                asm volatile ("add $16, %rsp");

                cpu.swapgs_if_necessary();

                asm volatile ("iretq");
            }
        }.handle;
    };

    idt[num] = IdtEntry.new(@intFromPtr(&handler), gate_type, ring);
}
