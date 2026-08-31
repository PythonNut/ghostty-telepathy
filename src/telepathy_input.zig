//! Stateful input encoding used by Telepathy's narrow Android embedding.
const std = @import("std");
const inputpkg = @import("input.zig");
const terminalpkg = @import("terminal/main.zig");

pub const modifier_shift: u32 = 1 << 0;
pub const modifier_control: u32 = 1 << 1;
pub const modifier_alt: u32 = 1 << 2;
pub const modifier_super: u32 = 1 << 3;
const modifier_mask = modifier_shift | modifier_control | modifier_alt | modifier_super;

pub fn encodeKey(
    terminal: *const terminalpkg.Terminal,
    key_code: []const u8,
    action_value: u32,
    modifier_bits: u32,
    consumed_modifier_bits: u32,
    text: []const u8,
    unshifted_codepoint: u32,
    output: ?[]u8,
    output_length: *usize,
) bool {
    output_length.* = 0;
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    if (!validCodepoint(unshifted_codepoint)) return false;

    const action_int = std.math.cast(c_int, action_value) orelse return false;
    const action = std.meta.intToEnum(inputpkg.Action, action_int) catch return false;
    const key = inputpkg.Key.fromW3C(key_code) orelse return false;
    const modifiers = modifiersFromBits(modifier_bits) orelse return false;
    const consumed_modifiers = modifiersFromBits(consumed_modifier_bits) orelse return false;
    const event: inputpkg.KeyEvent = .{
        .action = action,
        .key = key,
        .mods = modifiers,
        .consumed_mods = consumed_modifiers,
        .utf8 = text,
        .unshifted_codepoint = @intCast(unshifted_codepoint),
    };
    const options: inputpkg.key_encode.Options = .fromTerminal(terminal);

    var writer: std.Io.Writer = .fixed(output orelse &.{});
    inputpkg.key_encode.encode(&writer, event, options) catch |err| switch (err) {
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            inputpkg.key_encode.encode(&discarding.writer, event, options) catch unreachable;
            output_length.* = std.math.cast(usize, discarding.count) orelse return false;
            return false;
        },
    };
    output_length.* = writer.end;
    return true;
}

pub fn encodeText(
    terminal: *const terminalpkg.Terminal,
    text: []const u8,
    output: ?[]u8,
    output_length: *usize,
) bool {
    output_length.* = 0;
    if (!std.unicode.utf8ValidateSlice(text)) return false;

    const options: inputpkg.paste.Options = .fromTerminal(terminal);
    const framing_length: usize = if (options.bracketed) 12 else 0;
    const required = std.math.add(usize, text.len, framing_length) catch return false;
    output_length.* = required;
    if (required == 0) return true;
    const destination = output orelse return false;
    if (destination.len < required) return false;

    const prefix_length: usize = if (options.bracketed) 6 else 0;
    const mutable_text = destination[prefix_length .. prefix_length + text.len];
    @memcpy(mutable_text, text);
    const encoded = inputpkg.paste.encode(mutable_text, options);

    var offset: usize = 0;
    for (encoded) |part| {
        std.mem.copyForwards(u8, destination[offset .. offset + part.len], part);
        offset += part.len;
    }
    std.debug.assert(offset == required);
    return true;
}

fn modifiersFromBits(bits: u32) ?inputpkg.Mods {
    if (bits & ~modifier_mask != 0) return null;
    return .{
        .shift = bits & modifier_shift != 0,
        .ctrl = bits & modifier_control != 0,
        .alt = bits & modifier_alt != 0,
        .super = bits & modifier_super != 0,
    };
}

fn validCodepoint(codepoint: u32) bool {
    return codepoint == 0 or
        (codepoint <= 0x10FFFF and !(codepoint >= 0xD800 and codepoint <= 0xDFFF));
}

test "telepathy input follows cursor-key application mode" {
    const testing = std.testing;
    var terminal = try terminalpkg.Terminal.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();
    var output: [32]u8 = undefined;
    var output_length: usize = 0;

    try testing.expect(encodeKey(
        &terminal,
        "ArrowUp",
        @intFromEnum(inputpkg.Action.press),
        0,
        0,
        "",
        0,
        &output,
        &output_length,
    ));
    try testing.expectEqualStrings("\x1b[A", output[0..output_length]);

    try stream.nextSlice("\x1b[?1h");
    try testing.expect(encodeKey(
        &terminal,
        "ArrowUp",
        @intFromEnum(inputpkg.Action.press),
        0,
        0,
        "",
        0,
        &output,
        &output_length,
    ));
    try testing.expectEqualStrings("\x1bOA", output[0..output_length]);
}

test "telepathy input applies terminal paste semantics" {
    const testing = std.testing;
    var terminal = try terminalpkg.Terminal.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();
    var output: [64]u8 = undefined;
    var output_length: usize = 0;

    try testing.expect(encodeText(&terminal, "one\ntwo", &output, &output_length));
    try testing.expectEqualStrings("one\rtwo", output[0..output_length]);

    try stream.nextSlice("\x1b[?2004h");
    try testing.expect(encodeText(&terminal, "one\ntwo", &output, &output_length));
    try testing.expectEqualStrings("\x1b[200~one\ntwo\x1b[201~", output[0..output_length]);
}

test "telepathy input reports the required output capacity" {
    const testing = std.testing;
    var terminal = try terminalpkg.Terminal.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(testing.allocator);
    var output_length: usize = 0;

    try testing.expect(!encodeKey(
        &terminal,
        "ArrowLeft",
        @intFromEnum(inputpkg.Action.press),
        0,
        0,
        "",
        0,
        null,
        &output_length,
    ));
    try testing.expectEqual(@as(usize, 3), output_length);

    try testing.expect(!encodeText(&terminal, "hello", null, &output_length));
    try testing.expectEqual(@as(usize, 5), output_length);
}
