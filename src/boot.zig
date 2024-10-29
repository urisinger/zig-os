const limine = @import("limine");

const globals = @import("globals.zig");

export var base_revision: limine.BaseRevision = .{ .revision = 2 };

// We dont need a framebuffer for now, logging is done in serial only
//pub export var framebuffer_request: limine.FramebufferRequest = .{};

export var memory_map_request: limine.MemoryMapRequest = .{};

export var hhdm_request: limine.HhdmRequest = .{};

export var kernel_address_request: limine.KernelAddressRequest = .{};

// These are tempory variables, that wont last when we finish booting
pub const BootParams = struct {
    kernel_base_physical: u64,
    kernel_base_virtual: u64,
    memory_map: []const *const limine.MemoryMapEntry,
};

pub var params: ?BootParams = null;

pub fn init() !void {
    if (!base_revision.is_supported()) {
        @panic("limine revision not supported");
    }

    const mem_map_response = memory_map_request.response.?;
    const mem_map = mem_map_response.entries_ptr[0..mem_map_response.entry_count];

    params = BootParams{
        .memory_map = mem_map,
        .kernel_base_physical = kernel_address_request.response.?.physical_base,
        .kernel_base_virtual = kernel_address_request.response.?.virtual_base,
    };

    @import("std").log.debug("{any}", .{params});

    globals.hhdm_offset = hhdm_request.response.?.offset;

    for (mem_map) |mem_entry| {
        globals.mem_size += mem_entry.length;
    }
}
