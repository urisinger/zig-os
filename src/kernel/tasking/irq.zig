const root = @import("root");
const arch = root.arch;
const Context = arch.context.Context;

pub fn timer(ctx: *Context) *Context{
    const scheduler = &arch.getContext().scheduler;
    arch.lapic.sendEoi();
    return scheduler.nextTask(ctx) orelse ctx;
}

