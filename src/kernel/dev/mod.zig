pub const serial = @import("serial.zig");
pub const display = struct {
    pub const console = @import("display/console.zig");
    pub const framebuffer = @import("display/framebuffer.zig");
};
pub const ps2 = @import("ps2.zig");
pub const keyboard = @import("keyboard/mod.zig");
