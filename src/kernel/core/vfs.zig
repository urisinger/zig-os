const std = @import("std");
const root = @import("root");
const cbip = root.core.cbip;
const log = std.log.scoped(.vfs);

pub const Vnode = struct {
    name: []const u8,
    data: union(enum) {
        directory: struct {
            children: [16]?*Vnode = [_]?*Vnode{null} ** 16,
            count: usize = 0,
        },
        device: struct {
            /// The CBIP Handshake function
            get_interface: *const fn (self: *Vnode, id: u64) cbip.InterfaceResult,
        },
    },

    pub fn initDir(name: []const u8) Vnode {
        return .{
            .name = name,
            .data = .{ .directory = .{} },
        };
    }

    pub fn initDevice(
        name: []const u8, 
        iface_fn: *const fn (*Vnode, u64) cbip.InterfaceResult,
    ) Vnode {
        return .{
            .name = name,
            .data = .{ 
                .device = .{ 
                    .get_interface = iface_fn,
                } 
            },
        };
    }

    pub fn requestInterface(self: *Vnode, id: u64) cbip.InterfaceResult {
        return switch (self.data) {
            .device => |dev| dev.get_interface(self, id),
            .directory => .{ .vtable = null, .context = null, .status = 404 },
        };
    }

    pub fn addChild(self: *Vnode, child: *Vnode) !void {
        switch (self.data) {
            .directory => |*dir| {
                if (dir.count >= dir.children.len) return error.DirectoryFull;
                dir.children[dir.count] = child;
                dir.count += 1;
            },
            .device => return error.NotADirectory,
        }
    }

    pub fn findChild(self: *Vnode, child_name: []const u8) ?*Vnode {
        return switch (self.data) {
            .directory => |dir| {
                for (dir.children[0..dir.count]) |child| {
                    if (std.mem.eql(u8, child.?.name, child_name)) return child.?;
                }
                return null;
            },
            .device => null,
        };
    }
};

var root_vnode = Vnode.initDir("");

pub fn getRoot() *Vnode {
    return &root_vnode;
}

pub fn lookup(path: []const u8) ?*Vnode {
    if (std.mem.eql(u8, path, "/")) return &root_vnode;
    if (path.len == 0) return null;

    var current = &root_vnode;
    var iter = std.mem.tokenizeScalar(u8, path, '/');

    while (iter.next()) |part| {
        current = current.findChild(part) orelse return null;
    }
    return current;
}

pub fn mount(path: []const u8, vnode: *Vnode) !void {
    const parent = lookup(path) orelse {
        log.err("mount: target path '{s}' not found", .{path});
        return error.ParentDirectoryNotFound;
    };

    if (parent.data != .directory) {
        log.err("mount: target '{s}' is not a directory", .{path});
        return error.NotADirectory;
    }

    try parent.addChild(vnode);
    
    log.info("Mounted '{s}' into {s}", .{ vnode.name, path });
}
