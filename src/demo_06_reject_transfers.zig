const tb = @import("tigerbeetle.zig");
const demo = @import("demo.zig");

pub fn main() !void {
    const commits = [_]tb.Commit{
        tb.Commit{
            .id = 1001,
            .reserved = [_]u8{0} ** 32,
            .code = 0,
            .flags = .{ .reject = true },
        },
    };

    try demo.request(.commit_transfers, commits, demo.on_commit_transfers);
}
