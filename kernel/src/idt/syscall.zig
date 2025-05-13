const std = @import("std");
pub export fn syscall_dispatch() callconv(.SysV) void {
    std.log.info("hi", .{});
}

pub fn syscall_handler() callconv(.Naked) void {
    asm volatile  (
        \\ swapgs                  ; switch GS base to kernel
        \\ push %r11                ; save RFLAGS
        \\ push %rcx                ; save RIP (return address)
        \\ ; Save other registers if needed
        \\ ; Call syscall dispatch: syscall number in rax
        \\ call syscall_dispatch
        \\ ; Return value now in rax
        \\ pop %rcx                 ; restore return RIP
        \\ pop %r11                 ; restore RFLAGS
        \\ swapgs                  ; restore GS base to user
        \\ sysretq
    );
}

pub fn init() void{

}
