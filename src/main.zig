const std = @import("std");
const config_module = @import("config.zig");
const draft = @import("draft.zig");
const tui = @import("tui.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const draft_url = args.next() orelse {
        std.debug.print("usage: ff-drafter '<ESPN draft URL>'\n", .{});
        std.process.exit(1);
    };

    var config = try config_module.Config.load(init.gpa, init.io, draft_url);
    defer config.deinit();

    var shared = try draft.Shared.init(init.io, init.gpa, config.team_id);
    defer shared.deinit();

    try tui.run(init, &shared, &config);
}
