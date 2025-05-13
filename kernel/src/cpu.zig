pub inline fn getCr3() u64 {
    return asm volatile ("mov %cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn setCr3(pml4: u64) void {
    asm volatile ("mov %[pml4], %cr3"
        :
        : [pml4] "r" (pml4),
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
        : "memory"
    );
}

pub inline fn lgdt(gdtr: u64) void {
    asm volatile ("lgdt (%[gdtr])"
        :
        : [gdtr] "r" (gdtr),
        : "memory"
    );
}

pub inline fn getRsp() u64 {
    return asm volatile ("mov %rsp, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn ltr(selector: u16) void {
    asm volatile ("ltr %ax"
        :
        : [sel] "{ax}" (selector),
        : "memory"
    );
}

pub inline fn invlpg(page: u64) void {
    const ptr: *const u8 = @ptrFromInt(page);
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (ptr),
        : "memory"
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

pub fn swapgs_if_necessary() callconv(.Inline) void{
       asm volatile(
        \\ cmpw $0x08, 0x8(%rsp)
        \\ je 1f 
        \\ swapgs
        \\ 1:
       :::);
}

pub fn push_gpr() callconv(.Inline) void{
       asm volatile(
        \\     push %rax
        \\     push %rbx
        \\     push %rcx
        \\     push %rdx
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
        :::);
}

pub fn pop_gpr() callconv(.Inline) void{
    asm volatile( 
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
        \\     pop %rdx
        \\     pop %rcx
        \\     pop %rbx
        \\     pop %rax
        :::);
}

pub inline fn writeMsr(msr: u64, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @intCast(value >> 32))),
        : "memory"
    );
}
