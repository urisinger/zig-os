export fn _start() callconv(.Naked) noreturn {
    while (true) {
        asm volatile ("syscall");
    }
    @call(.{}, main, .{});
}

fn main() void {
    while (true) {
        asm volatile ("syscall");
    }
}
