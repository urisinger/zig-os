const std = @import("std");
const idt = @import("../idt.zig");

pub fn divisionError(_: *volatile idt.Context) void {
    @panic("Unhandled division error.");
}

pub fn debugException(_: *volatile idt.Context) void {
    @panic("Unhandled debug exception.");
}

pub fn nonMaskableInterrupt(_: *volatile idt.Context) void {
    @panic("Unhandled non-maskable interrupt.");
}

pub fn breakpoint(_: *volatile idt.Context) void {
    @panic("Unhandled breakpoint exception.");
}

pub fn boundRangeExceeded(_: *volatile idt.Context) void {
    @panic("Unhandled bound range exceeded.");
}

pub fn invalidOpcode(_: *volatile idt.Context) void {
    @panic("Unhandled invalid opcode.");
}

pub fn deviceNotAvailable(_: *volatile idt.Context) void {
    @panic("Unhandled device not available.");
}

pub fn doubleFault(_: *volatile idt.Context) void {
    @panic("Unhandled double fault.");
}

pub fn coprocessorSegmentOverrun(_: *volatile idt.Context) void {
    @panic("Unhandled coprocessor segment overrun.");
}

pub fn invalidTSS(_: *volatile idt.Context) void {
    @panic("Unhandled invalid TSS.");
}

pub fn segmentNotPresent(_: *volatile idt.Context) void {
    @panic("Unhandled segment not present.");
}

pub fn stackSegmentFault(_: *volatile idt.Context) void {
    @panic("Unhandled stack segment fault.");
}

pub fn generalProtectionFault(_: *volatile idt.Context) void {
    @panic("Unhandled general protection fault.");
}

pub fn pageFault(_: *volatile idt.Context) void {
    @panic("Unhandled page fault.");
}

pub fn x87FloatingPoint(_: *volatile idt.Context) void {
    @panic("Unhandled x87 floating point exception.");
}

pub fn alignmentCheck(_: *volatile idt.Context) void {
    @panic("Unhandled alignment check.");
}

pub fn machineCheck(_: *volatile idt.Context) void {
    @panic("Unhandled machine check.");
}

pub fn simdFloatingPoint(_: *volatile idt.Context) void {
    @panic("Unhandled SIMD floating point exception.");
}

pub fn virtualizationException(_: *volatile idt.Context) void {
    @panic("Unhandled virtualization exception.");
}

pub fn securityException(_: *volatile idt.Context) void {
    @panic("Unhandled security exception.");
}
