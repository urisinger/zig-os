pub const cpu = @import("cpu.zig");
pub const gdt = @import("gdt.zig");
pub const tss = @import("tss.zig");
pub const apic = @import("apic/mod.zig");
pub const idt = @import("idt/mod.zig");
pub const per_cpu = @import("per_cpu.zig");
pub const scheduler = @import("scheduler.zig");

// Generic Architecture API
pub const init = per_cpu.init;
pub const getContext = per_cpu.context;
pub const halt = cpu.halt;
pub const shutdown = cpu.shutdown;
pub const shutdownSuccess = cpu.shutdownSuccess;
pub const jumpToUserMode = scheduler.jumpToUserMode;
pub const writeRedirEntry = apic.writeRedirEntry;
pub const registerInterrupt = idt.idt.registerInterrupt;

pub inline fn entry() void {
    asm volatile (
        \\ cli
        \\ xor %rbp, %rbp
        \\ call kmain
        \\ ud2
    );
}

extern fn kmain() noreturn;
