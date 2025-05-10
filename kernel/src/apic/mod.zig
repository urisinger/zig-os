const cpu = @import("../cpu.zig");
const globals = @import("../globals.zig");
const std = @import("std");

const vmm = @import("../memory/kernel/vmm.zig");

const paging = @import("../memory/paging.zig");

const IA32_APIC_BASE = 0x1B;
const APIC_BASE_MASK = 0xFFFFF000;
const APIC_BASE_TOP = 0xFEE00000;
const APIC_ENABLE_BIT = 1 << 11;

const SPURIOUS_INTERRUPT_REGISTER = 0xF;

const LVT_TIMER_REGISTER = 0x32;
const TIMER_DIV_REGISTER = 0x3E;
const TIMER_INITIAL_COUNT = 0x38;

const TIME_PERIODIC = 0x20000;

const IOAPICID = 0x00;
const IOAPICVER = 0x01;
const IOAPICARB = 0x02;

const DeliveryMode = enum(u3) {
    Fixed = 0b000,
    LowPriority = 0b001,
    SMI = 0b010,
    NMI = 0b100,
    INIT = 0b101,
    ExtINT = 0b111,
};

const DestinationMode = enum(u1) {
    Physical = 0,
    Logical = 1,
};

var apic_id: u8 = 0;
var apic_ver: u32 = 0;
var redir_entry_count: u32 = 0;

const RedirectionEntry = packed struct {
    vector: u8,
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    delivery_status: u1 = 0,
    pin_polarity: u1,
    remote_IRR: u1,
    trigger_mode: u1,
    mask: u1,
    reserved: u39 = 0,
    destination: u8,
};

const IOAPIC_DEFAULT_ADDR = 0xFEC00000;

var apicBase: ?[*]volatile u32 = null;
var ioApicBase: ?[*]volatile u32 = null;

pub fn enableLocalApic() !void {
    asm volatile ("xchg %bx, %bx");
    var base = cpu.readMsr(IA32_APIC_BASE);
    base |= APIC_ENABLE_BIT;
    cpu.writeMsr(IA32_APIC_BASE, base);
    const apic_page_addr = try vmm.allocatePage();

    try paging.mapPage(@bitCast(apic_page_addr), (base & APIC_BASE_MASK) | APIC_BASE_TOP, .{.present = true, .read_write = .read_write, .cache_disable = true});

    apicBase = @ptrFromInt(apic_page_addr);

    const ioapic_page_addr = try vmm.allocatePage();

    try paging.mapPage(@bitCast(ioapic_page_addr), IOAPIC_DEFAULT_ADDR, .{.present = true, .read_write = .read_write, .cache_disable =  true});

    ioApicBase = @ptrFromInt(ioapic_page_addr);
}

pub inline fn writeRegister(reg: u32, value: u32) void {
    apicBase.?[reg * 4] = value;
}

pub inline fn readRegister(reg: u32) u32 {
    return apicBase.?[reg * 4];
}

pub inline fn writeIoRegister(reg: u32, value: u32) void {
    ioApicBase.?[0] = reg;
    ioApicBase.?[4] = value;
}

pub inline fn readIoRegister(reg: u32) u32 {
    ioApicBase.?[0] = reg;
    return ioApicBase.?[4]; 
}

pub inline fn sendEoi() void{
    writeRegister(0xB, 0);
}

pub inline fn writeRedirEntry(entry_num: u8, entry: RedirectionEntry) void {
    const entry_u64: u64 = @bitCast(entry);
    writeIoRegister(0x10 + @as(u32, @intCast(entry_num)) * 2 + 1, @intCast(entry_u64 >> 32));

    writeIoRegister(0x10 + @as(u32, @intCast(entry_num)) * 2, @intCast(entry_u64));
}


pub fn configureLocalApic() !void {
    // Enable the Local APIC by setting the appropriate MSR bit
    try enableLocalApic();

    // Disable legacy PIC interrupts by masking all interrupts (0xFF) on both PICs (master/slave)
    cpu.outb(0xA1, 0xff); // Slave PIC
    cpu.outb(0x21, 0xff); // Master PIC

    // Set the Spurious Interrupt Vector Register to vector 0xFF with the APIC software enable bit (bit 8)
    writeRegister(SPURIOUS_INTERRUPT_REGISTER, 0x100 | 0xFF);

    // Read the APIC ID from the IOAPICID register (bits 24–27 hold the ID)
    apic_id = @intCast((readIoRegister(IOAPICID) >> 24) & 0xF0);

    // Read the IOAPIC version from the IOAPICVER register
    apic_ver = @intCast(readIoRegister(IOAPICVER));

    // Determine how many redirection entries the IOAPIC supports (bits 16–23 + 1)
    redir_entry_count = (readIoRegister(IOAPICVER) >> 16) + 1;

    // Log the detected APIC ID, version, and redirection entry count
    std.log.info("apic_ID: 0x{x}, apic_ver: 0x{x}", .{ apic_id, apic_ver});

    // Configure a redirection entry for IRQ 1 (typically keyboard) to vector 0x20 (interrupt handler)
    writeRedirEntry(0x1, RedirectionEntry{
        .vector = 0x20,                  // Interrupt vector number
        .delivery_mode = .Fixed,        // Fixed delivery mode (normal interrupt)
        .destination_mode = .Physical,  // Physical destination mode
        .pin_polarity = 0,              // Active high
        .remote_IRR = 0,                // Initially 0 (not pending)
        .trigger_mode = 1,              // Level-triggered
        .mask = 0,                      // Unmasked (enabled)
        .destination = apic_id,         // Destination APIC ID (this processor)
    });

}
