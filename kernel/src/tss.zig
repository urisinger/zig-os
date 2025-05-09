pub const Tss = packed struct {
    reserved1: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved2: u64 = 0,
    ist0: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    reserved3: u64 = 0,
    reserved4: u16 = 0,
    iomap_base: u16 = 0,
};

pub var tss: Tss align(16) = .{};

pub fn set_rsp(rsp: u64) void{
    tss.rsp0 = rsp;
}
