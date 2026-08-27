const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Keep dependencies on a named module so ZLS can resolve imports.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));

    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("websocket", websocket.module("websocket"));

    const lunasvg = b.dependency("lunasvg", .{});
    const plutovg = b.dependency("plutovg", .{});
    exe_mod.addIncludePath(lunasvg.path("include"));
    exe_mod.addIncludePath(lunasvg.path("source"));
    exe_mod.addIncludePath(plutovg.path("include"));
    exe_mod.addIncludePath(plutovg.path("source"));
    exe_mod.addCSourceFiles(.{
        .root = lunasvg.path(""),
        .files = &.{
            "source/lunasvg.cpp",
            "source/graphics.cpp",
            "source/svgelement.cpp",
            "source/svggeometryelement.cpp",
            "source/svglayoutstate.cpp",
            "source/svgpaintelement.cpp",
            "source/svgparser.cpp",
            "source/svgproperty.cpp",
            "source/svgrenderstate.cpp",
            "source/svgtextelement.cpp",
        },
        .flags = &.{ "-std=c++17", "-DLUNASVG_BUILD_STATIC", "-DLUNASVG_DISABLE_LOAD_SYSTEM_FONTS" },
    });
    exe_mod.addCSourceFiles(.{
        .root = plutovg.path(""),
        .files = &.{
            "source/plutovg-blend.c",
            "source/plutovg-canvas.c",
            "source/plutovg-font.c",
            "source/plutovg-matrix.c",
            "source/plutovg-paint.c",
            "source/plutovg-path.c",
            "source/plutovg-rasterize.c",
            "source/plutovg-surface.c",
            "source/plutovg-ft-math.c",
            "source/plutovg-ft-raster.c",
            "source/plutovg-ft-stroker.c",
        },
        .flags = &.{ "-std=c11", "-DPLUTOVG_BUILD_STATIC", "-DPLUTOVG_DISABLE_FONT_FACE_CACHE_LOAD" },
    });
    exe_mod.addCSourceFile(.{ .file = b.path("src/svg.cpp"), .flags = &.{"-std=c++17"} });

    const exe = b.addExecutable(.{
        .name = "ff-drafter",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the TUI");
    run_step.dependOn(&run_cmd.step);
}
