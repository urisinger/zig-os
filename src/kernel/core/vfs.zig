const std = @import("std");
const root = @import("root");
const cbip = root.core.cbip;
const log = std.log.scoped(.vfs);

pub const Vnode = struct {
    name: []const u8,
    cbip_vnode: cbip.Vnode,
    children: [16]?*Vnode = [_]?*Vnode{null} ** 16,
    child_count: usize = 0,
    is_dir: bool = false,

    pub fn init(name: []const u8, is_dir: bool) Vnode {
        return .{
            .name = name,
            .is_dir = is_dir,
            .cbip_vnode = .{ .name = name },
        };
    }

    pub fn addChild(self: *Vnode, child: *Vnode) !void {
        if (!self.is_dir) return error.NotADirectory;
        if (self.child_count >= self.children.len) return error.DirectoryFull;
        self.children[self.child_count] = child;
        self.child_count += 1;
    }

    pub fn findChild(self: *Vnode, name: []const u8) ?*Vnode {
        for (self.children[0..self.child_count]) |child| {
            if (std.mem.eql(u8, child.?.name, name)) return child;
        }
        return null;
    }
};

var root_vnode = Vnode.init("", true);

pub fn getRoot() *Vnode {
    return &root_vnode;
}

pub fn lookup(path: []const u8) ?*Vnode {
    if (path.len == 0) return null;
    if (path[0] != '/') return null; // Only absolute paths for now

    var current = &root_vnode;
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    
    while (iter.next()) |part| {
        if (current.findChild(part)) |child| {
            current = child;
        } else {
            return null;
        }
    }
    return current;
}

pub fn mount(path: []const u8, vnode: *Vnode) !void {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    
    var current = &root_vnode;
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    var last_part: ?[]const u8 = null;

    // Traverse to the parent directory
    while (iter.next()) |part| {
        if (last_part) |lp| {
             if (current.findChild(lp)) |child| {
                current = child;
            } else {
                return error.ParentDirectoryNotFound;
            }
        }
        last_part = part;
    }

    if (last_part) |lp| {
        vnode.name = lp;
        try current.addChild(vnode);
        log.info("Mounted vnode at {s}", .{path});
    } else {
        return error.InvalidPath;
    }
}
