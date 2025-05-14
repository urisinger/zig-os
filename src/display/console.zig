const std = @import("std");

const font = @embedFile("DEF_8X16.F16");
const framebuffer = @import("framebuffer.zig");
const Color = framebuffer.Color;

const font_x = 8;
const font_y = 16;

const char_bytes = font_x * font_y / 8;

const ConsoleError = error{ConsoleNotInitialized};

pub fn writer() std.io.Writer(void, ConsoleError, write) {
    return .{ .context = {} };
}

pub var console: ?Console = null;

//Make sure this cant panic or display logs!
pub fn init() void {
    const fb = &framebuffer.framebuffer;

    const size = fb.width * fb.height;
    const allocator = std.heap.page_allocator;
    const pixels = allocator.alloc(Color, size) catch unreachable;

    @memset(pixels, Color.BLACK);

    const virt_fb = framebuffer.Framebuffer{
        .address = @ptrCast(pixels.ptr),
        .width = fb.width,
        .height = fb.height,
        .pitch = fb.width * @sizeOf(Color),
        .bpp = 32,
        .red_mask_offset = 0,
        .green_mask_offset = 1,
        .blue_mask_offset = 2,
    };

    console = .{
        .virt = virt_fb,
        .real = fb,
        .cur_color = Color.WHITE,
    };
}

pub const Console = struct {
    real: *framebuffer.Framebuffer,
    virt: framebuffer.Framebuffer,
    cur_line: usize = 0,
    cur_col: usize = 0,
    cur_color: Color,
};

fn write(_: void, str: []const u8) ConsoleError!usize {
    try puts(str);
    return str.len;
}

pub fn flush() ConsoleError!void {
    const con = console orelse return ConsoleError.ConsoleNotInitialized;

    const src = con.virt;
    const dst = con.real;

    const width = @min(src.width, dst.width);
    const height = @min(src.height, dst.height);

    const src_pixels: [*]const Color = @ptrCast(@alignCast(src.address));

    dst.blit(0, 0, src_pixels, width, height);
}

fn putc(c: u8) ConsoleError!void {
    const con = &(console orelse return ConsoleError.ConsoleNotInitialized);

    const base_x = con.cur_col * font_x;
    const base_y = con.cur_line * font_y;
    const c_u32: u32 = @intCast(c);
    const bitmap = font[char_bytes * c_u32 .. char_bytes * (c_u32 + 1)];

    for (0.., bitmap) |byte_index, byte| {
        for (0..8) |bit_index| {
            const y_offset = (byte_index * 8 + bit_index) / font_x;
            const x_offset = 8 - (byte_index * 8 + bit_index) % font_x;

            if (byte & (@as(u8, 1) << @intCast(bit_index)) != 0) {
                const x = base_x + x_offset;
                const y = base_y + y_offset;

                con.virt.setpixel(x, y, con.cur_color);
                con.real.setpixel(x, y, con.cur_color);
            }
        }
    }

    const num_cols = con.virt.width / font_x;
    con.cur_col += 1;

    if (con.cur_col >= num_cols) {
        con.cur_col = 0;
        con.cur_line += 1;
    }

    const max_lines = con.virt.height / font_y;
    if (con.cur_line >= max_lines) {
        try scrollAndFlush();
    }
}

pub fn puts(s: []const u8) ConsoleError!void {
    const con = &(console orelse return ConsoleError.ConsoleNotInitialized);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[') {
            i += 1;
            var color_code: ?u8 = null;
            while (i < s.len and s[i] != 'm') {
                if (std.ascii.isDigit(s[i])) {
                    color_code = 10 * (color_code orelse 0) + (s[i] - '0');
                }
                i += 1;
            }
            if (color_code) |code| {
                switch (code) {
                    0 => con.cur_color = Color.WHITE,
                    31 => con.cur_color = Color.RED,
                    32 => con.cur_color = Color.GREEN,
                    33 => con.cur_color = Color.YELLOW,
                    36 => con.cur_color = Color.CYAN,
                    else => {},
                }
            }
        } else if (s[i] == '\n') {
            con.cur_line += 1;
            con.cur_col = 0;
        } else {
            try putc(s[i]);
        }

        const max_lines = con.virt.height / font_y;
        if (con.cur_line >= max_lines) {
            try scrollAndFlush();
        }
    }
}

pub fn scrollAndFlush() ConsoleError!void {
    const con = &(console orelse return ConsoleError.ConsoleNotInitialized);
    const virt = con.virt;
    const real = con.real;

    const height = virt.height;
    const pitch_pixels = virt.pitch / @sizeOf(Color); // actual row width in pixels

    const virt_pixels: [*]Color = @alignCast(@ptrCast(virt.address));
    const real_pixels: [*]Color = @alignCast(@ptrCast(real.address));

    const rows_to_scroll = font_y;

    // Scroll: move rows up in the virtual buffer
    for (rows_to_scroll..height) |y| {
        const src_row = virt_pixels[y * pitch_pixels .. (y + 1) * pitch_pixels];
        const dst_row = virt_pixels[(y - rows_to_scroll) * pitch_pixels .. y * pitch_pixels];
        @memcpy(dst_row[0..pitch_pixels], src_row[0..pitch_pixels]);
    }

    // Clear the last `font_y` rows in the virtual buffer
    for (0..rows_to_scroll) |i| {
        const y = height - rows_to_scroll + i;
        const row = virt_pixels[y * pitch_pixels .. (y + 1) * pitch_pixels];
        @memset(row[0..pitch_pixels], Color.BLACK);
    }

    con.cur_line -= 1;

    // Flush virt → real buffer
    const dst_pitch = real.pitch / @sizeOf(Color);
    const flush_height = height;

    for (0..flush_height) |y| {
        const src_row = virt_pixels[y * pitch_pixels .. (y + 1) * pitch_pixels];
        const dst_row = real_pixels[y * dst_pitch .. (y + 1) * dst_pitch];
        @memcpy(dst_row[0..pitch_pixels], src_row[0..pitch_pixels]);
    }
}
