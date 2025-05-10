const std = @import("std");

pub const Region = struct {
    base: usize,
    size: usize,
    next: ?*Region = null,
};

pub const VmAllocator = struct {
    head: ?*Region = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, base: usize, size: usize) VmAllocator {
        const region = allocator.create(Region) catch unreachable;
        region.* = .{ .base = base, .size = size, .next = null };
        return .{ .head = region, .allocator = allocator };
    }

    pub fn alloc(self: *VmAllocator, size: usize, alignment: usize) ?usize {
        var current = self.head;
        var prev: ?*Region = null;

        while (current) |r| {
            const aligned_base = std.mem.alignForward(usize, r.base, alignment);
            const padding = aligned_base - r.base;
            if (r.size >= padding + size) {
                const alloc_base = aligned_base;
                const alloc_end = alloc_base + size;

                // shrink region or split
                if (padding + size == r.size) {
                    if (prev) |p| {
                        p.next = r.next;
                    } else {
                        self.head = r.next;
                    }
                    self.allocator.destroy(r);
                } else {
                    r.base = alloc_end;
                    r.size -= padding + size;
                }

                return alloc_base;
            }

            prev = r;
            current = r.next;
        }

        return null;
    }

    pub fn free(self: *VmAllocator, addr: usize, size: usize) void {
        const new_region = self.allocator.create(Region) catch unreachable;
        new_region.* = .{ .base = addr, .size = size, .next = null };

        if (self.head == null or addr < self.head.?.base) {
            new_region.next = self.head;
            self.head = new_region;
        } else {
            var current = self.head;
            while (current.?.next) |next| {
                if (addr < next.base) break;
                current = current.?.next;
            }

            new_region.next = current.?.next;
            current.?.next = new_region;
        }

        // Merge adjacent regions
        var current = self.head;
        while (current) |r| {
            var next = r.next;
            while (next != null and r.base + r.size == next.base) {
                r.size += next.size;
                r.next = next.next;
                self.allocator.destroy(next);
                next = r.next;
            }
            current = r.next;
        }
    }
};
