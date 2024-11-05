const std = @import("std");

const log = std.log;
const font = @embedFile("DEF_8X16.F16");
const framebuffer = @import("framebuffer.zig");
const Color = framebuffer.Color;

const font_x = 8;
const font_y = 16;

const char_bytes = font_x * font_y / 8;

pub fn blit_char(c: u8, x: usize, y: usize) void {
    const c_u32: u32 = @intCast(c);
    const bitmap = font[char_bytes * c_u32 .. char_bytes * (c_u32 + 1)];

    for (0.., bitmap) |byte_index, byte| {
        for (0..8) |bit_index| {
            const y_offset = (byte_index * 8 + bit_index) / font_x;
            const x_offset = 8 - (byte_index * 8 + bit_index) % font_x;

            if (byte & (@as(u8, 1) << @intCast(bit_index)) != 0) {
                framebuffer.framebuffer.setpixel(x + x_offset, y + y_offset, Color.BLACK);
            }
        }
    }
}
