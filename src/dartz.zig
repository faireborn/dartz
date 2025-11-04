const std = @import("std");

pub const DoubleArray = DoubleArrayImpl(u8, u8, i32, u32);
pub fn DoubleArrayImpl(comptime Node: type, comptime NodeU: type, comptime Array: type, comptime ArrayU: type) type {
    return struct {
        array: ?[]UnitT,
        used: ?[]u8,
        array_size: usize,
        alloc_size: usize,
        key_size: usize,
        key: ?[]const []const Node,
        length: ?[]const usize,
        value: ?[]const Array,
        progress: usize,
        next_check_pos: usize,
        no_delete: bool,
        allocator: std.mem.Allocator,

        const Self = @This();

        fn init(allocator: std.mem.Allocator) Self {
            return .{
                .array = null,
                .used = null,
                .array_size = 0,
                .alloc_size = 0,
                .key_size = 0,
                .key = null,
                .length = null,
                .value = null,
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

        fn build(self: *Self, key_size: usize, key: []const []const Key, length: ?[]const usize, value: ?[]const Value) !void {
            if (key_size < 1) {
                return error.BuildKeySizeError;
            }

            // Free `used` array and set null
            defer reset(u8, self.allocator, &self.used);
            self.key_size = key_size;
            self.key = key;
            self.length = length;
            self.value = value;

            // initialize `array` and `used`
            try self.resize(8192);

            self.array.?[0].base = 1;
            self.next_check_pos = 0;

            const root_node: NodeT = .{ .code = 0, .left = 0, .right = key_size, .depth = 0 };
            _ = root_node;

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

        fn fetch(parent: []const NodeT, siblings: std.ArrayList(NodeT)) void {
            _ = parent;
            _ = siblings;
        }

        fn pad(comptime T: type, allocator: std.mem.Allocator, array: ?[]const T, n: usize, l: usize, v: T) ![]T {
            const tmp = try allocator.alloc(T, l);

            if (array != null) {
                // Free original array
                defer allocator.free(array.?);
                @memcpy(tmp[0..n], array.?);
            }

            @memset(tmp[n..], v);
            return tmp;
        }

        fn reset(comptime T: type, allocator: std.mem.Allocator, array: *?[]T) void {
            if (array.* == null) {
                return;
            }

            allocator.free(array.*.?);
            array.* = null;
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
