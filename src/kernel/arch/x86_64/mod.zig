pub const instr = @import("instr.zig");
pub const gdt = @import("gdt.zig");
pub const tss = @import("tss.zig");
pub const apic = @import("apic/mod.zig");
pub const lapic = @import("apic/lapic.zig");
pub const ioapic = @import("apic/ioapic.zig");
pub const idt = @import("idt/mod.zig");
pub const pcpu = @import("pcpu.zig");
pub const context = @import("context.zig");

// Generic Architecture API
pub const init = pcpu.init;
pub const getContext = pcpu.context;
pub const halt = instr.halt;
pub const shutdown = instr.shutdown;
pub const shutdownSuccess = instr.shutdownSuccess;
pub const setRedirEntry = ioapic.setRedirEntry;
pub const registerInterrupt = idt.table.registerInterrupt;
pub const jumpToUserTask = context.jumpToUserTask;
pub const jumpToKernelTask = context.jumpToKernelTask;

pub inline fn entry() void {
    asm volatile (
        \\ cli
        \\ xor %rbp, %rbp
        \\ call kmain
        \\ ud2
    );
}

extern fn kmain() noreturn;
