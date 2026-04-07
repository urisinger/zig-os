const std = @import("std");
const log = std.log.scoped(.idt);

const root = @import("root");
const arch = root.arch;
const gdt = arch.gdt;
const context_mod = arch.context;
const Context = context_mod.Context;

const handlers_mod = @import("handlers.zig");
const instr = @import("../instr.zig");

pub fn init() void {
    registerExeptions();
    const idtr = Lidr{
        .size = @intCast((idt.len * @sizeOf(IdtEntry))),
        .offset = @intFromPtr(&idt),
    };

    instr.lidt(@intFromPtr(&idtr));
}

fn registerExeptions() void {
    registerInterrupt(0x0, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x1, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x2, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x3, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x5, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x6, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x7, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x8, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x9, handlers_mod.handleException, .int, .user);
    registerInterrupt(0xA, handlers_mod.handleException, .int, .user);
    registerInterrupt(0xB, handlers_mod.handleException, .int, .user);
    registerInterrupt(0xC, handlers_mod.handleException, .int, .user);
    registerInterrupt(0xD, handlers_mod.handleException, .int, .user);
    registerInterrupt(0xE, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x10, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x11, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x12, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x13, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x14, handlers_mod.handleException, .int, .user);
    registerInterrupt(0x1E, handlers_mod.handleException, .int, .user);
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
    _reserved3: u1 = 0,
    ring: Ring = .supervisor,
    present: bool = false,
    offset_2: u48 = 0,
    _reserved4: u32 = 0,

    pub fn new(address: u64, gate_type: GateType, ring: Ring) IdtEntry {
        return IdtEntry{
            .offset_1 = @truncate(address),
            .offset_2 = @truncate((address >> 16)),
            .selector = 0x8,
            .gate_type = gate_type,
            .ring = ring,
            .present = true,
        };
    }
};

const idt_size = 256;
pub var idt: [idt_size]IdtEntry = undefined;

pub fn registerInterrupt(comptime num: u8, handlerFn: fn (*volatile Context) void, gate_type: GateType, ring: Ring) void {
    context_mod.handlers[num] = handlerFn;

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

        const push_num = std.fmt.comptimePrint("push ${} \n", .{num});

        break :scope struct {
            fn handle() callconv(.naked) void {
                instr.swapgs_if_necessary();

                asm volatile (push_error ++ push_num);
                instr.pushGpr();

                asm volatile (
                    \\ xor %rbp, %rbp
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

                instr.popGpr();
                asm volatile ("add $16, %rsp");

                instr.swapgs_if_necessary();

                asm volatile ("iretq");
            }
        }.handle;
    };

    idt[num] = IdtEntry.new(@intFromPtr(&handler), gate_type, ring);
}
