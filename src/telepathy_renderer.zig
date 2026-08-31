//! Narrow Android-facing Ghostty terminal and generic renderer artifact.
//!
//! Telepathy owns the Android lifecycle and eventual transport. This module
//! owns only terminal emulation, shaping/rasterization, generic draw-data
//! generation, and the Vulkan resources needed for one attached surface.
const std = @import("std");
const configpkg = @import("config.zig");
const font = @import("font/main.zig");
const rendererpkg = @import("renderer.zig");
const terminalpkg = @import("terminal/main.zig");
const AndroidVulkan = @import("renderer/Vulkan.zig");
const vulkan = @import("renderer/vulkan/vk.zig");
const android = @cImport({
    @cInclude("android/log.h");
});

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = androidLog,
};

const allocator = std.heap.c_allocator;
const GenericRenderer = rendererpkg.GenericRenderer(AndroidVulkan);
const ghostty_version = "1.3.1";

const Engine = struct {
    terminal: terminalpkg.Terminal,
    stream: terminalpkg.ReadonlyStream,
    render_state: terminalpkg.RenderState = .empty,
    terminal_mutex: std.Thread.Mutex = .{},
    font_library: font.Library,
    font_grid: font.SharedGrid,
    renderer: ?GenericRenderer = null,
    telemetry_enabled: bool = false,
};

pub const Snapshot = extern struct {
    struct_size: u32,
    rows: u32,
    columns: u32,
    cursor_x: i32,
    cursor_y: i32,
    non_empty_cells: u32,
    background_rgba: u32,
    foreground_rgba: u32,
    content_hash: u64,
};

pub const Cell = extern struct {
    codepoint: u32,
    foreground_rgba: u32,
    background_rgba: u32,
    flags: u16,
    width: u8,
    grapheme_length: u8,
};

pub const PerformanceMetrics = extern struct {
    struct_size: u32,
    flags: u32,
    model_update_samples: u64,
    model_update_total_ns: u64,
    acquire_samples: u64,
    acquire_total_ns: u64,
    encode_samples: u64,
    encode_total_ns: u64,
    queue_submit_samples: u64,
    queue_submit_total_ns: u64,
    queue_present_samples: u64,
    queue_present_total_ns: u64,
    gpu_completion_samples: u64,
    gpu_completion_total_ns: u64,
    display_samples: u64,
    display_total_ns: u64,
    atlas_upload_samples: u64,
    atlas_upload_total_ns: u64,
    atlas_upload_bytes: u64,
    submitted_frames: u64,
    completed_frames: u64,
    displayed_frames: u64,
    in_flight_frames: u64,
    max_in_flight_frames: u64,
    completion_queue_depth: u64,
    max_completion_queue_depth: u64,
};

const performance_flag_display_timing: u32 = 1 << 0;

const cell_flag_bold: u16 = 1 << 0;
const cell_flag_italic: u16 = 1 << 1;
const cell_flag_underline: u16 = 1 << 2;
const cell_flag_inverse: u16 = 1 << 3;
const cell_flag_blink: u16 = 1 << 4;
const cell_flag_faint: u16 = 1 << 5;
const cell_flag_invisible: u16 = 1 << 6;
const cell_flag_strikethrough: u16 = 1 << 7;
const cell_flag_overline: u16 = 1 << 8;
const cell_flag_spacer: u16 = 1 << 9;
const cell_flag_grapheme: u16 = 1 << 10;

export fn ghostty_telepathy_renderer_abi_version() u32 {
    return 1;
}

export fn telepathy_ghostty_version() [*:0]const u8 {
    return ghostty_version;
}

export fn telepathy_ghostty_create(
    columns: u32,
    rows: u32,
    max_scrollback: usize,
) ?*Engine {
    const safe_columns: terminalpkg.size.CellCountInt =
        @intCast(@max(1, @min(columns, 4096)));
    const safe_rows: terminalpkg.size.CellCountInt =
        @intCast(@max(1, @min(rows, 4096)));

    const engine = allocator.create(Engine) catch return null;
    errdefer allocator.destroy(engine);

    engine.font_library = font.Library.init(allocator) catch return null;
    errdefer engine.font_library.deinit();

    engine.font_grid = initFontGrid(engine.font_library) catch return null;
    errdefer engine.font_grid.deinit(allocator);

    var config = configpkg.Config.default(allocator) catch return null;
    defer config.deinit();
    engine.terminal = terminalpkg.Terminal.init(allocator, .{
        .cols = safe_columns,
        .rows = safe_rows,
        .max_scrollback = max_scrollback,
        .colors = .{
            .background = .init(config.background.toTerminalRGB()),
            .foreground = .init(config.foreground.toTerminalRGB()),
            .cursor = .unset,
            .palette = .init(config.palette.value),
        },
    }) catch return null;
    errdefer engine.terminal.deinit(allocator);

    engine.stream = engine.terminal.vtStream();
    errdefer engine.stream.deinit();
    engine.render_state = .empty;
    engine.terminal_mutex = .{};
    engine.renderer = null;
    engine.telemetry_enabled = false;

    // Grapheme clustering is opt-in in the terminal protocol. Telepathy uses
    // it by default so combining input and emoji sequences remain atomic.
    engine.stream.nextSlice("\x1b[?2027h") catch return null;
    return engine;
}

export fn telepathy_ghostty_destroy(engine: ?*Engine) void {
    const value = engine orelse return;
    if (value.renderer) |*active_renderer| active_renderer.deinit();
    value.render_state.deinit(allocator);
    value.stream.deinit();
    value.terminal.deinit(allocator);
    value.font_grid.deinit(allocator);
    value.font_library.deinit();
    allocator.destroy(value);
}

export fn telepathy_ghostty_write(
    engine: ?*Engine,
    bytes: ?[*]const u8,
    length: usize,
) bool {
    const value = engine orelse return false;
    if (length == 0) return true;
    const data = bytes orelse return false;
    value.stream.nextSlice(data[0..length]) catch return false;
    return true;
}

export fn telepathy_ghostty_resize(
    engine: ?*Engine,
    columns: u32,
    rows: u32,
) bool {
    const value = engine orelse return false;
    const safe_columns: terminalpkg.size.CellCountInt =
        @intCast(@max(1, @min(columns, 4096)));
    const safe_rows: terminalpkg.size.CellCountInt =
        @intCast(@max(1, @min(rows, 4096)));
    value.terminal.resize(allocator, safe_columns, safe_rows) catch return false;
    return true;
}

export fn telepathy_ghostty_surface_attach(
    engine: ?*Engine,
    native_window: ?*anyopaque,
    width: u32,
    height: u32,
) bool {
    const value = engine orelse return false;
    const window = native_window orelse return false;
    if (width == 0 or height == 0) return false;

    if (value.renderer) |*active_renderer| active_renderer.deinit();
    value.renderer = null;

    resizeTerminalForPixels(value, width, height);

    var config = configpkg.Config.default(allocator) catch return false;
    defer config.deinit();
    var derived = GenericRenderer.DerivedConfig.init(allocator, &config) catch return false;
    errdefer derived.deinit();

    const size: rendererpkg.Size = .{
        .screen = .{ .width = width, .height = height },
        .cell = value.font_grid.cellSize(),
        .padding = .{},
    };
    value.renderer = GenericRenderer.init(allocator, .{
        .config = derived,
        .font_grid = &value.font_grid,
        .size = size,
        .rt_surface = window,
    }) catch return false;
    if (value.telemetry_enabled) {
        value.renderer.?.api.setTelemetryEnabled(true);
    }

    // The owner populates the terminal immediately after attachment and then
    // requests the first frame. Avoid presenting a throwaway blank frame.
    return true;
}

export fn telepathy_ghostty_surface_resize(
    engine: ?*Engine,
    width: u32,
    height: u32,
) bool {
    const value = engine orelse return false;
    if (width == 0 or height == 0) return false;
    const active_renderer = if (value.renderer) |*r| r else return false;
    active_renderer.api.setSurfaceSize(width, height);
    resizeTerminalForPixels(value, width, height);
    active_renderer.markDirty();
    return draw(value);
}

export fn telepathy_ghostty_surface_draw(engine: ?*Engine) bool {
    return draw(engine orelse return false);
}

export fn telepathy_ghostty_surface_detach(engine: ?*Engine) void {
    const value = engine orelse return;
    if (value.renderer) |*active_renderer| active_renderer.deinit();
    value.renderer = null;
}

export fn telepathy_ghostty_set_performance_metrics_enabled(
    engine: ?*Engine,
    enabled: bool,
) void {
    const value = engine orelse return;
    value.telemetry_enabled = enabled;
    if (value.renderer) |*active_renderer| {
        active_renderer.api.setTelemetryEnabled(enabled);
    }
}

export fn telepathy_ghostty_get_performance_metrics(
    engine: ?*Engine,
    output: ?*PerformanceMetrics,
) bool {
    const value = engine orelse return false;
    const destination = output orelse return false;
    destination.* = std.mem.zeroes(PerformanceMetrics);
    destination.struct_size = @sizeOf(PerformanceMetrics);
    const active_renderer = if (value.renderer) |*renderer| renderer else return true;
    const snapshot = active_renderer.api.telemetrySnapshot();
    if (snapshot.display_timing_supported) {
        destination.flags |= performance_flag_display_timing;
    }
    destination.model_update_samples = snapshot.renderer.model_update.samples;
    destination.model_update_total_ns = snapshot.renderer.model_update.total_ns;
    destination.acquire_samples = snapshot.renderer.acquire.samples;
    destination.acquire_total_ns = snapshot.renderer.acquire.total_ns;
    destination.encode_samples = snapshot.renderer.encode.samples;
    destination.encode_total_ns = snapshot.renderer.encode.total_ns;
    destination.queue_submit_samples = snapshot.renderer.queue_submit.samples;
    destination.queue_submit_total_ns = snapshot.renderer.queue_submit.total_ns;
    destination.queue_present_samples = snapshot.renderer.queue_present.samples;
    destination.queue_present_total_ns = snapshot.renderer.queue_present.total_ns;
    destination.gpu_completion_samples = snapshot.renderer.gpu_completion.samples;
    destination.gpu_completion_total_ns = snapshot.renderer.gpu_completion.total_ns;
    destination.display_samples = snapshot.renderer.display.samples;
    destination.display_total_ns = snapshot.renderer.display.total_ns;
    destination.atlas_upload_samples = snapshot.device.atlas_upload.samples;
    destination.atlas_upload_total_ns = snapshot.device.atlas_upload.total_ns;
    destination.atlas_upload_bytes = snapshot.device.atlas_upload_bytes;
    destination.submitted_frames = snapshot.renderer.submitted_frames;
    destination.completed_frames = snapshot.renderer.completed_frames;
    destination.displayed_frames = snapshot.renderer.displayed_frames;
    destination.in_flight_frames = snapshot.renderer.in_flight_frames;
    destination.max_in_flight_frames = snapshot.renderer.max_in_flight_frames;
    destination.completion_queue_depth = snapshot.renderer.completion_queue_depth;
    destination.max_completion_queue_depth = snapshot.renderer.max_completion_queue_depth;
    return true;
}

fn draw(engine: *Engine) bool {
    const active_renderer = if (engine.renderer) |*r| r else return false;
    var state: rendererpkg.State = .{
        .mutex = &engine.terminal_mutex,
        .terminal = &engine.terminal,
    };
    const update_started_ns = if (active_renderer.api.telemetry.enabled())
        vulkan.monotonicNanos()
    else
        0;
    active_renderer.updateFrame(&state, true) catch |err| {
        std.log.err("Ghostty frame update failed: {}", .{err});
        return false;
    };
    if (update_started_ns != 0) {
        const update_completed_ns = vulkan.monotonicNanos();
        if (update_completed_ns >= update_started_ns) {
            active_renderer.api.telemetry.recordModelUpdate(
                update_completed_ns - update_started_ns,
            );
        }
    }
    active_renderer.drawFrame(false) catch |err| {
        std.log.err("Ghostty frame draw failed: {}", .{err});
        return false;
    };
    return true;
}

fn androidLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const priority = switch (level) {
        .debug => android.ANDROID_LOG_DEBUG,
        .info => android.ANDROID_LOG_INFO,
        .warn => android.ANDROID_LOG_WARN,
        .err => android.ANDROID_LOG_ERROR,
    };
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    var buffer: [2048]u8 = undefined;
    const message = std.fmt.bufPrintZ(&buffer, prefix ++ format, args) catch return;
    _ = android.__android_log_write(priority, "TelepathyGhostty", message.ptr);
}

fn resizeTerminalForPixels(engine: *Engine, width: u32, height: u32) void {
    const cell = engine.font_grid.cellSize();
    const columns: u32 = @max(1, width / @max(1, cell.width));
    const rows: u32 = @max(1, height / @max(1, cell.height));
    _ = telepathy_ghostty_resize(engine, columns, rows);
}

fn initFontGrid(library: font.Library) !font.SharedGrid {
    const desired_size: font.face.DesiredSize = .{
        .points = 12,
        .xdpi = 96,
        .ydpi = 96,
    };
    var collection = font.Collection.init();
    collection.load_options = .{ .library = library, .size = desired_size };
    errdefer collection.deinit(allocator);

    const faces = .{
        .{ font.embedded.regular, font.Style.regular },
        .{ font.embedded.bold, font.Style.bold },
        .{ font.embedded.italic, font.Style.italic },
        .{ font.embedded.bold_italic, font.Style.bold_italic },
    };
    inline for (faces) |entry| {
        _ = try collection.add(
            allocator,
            try font.Face.init(library, entry[0], .{ .size = desired_size }),
            .{
                .style = entry[1],
                .fallback = false,
                .size_adjustment = .none,
            },
        );
    }

    var resolver: font.CodepointResolver = .{ .collection = collection };
    errdefer resolver.deinit(allocator);
    return font.SharedGrid.init(allocator, resolver);
}

export fn telepathy_ghostty_render_snapshot(
    engine: ?*Engine,
    cells: ?[*]Cell,
    cell_capacity: usize,
    snapshot: ?*Snapshot,
) bool {
    const value = engine orelse return false;
    const output = snapshot orelse return false;

    value.render_state.update(allocator, &value.terminal) catch return false;
    const rows: usize = value.render_state.rows;
    const columns: usize = value.render_state.cols;
    const required_cells = std.math.mul(usize, rows, columns) catch return false;
    if (cells != null and cell_capacity < required_cells) return false;

    var hash = std.hash.Wyhash.init(0);
    var non_empty: u32 = 0;
    var destination_index: usize = 0;
    const row_cells = value.render_state.row_data.slice().items(.cells);
    for (row_cells[0..rows]) |row| {
        const slice = row.slice();
        const raw_cells = slice.items(.raw);
        const styles = slice.items(.style);
        const graphemes = slice.items(.grapheme);
        for (0..columns) |x| {
            const raw = raw_cells[x];
            const style: terminalpkg.Style = if (raw.style_id == 0) .{} else styles[x];
            var foreground = style.fg(.{
                .default = value.render_state.colors.foreground,
                .palette = &value.render_state.colors.palette,
            });
            var background = style.bg(
                &raw,
                &value.render_state.colors.palette,
            ) orelse value.render_state.colors.background;
            if (style.flags.inverse)
                std.mem.swap(terminalpkg.color.RGB, &foreground, &background);

            const spacer = raw.wide == .spacer_head or raw.wide == .spacer_tail;
            const codepoint: u32 = if (spacer) 0 else raw.codepoint();
            if (codepoint != 0) non_empty +|= 1;

            var flags: u16 = 0;
            if (style.flags.bold) flags |= cell_flag_bold;
            if (style.flags.italic) flags |= cell_flag_italic;
            if (style.flags.underline != .none) flags |= cell_flag_underline;
            if (style.flags.inverse) flags |= cell_flag_inverse;
            if (style.flags.blink) flags |= cell_flag_blink;
            if (style.flags.faint) flags |= cell_flag_faint;
            if (style.flags.invisible) flags |= cell_flag_invisible;
            if (style.flags.strikethrough) flags |= cell_flag_strikethrough;
            if (style.flags.overline) flags |= cell_flag_overline;
            if (spacer) flags |= cell_flag_spacer;
            if (raw.content_tag == .codepoint_grapheme and graphemes[x].len > 0)
                flags |= cell_flag_grapheme;

            const rendered_cell: Cell = .{
                .codepoint = codepoint,
                .foreground_rgba = packRgba(foreground),
                .background_rgba = packRgba(background),
                .flags = flags,
                .width = raw.gridWidth(),
                .grapheme_length = if (raw.content_tag == .codepoint_grapheme)
                    @intCast(@min(graphemes[x].len, std.math.maxInt(u8)))
                else
                    0,
            };
            hash.update(std.mem.asBytes(&rendered_cell));
            if (cells) |destination| destination[destination_index] = rendered_cell;
            destination_index += 1;
        }
    }

    const cursor = value.render_state.cursor.viewport;
    output.* = .{
        .struct_size = @sizeOf(Snapshot),
        .rows = @intCast(rows),
        .columns = @intCast(columns),
        .cursor_x = if (cursor) |position| @intCast(position.x) else -1,
        .cursor_y = if (cursor) |position| @intCast(position.y) else -1,
        .non_empty_cells = non_empty,
        .background_rgba = packRgba(value.render_state.colors.background),
        .foreground_rgba = packRgba(value.render_state.colors.foreground),
        .content_hash = hash.final(),
    };
    return true;
}

fn packRgba(color: terminalpkg.color.RGB) u32 {
    return (@as(u32, color.r) << 24) |
        (@as(u32, color.g) << 16) |
        (@as(u32, color.b) << 8) |
        0xff;
}
