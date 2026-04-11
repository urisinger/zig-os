const std = @import("std");
const root = @import("root");
const cbip = root.core.cbip;
const log = std.log.scoped(.vfs);

var vnode_cache: root.mem.kernel.heap.slab.SlabCacheTyped(Vnode) = undefined;
var root_vnode: *Vnode = undefined;

pub fn init() !void {
    vnode_cache = try root.mem.get_slab_cache(Vnode);

    // Initialize the root filesystem
    const root_fs = try RamFs.create();
    root_vnode = try Vnode.createRoot(&root_fs.mount);
}

pub const Mount = struct {
    inode: cbip.Inode,
    ops: struct {
        lookup: *const fn (m: *Mount, parent: *cbip.Inode, name: []const u8) u64,
        create: *const fn (m: *Mount, parent: *cbip.Inode, name: []const u8) u64,
    },

    pub inline fn fromInode(inode: *cbip.Inode) *Mount {
        return @fieldParentPtr("inode", inode);
    }
};

pub const Vnode = struct {
    name: []const u8,
    inode: *cbip.Inode,
    mount: *Mount, // The mount governing this node's children
    parent: ?*Vnode,

    first_child: ?*Vnode = null,
    next_sibling: ?*Vnode = null,

    pub fn requestInterface(self: *Vnode, id: u64) cbip.InterfaceResult {
        return self.inode.get_interface(self.inode, id);
    }

    pub fn createRoot(mnt: *Mount) !*Vnode {
        const self = try vnode_cache.alloc();

        self.* = .{
            .name = "",
            .inode = &mnt.inode,
            .parent = null,
            .mount = mnt,
        };
        mnt.inode.ref();
        return self;
    }

    pub fn create(name: []const u8, inode: *cbip.Inode, parent: *Vnode) !*Vnode {
        const self = try vnode_cache.alloc();
        self.* = .{
            .name = name,
            .inode = inode,
            .parent = parent,
            .mount = parent.mount,
        };
        inode.ref();
        return self;
    }

    pub inline fn isMountPoint(self: *const Vnode) bool {
        return @intFromPtr(self.inode) == @intFromPtr(&self.mount.inode);
    }
};

pub fn lookup(path: []const u8) ?*Vnode {
    log.debug("lookup: scanning for '{s}', {}", .{ path, path.len });
    if (path.len == 0 or path[0] != '/') {
        log.err("lookup: invalid path start", .{});
        return null;
    }
    if (path.len == 1) return root_vnode;

    var current = root_vnode;
    var iter = std.mem.tokenizeScalar(u8, path, '/');

    while (iter.next()) |part| {
        log.debug("lookup: at node '{s}', searching for child '{s}'", .{ current.name, part });
        if (findChild(current, part)) |child| {
            current = child;
        } else {
            // Unified Discovery
            const active_mount = if (current.isMountPoint())
                Mount.fromInode(current.inode)
            else
                current.mount;

            log.debug("lookup: child '{s}' not in cache, checking mount {x}", .{ part, @intFromPtr(active_mount) });
            const res_ptr = active_mount.ops.lookup(active_mount, current.inode, part);

            if (res_ptr == 0) {
                log.warn("lookup: driver returned 0 for '{s}'", .{part});
                return null;
            }

            const next_inode: *cbip.Inode = @ptrFromInt(res_ptr);
            const new_node = Vnode.create(part, next_inode, current) catch |err| {
                log.err("lookup: failed to create vnode: {any}", .{err});
                return null;
            };

            new_node.mount = active_mount;
            new_node.next_sibling = current.first_child;
            current.first_child = new_node;
            current = new_node;
        }
    }
    return current;
}

fn findChild(parent: *Vnode, name: []const u8) ?*Vnode {
    var curr = parent.first_child;
    while (curr) |node| : (curr = node.next_sibling) {
        if (std.mem.eql(u8, node.name, name)) return node;
    }
    return null;
}

pub fn mkdir(path: []const u8) !*Vnode {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;

    // 1. Separate the path into "everything up to the last part" and "the new dir name"
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
    const parent_path = if (last_slash == 0) "/" else path[0..last_slash];
    const new_dir_name = path[last_slash + 1 ..];

    if (new_dir_name.len == 0) return error.InvalidName;

    // 2. Find the parent Vnode
    const parent_vn = lookup(parent_path) orelse return error.ParentNotFound;

    // 3. Ensure it doesn't already exist
    if (findChild(parent_vn, new_dir_name) != null) return error.AlreadyExists;

    // 4. Identify the active mount logic
    const active_mount = if (parent_vn.isMountPoint())
        Mount.fromInode(parent_vn.inode)
    else
        parent_vn.mount;

    // 5. Ask the mount driver to create the actual Inode
    // We pass a 'DIR' flag or similar if your 'create' ops supports it.
    const res_ptr = active_mount.ops.create(active_mount, parent_vn.inode, new_dir_name);
    if (res_ptr == 0) return error.PermissionDenied; // Or NotSupported

    const new_inode: *cbip.Inode = @ptrFromInt(res_ptr);

    // 6. Wrap in a Vnode and link it
    const new_node = try Vnode.create(new_dir_name, new_inode, parent_vn);
    new_node.mount = active_mount;

    new_node.next_sibling = parent_vn.first_child;
    parent_vn.first_child = new_node;

    return new_node;
}

pub fn mount(parent_path: []const u8, name: []const u8, target_mount: *Mount) !void {
    const parent_vn = lookup(parent_path) orelse return error.ParentNotFound;

    if (findChild(parent_vn, name)) |existing_vn| {
        existing_vn.inode.unref(); // Drop reference to the old underlying object

        existing_vn.inode = &target_mount.inode;
        existing_vn.mount = target_mount;

        existing_vn.inode.ref(); // Reference the new Mount's Inode

        log.info("Over-mounted '{s}' at {s}/{s}", .{ name, parent_path, name });
        return;
    }

    const vn = try Vnode.create(name, &target_mount.inode, parent_vn);
    vn.mount = target_mount;

    vn.next_sibling = parent_vn.first_child;
    parent_vn.first_child = vn;

    log.info("Mounted new filesystem '{s}' at {s}/{s}", .{ name, parent_path, name });
}

// --- RamFs Implementation ---

const RamFs = struct {
    mount: Mount,

    // The static "Empty" Inode for directories/placeholders
    var empty_inode_instance = cbip.Inode{
        .ref_count = 1, // Start at 1 to prevent deinit
        .get_interface = empty_get_iface,
        .deinit_fn = empty_deinit,
    };

    pub fn create() !*RamFs {
        const self = try root.mem.allocator.create(RamFs);
        self.* = .{
            .mount = .{
                .inode = .{
                    .get_interface = ram_get_iface,
                    .deinit_fn = ram_deinit,
                },
                .ops = .{
                    .lookup = ram_lookup,
                    .create = ram_create,
                },
            },
        };

        return self;
    }

    fn ram_lookup(_: *Mount, _: *cbip.Inode, _: []const u8) u64 {
        // RamFs is currently a container for mounts; it doesn't 
        // find existing files yet, so return 0.
        return 0;
    }

    fn ram_create(_: *Mount, _: *cbip.Inode, _: []const u8) u64 {
        // When mkdir is called, we return the address of our singleton empty inode.
        // The VFS will call .ref() on this address.
        return @intFromPtr(&empty_inode_instance);
    }

    fn ram_get_iface(_: *cbip.Inode, _: u64) cbip.InterfaceResult {
        return .{ .vtable = null, .context = null, .status = 404 };
    }

    fn ram_deinit(base: *cbip.Inode) void {
        const m = Mount.fromInode(base);
        const self: *RamFs = @fieldParentPtr("mount", m);
        root.mem.allocator.destroy(self);
    }

    fn empty_get_iface(_: *cbip.Inode, _: u64) cbip.InterfaceResult {
        return .{ .vtable = null, .context = null, .status = 404 };
    }

    fn empty_deinit(_: *cbip.Inode) void {
        // Do nothing. This is a singleton.
        // We don't want to free the static memory.
    }
};
