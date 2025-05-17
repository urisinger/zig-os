export fn _start() callconv(.Naked) noreturn {
    while (true) {
        asm volatile ("syscall");
    }
}
