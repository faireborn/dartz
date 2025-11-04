const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const DoubleArray = DoubleArrayImpl(u8, u8, i32, u32);
pub fn DoubleArrayImpl(comptime Node: type, comptime NodeU: type, comptime Array: type, comptime ArrayU: type) type {
    return struct {
        array: ?[]UnitT,
        used: ?[]u8,
        array_size: usize,
        alloc_size: usize,
        key_size: usize,
        key: ?[]const []const Node,
        length_array: ?[]const usize,
        value_array: ?[]const Array,
        progress: usize,
        next_check_pos: usize,
        no_delete: bool,
        allocator: Allocator,

        const Self = @This();

        fn init(allocator: Allocator) Self {
            return .{
                .array = null,
                .used = null,
                .array_size = 0,
                .alloc_size = 0,
                .key_size = 0,
                .key = null,
                .length_array = null,
                .value_array = null,
                .progress = 0,
                .next_check_pos = 0,
                .no_delete = false,
                .allocator = allocator,
            };
        }

        fn deinit(self: *Self) void {
            self.clear();
        }

        fn setResult(_: Self, x: *Value, r: Value) void {
            x.* = r;
        }

        fn setResultPair(_: Self, x: *ResultPair, r: Value, l: usize) void {
            x.value = r;
            x.length = l;
        }

        fn setArray(self: *Self, array: []UnitT, array_size: usize) void {
            self.clear();
            self.array = array;
            self.array_size = array_size;
        }

        fn clear(self: *Self) void {
            if (!self.no_delete) {
                reset(UnitT, self.allocator, &self.array);
            }
            reset(u8, self.allocator, &self.used);
            self.alloc_size = 0;
            self.array_size = 0;
            self.no_delete = false;
        }

        fn unitSize(_: Self) usize {
            return @sizeOf(UnitT);
        }

        fn size(self: Self) usize {
            return self.array_size;
        }

        fn totalSize(self: Self) usize {
            return self.array_size * @sizeOf(UnitT);
        }

        fn nonZeroSize(self: Self) usize {
            var result = 0;
            for (self.array) |unit| {
                if (unit.check > 0) {
                    result += 1;
                }
            }
            return result;
        }

        fn build(self: *Self, key_size: usize, key: ?[]const []const Key, length_array: ?[]const usize, value_array: ?[]const Value) !void {
            if (key_size < 1 or key == null) return error.BuildKeyError;

            // Free `used` array and set null
            defer reset(u8, self.allocator, &self.used);

            self.key_size = key_size;
            self.key = key;
            self.length_array = length_array;
            self.value_array = value_array;
            self.progress = 0;

            // initialize `array` and `used`
            try self.resize(8192);

            self.array.?[0].base = 1;
            self.next_check_pos = 0;

            const root_node: NodeT = .{ .code = 0, .left = 0, .right = key_size, .depth = 0 };

            var siblings: ArrayList(NodeT) = .empty;
            defer siblings.deinit(self.allocator);
            _ = try self.fetch(root_node, &siblings);
            _ = insert(siblings);

            // Padding
            self.array_size += (1 << 8 * @sizeOf(Key)) + 1;
            if (self.array_size >= self.alloc_size) try self.resize(self.array_size);
        }

        fn open() !void {}

        fn save() !void {}

        fn resize(self: *Self, new_size: usize) !void {
            const tmp = UnitT{
                .base = 0,
                .check = 0,
            };

            self.array = try pad(UnitT, self.allocator, self.array, self.alloc_size, new_size, tmp);
            self.used = try pad(u8, self.allocator, self.used, self.alloc_size, new_size, 0);

            self.alloc_size = new_size;
            return;
        }

        fn fetch(self: Self, parent: NodeT, siblings: *ArrayList(NodeT)) !usize {
            var prev: ArrayU = 0;

            for (parent.left..parent.right) |i| {
                if (self.keyLength(i) < parent.depth) continue;

                const tmp = self.key.?[i];
                _ = tmp;

                var cur: ArrayU = 0;
                cur = 1;

                if (prev > cur) {
                    return error.BuildFetchError;
                }

                if (cur != prev or siblings.items.len == 0) {
                    const tmp_node = NodeT{ .depth = parent.depth + 1, .code = cur, .left = i, .right = 0 };
                    if (siblings.items.len > 0) siblings.items[siblings.items.len - 1].right = i;

                    try siblings.append(self.allocator, tmp_node);
                }

                prev = cur;
            }

            if (siblings.items.len > 0) siblings.items[siblings.items.len - 1].right = parent.right;
            return siblings.items.len;
        }

        fn insert(siblings: ArrayList(NodeT)) usize {
            _ = siblings;
            return 0;
        }

        fn reset(comptime T: type, allocator: Allocator, array: *?[]T) void {
            if (array.* == null) {
                return;
            }

            allocator.free(array.*.?);
            array.* = null;
        }

        fn keyLength(self: Self, i: usize) usize {
            if (self.length_array != null) return self.length_array.?[i];
            return len(Node, self.key.?[i]);
        }

        const ResultPair = struct {
            value: Value,
            length: usize,
        };

        const NodeT = struct {
            code: ArrayU,
            depth: usize,
            left: usize,
            right: usize,
        };
        const UnitT = struct {
            base: Array,
            check: ArrayU,
        };

        const Value = Array;
        const Key = Node;
        const Result = Array;

        const _ = NodeU;
    };
}

fn len(comptime T: type, key: []const T) usize {
    return key.len;
}

fn pad(comptime T: type, allocator: Allocator, array: ?[]const T, n: usize, l: usize, v: T) ![]T {
    const tmp = try allocator.alloc(T, l);

    if (array != null) {
        // Free original array
        defer allocator.free(array.?);
        @memcpy(tmp[0..n], array.?);
    }

    @memset(tmp[n..], v);
    return tmp;
}

test "Resize" {
    var da = DoubleArray.init(std.testing.allocator);
    defer da.deinit();

    const alloc_size = 1024;
    try da.resize(alloc_size);

    try std.testing.expectEqual(alloc_size, da.array.?.len);
    try std.testing.expectEqual(alloc_size, da.used.?.len);
    try std.testing.expectEqual(alloc_size, da.alloc_size);
}

test "Clear" {
    {
        // For `no_delete` = false
        var da = DoubleArray.init(std.testing.allocator);
        defer da.deinit();

        const alloc_size = 1024;
        try da.resize(alloc_size);
        da.clear();

        try std.testing.expectEqual(null, da.array);
        try std.testing.expectEqual(null, da.used);
        try std.testing.expectEqual(0, da.alloc_size);
        try std.testing.expectEqual(0, da.array_size);
        try std.testing.expectEqual(false, da.no_delete);
    }
    {
        // For `no_delete` = true
        var da = DoubleArray.init(std.testing.allocator);
        defer da.deinit();

        const alloc_size = 1024;
        try da.resize(alloc_size);
        da.no_delete = true;
        da.clear();

        try std.testing.expect(null != da.array);
        try std.testing.expectEqual(alloc_size, da.array.?.len);
        try std.testing.expectEqual(null, da.used);
        try std.testing.expectEqual(0, da.alloc_size);
        try std.testing.expectEqual(0, da.array_size);
        try std.testing.expectEqual(false, da.no_delete);
    }
}

test "Build" {
    var da = DoubleArray.init(std.testing.allocator);
    defer da.deinit();

    const key = &[_][]const u8{ "hello", "world" };
    try da.build(key.len, key, null, null);
}

test "Type which DoubleArray struct has" {
    var da = DoubleArray.init(std.testing.allocator);
    defer da.deinit();

    try std.testing.expectEqual(u8, DoubleArray.Key);
    try std.testing.expectEqual(i32, DoubleArray.Result);
}

test "Length func" {
    var da = DoubleArray.init(std.testing.allocator);
    defer da.deinit();

    const key = &[_][]const u8{ "The", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog" };
    try da.build(key.len, key, null, null);
    try std.testing.expectEqual(3, da.keyLength(0));
    try std.testing.expectEqual(5, da.keyLength(1));
    try std.testing.expectEqual(5, da.keyLength(2));
    try std.testing.expectEqual(3, da.keyLength(3));
    try std.testing.expectEqual(5, da.keyLength(4));
    try std.testing.expectEqual(4, da.keyLength(5));
    try std.testing.expectEqual(3, da.keyLength(6));
    try std.testing.expectEqual(4, da.keyLength(7));
    try std.testing.expectEqual(3, da.keyLength(8));
}
