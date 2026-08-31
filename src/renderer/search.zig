const std = @import("std");
const terminal = @import("../terminal/main.zig");

pub const Matches = struct {
    arena: std.heap.ArenaAllocator,
    matches: []const terminal.highlight.Flattened,
};

pub const Match = struct {
    arena: std.heap.ArenaAllocator,
    match: terminal.highlight.Flattened,
};
