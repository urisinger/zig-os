const std = @import("std");

pub const Attr = enum { Free, Read, ReadWrite, ReadExecute };

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

pub const Region = struct {
    start: u64,
    end: u64,
    attr: Attr,

    pub fn size(self: Region) u64 {
        return self.end - self.start;
    }
};

pub const Node = struct {
    region: Region,

    left: ?*Node = null,
    right: ?*Node = null,
    parent: ?*Node = null,
    color: Color = .Red,

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

pub const VmAllocator = struct {
    root: ?*Node,
    allocator: std.mem.Allocator,

    pub fn format(self: VmAllocator, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("VmAllocator:\n", .{});
        try self.format_recursive(self.root, 0, writer);
    }

    fn format_recursive(self: VmAllocator, node: ?*Node, depth: usize, writer: anytype) !void {
        if (node == null) return;

        const n = node.?;

        // Left subtree first
        try self.format_recursive(n.right, depth + 1, writer);

        // Indentation
        try writer.writeByteNTimes(' ', depth * 2);

        // Node information
        try writer.print("└─ [{x}-{x}) size={} attr={}\n", .{ n.region.start, n.region.end, n.region.size(), n.region.attr });

        // Right subtree next
        try self.format_recursive(n.left, depth + 1, writer);
    }

    pub fn initAllocator(allocator: std.mem.Allocator, base: u64, size: u64) !VmAllocator {
        const root = try allocator.create(Node);
        root.* = Node{
            .region = Region{
                .start = base,
                .end = base + size,
                .attr = .Free,
            },
            .color = .Black,
        };

        return VmAllocator{
            .root = root,
            .allocator = allocator,
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

    fn rotate(self: *VmAllocator, node: *Node, dir: Dir) ?*Node {
        const parent = node.parent;
        const new_root: *Node = if (node.node(dir.opposite()).*) |n| n else return null;
        const new_child = new_root.node(dir);

        node.node(dir.opposite()).* = new_root;

        if (new_child.*) |child| {
            child.parent = node;
        }

        new_root.parent = parent;
        new_root.node(dir).* = node;

        node.parent = new_root;
        if (parent) |p| {
            p.node(node.direction()).* = new_root;
        } else {
            self.root = new_root;
        }

        return new_root;
    }

    pub fn allocate_address(self: *VmAllocator, base: u64, size: u64, attr: Attr) !void {
        const aligned_base = base;

        const node = self.find_exact_gap(self.root, aligned_base, size) orelse return error.NoFreeMemory;

        const new_node = try self.allocator.create(Node);
        new_node.* = .{
            .region = Region{
                .start = aligned_base,
                .end = aligned_base + size,
                .attr = attr,
            },
            .color = .Red,
        };

        if (node.region.start < new_node.region.start) {
            const new_left = try self.allocator.create(Node);
            new_left.* = .{
                .region = Region{
                    .start = node.region.start,
                    .end = new_node.region.start,
                    .attr = .Free,
                },
            };
            const new_right = try self.allocator.create(Node);
            new_right.* = .{
                .region = Region{
                    .start = new_left.region.end,
                    .end = node.region.end,
                    .attr = .Free,
                },
                .color = .Red,
            };
            self.insert(new_left, node, .Left);
            self.insert(new_right, node, .Right);
            self.insert(new_node, new_right, .Left);
        } else if (node.region.start == aligned_base) {
            self.insert(new_node, node, .Left);
        } else {
            @panic("find_gap: invalid base");
        }
    }

    fn find_exact_gap(self: *VmAllocator, node: ?*Node, base: u64, size: u64) ?*Node {
        if (node == null) return null;
        const n = node.?;

        if (n.left != null) {
            if (self.find_exact_gap(n.left, base, size)) |found| return found;
        }

        if (n.region.attr == .Free and n.left == null and n.right == null and
            n.region.start <= base and n.region.end >= base + size)
        {
            return n;
        }

        if (n.right != null) {
            if (self.find_exact_gap(n.right, base, size)) |found| return found;
        }

        return null;
    }

    pub fn allocate(self: *VmAllocator, size: u64, alignment: u64, attr: Attr) !u64 {
        const node = self.find_gap(self.root, size, alignment) orelse return error.NoFreeMemory;
    }

    fn allocate_helper(self: *VmAllocator, node: ?*Node, size: u64, alignment: u64, attr: Attr) ?u64 {
        if (node == null) return null;
        const n = node.?;

        if (n.left) |left| {
            const aligned_base = std.mem.alignForward(u64, left.region.start, alignment);
            const padding = aligned_base - left.region.start;

            if (left.region.attr == .Free and left.region.size() >= size + padding) {
                return aligned_base;
            }

            if (self.allocate_helper(left, size, alignment)) |found| return found;
        }

        if (n.region.attr == .Free and n.left == null and n.right == null) {
            const aligned_base = std.mem.alignForward(u64, n.region.start, alignment);

            if (n.region.end >= aligned_base + size) {
                self.insert_null_child(n, aligned_base, aligned_base + size, attr);
                return aligned_base;
            }
        }

        if (n.right) |right| {
            const aligned_base = std.mem.alignForward(u64, right.region.start, alignment);
            const padding = aligned_base - right.region.start;

            if (right.region.attr == .Free and right.region.size() >= size + padding) {
                return aligned_base;
            }

            if (self.find_gap(right, size, alignment)) |found| return found;
        }

        return null;
    }

    fn insert_null_child(self: *VmAllocator, node: *Node, start: u64, end: u64, attr: Attr) void {
        if (node.region.end == end) {
            node.region.attr = attr;
            return;
        }

        const new_node = try self.allocator.create(Node);
        new_node.* = .{
            .region = Region{
                .start = start,
                .end = end,
                .attr = attr,
            },
            .color = .Red,
        };

        if (node.region.start < new_node.region.start) {
            const new_left = try self.allocator.create(Node);
            new_left.* = .{
                .region = Region{
                    .start = node.region.start,
                    .end = new_node.region.end,
                    .attr = .Free,
                },
            };

            const new_right = try self.allocator.create(Node);
            new_right.* = .{
                .region = Region{
                    .start = new_left.region.end,
                    .end = node.region.end,
                    .attr = .Free,
                },
                .color = .Red,
            };
            self.insert(new_left, node, .Left);
            self.insert(new_right, node, .Right);
            self.insert(new_node, new_right, .Left);
        } else if (node.region.start == new_node.region.start) {
            self.insert(new_node, node, .Left);
        } else {
            @panic("find_gap: invalid base");
        }
    }

    pub fn insert(self: *VmAllocator, node: *Node, null_parent: ?*Node, dir: Dir) void {
        node.color = .Red;
        node.parent = null_parent;

        if (null_parent) |p| {
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
            if (uncle == null or uncle.?.color == .Red) {
                var p = parent;
                if (current == parent.node(parent_dir).*) {
                    _ = self.rotate(parent, parent_dir.opposite());

                    p = current;
                    current = parent;
                }

                _ = self.rotate(grandparent, parent_dir);
                parent.color = .Black;
                grandparent.color = .Red;
                return;
            }

            uncle.?.color = .Black;
            parent.color = .Black;
            current = grandparent;
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
};

const PAGE = 4096;

const testing = std.testing;

fn initTestAllocator() !VmAllocator {
    return VmAllocator.initAllocator(testing.allocator, 0, 1024 * 1024);
}

test "init creates black root" {
    const vm = try initTestAllocator();
    const root = vm.root.?;
    defer testing.allocator.destroy(root);
    try testing.expect(vm.root != null);
    try testing.expect(vm.root.?.color == .Black);
    try testing.expect(vm.root.?.region.size() == 1024 * 1024);
}

test "insert maintains red-black properties" {
    var vm = try initTestAllocator();
    const root = vm.root.?;
    defer testing.allocator.destroy(root);
    // Create some nodes
    const node1 = try vm.allocator.create(Node);
    defer vm.allocator.destroy(node1);
    node1.* = .{
        .region = .{ .start = 100, .end = 200, .attr = .Free },
        .color = .Red,
    };

    const node2 = try vm.allocator.create(Node);
    defer vm.allocator.destroy(node2);
    node2.* = .{
        .region = .{ .start = 200, .end = 300, .attr = .Free },
        .color = .Red,
    };

    // Insert nodes
    vm.insert(node1, vm.root.?, .Left);
    vm.insert(node2, vm.root.?, .Right);

    // Verify properties
    try testing.expectEqual(vm.root.?.color, .Black);
    try testing.expectEqual(node1.color, .Red);
    try testing.expectEqual(node2.color, .Red);
    try testing.expectEqual(node1.parent, vm.root);
    try testing.expectEqual(node2.parent, vm.root);
}

test "delete leaf node" {
    var vm = try initTestAllocator();
    defer vm.deinit();
    const node = try vm.allocator.create(Node);
    node.* = .{
        .region = .{ .start = 100, .end = 200, .attr = .Free },
        .color = .Red,
    };

    vm.insert(node, vm.root.?, .Left);
    const to_free = vm.delete(node);
    defer vm.allocator.destroy(to_free);

    try testing.expectEqual(vm.root.?.left, null);
}

test "delete node with one child" {
    var vm = try initTestAllocator();
    defer vm.deinit();
    const parent = try vm.allocator.create(Node);
    parent.* = .{
        .region = .{ .start = 200, .end = 300, .attr = .Free },
        .color = .Black,
    };

    const child = try vm.allocator.create(Node);
    child.* = .{
        .region = .{ .start = 100, .end = 200, .attr = .Free },
        .color = .Red,
    };

    vm.insert(parent, vm.root.?, .Left);
    vm.insert(child, parent, .Left);

    const to_free = vm.delete(parent);
    defer vm.allocator.destroy(to_free);

    try testing.expectEqual(vm.root.?.left, child);
    try testing.expectEqual(child.color, .Black);
}

test "delete node with two children" {
    var vm = try initTestAllocator();
    defer vm.deinit();

    const node = try vm.allocator.create(Node);
    const left = try vm.allocator.create(Node);
    const right = try vm.allocator.create(Node);

    node.* = .{
        .region = .{ .start = 200, .end = 300, .attr = .Free },
        .color = .Black,
    };

    left.* = .{
        .region = .{ .start = 100, .end = 200, .attr = .Free },
        .color = .Red,
    };

    right.* = .{
        .region = .{ .start = 300, .end = 400, .attr = .Free },
        .color = .Red,
    };

    vm.insert(node, vm.root.?, .Left);
    vm.insert(left, node, .Left);
    vm.insert(right, node, .Right);

    const original_base = node.region.start;
    const to_free = vm.delete(node);
    defer vm.allocator.destroy(to_free);

    try testing.expect(to_free == right); // The successor (right) should be the node we need to free
    try testing.expect(original_base != node.region.start);
    try testing.expectEqual(node.left, left);
    try testing.expectEqual(left.parent, node);
    try testing.expectEqual(node.right, null);
}

test "basic allocation with exact match" {
    var vm = try VmAllocator.initAllocator(testing.allocator, 0, 0x1000);
    defer vm.deinit();

    const addr = try vm.allocate(0x1000, 0x1000, .ReadWrite);
    try testing.expectEqual(addr, 0);
}

test "basic allocation with alignment offset" {
    var vm = try VmAllocator.initAllocator(testing.allocator, 0x1000, 0x2000);
    defer vm.deinit();

    const addr = try vm.allocate(1, 0x1000, .ReadWrite);
    try testing.expectEqual(addr, 0x1000);
}

test "allocation fails with no space" {
    var vm = try VmAllocator.initAllocator(testing.allocator, 0, 0x1000);
    defer vm.deinit();

    const result = vm.allocate(0x1001, 0x1000, .ReadWrite);
    try testing.expectError(error.NoFreeMemory, result);
}

test "allocate_address: exact match" {
    var vm = try VmAllocator.initAllocator(testing.allocator, 0x1000, 0x1000);
    defer vm.deinit();

    try vm.allocate_address(0x1000, 0x1000, .Read);
    try testing.expectEqual(vm.root.?.left.?.region.start, 0x1000);
    try testing.expectEqual(vm.root.?.left.?.region.size(), 0x1000);
    try testing.expectEqual(vm.root.?.left.?.region.attr, .Read);
}

test "allocate_address: partial fit inside larger region" {
    var vm = try VmAllocator.initAllocator(testing.allocator, 0x1000, 0x4000);
    defer vm.deinit();

    try vm.allocate_address(0x2000, 0x1000, .ReadWrite);
    try testing.expectEqual(vm.root.?.right.?.left.?.region.start, 0x2000);
    try testing.expectEqual(vm.root.?.right.?.left.?.region.size(), 0x1000);
}

test "allocate_address: fails when no matching region exists" {
    var vm = try VmAllocator.initAllocator(testing.allocator, 0x1000, 0x1000);
    defer vm.deinit();

    try testing.expectError(error.NoFreeMemory, vm.allocate_address(0x2000, 0x1000, .ReadWrite));
}

test "allocate_address: fails when region is too small" {
    var vm = try VmAllocator.initAllocator(testing.allocator, 0x1000, 0x800);
    defer vm.deinit();

    try testing.expectError(error.NoFreeMemory, vm.allocate_address(0x1000, 0x1000, .ReadWrite));
}

test "allocate fixed then dynamic" {
    var vm = try VmAllocator.initAllocator(testing.allocator, 0x1000, 0x4000); // [0x1000–0x5000)
    defer vm.deinit();

    try vm.allocate_address(0x3000, 0x1000, .ReadWrite); // Manually reserve 0x3000–0x4000

    const a = try vm.allocate(0x1000, 0x1000, .Read); // 0x1000
    const b = try vm.allocate(0x1000, 0x1000, .Read); // 0x2000
    const c = try vm.allocate(0x1000, 0x1000, .Read); // should skip 0x3000 (taken) → 0x4000

    try testing.expectEqual(a, 0x1000);
    try testing.expectEqual(b, 0x2000);
    try testing.expectEqual(c, 0x4000);
}
