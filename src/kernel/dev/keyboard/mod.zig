pub const ps2 = @import("ps2.zig");
const std = @import("std");
const log = std.log.scoped(.keyboard);

pub const KeyState = enum {
    pressed,
    released,
};

pub const KeyEvent = struct {
    code: KeyCode,
    state: KeyState,
};

pub const KeyCode = enum(u32) {
    A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
    Digit0, Digit1, Digit2, Digit3, Digit4, Digit5, Digit6, Digit7, Digit8, Digit9,
    Enter, Escape, LeftShift, RightShift, Backspace, Space, Tab,
    LeftControl, RightControl, LeftAlt, RightAlt,
    ArrowUp, ArrowDown, ArrowLeft, ArrowRight,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    Unknown
};


/// The Keyboard Manager handles events from all registered keyboard drivers.
pub const Manager = struct {
    var initialized: bool = false;
    
    // In a real OS, we'd have a ring buffer here to store events for consumers.
    // For now, we'll just log them or pass them to a TTY.
    
    pub fn init() void {
        initialized = true;
        log.info("Keyboard manager initialized", .{});
    }

    pub fn handleEvent(event: KeyEvent) void {
        if (!initialized) return;
        
        // This is where we'd push to a ring buffer or notify a listener.
        log.info("Key Event: {s} {s}", .{@tagName(event.code), @tagName(event.state)});
    }
};
