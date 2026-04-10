const lapic = @import("lapic.zig");
const ioapic = @import("ioapic.zig");

const instr = @import("../instr.zig");
const root = @import("root");
const globals = root.common.globals;
const paging = root.mem.kernel.paging;

const IOAPIC_PBASE = 0xFEC00000;

pub fn init() !void {
    // 1. Get the LAPIC Physical Base from the MSR
    const msr_val = instr.readMsr(0x1B);
    const lapic_pbase = msr_val & 0xFFFFF000;

    // 2. Ensure these pages are mapped in your kernel page tables
    const lapic_vaddr = lapic_pbase + globals.hhdm_offset;
    const ioapic_vaddr = IOAPIC_PBASE + globals.hhdm_offset;

    try paging.mapPage(@bitCast(lapic_vaddr), lapic_pbase, .{
        .present = true,
        .read_write = .read_write,
        .cache_disable = true, 
    });

    try paging.mapPage(@bitCast(ioapic_vaddr), IOAPIC_PBASE, .{
        .present = true,
        .read_write = .read_write,
        .cache_disable = true,
    });

    // 3. Initialize the modules
    lapic.init(lapic_vaddr);
    ioapic.init(ioapic_vaddr);
    lapic.calibrate();
    
    // 4. Disable the old 8259 PIC
    instr.outb(0xA1, 0xFF);
    instr.outb(0x21, 0xFF);
}
