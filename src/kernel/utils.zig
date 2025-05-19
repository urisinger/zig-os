const std = @import("std");
const builtin = @import("builtin");
const cpu = @import("cpu.zig");
const root = @import("root");

// 4kb
pub const PAGE_SIZE = KB(4);

// 2mb
pub const LARGE_PAGE_SIZE = MB(2);

pub const BYTES_PER_KB = 1024;
pub const BYTES_PER_MB = 1024 * 1024;
pub const BYTES_PER_GB = 1024 * 1024 * 1024;

pub fn KB(kb: u64) u64 {
    return kb * BYTES_PER_KB;
}

pub fn MB(mb: u64) u64 {
    return mb * BYTES_PER_MB;
}

pub fn GB(gb: u64) u64 {
    return gb * BYTES_PER_GB;
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);
    const log = std.log.scoped(.panic);

    const name =
        if (@hasDecl(root, "name")) root.name else "<unknown>";
    log.err("{s} panicked: {s}\nstack trace:", .{ name, msg });

    cpu.halt();
    var iter = std.debug.StackIterator.init(@returnAddress(), @frameAddress());
    while (iter.next()) |addr| {
        log.err("  0x{x}", .{addr});
    }
}
