const limine = @import("limine");

const std = @import("std");
const log = std.log;
export var framebuffer_request: limine.FramebufferRequest = .{};

var framebuffer: Framebuffer = undefined;

pub fn init() void {
    const response = framebuffer_request.response.?;
    const limine_framebuffer = response.framebuffers()[0];
    framebuffer = .{
        .address = limine_framebuffer.address,
        .width = limine_framebuffer.width,
        .height = limine_framebuffer.height,
        .bpp = limine_framebuffer.bpp,
        .pitch = limine_framebuffer.pitch,
    };

    framebuffer.clear(Color.RED);
}

pub const Color = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    const RED = Color{ .r = 255 };
};

pub const Framebuffer = struct {
    address: [*]u8,
    width: u64, // screen width in pixels
    height: u64, // screen height in pixels
    pitch: u64, // number of bytes per row
    bpp: u16, // bits per pixel

    pub fn setpixel(self: *const Framebuffer, x: u64, y: u64, color: Color) void {
        if (x >= self.width or y >= self.height) return; // prevent out-of-bounds access

        const bytes_per_pixel = self.bpp / 8;
        const offset = y * self.pitch + x * bytes_per_pixel;
        const pixel = self.address[offset .. offset + bytes_per_pixel];

        pixel[0] = color.b; // red
        pixel[1] = color.g; // green
        pixel[2] = color.r;
    }

    pub fn clear(self: *const Framebuffer, color: Color) void {
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                self.setpixel(x, y, color);
            }
        }
    }

    pub fn getwidth(self: *const Framebuffer) u64 {
        return self.width;
    }

    pub fn getheight(self: *const Framebuffer) u64 {
        return self.height;
    }

    pub fn blit(
        self: *const Framebuffer,
        x: u64,
        y: u64,
        src: [*]const Color,
        src_width: u64,
        src_height: u64,
    ) void {
        for (0..src_height) |src_y| {
            const dest_y = y + src_y;
            if (dest_y >= self.height) break;

            for (0..src_width) |src_x| {
                const dest_x = x + src_x;
                if (dest_x >= self.width) break;

                // Get the source pixel color
                const color = src[src_y * src_width + src_x];
                // Set the destination pixel
                self.setPixel(dest_x, dest_y, color);
            }
        }
    }
};
