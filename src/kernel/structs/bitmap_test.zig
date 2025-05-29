const std = @import("std");
const testing = std.testing;
const Bitmap = @import("bitmap.zig").Bitmap;

test "bitmap initialization" {
    var memory: [1]u64 = undefined;
    const bitmap = try Bitmap.init(&memory, 64);

    try testing.expectEqual(@as(usize, 64), bitmap.size);
    try testing.expectEqual(@as(usize, 1), bitmap.data.len);
}

test "bitmap get/set/clear" {
    var memory: [1]u64 = undefined;
    var bitmap = try Bitmap.init(&memory, 64);

    bitmap.zero();

    // Test individual bit operations
    bitmap.set(5);
    try testing.expect(bitmap.get(5));

    bitmap.clear(5);
    try testing.expect(!bitmap.get(5));

    // Test edge cases
    bitmap.set(0);
    try testing.expect(bitmap.get(0));

    bitmap.set(63);
    try testing.expect(bitmap.get(63));
}

test "bitmap findFirstSet" {
    var memory: [2]u64 = undefined;
    var bitmap = try Bitmap.init(&memory, 128);

    bitmap.zero();

    // Test empty bitmap
    try testing.expectEqual(null, bitmap.findFirstSet());

    // Test single bit set
    bitmap.set(5);
    try testing.expectEqual(@as(?usize, 5), bitmap.findFirstSet());

    // Test multiple bits set
    bitmap.set(10);
    try testing.expectEqual(@as(?usize, 5), bitmap.findFirstSet());

    // Test across word boundary
    bitmap.clear(5);
    bitmap.clear(10);
    bitmap.set(65);
    try testing.expectEqual(@as(?usize, 65), bitmap.findFirstSet());
}

test "bitmap findFirstClear" {
    var memory: [2]u64 = undefined;
    var bitmap = try Bitmap.init(&memory, 128);

    bitmap.zero();

    // Test full bitmap
    bitmap.setRange(0, 128);
    try testing.expectEqual(null, bitmap.findFirstClear());

    // Test single bit clear
    bitmap.clear(5);
    try testing.expectEqual(@as(?usize, 5), bitmap.findFirstClear());

    // Test multiple bits clear
    bitmap.clear(10);
    try testing.expectEqual(@as(?usize, 5), bitmap.findFirstClear());
}

test "bitmap findFirstNSet" {
    var memory: [2]u64 = undefined;
    var bitmap = try Bitmap.init(&memory, 128);

    bitmap.zero();

    // Test empty bitmap
    try testing.expectEqual(@as(?usize, null), bitmap.findFirstNSet(3));

    // Test single bit set
    bitmap.set(5);
    try testing.expectEqual(@as(?usize, null), bitmap.findFirstNSet(3));

    // Test multiple bits set
    bitmap.set(6);
    bitmap.set(7);
    try testing.expectEqual(@as(?usize, 5), bitmap.findFirstNSet(3));

    // Test across word boundary
    bitmap.clear(5);
    bitmap.clear(6);
    bitmap.clear(7);
    bitmap.set(63);
    bitmap.set(64);
    bitmap.set(65);
    try testing.expectEqual(@as(?usize, 63), bitmap.findFirstNSet(3));
}

test "bitmap setRange/clearRange" {
    var memory: [2]u64 = undefined;
    var bitmap = try Bitmap.init(&memory, 128);

    bitmap.zero();

    // Test setting range
    bitmap.setRange(5, 10);
    for (5..10) |i| {
        try testing.expect(bitmap.get(i));
    }

    // Test clearing range
    bitmap.clearRange(5, 10);
    for (5..10) |i| {
        try testing.expect(!bitmap.get(i));
    }

    // Test edge cases
    bitmap.setRange(0, 64);
    for (0..64) |i| {
        try testing.expect(bitmap.get(i));
    }

    bitmap.clearRange(0, 64);
    for (0..64) |i| {
        try testing.expect(!bitmap.get(i));
    }
}

test "bitmap zero" {
    var memory: [2]u64 = undefined;
    var bitmap = try Bitmap.init(&memory, 128);

    // Set all bits
    bitmap.setRange(0, 64);

    // Zero the bitmap
    bitmap.zero();

    // Verify all bits are cleared
    for (0..64) |i| {
        try testing.expect(!bitmap.get(i));
    }
}

test "bitmap findFirstNAligned" {
    var memory: [5]u64 = undefined;
    var bitmap = try Bitmap.init(&memory, 320);

    bitmap.zero();

    // Test word-aligned cases (alignment >= 64)
    const word_alignment = .@"64"; // 64 bytes

    // Test empty bitmap
    try testing.expectEqual(@as(?usize, null), bitmap.findFirstNSetAligned(1, word_alignment));

    // Test single word set at aligned position
    bitmap.setRange(64, 128); // Set second word
    try testing.expectEqual(@as(?usize, 64), bitmap.findFirstNSetAligned(64, word_alignment));

    // Test multiple words set
    bitmap.setRange(128, 192); // Set third word
    try testing.expectEqual(@as(?usize, 64), bitmap.findFirstNSetAligned(128, word_alignment));

    // Test unaligned set bits
    bitmap.zero();
    bitmap.setRange(65, 70); // Set some bits in second word
    try testing.expectEqual(@as(?usize, null), bitmap.findFirstNSetAligned(1, word_alignment));

    // Test bit-aligned cases (alignment < 64)
    const bit_alignment = .@"4"; // 4 bytes

    bitmap.zero();

    // Test single bit set at aligned position
    bitmap.set(4);
    try testing.expectEqual(@as(?usize, 4), bitmap.findFirstNSetAligned(1, bit_alignment));

    // Test multiple bits set at aligned position
    bitmap.set(5);
    bitmap.set(6);
    try testing.expectEqual(@as(?usize, 4), bitmap.findFirstNSetAligned(3, bit_alignment));

    // Test unaligned set bits
    bitmap.zero();
    bitmap.set(5);
    bitmap.set(6);
    bitmap.set(7);
    try testing.expectEqual(@as(?usize, null), bitmap.findFirstNSetAligned(3, bit_alignment));

    // Test across word boundary
    bitmap.zero();
    bitmap.set(60);
    bitmap.set(61);
    bitmap.set(62);
    bitmap.set(63);
    bitmap.set(64);
    try testing.expectEqual(@as(?usize, 60), bitmap.findFirstNSetAligned(5, bit_alignment));

    // Test large alignment
    const large_alignment = std.mem.Alignment.fromByteUnits(256); // 256 bytes
    bitmap.zero();
    bitmap.setRange(256, 320);
    try testing.expectEqual(@as(?usize, 256), bitmap.findFirstNSetAligned(64, large_alignment));
}

test "bitmap invalid initialization" {
    var memory: [1]u64 = undefined;
    try testing.expectError(error.InvalidSize, Bitmap.init(&memory, 65));

    var memory2: [2]u64 = undefined;
    try testing.expectError(error.InvalidSize, Bitmap.init(&memory2, 129));
}
