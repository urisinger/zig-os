const std = @import("std");
const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
const cpu = @import("cpu.zig");

const serial = @import("serial.zig");
const console = @import("display/console.zig");

const conf = @import("conf.zig");

const core = @import("core.zig");

const log_writer = std.io.Writer(void, error{}, write){
    .context = {},
};

fn write(_: void, bytes: []const u8) error{}!usize {
    serial.puts(bytes);
    console.puts(bytes) catch {};
    return bytes.len;
}

pub fn init() void {
    serial.init() catch {
        @panic("failed to initialize logged");
    };
    std.log.info("initialized logger", .{});
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
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

    const colored_prefix = color ++ prefix ++ reset_color;

    log_writer.print(colored_prefix ++ format ++ "\n", args) catch return;
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);
    const log = std.log.scoped(.panic);
    log.err("kernel panic: {s}", .{msg});
    const panic_printer = log_writer;

    var iter = std.debug.StackIterator.init(@returnAddress(), @frameAddress());
    if (getSelfDwarf()) |_dwarf| {
        const gpa = core.context().gpa.allocator();

        var dwarf = _dwarf;
        defer dwarf.deinit(gpa);

        while (iter.next()) |r_addr| {
            printSourceAtAddress(panic_printer, &dwarf, r_addr) catch {};
        }
    } else |err| {
        log.err("failed to open DWARF info: {}", .{err});

        while (iter.next()) |r_addr| {
            std.fmt.format(panic_printer, "  \x1B[90m0x{x:0>16}\x1B[0m\n", .{r_addr}) catch {};
        }
    }

    std.fmt.format(panic_printer, "\n", .{}) catch {};

    cpu.halt();
}

pub const Addr2Line = struct {
    addr: usize,

    pub fn format(self: Addr2Line, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const gpa = core.context().gpa.allocator();

        if (getSelfDwarf()) |_dwarf| {
            var dwarf = _dwarf;
            defer dwarf.deinit(gpa);
            try printSourceAtAddress(writer, &dwarf, self.addr);
        } else |err| {
            try std.fmt.format(writer, "failed to open DWARF info: {}\n", .{err});
        }
    }
};

fn printSourceAtAddress(writer: anytype, debug_info: *std.debug.Dwarf, address: usize) !void {
    const gpa = core.context().gpa.allocator();

    const sym = debug_info.getSymbol(gpa, address) catch {
        try std.fmt.format(writer, "\x1B[90m0x{x}\x1B[0m\n", .{address});
        return;
    };
    defer if (sym.source_location) |loc| std.heap.page_allocator.free(loc.file_name);

    try std.fmt.format(writer, "\x1B[1m", .{});

    if (sym.source_location) |*sl| {
        try std.fmt.format(
            writer,
            "{s}:{d}:{d}",
            .{ sl.file_name, sl.line, sl.column },
        );
    } else {
        try std.fmt.format(writer, "???:?:?", .{});
    }

    try std.fmt.format(
        writer,
        "\x1B[0m: \x1B[90m0x{x} in {s} ({s})\x1B[0m\n",
        .{ address, sym.name, sym.compile_unit_name },
    );

    // std.debug.printSourceAtAddress(debug_info: *SelfInfo, out_stream: anytype, address: usize, tty_config: io.tty.Config)

    const loc = sym.source_location orelse return;
    const source_file = findSourceFile(loc.file_name) orelse return;

    var source_line: []const u8 = "<out-of-bounds>";
    var lines_iter = std.mem.splitScalar(u8, source_file.contents, '\n');
    for (0..loc.line) |_| {
        source_line = lines_iter.next() orelse "<out-of-bounds>";
    }

    try std.fmt.format(writer, "{s}\n", .{source_line});

    const space_needed = @as(usize, @intCast(loc.column - 1));

    try writer.writeBytesNTimes(" ", space_needed);
    try writer.writeAll("\x1B[92m^\x1B[0m\n");
}

fn findSourceFile(path: []const u8) ?SourceFile {
    for_loop: for (source_files) |s| {
        // b path is a full absolute path,
        // while a is relative to the git repo

        var a = std.fs.path.componentIterator(s.path) catch
            continue;
        var b = std.fs.path.componentIterator(path) catch
            continue;

        const a_last = a.last() orelse continue;
        const b_last = b.last() orelse continue;

        if (!std.mem.eql(u8, a_last.name, b_last.name)) continue;

        while (a.previous()) |a_part| {
            const b_part = b.previous() orelse continue :for_loop;
            if (!std.mem.eql(u8, a_part.name, b_part.name)) continue :for_loop;
        }

        return s;
    }

    return null;
}

const SourceFile = struct {
    path: []const u8,
    contents: []const u8,

    fn open(comptime path: []const u8) SourceFile {
        return .{
            .path = path,
            .contents = @embedFile(path),
        };
    }
};

const source_files: []const SourceFile = &.{
    .open("utils.zig"),
    .open("tss.zig"),
    .open("cpu.zig"),
    .open("gdt.zig"),
    .open("idt/idt.zig"),
    .open("idt/syscall.zig"),
    .open("logger.zig"),
    .open("main.zig"),
    .open("memory/buddy.zig"),
    .open("memory/kernel/heap.zig"),
    .open("memory/kernel/paging.zig"),
    .open("memory/pmm.zig"),
    .open("memory/user/heap.zig"),
    .open("memory/user/vmm.zig"),
    .open("syscalls.zig"),
    .open("boot.zig"),
    .open("scheduler/scheduler.zig"),
    .open("serial.zig"),
    .open("display/console.zig"),
    .open("conf.zig"),
};

fn getSelfDwarf() !std.debug.Dwarf {
    if (!conf.STACK_TRACE) return error.StackTracesDisabled;

    const gpa = core.context().gpa.allocator();

    // std.debug.captureStackTrace(first_address: ?usize, stack_trace: *std.builtin.StackTrace)

    const kernel_file = @import("boot.zig").kernel_file.response orelse return error.NoKernelFile;
    const addr: [*]u8 = @ptrCast(kernel_file.kernel_file.address);
    const size = kernel_file.kernel_file.size;
    const elf_bin = addr[0..size];
    var elf = std.io.fixedBufferStream(elf_bin);

    const header = try std.elf.Header.read(&elf);

    var sections = std.debug.Dwarf.null_section_array;

    for (sectionsHeaders(elf_bin, header)) |shdr| {
        const name = getString(elf_bin, header, shdr.sh_name);
        // std.log.info("shdr: {s}", .{name});

        if (std.mem.eql(u8, name, ".debug_info")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_info)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_abbrev")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_abbrev)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_str")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_str)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_line")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_line)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_ranges")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_ranges)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".eh_frame")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".eh_frame_hdr")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame_hdr)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        }
    }

    var dwarf: std.debug.Dwarf = .{
        .endian = .little,
        .sections = sections,
        .is_macho = false,
    };

    try dwarf.open(gpa);

    return dwarf;
}

fn getString(bin: []const u8, header: std.elf.Header, off: u32) []const u8 {
    const strtab = getSectionData(
        bin,
        sectionsHeaders(bin, header)[header.shstrndx],
    );
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(strtab.ptr + off)), 0);
}

fn getSectionData(bin: []const u8, shdr: std.elf.Elf64_Shdr) []const u8 {
    return bin[shdr.sh_offset..][0..shdr.sh_size];
}

fn sectionsHeaders(bin: []const u8, header: std.elf.Header) []const std.elf.Elf64_Shdr {
    // FIXME: bounds checking maybe
    const section_headers: [*]const std.elf.Elf64_Shdr = @alignCast(@ptrCast(bin.ptr + header.shoff));
    return section_headers[0..header.shnum];
}

fn sectionFromSym(start: *const u8, end: *const u8) std.debug.Dwarf.Section {
    const size = @intFromPtr(end) - @intFromPtr(start);
    const addr = @as([*]const u8, @ptrCast(start));
    return .{
        .data = addr[0..size],
        .owned = false,
    };
}
