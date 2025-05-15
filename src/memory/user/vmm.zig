const std = @import("std");

pub const Permissions = enum { Read, ReadWrite, ReadExecute };

pub const Attr = struct {
    permissions: Permissions,
};

pub const Region = struct {
    start: u64,
    end: u64,

    attr: Attr,

    pub fn size(self: Region) u64 {
        return self.end - self.start;
    }
};

pub const Color = enum { Red, Black };

const Dir = enum {
    Left,
    Right,

    fn opposite(self: Dir) Dir {
        return switch (self) {
            .Left => .Right,
            .Right => .Left,
        };
    }
};

pub const Node = struct {
    region: Region,

    left: ?*Node = null,
    right: ?*Node = null,
    parent: ?*Node = null,
    color: Color = .Red,

    pub fn iter(self: *Node) InOrderIterator {
        return InOrderIterator.init(self);
    }

    pub fn node(self: *Node, dir: Dir) *?*Node {
        return switch (dir) {
            .Left => &self.left,
            .Right => &self.right,
        };
    }

    pub fn direction(self: *Node) Dir {
        return if (self.parent.?.left == self) .Left else .Right;
    }

    pub fn sibling(self: *Node) ?*Node {
        return if (self.parent) |parent| if (parent.left == self) parent.right else parent.left else null;
    }

    pub fn grandparent(self: *Node) ?*Node {
        return if (self.parent) |parent| parent.parent else null;
    }
};

pub const InOrderIterator = struct {
    current: ?*Node,

    pub fn init(root: ?*Node) InOrderIterator {
        var node = root;
        // Walk to the leftmost node (smallest)
        while (node != null and node.?.left != null) {
            node = node.?.left;
        }
        return InOrderIterator{ .current = node };
    }

    pub fn next(self: *InOrderIterator) ?*Node {
        const result = self.current;
        if (result == null) return null;

        if (result.?.right != null) {
            // Move to leftmost node in right subtree
            var node = result.?.right;
            while (node.?.left != null) {
                node = node.?.left;
            }
            self.current = node;
        } else {
            // Walk up until we come from left
            var node = result.?;
            while (node.parent != null and node.parent.?.right == node) {
                node = node.parent.?;
            }
            self.current = node.parent;
        }

        return result;
    }
};

pub const VmAllocator = struct {
    root: ?*Node,
    start: u64,
    end: u64,
    allocator: std.mem.Allocator,

    pub fn format(self: VmAllocator, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("VmAllocator:\n", .{});
        try self.format_recursive(self.root, 0, writer);
    }

    fn format_recursive(self: VmAllocator, node: ?*Node, depth: usize, writer: anytype) !void {
        if (node == null) return;

        const n = node.?;

        try self.format_recursive(n.left, depth + 1, writer);

        try writer.print("[{x}-{x}) size={} attr={}\n", .{ n.region.start, n.region.end, n.region.size(), n.region.attr });

        try self.format_recursive(n.right, depth + 1, writer);
    }

    pub fn init(allocator: std.mem.Allocator, start: u64, size: u64) VmAllocator {
        return VmAllocator{
            .root = null,
            .allocator = allocator,
            .start = start,
            .end = start + size,
        };
    }

    pub fn deinit(self: *VmAllocator) void {
        if (self.root) |root| {
            self.free(root);
        }
    }

    fn free(self: *VmAllocator, node: *Node) void {
        if (node.left) |left| {
            self.free(left);
        }

        if (node.right) |right| {
            self.free(right);
        }

        self.allocator.destroy(node);
    }

    pub fn find_node(self: *VmAllocator, addr: u64) ?*Node {
        var current = self.root;
        while (current) |node| {
            if (addr >= node.region.start and addr < node.region.end) return node;
            current = if (addr < node.region.start) node.left else node.right;
        }
        return null;
    }

    pub fn allocate_address(self: *VmAllocator, base: u64, size: u64, attr: Attr) !void {
        if (base < self.start or base + size > self.end) return error.InvalidAddress;
        const region = Region{ .start = base, .end = base + size, .attr = attr };
        try self.insert_region(region);
    }

    pub fn allocate(self: *VmAllocator, size: u64, alignment: u64, attr: Attr) !u64 {
        var iter = InOrderIterator.init(self.root);
        var prev_end: u64 = self.start;

        while (iter.next()) |node| {
            const gap_start = prev_end;
            const gap_end = node.region.start;

            const aligned = std.mem.alignForward(u64, gap_start, alignment);
            if (aligned + size > self.end) return error.NoFreeMemory;
            if (aligned + size <= gap_end) {
                const region = Region{ .start = aligned, .end = aligned + size, .attr = attr };
                try self.insert_region(region);
                return aligned;
            }

            prev_end = node.region.end;
        }

        // Check gap after the last node
        const aligned = std.mem.alignForward(u64, prev_end, alignment);
        if (aligned + size > self.end) return error.NoFreeMemory;
        const region = Region{ .start = aligned, .end = aligned + size, .attr = attr };
        try self.insert_region(region);
        return aligned;
    }

    pub fn insert_region(self: *VmAllocator, region: Region) !void {
        const node = try self.allocator.create(Node);
        node.* = .{
            .region = region,
        };

        if (self.root == null) {
            self.root = node;
            node.color = .Black;
            return;
        }

        var parent: *Node = self.root.?;
        var current: ?*Node = parent;
        var dir: Dir = .Left;

        while (current) |n| {
            parent = n;

            const r1 = region;
            const r2 = n.region;

            const overlaps = !(r1.end <= r2.start or r1.start >= r2.end);
            if (overlaps) return error.OverlappingRegion;

            if (region.start < r2.start) {
                current = n.left;
                dir = .Left;
            } else {
                current = n.right;
                dir = .Right;
            }
        }

        node.parent = parent;
        self.insert_at(node, dir);
    }

    fn insert_at(self: *VmAllocator, node: *Node, dir: Dir) void {
        node.color = .Red;

        if (node.parent) |p| {
            p.node(dir).* = node;
        } else {
            self.root = node;
            return;
        }

        var current = node;
        while (current.parent) |parent| {
            if (parent.color == .Black) return;

            const grandparent = if (parent.grandparent()) |gp| gp else {
                parent.color = .Black;
                return;
            };

            const parent_dir = parent.direction();
            const uncle = grandparent.node(parent_dir.opposite()).*;

            // Case 1: Red uncle - just recolor
            if (uncle != null and uncle.?.color == .Red) {
                uncle.?.color = .Black;
                parent.color = .Black;
                grandparent.color = .Red;
                current = grandparent;
                continue;
            }

            var p = parent;
            // Case 2: Black uncle - need rotations
            if (current == parent.node(parent_dir.opposite()).*) {
                _ = self.rotate(parent, parent_dir);
                current = parent;
                p = current;
            }

            _ = self.rotate(grandparent, parent_dir.opposite());
            p.color = .Black;
            grandparent.color = .Red;
            return;
        }

        // Color root black
        if (current.parent == null) {
            current.color = .Black;
        }
    }

    pub fn delete(self: *VmAllocator, node: *Node) *Node {
        if (node.parent == null) {
            self.root = null;
            return node;
        }

        var dir = node.direction();
        var to_remove = node;

        // Case 1: Node has two children
        if (node.left != null and node.right != null) {
            // Find successor (leftmost in right subtree)
            var successor = node.right.?;
            while (successor.left) |left| {
                successor = left;
            }

            // Swap the nodes' regions
            const temp = node.region;
            node.region = successor.region;
            successor.region = temp;

            // Now delete the successor instead (which has at most one child)
            to_remove = successor;
            dir = if (successor.parent.? == node) .Right else .Left;
        }

        // At this point, to_remove has at most one child
        const child = if (to_remove.left) |left| left else to_remove.right;

        // Case 2: Node has one child
        if (child) |c| {
            c.parent = to_remove.parent;
            c.color = .Black;
            to_remove.parent.?.node(dir).* = c;
            return to_remove;
        }

        // Case 3: Node is root with no children (handled above)
        // Case 4: Node is red with no children
        if (to_remove.color == .Red) {
            to_remove.parent.?.node(dir).* = null;
            return to_remove;
        }

        // Case 5: Node is black with no children
        // Remove node and rebalance
        to_remove.parent.?.node(dir).* = null;

        var current = to_remove.parent.?;
        dir = to_remove.direction();

        // Do rebalancing...
        while (current.parent) |parent| {
            var sibling = parent.sibling();
            var distant_nephew = sibling.?.node(dir.opposite()).*;
            const close_nephew = sibling.?.node(dir).*;
            if (sibling.?.color == .Red) {
                _ = self.rotate(parent, dir);
                parent.color = .Red;
                sibling.?.color = .Black;
                sibling = close_nephew;
                if (distant_nephew != null and distant_nephew.?.color == .Red) {
                    _ = self.rotate(parent, dir);
                    distant_nephew.?.color = .Black;
                    sibling.?.color = .Black;
                    parent.color = .Red;
                    return to_remove;
                }

                if (close_nephew != null and close_nephew.?.color == .Red) {
                    _ = self.rotate(sibling.?, dir.opposite());
                    sibling.?.color = .Red;
                    close_nephew.?.color = .Black;
                    distant_nephew = sibling;
                    sibling = close_nephew;
                    return to_remove;
                }

                sibling.?.color = .Red;
                parent.color = .Black;
                return to_remove;
            }

            if (distant_nephew != null and distant_nephew.?.color == .Red) {
                _ = self.rotate(parent, dir);
                distant_nephew.?.color = .Black;
                sibling.?.color = .Black;
                parent.color = .Red;
                return to_remove;
            }

            if (close_nephew != null and close_nephew.?.color == .Red) {
                _ = self.rotate(sibling.?, dir.opposite());
                sibling.?.color = .Red;
                close_nephew.?.color = .Black;
                distant_nephew = sibling;
                sibling = close_nephew;
                return to_remove;
            }

            if (parent.color == .Red) {
                sibling.?.color = .Red;
                parent.color = .Black;
                return to_remove;
            }

            sibling.?.color = .Red;
            current = parent;
        }

        return to_remove;
    }

    fn rotate(self: *VmAllocator, node: *Node, dir: Dir) ?*Node {
        const parent = node.parent;
        const new_root: *Node = if (node.node(dir.opposite()).*) |n| n else return null;
        const new_child = new_root.node(dir).*;

        // Update parent pointers first
        new_root.parent = parent;
        node.parent = new_root;
        if (new_child) |child| {
            child.parent = node;
        }

        // Then update child pointers
        new_root.node(dir).* = node;
        node.node(dir.opposite()).* = new_child;

        // Finally update the parent's child pointer or root
        if (parent) |p| {
            p.node(node.direction()).* = new_root;
        } else {
            self.root = new_root;
        }

        return new_root;
    }
};

const PAGE = 0x1000;

const testing = std.testing;

fn initTestAllocator() VmAllocator {
    return VmAllocator.init(testing.allocator, 0, 1024 * 1024);
}

test "basic allocation with exact match" {
    var vm = VmAllocator.init(testing.allocator, 0, 0x1000);
    defer vm.deinit();

    const addr = try vm.allocate(0x1000, 0x1000, .ReadWrite);
    try testing.expectEqual(addr, 0);
}

test "basic allocation with alignment offset" {
    var vm = VmAllocator.init(testing.allocator, 0x1000, 0x2000);
    defer vm.deinit();

    const addr = try vm.allocate(1, 0x1000, .ReadWrite);
    try testing.expectEqual(addr, 0x1000);
}

test "allocation fails with no space" {
    var vm = VmAllocator.init(testing.allocator, 0, 0x1000);
    defer vm.deinit();

    const result = vm.allocate(0x1001, 0x1000, .ReadWrite);
    try testing.expectError(error.NoFreeMemory, result);
}

test "allocate_address: exact match" {
    var vm = VmAllocator.init(testing.allocator, 0x1000, 0x1000);
    defer vm.deinit();

    try vm.allocate_address(0x1000, 0x1000, .Read);
    try testing.expectEqual(vm.root.?.region.start, 0x1000);
    try testing.expectEqual(vm.root.?.region.size(), 0x1000);
    try testing.expectEqual(vm.root.?.region.attr, .Read);
}

test "allocate_address: partial fit inside larger region" {
    var vm = VmAllocator.init(testing.allocator, 0x1000, 0x4000);
    defer vm.deinit();

    try vm.allocate_address(0x2000, 0x1000, .ReadWrite);
    try testing.expectEqual(vm.root.?.region.start, 0x2000);
    try testing.expectEqual(vm.root.?.region.size(), 0x1000);
}

test "allocate_address: fails when no matching region exists" {
    var vm = VmAllocator.init(testing.allocator, 0x1000, 0x1000);
    defer vm.deinit();

    try testing.expectError(error.InvalidAddress, vm.allocate_address(0x2000, 0x1000, .ReadWrite));
}

test "allocate_address: fails when region is too small" {
    var vm = VmAllocator.init(testing.allocator, 0x1000, 0x800);
    defer vm.deinit();

    try testing.expectError(error.InvalidAddress, vm.allocate_address(0x1000, 0x1000, .ReadWrite));
}

test "allocate fixed then dynamic" {
    var vm = VmAllocator.init(testing.allocator, 0x1000, 0x4000); // [0x1000–0x5000)
    defer vm.deinit();

    try vm.allocate_address(0x3000, 0x1000, .ReadWrite); // Manually reserve 0x3000–0x4000
    const a = try vm.allocate(0x1000, 0x1000, .Read); // 0x1000
    const b = try vm.allocate(0x1000, 0x1000, .Read); // 0x2000
    const c = try vm.allocate(0x1000, 0x1000, .Read); // should skip 0x3000 (taken) → 0x4000

    try testing.expectEqual(0x1000, a);
    try testing.expectEqual(0x2000, b);
    try testing.expectEqual(0x4000, c);
}

test "allocation with internal alignment gap" {
    var vm = VmAllocator.init(testing.allocator, 0x1000, 0x3000); // [0x1000–0x4000)
    defer vm.deinit();

    // Allocate 0x800 with 0x1000 alignment: first aligned base is 0x1000
    const a = try vm.allocate(0x800, 0x1000, .Read);

    try testing.expectEqual(a, 0x1000);

    // Next allocation of 0x800 with 0x1000 alignment should land on 0x2000
    const b = try vm.allocate(0x800, 0x1000, .Read);

    try testing.expectEqual(b, 0x2000);
}

test "precise fills with aligned pages" {
    var vm = VmAllocator.init(testing.allocator, 0x0, 3 * PAGE);
    defer vm.deinit();

    _ = try vm.allocate(PAGE, PAGE, .Read);
    _ = try vm.allocate(PAGE, PAGE, .Read);
    _ = try vm.allocate(PAGE, PAGE, .Read);

    try testing.expectError(error.NoFreeMemory, vm.allocate(PAGE, PAGE, .Read));
}

test "allocate around existing fixed regions" {
    var vm = VmAllocator.init(testing.allocator, 0x1000, 0x5000); // [0x1000–0x6000)
    defer vm.deinit();

    try vm.allocate_address(0x2000, 0x1000, .ReadWrite); // Reserve [0x2000–0x3000)
    try vm.allocate_address(0x4000, 0x1000, .ReadWrite); // Reserve [0x4000–0x5000)

    const a = try vm.allocate(0x1000, 0x1000, .ReadWrite);
    const b = try vm.allocate(0x1000, 0x1000, .ReadWrite);
    const c = try vm.allocate(0x1000, 0x1000, .ReadWrite);

    try testing.expectEqual(0x1000, a);
    try testing.expectEqual(0x3000, b);
    try testing.expectEqual(0x5000, c);
}

test "fragmented allocation fills range" {
    var vm = VmAllocator.init(testing.allocator, 0x0, 0x3000); // [0x0–0x3000)
    defer vm.deinit();

    // Fragmented allocations (out-of-order sizes)
    const a = try vm.allocate(0x1000, 1, .Read); // 0x0000–0x1000
    const b = try vm.allocate(0x800, 1, .Read); // 0x1000–0x1800
    const c = try vm.allocate(0x800, 1, .Read); // 0x1800–0x2000
    const d = try vm.allocate(0x1000, 1, .Read); // 0x2000–0x3000

    try testing.expectEqual(a, 0x0000);
    try testing.expectEqual(b, 0x1000);
    try testing.expectEqual(c, 0x1800);
    try testing.expectEqual(d, 0x2000);

    // Should now be full
    try testing.expectError(error.NoFreeMemory, vm.allocate(1, 1, .Read));
}
