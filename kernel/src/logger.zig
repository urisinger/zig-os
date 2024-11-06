const std = @import("std");
const uefi = std.os.uefi;
const log = std.log;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;

const serial = @import("serial.zig");
const console = @import("display/console.zig");

pub fn init() void {
    serial.init() catch {
        @panic("failed to initialize logged");
    };
    log.info("initialized logger", .{});
}

pub fn logFn(comptime level: log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const color = switch (level) {
        .err => "\x1b[31m", // Red for errors
        .warn => "\x1b[33m", // Yellow for warnings
        .info => "\x1b[32m", // Green for info
        .debug => "\x1b[36m", // Cyan for debug
    };

    const reset_color = "\x1b[0m";

    const scope_prefix = switch (scope) {
        std.log.default_log_scope => "",
        else => "(" ++ @tagName(scope) ++ ") ",
    };
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    // Apply the color to the prefix
    const colored_prefix = color ++ prefix ++ reset_color;

    // Print the formatted message with the colored prefix
    serial.writer().print(colored_prefix ++ format ++ "\n", args) catch return;
    console.writer().print(colored_prefix ++ format ++ "\n", args) catch return;
}
