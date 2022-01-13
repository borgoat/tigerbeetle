const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;

const config = @import("../config.zig");
const lsm = @import("tree.zig");
const binary_search = @import("binary_search").binary_search;

const Direction = @import("tree.zig").Direction;
const SegmentedArray = @import("segmented_array.zig").SegmentedArray;

fn div_ceil(numerator: anytype, denominator: anytype) @TypeOf(numerator, denominator) {
    const T = @TypeOf(numerator, denominator);
    return math.divCeil(T, numerator, denominator) catch unreachable;
}

pub fn ManifestLevel(
    comptime Key: type,
    comptime TableInfo: type,
    comptime compare_keys: fn (Key, Key) math.Order,
) type {
    return struct {
        const Self = @This();

        const Keys = SegmentedArray(Key, node_size, lsm.table_count_max);
        const Tables = SegmentedArray(TableInfo, node_size, lsm.table_count_max);

        /// The minimum key of each key node in the keys segmented array.
        /// This is the starting point of our tiered lookup approach.
        /// Only the first keys.node_count elements are valid.
        root_keys_array: *[Keys.node_count_max]Key,
        /// This is the index of the table node containing the TableInfo corresponding to a given
        /// root key. This allows us to skip table nodes which cannot contain the target TableInfo
        /// when searching for the TableInfo with a given absolute index.
        root_table_nodes_array: *[Keys.node_count_max]u32,

        // These two segmented arrays are parallel. That is, the absolute indexes of key and
        // corresponding TableInfo are the same. However, the number of nodes, node index, and
        // relative index into the node differ as the elements per node are different.
        keys: Keys,
        tables: Tables,

        fn init(allocator: *mem.Allocator, level: u8) !Self {}

        pub const Iterator = struct {
            level: *const Self,
            inner: Tables.Iterator,

            /// May pass math.maxInt(u64)-1 if there is no snapshot.
            snapshot: u64,
            key_min: Key,
            key_max: Key,
            direction: Direction,

            pub fn next(it: *Iterator) ?*const TableInfo {
                const table_info = it.inner.next() orelse return null;

                switch (direction) {
                    .ascending => {
                        if (compare_keys(table_info.key_min, it.key_max) == .gt) {
                            inner.done = true;
                            return null;
                        }
                    },
                    .descending => {
                        if (compare_keys(table_info.key_max, it.key_min) == .lt) {
                            inner.done = true;
                            return null;
                        }
                    },
                }

                return table_info;
            }
        };

        pub fn iterator(
            level: *const Self,
            /// May pass math.maxInt(u64) if there is no snapshot.
            snapshot: u64,
            key_min: Key,
            key_max: Key,
            direction: Direction,
        ) Iterator {
            const inner = blk: {
                const key = switch (direction) {
                    .ascending => key_min,
                    .descending => key_max,
                };
                if (level.iterator_start(key)) |start| {
                    // TODO move this code to a helper for iterator_start()
                    const reverse = level.keys.iterator(
                        level.keys.absolute_index(start.key_node, start.relative_index),
                        start.key_node,
                        direction.reverse(),
                    );

                    var adjusted = start;
                    assert(adjusted.key_node == reverse.key_node);
                    assert(adjusted.relative_index == reverse.relative_index);

                    const start_key = reverse.next().?;
                    var next_adjusted = adjusted;
                    next_adjusted.key_node = reverse.key_node;
                    next_adjusted.relative_index = reverse.relative_index;
                    while (reverse.next()) |k| {
                        if (compare_keys(start_key, k) != .eq) break;
                        adjusted = next_adjusted;
                        next_adjusted.key_node = reverse.key_node;
                        next_adjusted.relative_index = reverse.relative_index;
                    }
                    // TODO add assertions

                    break :blk level.keys.iterator(
                        level.keys.absolute_index(adjusted.key_node, adjusted.relative_index),
                        start.key_node,
                        direction,
                    );
                } else {
                    break :blk Tables.Iterator{
                        .array = undefined,
                        .direction = undefined,
                        .node = undefined,
                        .relative_index = undefined,
                        .done = true,
                    };
                }
            };

            return .{
                .level = level,
                .inner = inner,
                .snapshot = snapshot,
                .key_min = key_min,
                .key_max = key_max,
                .direction = direction,
            };
        }

        const Start = struct {
            key_node: u32,
            relative_index: u32,
        };

        // TODO add doc comments, this is pretty tricky
        fn iterator_start(level: Self, key: Key) ?Start {
            const root = level.root_keys();
            if (root.len == 0) return null;

            const root_result = binary_search(root, key);
            if (root_result.exact) {
                return .{
                    .key_node = root_result.index,
                    .relative_index = 0,
                };
            } else if (root_result.index == 0) {
                // Out of bounds to the left, so start the search at the first table in the
                // level in the case of an ascending search. This is not strictly necessary
                // in the case of a descending search, but it allows us to have a single code
                // path for ascending and descending searches.
                return .{
                    .key_node = 0,
                    .relative_index = 0,
                };
            } else {
                const key_node = root_result.index - 1;

                const keys = level.keys.node_elements(key_node);
                const keys_result = binary_search(keys, key);

                // Since we didn't have an exact match in the previous binary search, and since
                // we've already handled the case of being out of bounds to the left with an
                // early return, we know that the target key_min is strictly greater than the
                // first key in the key node.
                assert(keys_result.index != 0);

                return .{
                    .key_node = key_node,
                    .relative_index = keys_result.index - @boolToInt(!keys_result.exact),
                };
            }
        }

        inline fn iterator_start_table_node_for_key_node(level: Self, key_node: u32) u32 {
            assert(key_node < level.keys.node_count);
            return level.root_table_nodes_array[key_node];
        }

        const BinarySearchResult = struct {
            index: usize,
            exact: bool,
        };

        // TODO move this back to binary_search.zig and allow max key searching.
        fn binary_search(keys: []const Key, key: Key) BinarySearchResult {
            assert(keys.len > 0);

            var offset: usize = 0;
            var length: usize = keys.len;
            while (length > 1) {
                const half = length / 2;
                const mid = offset + half;

                // This trick seems to be what's needed to get llvm to emit branchless code for this,
                // a ternay-style if expression was generated as a jump here for whatever reason.
                const next_offsets = [_]usize{ offset, mid };
                offset = next_offsets[@boolToInt(compare_keys(keys[mid], key) == .lt)];

                length -= half;
            }
            const exact = compare_keys(keys[offset], key) == .eq;
            return .{
                .index = offset + @boolToInt(!exact),
                .exact = exact,
            };
        }

        inline fn root_keys(level: Self) []Key {
            return level.root_keys_array[0..level.keys.node_count];
        }
    };
}
