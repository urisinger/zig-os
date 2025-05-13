export fn _start() callconv(.C) noreturn {
    while (true){
        asm volatile("syscall");
    }
}
