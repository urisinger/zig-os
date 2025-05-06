pub inline fn getCr3() u64 {
    return asm volatile ("mov %cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn setCr3(pml4: u64) void {
    asm volatile ("mov %[pml], %cr3"
        :
        : [pml] "r" (pml4),
        : "memory"
    );
}

pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub inline fn lidt(idtr: u64) void {
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (idtr),
    );
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [port] "{dx}" (port),
          [value] "{al}" (value),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn readMsr(msr: u64) u64 {
    var high: u64 = undefined;
    const low = asm volatile ("rdmsr"
        : [ret] "={eax}" (-> u32),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (high << 32) | low;
}

pub inline fn writeMsr(msr: u64, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (@as(u32, @intCast(value))),
          [high] "{edx}" (@as(u32, @intCast(value >> 32))),
        : "memory"
    );
}
