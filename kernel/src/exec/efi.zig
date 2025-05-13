const std = @import("std");
const log = std.log;
const elf = std.elf;
const Header = elf.Header;


const page_table = @import("../memory/page_table.zig");
const uvmm = @import("../memory/user/vmm.zig");

pub fn loadEfi(buffer: []align(@alignOf(elf.Elf64_Ehdr)) const u8, _: *page_table.PageMapping, _: *uvmm.VmAllocator) !void {
    const header = try Header.parse(buffer[0..64]);

    log.debug("elf header: {}", .{header});

    var iter = header.section_header_iterator(std.io.fixedBufferStream(buffer));

    while (try iter.next()) |item| {
        log.debug("found section: {}", .{item});
    }
}
