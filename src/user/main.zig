export fn _start() callconv(.Naked) noreturn {
    while (true) {
        _ = syscall(
            0,
            1,
            2,
            3,
            4,
            5,
            6,
        );
    }
}

inline fn syscall(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [syscall_num] "{rax}" (syscall_num),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
          [arg6] "{r9}" (arg6),
        : "memory", "r11", "r12", "r13", "r14", "r15"
    );
}
