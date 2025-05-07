const idt = @import("../idt/idt.zig");

const Thread = packed struct {
    context: idt.Context,
};
