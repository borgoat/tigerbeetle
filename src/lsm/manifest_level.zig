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

            node: u32,
            /// The index inside the current table node.
            index: u32,

            /// May pass math.maxInt(u64)-1 if there is no snapshot.
            snapshot: u64,

            key_min: Key,
            key_max: Key,
            direction: Direction,

            pub fn next(it: *Iterator) ?*const TableInfo {
                {
                    assert(direction == .ascending);
                    if (it.node >= it.level.table_node_count) return null;
                }

                const tables_len = it.level.table_node_count[it.node];
                const tables = it.level.table_node_pointer[it.node][0..tables_len];

                const table_info = &tables[it.index];

                switch (direction) {
                    .ascending => {
                        assert(compare_keys(table_info.key_min, it.key_min) != .lt);
                        if (compare_keys(table_info.key_min, it.key_max) == .gt) {
                            // Set this to ensure that next() continues to return null if called again.
                            it.node = it.level.table_node_count;
                            return null;
                        }
                    },
                    .descending => {
                        assert(compare_keys(table_info.key_max, it.key_max) != .gt);
                        if (compare_keys(table_info.key_max, it.key_min) == .lt) {
                            // Set this to ensure that next() continues to return null if called again.
                            it.node = 0;
                            return null;
                        }
                    },
                }

                it.index += 1;
                if (it.index >= tables.len) {
                    assert(direction == .ascending);
                    it.index = 0;
                    it.node += 1;
                }

                return table_info;
            }
        };

        pub fn iterate(
            level: *const Self,
            /// May pass math.maxInt(u64) if there is no snapshot.
            snapshot: u64,
            key_min: Key,
            key_max: Key,
            direction: Direction,
        ) Iterator {
            // TODO handle descending direction
            assert(direction == .ascending);

            if (level.root_keys().len == 0) {
                // TODO return empty iterator
                unreachable;
            }

            const key_node = binary_search(level.root_keys(), key_min);
            if (key_node >= level.keys.node_count) {
                // TODO return empty iterator
                unreachable;
            }

            // TODO think through out of bounds/negative lookup/etc.
            const keys = level.keys.node_elements(key_node);
            const relative_index = binary_search(keys, key_min);
            if (relative_index >= keys.len) {
                // TODO return empty iterator
                unreachable;
            }
            const index = level.keys.absolute_index(key_node, relative_index);

            const start_node = level.root_table_nodes()[key_node];

            return .{
                .level = level,

                .iterator = level.tables.iterator(index, start_node, direction),

                .snapshot = snapshot,
                .key_min = key_min,
                .key_max = key_max,
                .direction = direction,
            };
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

        fn root_keys(level: Self) []Key {
            return level.root_keys_array[0..level.keys.node_count];
        }

        fn root_table_nodes(level: Self) []u32 {
            return level.root_table_nodes_array[0..level.keys.node_count];
        }
    };
}
