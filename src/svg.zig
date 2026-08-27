const std = @import("std");

const SvgPng = extern struct {
    data: [*]u8,
    length: usize,
};

extern fn svg_render_png(
    data: [*]const u8,
    length: usize,
    width: c_uint,
    height: c_uint,
    output: *SvgPng,
) bool;
extern fn svg_png_free(data: [*]u8) void;

pub fn isSvg(data: []const u8) bool {
    return std.mem.indexOf(u8, data[0..@min(data.len, 256)], "<svg") != null;
}

pub fn renderPng(allocator: std.mem.Allocator, data: []const u8, width: u16, height: u16) ![]u8 {
    var rendered: SvgPng = undefined;
    if (!svg_render_png(data.ptr, data.len, width, height, &rendered)) return error.InvalidSvg;
    defer svg_png_free(rendered.data);
    return allocator.dupe(u8, rendered.data[0..rendered.length]);
}
