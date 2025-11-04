const std = @import("std");

pub const DoubleArray = DoubleArrayImpl(u8, u8, i32, u32);
pub fn DoubleArrayImpl(comptime Node: type, comptime NodeU: type, comptime Array: type, comptime ArrayU: type) type {
    return struct {
        array: []UnitT,
        used: []u8,
        array_size: usize,
        alloc_size: usize,
        key_size: usize,
        key: ?[]const []const Node,
        length: ?[]usize,
        value: ?[]Array,
        progress: usize,
        next_check_pos: usize,
        no_delete: bool,
        allocator: std.mem.Allocator,

        const Self = @This();

        fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .array = try allocator.alloc(UnitT, 0),
                .used = try allocator.alloc(u8, 0),
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

        fn deinit(self: Self) void {
            self.allocator.free(self.array);
            self.allocator.free(self.used);
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
            self.allocator.free(self.used);
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

        fn build(self: *Self, key_size: usize, key: []const []const Key, length: []const usize, value: []const Value) !void {
            if (key_size < 1) {
                return error.BuildKeySizeError;
            }

            // Free `used` array
            defer self.allocator.free(self.used);

            self.key_size = key_size;
            self.key = key;
            self.length = length;
            self.value = value;

            // initialize `array` and `used`
            try self.resize(8192);

            self.array[0].base = 1;
            self.next_check_pos = 0;

            const root_node: NodeT = .{ .left = 0, .right = key_size, .depth = 0 };
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

        fn pad(comptime T: type, allocator: std.mem.Allocator, array: []const T, n: usize, l: usize, v: T) ![]T {
            defer allocator.free(array);
            const tmp = try allocator.alloc(T, l);
            @memcpy(tmp[0..n], array);
            @memset(tmp[n..], v);
            return tmp;
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
    var da = try DoubleArray.init(std.testing.allocator);
    defer da.deinit();

    const alloc_size = 1024;
    try da.resize(alloc_size);

    try std.testing.expectEqual(alloc_size, da.array.len);
    try std.testing.expectEqual(alloc_size, da.used.len);
    try std.testing.expectEqual(alloc_size, da.alloc_size);
}
