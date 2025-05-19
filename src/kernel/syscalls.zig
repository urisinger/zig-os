const std = @import("std");

pub export fn testSyscall(arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) callconv(.SysV) u64 {
    _ = arg1;
    _ = arg2;
    _ = arg3;
    _ = arg4;
    _ = arg5;
    _ = arg6;
    return 0;
}
