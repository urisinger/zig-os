const std = @import("std");

// --- CBIP Definitions (Must match kernel) ---

/// The structure of the Interface Info returned by the kernel
pub const InterfaceInfo = struct {
    id: u64,
    vtable_len: u64,
};

/// The Stream interface layout (logical indices)
/// Index 0: read
/// Index 1: write
pub const Stream = struct {
    pub const ID = 0xb33e307ab5e8ffa6; // You should use your actual hash here
    pub const FN_WRITE = 0;
};

// --- Syscall Infrastructure ---

const SyscallNum = enum(u64) {
    open = 0,
    call = 1
};

/// Executes a raw syscall with 6 arguments
fn syscall6(num: SyscallNum, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(num)),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}" (a5),
          [a6] "{r9}" (a6),
        : .{
          .rcx = true,
          .r11 = true,
          .memory = true,
        });
}

// --- High Level User Wrappers ---

pub fn open(path: []const u8, id: u64) !u64 {
    const res = syscall6(.open, @intFromPtr(path.ptr), path.len, id, 0, 0, 0);
    if (res == 0xFFFFFFFFFFFFFFFF) return error.FileNotFound;
    return res;
}

pub fn getInterfaceInfo(fd: u64, id: u64) !InterfaceInfo {
    var info: InterfaceInfo = undefined;
    const res = syscall6(.get_interface_info, fd, id, @intFromPtr(&info), 0, 0, 0);
    if (res != 0) return error.InterfaceNotFound;
    return info;
}

pub fn streamWrite(fd: u64, data: []const u8) u64 {
    return syscall6(.call, fd, Stream.FN_WRITE, @intFromPtr(data.ptr), data.len, 0, 0);
}

// --- Main Program Entry ---

pub export fn main() void {
    const device_path = "/dev/serial";
    const hello_msg = "CBIP Syscall Demo: Hello from Userspace!\n";

    // 1. Open the serial vnode
    const fd = open(device_path, Stream.ID) catch {
        // We can't use std.debug.print if we don't have a working OS env,
        // but for a demo, we assume success or hang.
        return;
    };

    // 4. Perform the call
    _ = streamWrite(fd, hello_msg);
}

export fn _start() noreturn {
    @setRuntimeSafety(false);
    asm volatile (
        \\ # 1. Align the stack to 16 bytes and provide a 'null' stack frame
        \\ # RSP was 0x200000, subtracting 8 makes it 0x1FFFF8.
        \\ # This satisfies alignment for the subsequent 'call'.
        \\ andq $-16, %rsp
        \\
        \\ # 2. Call our main logic
        \\ call main
        \\
        \\ # 3. If main returns, trigger exit syscall (Syscall 60)
        \\ movq $60, %rax
        \\ xorq %rdi, %rdi
        \\ syscall
        \\
        \\ # 4. Fallback hang
        \\ 1: nop 
        \\ jmp 1b
    );
    unreachable;
}
