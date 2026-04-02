pub const pmm = @import("pmm.zig");
pub const page_table = @import("page_table.zig");
pub const buddy = @import("buddyy.zig");
pub const kernel = struct {
    pub const heap = @import("kernel/heap.zig");
    pub const paging = @import("kernel/paging.zig");
    pub const slab = @import("kernel/slab.zig");
    pub const slab_allocator = @import("kernel/slab_allocator.zig");
};
pub const user = struct {
    pub const heap = @import("user/heap.zig");
    pub const vmm = @import("user/vmm.zig");
};
