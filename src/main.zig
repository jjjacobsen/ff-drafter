const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = struct {
    text: vxfw.Text,
    center: vxfw.Center,

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(
        ptr: *anyopaque,
        ctx: *vxfw.EventContext,
        event: vxfw.Event,
    ) anyerror!void {
        _ = ptr;
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(
        ptr: *anyopaque,
        ctx: vxfw.DrawContext,
    ) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        var surface = try self.center.draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(init.io, allocator, init.environ_map, &buffer);
    defer app.deinit();

    const model = try allocator.create(Model);
    defer allocator.destroy(model);

    model.text = .{
        .text = "FF Drafter\n\nPress q to quit",
        .text_align = .center,
    };
    model.center = .{ .child = model.text.widget() };

    try app.run(model.widget(), .{});
}
