//! The options that are used to configure a renderer.

const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");

/// The derived configuration for this renderer implementation.
config: renderer.Renderer.DerivedConfig,

/// The font grid that should be used along with the key for deref-ing.
font_grid: *font.SharedGrid,

/// The size of everything.
size: renderer.Size,

/// The mailbox for sending the surface messages. This is only valid
/// once the thread has started and should not be used outside of the thread.
surface_mailbox: SurfaceMailbox = .{},

/// The apprt surface.
rt_surface: *anyopaque = undefined,

/// The renderer thread.
thread: *anyopaque = undefined,

/// Telepathy owns Android lifecycle and session messaging outside Ghostty's
/// desktop application runtime. The generic renderer only uses this mailbox
/// for optional health/scrollbar notifications, so the narrow Android
/// artifact deliberately makes those notifications no-ops.
pub const SurfaceMailbox = struct {
    pub fn push(_: SurfaceMailbox, _: anytype, _: anytype) usize {
        return 0;
    }
};
