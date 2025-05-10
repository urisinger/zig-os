const std = @import("std");

pub const Region = struct {
    base: u64,
    size: u64,
    next: ?*Region = null,
    prev: ?*Region = null,
};

pub const VmAllocator = struct {
    head: ?*Region = null,
    tail: ?*Region = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, base: u64, size: u64) VmAllocator {
        const region = allocator.create(Region) catch unreachable;

        region.* = .{ .base = base, .size = size, .next = null, .prev = null };

        return .{ .head = region, .tail = region, .allocator = allocator };
    }

    pub fn alloc(self: *VmAllocator, size: usize, alignment: usize) ?usize {
        var current = self.head;

        while (current) |r| {
            const aligned_base = std.mem.alignForward(usize, r.base, alignment);
            const padding = aligned_base - r.base;

            if (r.size >= padding + size) {
                const alloc_base = aligned_base;
                const alloc_end = alloc_base + size;

                // Remove region or shrink it
                if (padding + size == r.size) {
                    if (r.prev) |p| {
                        p.next = r.next;
                    } else {
                        self.head = r.next;
                    }

                    if (r.next) |n| {
                        n.prev = r.prev;
                    } else {
                        self.tail = r.prev;
                    }

                    self.allocator.destroy(r);
                } else {
                    r.base = alloc_end;
                    r.size -= padding + size;
                }

                return alloc_base;
            }

            current = r.next;
        }

        return null;
    }

    pub fn destroy(self: *VmAllocator) void {
        var current = self.head;
    
        while (current) |region| {
            const next = region.next;
            self.allocator.destroy(region);
            current = next;
        }
    
        self.head = null;
        self.tail = null;
    }

    pub fn free(self: *VmAllocator, addr: usize, size: usize) void {
        const new_region = self.allocator.create(Region) catch unreachable;
        new_region.* = .{ .base = addr, .size = size, .next = null, .prev = null };

        // Insert in sorted order
        if (self.head == null or addr < self.head.?.base) {
            new_region.next = self.head;
            if (self.head) |h| h.prev = new_region;
            self.head = new_region;
            if (self.tail == null) self.tail = new_region;
        } else {
            var current = self.head;
            while (current.?.next) |next| {
                if (addr < next.base) break;
                current = next;
            }

            new_region.next = current.?.next;
            if (current.?.next) |n| n.prev = new_region;

            new_region.prev = current;
            current.?.next = new_region;

            if (new_region.next == null)
                self.tail = new_region;
        }

        // Merge forward
        var r = new_region;
        while (r.next != null and r.base + r.size == r.next.?.base) {
            const next = r.next.?;
            r.size += next.size;
            r.next = next.next;
            if (next.next) |n| n.prev = r;
            if (self.tail == next) self.tail = r;
            self.allocator.destroy(next);
        }

        // Merge backward
        if (r.prev != null and r.prev.?.base + r.prev.?.size == r.base) {
            const prev = r.prev.?;
            prev.size += r.size;
            prev.next = r.next;
            if (r.next) |n| n.prev = prev;
            if (self.tail == r) self.tail = prev;
            self.allocator.destroy(r);
        }
    }
};

const PAGE = 4096;

const testing = std.testing;

fn initAllocator() !VmAllocator {
    return VmAllocator.init(std.testing.allocator, 0x100000, 64 * PAGE);
}

test "basic allocation works" {
    var vm = try initAllocator();
    const addr = vm.alloc(PAGE, PAGE).?;
    try testing.expect(addr >= 0x100000);
    vm.destroy();
}

test "alignment is respected" {
    var vm = try initAllocator();
    const addr = vm.alloc(PAGE, PAGE * 4).?;
    try testing.expect(addr % (PAGE * 4) == 0);
    vm.destroy();
}

test "free merges forward" {
    var vm = try initAllocator();
    const a = vm.alloc(PAGE, PAGE).?;
    const b = vm.alloc(PAGE, PAGE).?;
    vm.free(a, PAGE);
    vm.free(b, PAGE);
    const merged = vm.alloc(2 * PAGE, PAGE);
    try testing.expect(merged == a);
    vm.destroy();
}

test "free merges backward" {
    var vm = try initAllocator();
    const a = vm.alloc(PAGE, PAGE).?;
    const b = vm.alloc(PAGE, PAGE).?;
    vm.free(b, PAGE);
    vm.free(a, PAGE);
    const merged = vm.alloc(2 * PAGE, PAGE);
    try testing.expect(merged == a);
    vm.destroy();
}

test "free merges both directions" {
    var vm = try initAllocator();
    const a = vm.alloc(PAGE, PAGE).?;
    const b = vm.alloc(PAGE, PAGE).?;
    const c = vm.alloc(PAGE, PAGE).?;
    vm.free(a, PAGE);
    vm.free(c, PAGE);
    vm.free(b, PAGE);
    const merged = vm.alloc(3 * PAGE, PAGE);
    try testing.expect(merged == a);
    vm.destroy();
}

test "full range reuse after free" {
    var vm = try initAllocator();
    const base = vm.alloc(64 * PAGE, PAGE).?;
    vm.free(base, 64 * PAGE);
    const again = vm.alloc(64 * PAGE, PAGE).?;
    try testing.expect(again == base);
    vm.destroy();
}

test "out of memory returns null" {
    var vm = try initAllocator();
    _ = vm.alloc(64 * PAGE, PAGE).?;
    const fail = vm.alloc(PAGE, PAGE);
    try testing.expect(fail == null);
    vm.destroy();
}
