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

        pub fn init(allocator: Allocator) Self {
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

        pub fn deinit(self: *Self) void {
            self.clear();
        }

        fn setResult(comptime T: type, x: *T, r: Value, l: usize) !void {
            switch (T) {
                Value => x.* = r,
                ResultPair => {
                    x.value = r;
                    x.length = l;
                },
                else => return error.InvalidResultType,
            }
        }

        pub fn setArray(self: *Self, array: []UnitT, array_size: usize) void {
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

        pub fn unitSize(_: Self) usize {
            return @sizeOf(UnitT);
        }

        pub fn size(self: Self) usize {
            return self.array_size;
        }

        pub fn totalSize(self: Self) usize {
            return self.array_size * @sizeOf(UnitT);
        }

        pub fn nonZeroSize(self: Self) usize {
            var result = 0;
            for (self.array) |unit| {
                if (unit.check > 0) {
                    result += 1;
                }
            }
            return result;
        }

        pub fn build(self: *Self, key_size: usize, key: []const []const Key, length_array: ?[]const usize, value_array: ?[]const Value) !void {
            if (key_size < 1) return error.BuildKeyError;

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
            _ = try self.insert(siblings);

            // Padding
            self.array_size += (1 << 8 * @sizeOf(Key)) + 1;
            if (self.array_size >= self.alloc_size) try self.resize(self.array_size);
        }

        pub fn open() !void {}

        pub fn save() !void {}

        pub fn commonPrefixSearch(self: Self, comptime T: type, key: []const Key, result: []T, result_len: usize, k_len_or_null: ?usize, node_pos_or_null: ?usize) !usize {
            const k_len = k_len_or_null orelse len(Key, key);
            const node_pos = node_pos_or_null orelse 0;

            var b: Array = self.array.?[node_pos].base;
            var num: usize = 0;
            var n: ?Array = null;
            var p: ?ArrayU = null;

            for (0..k_len) |i| {
                p = @intCast(b); // +0;
                n = self.array.?[p.?].base; // (#) Leaf of trie?
                if (b == self.array.?[p.?].check and n.? < 0) {
                    // result[num] = -n-1;
                    if (num < result_len) try setResult(T, &result[num], -n.? - 1, i);
                    num += 1;
                }

                p = @intCast(b + key[i] + 1);
                if (b == self.array.?[p.?].check)
                    b = self.array.?[p.?].base
                else
                    return num;
            }

            p = @intCast(b);
            n = self.array.?[p.?].base;

            if (b == self.array.?[p.?].check and n.? < 0) {
                if (num < result_len) try setResult(T, &result[num], -n.? - 1, k_len);
                num += 1;
            }

            return num;
        }

        pub fn traverse(self: Self, key: []const Key, node_pos: *usize, key_pos: *usize, k_len_or_null: ?usize) !Value {
            const k_len = k_len_or_null orelse len(Key, key);

            var b = self.array.?[node_pos.*].base;
            var p: ?ArrayU = null;

            while (key_pos.* < k_len) : (key_pos.* += 1) {
                p = @intCast(b + key[key_pos.*] + 1);
                if (b == self.array.?[p.?].check) {
                    node_pos.* = p.?;
                    b = self.array.?[p.?].base;
                } else return error.NoNode;
            }

            p = @intCast(b);
            const n = self.array.?[p.?].base;
            if (b == self.array.?[p.?].check and n < 0) return -n - 1; // Value is Found!

            return error.FoundButNoValue;
        }

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

                var cur: ArrayU = 0;
                if (self.keyLength(i) != parent.depth) cur = tmp[parent.depth] + 1;

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

        fn insert(self: *Self, siblings: ArrayList(NodeT)) !usize {
            var begin: usize = 0;
            var pos: usize = @max(siblings.items[0].code + 1, self.next_check_pos) - 1;
            var nonzero_num: usize = 0;
            var first = false;

            if (self.alloc_size <= pos) try self.resize(pos + 1);

            next: while (true) {
                pos += 1;

                if (self.alloc_size <= pos) try self.resize(pos + 1);

                if (self.array.?[pos].check > 0) {
                    nonzero_num += 1;
                    continue;
                } else if (!first) {
                    self.next_check_pos = pos;
                    first = true;
                }

                begin = pos - siblings.items[0].code;
                if (self.alloc_size <= (begin + siblings.items[siblings.items.len - 1].code)) {
                    const key_size: f32 = @floatFromInt(self.key_size);
                    const progress: f32 = @floatFromInt(self.progress);
                    try self.resize(self.alloc_size * @as(u32, @intFromFloat(@max(1.05, key_size / progress))));
                }

                if (self.used.?[begin] > 0) continue;

                for (1..siblings.items.len) |i| {
                    if (self.array.?[begin + siblings.items[i].code].check != 0) continue :next;
                }

                break;
            }

            if (@as(f32, @floatFromInt(nonzero_num)) / @as(f32, @floatFromInt(pos - self.next_check_pos + 1)) >= 0.95) {
                self.next_check_pos = pos;
            }

            self.used.?[begin] = 1;
            self.array_size = @max(self.array_size, begin + siblings.items[siblings.items.len - 1].code + 1);

            for (0..siblings.items.len) |i| {
                self.array.?[begin + siblings.items[i].code].check = @intCast(begin);
            }

            for (0..siblings.items.len) |i| {
                var new_siblings: ArrayList(NodeT) = .empty;
                defer new_siblings.deinit(self.allocator);

                if (try self.fetch(siblings.items[i], &new_siblings) < 1) {
                    self.array.?[begin + siblings.items[i].code].base = if (self.value_array == null)
                        -@as(i32, @intCast(siblings.items[i].left)) - 1
                    else
                        -self.value_array.?[siblings.items[i].left] - 1;

                    if (self.value_array != null and -self.value_array.?[siblings.items[i].left] - 1 >= 0) {
                        return error.WTF;
                    }

                    self.progress += 1;
                } else {
                    const h = try self.insert(new_siblings);
                    self.array.?[begin + siblings.items[i].code].base = @intCast(h);
                }
            }

            return begin;
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
    const expected = [_]usize{ 3, 5, 5, 3, 5, 4, 3, 4, 3 };

    // Ignore Build process and test only length func
    // build to set key
    da.build(key.len, key, null, null) catch {};

    for (expected, 0..) |e, i| {
        try std.testing.expectEqual(e, da.keyLength(i));
    }
}

test "commonPrefixSearch" {
    var da = DoubleArray.init(std.testing.allocator);
    defer da.deinit();

    const key = &[_][]const u8{ "a", "ab", "abc", "abd", "ba", "bbc", "ca" };
    try da.build(key.len, key, null, null);

    const input = "abcd";

    const result = try std.testing.allocator.alloc(DoubleArray.ResultPair, 1024);
    defer std.testing.allocator.free(result);

    const num = try da.commonPrefixSearch(DoubleArray.ResultPair, input, result, result.len, null, null);

    try std.testing.expectEqual(3, num);
    try std.testing.expect(std.mem.eql(u8, "a", input[0..result[0].length]));
    try std.testing.expect(std.mem.eql(u8, "ab", input[0..result[1].length]));
    try std.testing.expect(std.mem.eql(u8, "abc", input[0..result[2].length]));
}

test "traverse" {
    var da = DoubleArray.init(std.testing.allocator);
    defer da.deinit();

    const key = &[_][]const u8{ "a", "ab", "abc", "abd", "ba", "bbc", "ca" };
    try da.build(key.len, key, null, null);

    const input = "abc";

    const result = try std.testing.allocator.alloc(DoubleArray.ResultPair, 1024);
    defer std.testing.allocator.free(result);

    var node_pos: usize = 0;
    var key_pos: usize = 0;
    const v = try da.traverse(input, &node_pos, &key_pos, null);

    try std.testing.expectEqual(2, v);
    try std.testing.expectEqual(3, key_pos);
}
