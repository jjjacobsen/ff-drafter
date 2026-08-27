const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const config_module = @import("config.zig");
const draft = @import("draft.zig");
const espn = @import("espn.zig");
const events = @import("events.zig");
const svg = @import("svg.zig");

const accent: Cell.Style = .{ .fg = .{ .rgb = .{ 92, 200, 160 } }, .bold = true };
const selected: Cell.Style = .{ .fg = .{ .rgb = .{ 255, 213, 79 } }, .bold = true };
const muted: Cell.Style = .{ .fg = .{ .rgb = .{ 130, 140, 150 } }, .dim = true };
const money: Cell.Style = .{ .fg = .{ .rgb = .{ 115, 210, 135 } }, .bold = true };
const clock: Cell.Style = .{ .fg = .{ .rgb = .{ 255, 180, 75 } }, .bold = true };
const error_style: Cell.Style = .{ .fg = .{ .rgb = .{ 245, 100, 100 } }, .bold = true };
const heading: Cell.Style = .{ .bold = true };

const Screen = union(enum) {
    main,
    team: i32,
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    shared: *draft.Shared,
    team_images: std.AutoHashMap(i32, vaxis.Image),
    screen: Screen = .main,
    focused_team_id: ?i32 = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, shared: *draft.Shared) App {
        return .{
            .allocator = allocator,
            .io = io,
            .shared = shared,
            .team_images = std.AutoHashMap(i32, vaxis.Image).init(allocator),
        };
    }

    fn deinit(self: *App, vx: *vaxis.Vaxis, tty: *vaxis.Tty) void {
        var images = self.team_images.valueIterator();
        while (images.next()) |image| vx.freeImage(tty.writer(), image.imageId());
        self.team_images.deinit();
    }

    fn loadTeamImages(self: *App, vx: *vaxis.Vaxis, tty: *vaxis.Tty) !void {
        if (!vx.caps.kitty_graphics) return;

        const state = self.shared.lock();
        defer self.shared.unlock();
        for (state.teams.items) |team| {
            const logo = team.logo orelse continue;
            if (self.team_images.contains(team.id)) continue;

            const image = try loadTeamImage(self.allocator, vx, tty, logo);
            errdefer vx.freeImage(tty.writer(), image.imageId());
            try self.team_images.put(team.id, image);
        }
    }

    fn handleKey(self: *App, key: vaxis.Key) bool {
        return switch (self.screen) {
            .main => self.handleMainKey(key),
            .team => self.handleTeamKey(key),
        };
    }

    fn handleMainKey(self: *App, key: vaxis.Key) bool {
        if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) return true;

        const state = self.shared.lock();
        defer self.shared.unlock();
        const team_count = state.teams.items.len;
        if (team_count == 0) return false;

        if (key.matches('k', .{})) {
            if (self.focused_team_id == null) self.focused_team_id = state.user_team_id;
            return false;
        }
        if (key.matches('j', .{})) {
            self.focused_team_id = null;
            return false;
        }
        if (key.matches('h', .{}) and self.focused_team_id != null) {
            const index = state.teamIndexById(self.focused_team_id.?).?;
            const previous = if (index == 0) team_count - 1 else index - 1;
            self.focused_team_id = state.teams.items[previous].id;
            return false;
        }
        if (key.matches('l', .{}) and self.focused_team_id != null) {
            const index = state.teamIndexById(self.focused_team_id.?).?;
            self.focused_team_id = state.teams.items[(index + 1) % team_count].id;
            return false;
        }
        if (key.matches(vaxis.Key.enter, .{}) and self.focused_team_id != null) {
            self.screen = .{ .team = self.focused_team_id.? };
        }
        return false;
    }

    fn handleTeamKey(self: *App, key: vaxis.Key) bool {
        if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
            self.screen = .main;
        }
        return false;
    }

    fn draw(self: *App, window: vaxis.Window) void {
        window.clear();
        window.hideCursor();

        const state = self.shared.lock();
        defer self.shared.unlock();

        if (window.width < 48 or window.height < 18) {
            printCentered(window, window.height / 2, "Terminal is too small", error_style);
            return;
        }

        switch (self.screen) {
            .main => drawMain(self, state, window),
            .team => |team_id| drawTeam(state, team_id, window),
        }
    }
};

pub fn run(
    init: std.process.Init,
    shared: *draft.Shared,
    config: *const config_module.Config,
) !void {
    const allocator = init.gpa;
    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(init.io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(init.io, allocator, init.environ_map, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: events.Loop = .init(init.io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try vx.resize(allocator, tty.writer(), try tty.getWinsize());

    const use_signal_resize = !vx.state.in_band_resize;
    if (use_signal_resize) try loop.installResizeHandler();
    defer if (use_signal_resize) loop.uninstallResizeHandler();

    var worker = try init.io.concurrent(espn.run, .{
        init.io,
        allocator,
        shared,
        &loop,
        config,
    });
    defer {
        shared.stop.store(true, .release);
        worker.await(init.io);
    }

    var app: App = .init(allocator, init.io, shared);
    defer app.deinit(&vx, &tty);
    try app.loadTeamImages(&vx, &tty);
    app.draw(vx.window());
    try vx.render(tty.writer());

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| if (app.handleKey(key)) break,
            .winsize => |winsize| try vx.resize(allocator, tty.writer(), winsize),
            .draft_update, .tick => {},
        }
        try app.loadTeamImages(&vx, &tty);
        app.draw(vx.window());
        try vx.render(tty.writer());
    }
}

fn loadTeamImage(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    logo: []const u8,
) !vaxis.Image {
    if (!svg.isSvg(logo)) return vx.loadImage(allocator, tty.writer(), .{ .mem = logo });

    const png = try svg.renderPng(allocator, logo, 96, 96);
    defer allocator.free(png);
    return vx.loadImage(allocator, tty.writer(), .{ .mem = png });
}

fn drawMain(app: *const App, state: *const draft.State, window: vaxis.Window) void {
    drawTeamBar(state, &app.team_images, app.focused_team_id, window.child(.{
        .height = 7,
    }));

    const content = window.child(.{
        .y_off = 8,
        .height = window.height -| 11,
    });
    drawAuction(state, app.io, content);
    drawFooter(state, window);
}

fn drawTeamBar(
    state: *const draft.State,
    team_images: *const std.AutoHashMap(i32, vaxis.Image),
    focused_team_id: ?i32,
    window: vaxis.Window,
) void {
    const team_count = state.teams.items.len;
    if (team_count == 0) {
        printCentered(window, 3, "Loading teams...", muted);
        return;
    }

    var start: u16 = 0;
    for (state.teams.items, 0..) |team, index| {
        const end: u16 = @intCast(((index + 1) * window.width) / team_count);
        const width = end - start;
        const is_focused = focused_team_id != null and focused_team_id.? == team.id;
        const border_style = if (is_focused) selected else muted;
        const team_window = window.child(.{
            .x_off = @intCast(start),
            .width = width,
            .height = 7,
            .border = .{ .where = .all, .style = border_style },
        });
        const team_text = team_window.child(.{
            .x_off = 1,
            .y_off = 1,
            .width = width -| 2,
            .height = 1,
        });
        _ = team_text.printSegment(.{
            .text = team.name,
            .style = if (is_focused) selected else heading,
        }, .{ .wrap = .none });

        if (team_images.get(team.id)) |image| {
            const logo_width = @min(width -| 2, 6);
            const logo = team_window.child(.{
                .x_off = @intCast((width - logo_width) / 2),
                .y_off = 2,
                .width = logo_width,
                .height = 3,
            });
            image.draw(logo, .{ .scale = .fit }) catch unreachable;
        } else {
            printCentered(team_window, 3, team.abbreviation, accent);
        }

        var budget_buffer: [24]u8 = undefined;
        const budget = std.fmt.bufPrint(&budget_buffer, "${d}", .{team.remaining_budget}) catch unreachable;
        printCentered(team_window, 5, budget, money);
        start = end;
    }
}

fn drawAuction(state: *const draft.State, io: std.Io, window: vaxis.Window) void {
    const panel_width = @min(window.width -| 4, 70);
    const panel_height = @min(window.height, 13);
    const panel = window.child(.{
        .x_off = @intCast((window.width - panel_width) / 2),
        .y_off = @intCast((window.height - panel_height) / 2),
        .width = panel_width,
        .height = panel_height,
        .border = .{ .where = .all, .style = accent },
    });
    const content = panel.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = panel.width -| 2,
        .height = panel.height -| 2,
    });

    if (state.auction.player_id) |player_id| {
        var unknown_buffer: [48]u8 = undefined;
        const player = state.players.get(player_id);
        const name = if (player) |value|
            value.name
        else
            std.fmt.bufPrint(&unknown_buffer, "Player {d}", .{player_id}) catch unreachable;
        const position = if (player) |value| value.position else "--";
        const estimated_price = if (player) |value| value.estimated_price else 0;

        printCentered(content, 1, name, .{ .bold = true });

        var details_buffer: [64]u8 = undefined;
        const details = std.fmt.bufPrint(
            &details_buffer,
            "{s}  •  ESPN value ${d}",
            .{ position, estimated_price },
        ) catch unreachable;
        printCentered(content, 3, details, muted);

        var bid_buffer: [32]u8 = undefined;
        const bid = std.fmt.bufPrint(&bid_buffer, "${d}", .{state.auction.bid_amount}) catch unreachable;
        printCentered(content, 5, bid, money);

        if (state.auction.bid_team_id) |team_id| {
            const bidder = teamName(state, team_id) orelse "Unknown team";
            printCentered(content, 7, bidder, heading);
        }

        var clock_buffer: [16]u8 = undefined;
        const remaining = state.clockRemainingMs(std.Io.Timestamp.now(io, .awake).toMilliseconds());
        const clock_text = formatClock(&clock_buffer, remaining);
        printCentered(content, 9, clock_text, clock);
        return;
    }

    if (state.auction.nomination_team_id) |team_id| {
        printCentered(content, 2, "Waiting for nomination", heading);
        printCentered(content, 4, teamName(state, team_id) orelse "Unknown team", accent);
        var clock_buffer: [16]u8 = undefined;
        const remaining = state.clockRemainingMs(std.Io.Timestamp.now(io, .awake).toMilliseconds());
        printCentered(content, 7, formatClock(&clock_buffer, remaining), clock);
        return;
    }

    printCentered(content, 3, "Waiting for the next nomination", heading);
    printCentered(content, 6, state.status_message, statusStyle(state.status));
}

fn drawTeam(state: *const draft.State, team_id: i32, window: vaxis.Window) void {
    const team_index = state.teamIndexById(team_id) orelse return;
    const team = state.teams.items[team_index];

    printCentered(window, 1, team.name, .{ .bold = true });
    var budget_buffer: [48]u8 = undefined;
    const budget = std.fmt.bufPrint(
        &budget_buffer,
        "${d} remaining",
        .{team.remaining_budget},
    ) catch unreachable;
    printCentered(window, 3, budget, money);

    const table_width = @min(window.width -| 4, 86);
    const table_height = @min(window.height -| 8, @as(u16, @intCast(@max(team.roster.items.len + 4, 7))));
    const table = window.child(.{
        .x_off = @intCast((window.width - table_width) / 2),
        .y_off = 5,
        .width = table_width,
        .height = table_height,
        .border = .{ .where = .all, .style = muted },
    });

    _ = table.printSegment(.{ .text = "POS", .style = heading }, .{
        .row_offset = 1,
        .col_offset = 2,
        .wrap = .none,
    });
    _ = table.printSegment(.{ .text = "PLAYER", .style = heading }, .{
        .row_offset = 1,
        .col_offset = 10,
        .wrap = .none,
    });
    _ = table.printSegment(.{ .text = "COST", .style = heading }, .{
        .row_offset = 1,
        .col_offset = table.width -| 8,
        .wrap = .none,
    });

    const divider = table.child(.{
        .x_off = 1,
        .y_off = 2,
        .width = table.width -| 2,
        .height = 1,
    });
    divider.fill(.{ .char = .{ .grapheme = "─", .width = 1 }, .style = muted });

    if (team.roster.items.len == 0) {
        printCentered(table, 4, "No players drafted yet", muted);
    } else {
        const visible_rows = table.height -| 4;
        for (team.roster.items[0..@min(team.roster.items.len, visible_rows)], 0..) |purchase, index| {
            const row: u16 = @intCast(index + 3);
            const player = state.players.get(purchase.player_id);
            const position = if (player) |value| value.position else "--";
            var player_buffer: [48]u8 = undefined;
            const name = if (player) |value|
                value.name
            else
                std.fmt.bufPrint(&player_buffer, "Player {d}", .{purchase.player_id}) catch unreachable;

            _ = table.printSegment(.{ .text = position, .style = accent }, .{
                .row_offset = row,
                .col_offset = 2,
                .wrap = .none,
            });
            const player_name = table.child(.{
                .x_off = 10,
                .y_off = @intCast(row),
                .width = table.width -| 20,
                .height = 1,
            });
            _ = player_name.printSegment(.{ .text = name }, .{ .wrap = .none });

            var cost_buffer: [16]u8 = undefined;
            const cost = std.fmt.bufPrint(&cost_buffer, "${d}", .{purchase.cost}) catch unreachable;
            _ = table.printSegment(.{ .text = cost, .style = money }, .{
                .row_offset = row,
                .col_offset = table.width -| @as(u16, @intCast(cost.len + 2)),
                .wrap = .none,
            });
        }
    }

    printCentered(window, window.height -| 1, "esc/q back", muted);
}

fn drawFooter(state: *const draft.State, window: vaxis.Window) void {
    printCentered(window, window.height -| 2, state.status_message, statusStyle(state.status));
    printCentered(window, window.height -| 1, "k teams  •  h/l move  •  j clear  •  enter open  •  esc/q quit", muted);
}

fn printCentered(window: vaxis.Window, row: u16, text: []const u8, style: Cell.Style) void {
    const width = window.gwidth(text);
    const col = if (width < window.width) (window.width - width) / 2 else 0;
    _ = window.printSegment(.{ .text = text, .style = style }, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
}

fn teamName(state: *const draft.State, team_id: i32) ?[]const u8 {
    const index = state.teamIndexById(team_id) orelse return null;
    return state.teams.items[index].name;
}

fn formatClock(buffer: []u8, milliseconds: i64) []const u8 {
    const total_seconds = @divFloor(milliseconds + 999, 1000);
    return std.fmt.bufPrint(
        buffer,
        "{d}:{d:0>2}",
        .{ @divFloor(total_seconds, 60), @mod(total_seconds, 60) },
    ) catch unreachable;
}

fn statusStyle(status: draft.Status) Cell.Style {
    return switch (status) {
        .live => accent,
        .loading, .connecting => muted,
        .reconnecting => error_style,
    };
}
