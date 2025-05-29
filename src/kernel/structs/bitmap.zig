const std = @import("std");

pub const Bitmap = struct {
    data: []u64,
    size: usize,

    pub fn getBitmapSize(size: usize) usize {
        return ((size + 63) / 64);
    }

    pub fn getBitmapSizeBytes(size: usize) usize {
        return getBitmapSize(size) * 8;
    }

    pub fn init(mem: []u64, size: usize) !@This() {
        if (mem.len != getBitmapSize(size)) {
            return error.InvalidSize;
        }
        return .{ .data = mem, .size = size };
    }

    pub fn findFirstSet(self: *@This()) ?usize {
        var index: usize = 0;
        while (index < self.data.len) : (index += 1) {
            const dword = self.data[index];
            if (dword == 0) {
                continue;
            }

            const bit = @ctz(dword);
            return index * 64 + bit;
        }
        return null;
    }

    pub fn findFirstNSet(self: *@This(), n: usize) ?usize {
        var index: usize = 0;
        var count: usize = 0;
        while (index < self.data.len) : (index += 1) {
            const dword = self.data[index];
            if (dword == 0) {
                count = 0;
                continue;
            }

            for (0..64) |i| {
                if ((dword & (@as(u64, 1) << @intCast(i))) != 0) {
                    count += 1;
                    if (count == n) {
                        return index * 64 + i - n + 1;
                    }
                } else {
                    count = 0;
                }
            }
        }
        return null;
    }

    pub fn findFirstClear(self: *@This()) ?usize {
        var index: usize = 0;
        while (index < self.data.len) : (index += 1) {
            const dword = self.data[index];
            const inverted = ~dword;
            if (inverted == 0) {
                continue;
            }
            const bit = @ctz(inverted);
            return index * 64 + bit;
        }
        return null;
    }

    pub fn findFirstNClear(self: *@This(), n: usize) ?usize {
        var index: usize = 0;
        var count: usize = 0;
        while (index < self.data.len) : (index += 1) {
            const dword = self.data[index];
            if (dword == (1 << 64) - 1) {
                count = 0;
                continue;
            }

            for (0..64) |i| {
                if ((dword & (@as(u64, 1) << @intCast(i))) == 0) {
                    count += 1;
                    if (count == n) {
                        return index * 64 + i - n + 1;
                    }
                } else {
                    count = 0;
                }
            }
        }
        return null;
    }

    pub fn zero(self: *@This()) void {
        @memset(self.data, 0);
    }

    pub fn setAll(self: *@This()) void {
        @memset(self.data, 0xFFFFFFFFFFFFFFFF);
    }

    pub fn get(self: *@This(), index: usize) bool {
        return self.data[index / 64] & (@as(u64, 1) << @truncate(index % 64)) != 0;
    }

    pub fn set(self: *@This(), index: usize) void {
        self.data[index / 64] |= @as(u64, 1) << @truncate(index % 64);
    }

    pub fn clear(self: *@This(), index: usize) void {
        self.data[index / 64] &= ~(@as(u64, 1) << @truncate(index % 64));
    }

    pub fn setRange(self: *@This(), start: usize, end: usize) void {
        for (start..end) |i| {
            if (end > self.size) {
                return;
            }
            self.set(i);
        }
    }

    pub fn clearRange(self: *@This(), start: usize, end: usize) void {
        for (start..end) |i| {
            if (end > self.size) {
                return;
            }
            self.clear(i);
        }
    }

    pub fn findFirstNSetAligned(self: *@This(), n: usize, alignment: std.mem.Alignment) ?usize {
        // For alignments >= 64, we can check word by word
        if (alignment.toByteUnits() >= 64) {
            // Convert alignment to words alignment, by subtracting 6(log2(64))
            const words_alignment: std.mem.Alignment = @enumFromInt(@intFromEnum(alignment) - 6);
            var word_index: usize = 0;

            while (word_index < self.data.len) {
                // Check if this word position is aligned
                if (words_alignment.backward(word_index) != word_index) {
                    word_index += 1;
                    continue;
                }

                // If we need more bits than fit in a single word
                if (n > 64) {
                    // Check if we have enough space from this position
                    if (word_index * 64 + n > self.size) {
                        return null;
                    }

                    // Check if we have enough consecutive set bits
                    var count: usize = 0;
                    var current_word = word_index;
                    while (count < n and current_word < self.data.len) {
                        const word = self.data[current_word];
                        if (~word != 0) {
                            break;
                        }
                        count += 64;
                        current_word += 1;
                    }

                    // If we found enough full words, check remaining bits
                    if (count >= n) {
                        return word_index * 64;
                    }

                    // Skip to next alignment boundary
                    word_index = words_alignment.forward(word_index + 1);
                    continue;
                }

                // For smaller n, check if the word is fully set
                if (~self.data[word_index] == 0) {
                    return word_index * 64;
                }

                // Skip to next alignment boundary
                word_index = words_alignment.forward(word_index + 1);
            }
            return null;
        }

        // For smaller alignments, use the original bit-by-bit approach
        var index: usize = 0;
        var count: usize = 0;
        var start_index: ?usize = null;

        while (index < self.size) {
            if (self.get(index)) {
                if (start_index == null) {
                    // Check if this position is aligned
                    start_index = alignment.forward(index);
                    continue;
                }
                count += 1;
                if (count == n) {
                    return start_index;
                }
            } else {
                count = 0;
                start_index = null;
            }
            index += 1;
        }
        return null;
    }
};
