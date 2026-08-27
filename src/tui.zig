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
const details_style: Cell.Style = .{ .fg = .{ .rgb = .{ 185, 190, 195 } } };
const money: Cell.Style = .{ .fg = .{ .rgb = .{ 115, 210, 135 } }, .bold = true };
const clock: Cell.Style = .{ .fg = .{ .rgb = .{ 255, 180, 75 } }, .bold = true };
const error_style: Cell.Style = .{ .fg = .{ .rgb = .{ 245, 100, 100 } }, .bold = true };
const heading: Cell.Style = .{ .bold = true };

const Screen = union(enum) {
    main,
    team: i32,
};

const PlayerImage = struct {
    player_id: i32,
    image: vaxis.Image,
};

const App = struct {
    allocator: std.mem.Allocator,
    frame_arena: std.heap.ArenaAllocator,
    io: std.Io,
    shared: *draft.Shared,
    team_images: std.AutoHashMap(i32, vaxis.Image),
    player_image: ?PlayerImage = null,
    screen: Screen = .main,
    focused_team_id: ?i32 = null,
    last_focused_team_id: ?i32 = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, shared: *draft.Shared) App {
        return .{
            .allocator = allocator,
            .frame_arena = .init(allocator),
            .io = io,
            .shared = shared,
            .team_images = std.AutoHashMap(i32, vaxis.Image).init(allocator),
        };
    }

    fn deinit(self: *App, vx: *vaxis.Vaxis, tty: *vaxis.Tty) void {
        self.frame_arena.deinit();
        var team_images = self.team_images.valueIterator();
        while (team_images.next()) |image| vx.freeImage(tty.writer(), image.imageId());
        self.team_images.deinit();

        if (self.player_image) |player_image| {
            vx.freeImage(tty.writer(), player_image.image.imageId());
        }
    }

    fn loadImages(self: *App, vx: *vaxis.Vaxis, tty: *vaxis.Tty) !void {
        if (!vx.caps.kitty_graphics) return;

        const state = self.shared.lock();
        defer self.shared.unlock();
        for (state.teams.items) |team| {
            const logo = team.logo orelse continue;
            if (self.team_images.contains(team.id)) continue;

            const image = try loadImage(self.allocator, vx, tty, logo);
            errdefer vx.freeImage(tty.writer(), image.imageId());
            try self.team_images.put(team.id, image);
        }

        const player_id = state.auction.player_id;
        if (self.player_image) |player_image| {
            if (player_id == null or player_image.player_id != player_id.?) {
                vx.freeImage(tty.writer(), player_image.image.imageId());
                self.player_image = null;
            }
        }

        if (player_id) |id| {
            if (self.player_image == null) {
                const player = state.players.get(id) orelse return;
                const image_bytes = player.image orelse return;
                const image = try loadImage(self.allocator, vx, tty, image_bytes);
                errdefer vx.freeImage(tty.writer(), image.imageId());
                self.player_image = .{ .player_id = id, .image = image };
            }
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
            if (self.focused_team_id == null) {
                self.focused_team_id = self.last_focused_team_id orelse state.user_team_id;
                self.last_focused_team_id = self.focused_team_id;
            }
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
            self.last_focused_team_id = self.focused_team_id;
            return false;
        }
        if (key.matches('l', .{}) and self.focused_team_id != null) {
            const index = state.teamIndexById(self.focused_team_id.?).?;
            self.focused_team_id = state.teams.items[(index + 1) % team_count].id;
            self.last_focused_team_id = self.focused_team_id;
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
        _ = self.frame_arena.reset(.retain_capacity);
        const frame_allocator = self.frame_arena.allocator();

        window.clear();
        window.hideCursor();

        const state = self.shared.lock();
        defer self.shared.unlock();

        if (window.width < 48 or window.height < 18) {
            printCentered(window, window.height / 2, "Terminal is too small", error_style);
            return;
        }

        switch (self.screen) {
            .main => drawMain(self, state, window, frame_allocator),
            .team => |team_id| drawTeam(state, team_id, window, frame_allocator),
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
        vx.exitAltScreen(tty.writer()) catch {};
        worker.await(init.io);
    }

    var app: App = .init(allocator, init.io, shared);
    defer app.deinit(&vx, &tty);
    try app.loadImages(&vx, &tty);
    app.draw(vx.window());
    try vx.render(tty.writer());

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| if (app.handleKey(key)) break,
            .winsize => |winsize| try vx.resize(allocator, tty.writer(), winsize),
            .draft_update, .tick => {},
        }
        try app.loadImages(&vx, &tty);
        app.draw(vx.window());
        try vx.render(tty.writer());
    }
}

fn loadImage(
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

fn drawMain(
    app: *const App,
    state: *const draft.State,
    window: vaxis.Window,
    frame_allocator: std.mem.Allocator,
) void {
    const now_ms = std.Io.Timestamp.now(app.io, .awake).toMilliseconds();
    drawTeamBar(state, &app.team_images, app.focused_team_id, window.child(.{
        .height = 11,
    }), frame_allocator, now_ms);

    const content = window.child(.{
        .y_off = 12,
        .height = window.height -| 15,
    });
    drawAuction(state, app.player_image, now_ms, content, frame_allocator);
    drawFooter(state, window);
}

fn drawTeamBar(
    state: *const draft.State,
    team_images: *const std.AutoHashMap(i32, vaxis.Image),
    focused_team_id: ?i32,
    window: vaxis.Window,
    frame_allocator: std.mem.Allocator,
    now_ms: i64,
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
            .height = 9,
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

        const budget = std.fmt.allocPrint(frame_allocator, "${d}", .{team.remaining_budget}) catch unreachable;
        printCentered(team_window, 5, budget, money);

        if (state.recent_sale) |sale| {
            if (sale.team_id == team.id and now_ms - sale.sold_at_ms < 3_000) {
                const player_name = if (state.players.get(sale.player_id)) |player|
                    player.name
                else
                    std.fmt.allocPrint(frame_allocator, "Player {d}", .{sale.player_id}) catch unreachable;
                const summary = std.fmt.allocPrint(
                    frame_allocator,
                    "${d} - {s}",
                    .{ sale.cost, player_name },
                ) catch unreachable;
                printCentered(team_window, 6, summary, accent);
            }
        }

        if (state.auction.bid_team_id) |bid_team_id| {
            if (bid_team_id == team.id) {
                const underline = window.child(.{
                    .x_off = @intCast(start),
                    .y_off = 9,
                    .width = width,
                    .height = 1,
                });
                underline.fill(.{ .char = .{ .grapheme = "─", .width = 1 }, .style = accent });

                const bid = std.fmt.allocPrint(
                    frame_allocator,
                    "${d}",
                    .{state.auction.bid_amount},
                ) catch unreachable;
                const bid_window = window.child(.{
                    .x_off = @intCast(start),
                    .y_off = 10,
                    .width = width,
                    .height = 1,
                });
                printCentered(bid_window, 0, bid, money);
            }
        }
        start = end;
    }
}

fn drawAuction(
    state: *const draft.State,
    player_image: ?PlayerImage,
    now_ms: i64,
    window: vaxis.Window,
    frame_allocator: std.mem.Allocator,
) void {
    const panel_width = @min(window.width -| 4, 70);
    const panel_height = @min(window.height, 17);
    const panel = window.child(.{
        .x_off = @intCast((window.width - panel_width) / 2),
        .y_off = @intCast((window.height - panel_height) / 2),
        .width = panel_width,
        .height = panel_height,
        .border = .{ .where = .all, .style = accent },
    });
    const content = panel;

    if (state.total_picks > 0) {
        const progress = std.fmt.allocPrint(
            frame_allocator,
            "{d} of {d} picks",
            .{ state.completed_picks, state.total_picks },
        ) catch unreachable;
        _ = content.printSegment(.{ .text = progress, .style = accent }, .{
            .row_offset = 0,
            .col_offset = content.width -| @as(u16, @intCast(progress.len)),
            .wrap = .none,
        });
    }

    if (state.auction.player_id) |player_id| {
        const player = state.players.get(player_id);
        const name = if (player) |value|
            value.name
        else
            std.fmt.allocPrint(frame_allocator, "Player {d}", .{player_id}) catch unreachable;
        const position = if (player) |value| value.position else "--";
        const estimated_price = if (player) |value| value.estimated_price else 0;

        printCentered(content, 1, name, .{ .bold = true });

        if (player_image != null and player_image.?.player_id == player_id) {
            const image = player_image.?.image;
            const artwork_width = @min(content.width / 4, 12);
            const artwork = content.child(.{
                .x_off = 1,
                .y_off = 2,
                .width = artwork_width,
                .height = 8,
            });
            image.draw(artwork, .{ .scale = .fit }) catch unreachable;
        }

        const details = std.fmt.allocPrint(
            frame_allocator,
            "{s}  •  ESPN value ${d}",
            .{ position, estimated_price },
        ) catch unreachable;
        printCentered(content, 3, details, details_style);

        const bid = std.fmt.allocPrint(frame_allocator, "${d}", .{state.auction.bid_amount}) catch unreachable;
        printCentered(content, 5, bid, money);

        const recommendation = state.recommendation;
        if (recommendation.player_id == player_id) {
            const action = switch (recommendation.action) {
                .bid => "BID",
                .hold => "HOLD",
                .pass => "PASS",
            };
            const recommendation_text = std.fmt.allocPrint(
                frame_allocator,
                "{s}  •  target ${d}  •  max ${d}  •  legal ${d}",
                .{ action, recommendation.target_bid, recommendation.max_bid, recommendation.legal_max },
            ) catch unreachable;
            printCentered(
                content,
                11,
                recommendation_text,
                if (recommendation.action == .bid) accent else details_style,
            );
        }

        if (state.auction.bid_team_id) |team_id| {
            const bidder = teamName(state, team_id) orelse "Unknown team";
            printCentered(content, 7, bidder, heading);
        }

        if (recommendation.player_id == player_id) {
            const explanation = if (recommendation.max_bid == 0)
                "No value-preserving roster plan"
            else
                std.fmt.allocPrint(
                    frame_allocator,
                    "{s}  •  replacement ${d}  •  marginal +${d}",
                    .{
                        if (recommendation.projected_starter) "Starter" else "Bench",
                        recommendation.replacement_value,
                        recommendation.marginal_value,
                    },
                ) catch unreachable;
            printCentered(content, 13, explanation, details_style);
        }

        const remaining = state.clockRemainingMs(now_ms);
        const clock_text = formatClock(frame_allocator, remaining);
        printCentered(content, 9, clock_text, clock);
        return;
    }

    if (state.auction.nomination_team_id) |team_id| {
        printCentered(content, 2, "Waiting for nomination", heading);
        printCentered(content, 4, teamName(state, team_id) orelse "Unknown team", accent);
        const remaining = state.clockRemainingMs(now_ms);
        printCentered(content, 7, formatClock(frame_allocator, remaining), clock);
        return;
    }

    printCentered(content, 3, "Waiting for the next nomination", heading);
    printCentered(content, 6, state.status_message, statusStyle(state.status));
}

fn drawTeam(
    state: *const draft.State,
    team_id: i32,
    window: vaxis.Window,
    frame_allocator: std.mem.Allocator,
) void {
    const team_index = state.teamIndexById(team_id) orelse return;
    const team = state.teams.items[team_index];

    printCentered(window, 1, team.name, .{ .bold = true });
    const roster_size = state.roster_slots.items.len;
    const slots_remaining = roster_size -| team.roster.items.len;
    const budget = std.fmt.allocPrint(
        frame_allocator,
        "${d} remaining  •  {d} slots remaining",
        .{ team.remaining_budget, slots_remaining },
    ) catch unreachable;
    printCentered(window, 3, budget, money);

    var espn_spend: i32 = 0;
    var real_spend: i32 = 0;
    for (team.roster.items) |purchase| {
        real_spend += purchase.cost;
        espn_spend += state.players.get(purchase.player_id).?.estimated_price;
    }
    const difference = espn_spend - real_spend;
    const difference_text = if (difference >= 0)
        std.fmt.allocPrint(frame_allocator, "+${d}", .{difference}) catch unreachable
    else
        std.fmt.allocPrint(frame_allocator, "-${d}", .{-difference}) catch unreachable;
    const totals = std.fmt.allocPrint(
        frame_allocator,
        "ESPN spend ${d}  •  real spend ${d}  •  diff {s}",
        .{ espn_spend, real_spend, difference_text },
    ) catch unreachable;
    printCentered(window, 4, totals, details_style);

    if (window.height < roster_size + 13) {
        printCentered(window, 7, "Terminal is too short for the full roster", error_style);
        return;
    }

    const table_width = @min(window.width -| 4, 86);
    const table_height = window.height -| 8;
    const table = window.child(.{
        .x_off = @intCast((window.width - table_width) / 2),
        .y_off = 6,
        .width = table_width,
        .height = table_height,
        .border = .{ .where = .all, .style = muted },
    });

    _ = table.printSegment(.{ .text = "SLOT", .style = heading }, .{
        .row_offset = 1,
        .col_offset = 2,
        .wrap = .none,
    });
    _ = table.printSegment(.{ .text = "PLAYER", .style = heading }, .{
        .row_offset = 1,
        .col_offset = 12,
        .wrap = .none,
    });
    _ = table.printSegment(.{ .text = "COST", .style = heading }, .{
        .row_offset = 1,
        .col_offset = table.width -| 16,
        .wrap = .none,
    });
    _ = table.printSegment(.{ .text = "ESPN", .style = heading }, .{
        .row_offset = 1,
        .col_offset = table.width -| 6,
        .wrap = .none,
    });

    const divider = table.child(.{
        .x_off = 1,
        .y_off = 2,
        .width = table.width -| 2,
        .height = 1,
    });
    divider.fill(.{ .char = .{ .grapheme = "─", .width = 1 }, .style = muted });

    for (state.roster_slots.items, 0..) |slot_id, index| {
        const row = rosterTableRow(table.height, index, roster_size);
        const slot_style = if (slot_id == 20) muted else accent;
        _ = table.printSegment(.{ .text = rosterSlotName(slot_id), .style = slot_style }, .{
            .row_offset = row,
            .col_offset = 2,
            .wrap = .none,
        });

        const occurrence = rosterSlotOccurrence(state.roster_slots.items[0..index], slot_id);
        const purchase = purchaseForRosterSlot(&team, slot_id, occurrence) orelse continue;
        const player = state.players.get(purchase.player_id);
        const name = if (player) |value|
            value.name
        else
            std.fmt.allocPrint(frame_allocator, "Player {d}", .{purchase.player_id}) catch unreachable;

        const player_name = table.child(.{
            .x_off = 12,
            .y_off = @intCast(row),
            .width = table.width -| 30,
            .height = 1,
        });
        _ = player_name.printSegment(.{ .text = name }, .{ .wrap = .none });

        const cost = std.fmt.allocPrint(frame_allocator, "${d}", .{purchase.cost}) catch unreachable;
        _ = table.printSegment(.{ .text = cost, .style = money }, .{
            .row_offset = row,
            .col_offset = table.width -| @as(u16, @intCast(cost.len + 12)),
            .wrap = .none,
        });

        const espn_value = if (player) |value| value.estimated_price else 0;
        const espn_price = std.fmt.allocPrint(frame_allocator, "${d}", .{espn_value}) catch unreachable;
        _ = table.printSegment(.{ .text = espn_price, .style = details_style }, .{
            .row_offset = row,
            .col_offset = table.width -| @as(u16, @intCast(espn_price.len + 2)),
            .wrap = .none,
        });
    }

    printCentered(window, window.height -| 1, "esc/q back", muted);
}

fn rosterTableRow(table_height: u16, index: usize, roster_size: usize) u16 {
    if (roster_size == 1) return 3;
    const row_span: usize = @intCast(table_height -| 4);
    const spacing = @max(row_span / (roster_size - 1), 1);
    const used_span = spacing * (roster_size - 1);
    const first_row = 3 + (row_span - used_span) / 2;
    return @intCast(first_row + index * spacing);
}

fn rosterSlotName(slot_id: i32) []const u8 {
    return switch (slot_id) {
        0 => "QB",
        1 => "TQB",
        2 => "RB",
        3 => "RB/WR",
        4 => "WR",
        5 => "WR/TE",
        6 => "TE",
        7 => "OP",
        8 => "DT",
        9 => "DE",
        10 => "LB",
        11 => "DL",
        12 => "CB",
        13 => "S",
        14 => "DB",
        15 => "DP",
        16 => "D/ST",
        17 => "K",
        18 => "P",
        19 => "HC",
        20 => "BENCH",
        22 => "RES",
        23 => "FLEX",
        24 => "EDR",
        else => unreachable,
    };
}

fn rosterSlotOccurrence(previous_slots: []const i32, slot_id: i32) usize {
    var occurrence: usize = 0;
    for (previous_slots) |previous_slot_id| {
        if (previous_slot_id == slot_id) occurrence += 1;
    }
    return occurrence;
}

fn purchaseForRosterSlot(team: *const draft.Team, slot_id: i32, occurrence: usize) ?draft.Purchase {
    var current: usize = 0;
    for (team.roster.items) |purchase| {
        if (purchase.slot_id != slot_id) continue;
        if (current == occurrence) return purchase;
        current += 1;
    }
    return null;
}

fn drawFooter(state: *const draft.State, window: vaxis.Window) void {
    printCentered(window, window.height -| 2, state.status_message, statusStyle(state.status));

    printCentered(window, window.height -| 1, "hjkl navigation  •  esc/q exit", muted);
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

fn formatClock(frame_allocator: std.mem.Allocator, milliseconds: i64) []const u8 {
    const total_seconds = @divFloor(milliseconds + 999, 1000);
    const seconds: u8 = @intCast(@mod(total_seconds, 60));
    return std.fmt.allocPrint(
        frame_allocator,
        "{d}:{d:0>2}",
        .{ @divFloor(total_seconds, 60), seconds },
    ) catch unreachable;
}

fn statusStyle(status: draft.Status) Cell.Style {
    return switch (status) {
        .live => accent,
        .loading, .connecting => muted,
        .reconnecting => error_style,
    };
}
