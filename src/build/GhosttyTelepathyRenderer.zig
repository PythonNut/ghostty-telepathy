const GhosttyTelepathyRenderer = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");

library: *std.Build.Step.Compile,
link_libraries: [5]*std.Build.Step.Compile,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyTelepathyRenderer {
    const target = deps.config.target;
    const optimize = deps.config.optimize;

    const library = b.addLibrary(.{
        .name = "ghostty_telepathy_renderer",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/telepathy_renderer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    library.bundle_compiler_rt = true;
    library.bundle_ubsan_rt = true;

    const link_libraries = try addDependencies(b, deps, library);
    return .{ .library = library, .link_libraries = link_libraries };
}

fn addDependencies(
    b: *std.Build,
    deps: *const SharedDeps,
    library: *std.Build.Step.Compile,
) ![5]*std.Build.Step.Compile {
    const module = library.root_module;
    const target = module.resolved_target.?;
    const optimize = module.optimize.?;

    module.addOptions("build_options", deps.options);
    deps.config.terminalOptions().add(b, module);
    deps.help_strings.addImport(library);
    deps.unicode_tables.addImport(library);
    deps.framedata.addImport(library);
    deps.addUucode(b, module, target, optimize);

    library.linkLibC();
    library.addIncludePath(b.path("src/stb"));
    library.addCSourceFiles(.{ .files = &.{"src/stb/stb.c"} });

    const freetype = b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    }) orelse @panic("freetype dependency unavailable");
    module.addImport("freetype", freetype.module("freetype"));

    const harfbuzz = b.lazyDependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
        .@"enable-freetype" = true,
        .@"enable-coretext" = false,
    }) orelse @panic("harfbuzz dependency unavailable");
    module.addImport("harfbuzz", harfbuzz.module("harfbuzz"));

    // These are transitive font dependencies, but naming them here lets the
    // Android NDK path adapter configure their C compilation as well.
    const zlib = b.lazyDependency("zlib", .{ .target = target, .optimize = optimize }) orelse
        @panic("zlib dependency unavailable");
    const libpng = b.lazyDependency("libpng", .{ .target = target, .optimize = optimize }) orelse
        @panic("libpng dependency unavailable");

    const oniguruma = b.lazyDependency("oniguruma", .{ .target = target, .optimize = optimize }) orelse
        @panic("oniguruma dependency unavailable");
    module.addImport("oniguruma", oniguruma.module("oniguruma"));

    inline for (.{
        .{ "wuffs", "wuffs" },
        .{ "libxev", "xev" },
        .{ "z2d", "z2d" },
    }) |entry| {
        const dependency = b.lazyDependency(entry[0], .{
            .target = target,
            .optimize = optimize,
        }) orelse @panic(entry[0] ++ " dependency unavailable");
        module.addImport(entry[1], dependency.module(entry[1]));
    }

    const zf = b.lazyDependency("zf", .{
        .target = target,
        .optimize = optimize,
        .with_tui = false,
    }) orelse @panic("zf dependency unavailable");
    module.addImport("zf", zf.module("zf"));

    const jetbrains = b.lazyDependency("jetbrains_mono", .{}) orelse
        @panic("JetBrains Mono dependency unavailable");
    module.addAnonymousImport("jetbrains_mono_regular", .{
        .root_source_file = jetbrains.path("fonts/ttf/JetBrainsMono-Regular.ttf"),
    });
    module.addAnonymousImport("jetbrains_mono_bold", .{
        .root_source_file = jetbrains.path("fonts/ttf/JetBrainsMono-Bold.ttf"),
    });
    module.addAnonymousImport("jetbrains_mono_italic", .{
        .root_source_file = jetbrains.path("fonts/ttf/JetBrainsMono-Italic.ttf"),
    });
    module.addAnonymousImport("jetbrains_mono_bold_italic", .{
        .root_source_file = jetbrains.path("fonts/ttf/JetBrainsMono-BoldItalic.ttf"),
    });
    module.addAnonymousImport("jetbrains_mono_variable", .{
        .root_source_file = jetbrains.path("fonts/variable/JetBrainsMono[wght].ttf"),
    });
    module.addAnonymousImport("jetbrains_mono_variable_italic", .{
        .root_source_file = jetbrains.path("fonts/variable/JetBrainsMono-Italic[wght].ttf"),
    });

    const nerd = b.lazyDependency("nerd_fonts_symbols_only", .{}) orelse
        @panic("Nerd Fonts dependency unavailable");
    module.addAnonymousImport("nerd_fonts_symbols_only", .{
        .root_source_file = nerd.path("SymbolsNerdFont-Regular.ttf"),
    });

    // Configure every C/C++ compile step with bionic headers and libraries.
    if (target.result.abi == .android) {
        const android_ndk = @import("android_ndk");
        try android_ndk.addPaths(b, library);
        try android_ndk.addPaths(b, freetype.artifact("freetype"));
        try android_ndk.addPaths(b, harfbuzz.artifact("harfbuzz"));
        try android_ndk.addPaths(b, zlib.artifact("z"));
        try android_ndk.addPaths(b, libpng.artifact("png"));
        try android_ndk.addPaths(b, oniguruma.artifact("oniguruma"));
    }

    return .{
        harfbuzz.artifact("harfbuzz"),
        freetype.artifact("freetype"),
        libpng.artifact("png"),
        zlib.artifact("z"),
        oniguruma.artifact("oniguruma"),
    };
}
