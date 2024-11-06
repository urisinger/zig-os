const std = @import("std");

const log = std.log;
const font = @embedFile("DEF_8X16.F16");
const framebuffer = @import("framebuffer.zig");
const Color = framebuffer.Color;

const font_x = 8;
const font_y = 16;

const char_bytes = font_x * font_y / 8;

pub fn writer() std.io.Writer(void, error{}, write) {
    return .{ .context = {} };
}

var console: ?Console = null;

//Make sure this cant panic or display logs!
pub fn init() void {
    console = .{
        .framebuffer = &framebuffer.framebuffer,
        .cur_color = Color.WHITE,
    };
}

pub const Console = struct {
    framebuffer: *framebuffer.Framebuffer,
    cur_line: usize = 0,
    cur_col: usize = 0,
    cur_color: Color,
};

fn write(_: void, str: []const u8) error{}!usize {
    puts(str);
    return str.len;
}

fn putc(c: u8) void {
    const base_y = console.?.cur_line * font_y;
    const base_x = console.?.cur_col * font_x;
    const c_u32: u32 = @intCast(c);
    const bitmap = font[char_bytes * c_u32 .. char_bytes * (c_u32 + 1)];

    for (0.., bitmap) |byte_index, byte| {
        for (0..8) |bit_index| {
            const y_offset = (byte_index * 8 + bit_index) / font_x;
            const x_offset = 8 - (byte_index * 8 + bit_index) % font_x;

            if (byte & (@as(u8, 1) << @intCast(bit_index)) != 0) {
                framebuffer.framebuffer.setpixel(base_x + x_offset, base_y + y_offset, console.?.cur_color);
            }
        }
    }
    const num_cols = console.?.framebuffer.width / font_x;
    console.?.cur_col += 1;
    if (console.?.cur_col / num_cols >= 1) {
        console.?.cur_col = 0;
        console.?.cur_line += 1;
    }
}

pub fn puts(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[') {
            // Parse ANSI escape sequence
            i += 1; // Skip the "\x1b["
            var color_code: ?u8 = null;
            while (i < s.len and s[i] != 'm') {
                if (std.ascii.isDigit(s[i])) {
                    if (color_code) |code| {
                        color_code = code * 10 + (s[i] - '0');
                    } else {
                        color_code = s[i] - '0';
                    }
                }
                i += 1;
            }
            if (color_code) |code| {
                switch (code) {
                    0 => console.?.cur_color = Color.WHITE,
                    1 => console.?.cur_color = Color.WHITE,
                    2 => console.?.cur_color = Color.RED,
                    3 => console.?.cur_color = Color.GREEN,
                    4 => console.?.cur_color = Color.BLUE,
                    31 => console.?.cur_color = Color.RED,
                    32 => console.?.cur_color = Color.GREEN,
                    33 => console.?.cur_color = Color.YELLOW,
                    36 => console.?.cur_color = Color.RED,
                    else => {}, // Handle unknown color codes or extend for more colors
                }
            }
        } else if (s[i] == '\n') {
            console.?.cur_line += 1;
            console.?.cur_col = 0;
        } else {
            putc(s[i]);
        }
    }
}
