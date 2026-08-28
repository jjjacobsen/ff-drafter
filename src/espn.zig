const std = @import("std");
const websocket = @import("websocket");
const config_module = @import("config.zig");
const draft = @import("draft.zig");
const engine = @import("engine.zig");
const events = @import("events.zig");
const init_decoder = @import("init_decoder.zig");

const Config = config_module.Config;
const player_filter =
    \\{"players":{"limit":2000,"sortDraftRanks":{"sortPriority":1,"sortAsc":true,"value":"PPR"}}}
;
const roster_slot_order = [_]i32{
    0, 1, 2, 3, 4, 5, 6, 23, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 22, 24, 20,
};
const Automation = struct {
    bid_player_id: ?i32 = null,
    bid_amount: i32 = 0,
    bid_team_id: ?i32 = null,
    bid_due_ms: i64 = 0,
    bid_sent: bool = false,
    nomination_pick_number: ?i32 = null,
    nomination_due_ms: i64 = 0,
    nomination_sent: bool = false,
};

const OutgoingAction = union(enum) {
    bid: struct { player_id: i32, amount: i32 },
    nominate: struct { player_id: i32, amount: i32 },
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    shared: *draft.Shared,
    loop: *events.Loop,
    config: *const Config,
) void {
    runWorker(io, allocator, shared, loop, config) catch |err| {
        reportError(shared, loop, err);
    };
}

pub fn runArtwork(
    io: std.Io,
    allocator: std.mem.Allocator,
    shared: *draft.Shared,
    loop: *events.Loop,
    config: *const Config,
) void {
    var http: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http.deinit();

    while (!shared.shouldStop()) {
        const player_id = player: {
            const state = shared.lock();
            defer shared.unlock();
            break :player state.auction.player_id;
        };
        if (player_id) |id| {
            ensureNominatedPlayer(&http, allocator, shared, loop, config, id) catch |err| {
                std.log.warn("could not load player artwork: {s}", .{@errorName(err)});
            };
        }

        const team_request = request: {
            const state = shared.lock();
            defer shared.unlock();
            for (state.teams.items) |team| {
                if (!state.requestTeamLogo(team.id)) continue;
                break :request .{ .id = team.id, .url = team.logo_url };
            }
            break :request null;
        };
        if (team_request) |team| {
            const logo = fetchEspn(&http, allocator, config, team.url, null) catch |err| {
                std.log.warn("could not load logo for team {d}: {s}", .{ team.id, @errorName(err) });
                continue;
            };
            if (shared.shouldStop()) {
                allocator.free(logo);
                return;
            }
            {
                const state = shared.lock();
                defer shared.unlock();
                state.setTeamLogo(team.id, logo);
            }
            _ = loop.tryPostEvent(.draft_update) catch {};
            continue;
        }

        io.sleep(.fromMilliseconds(250), .awake) catch return;
    }
}

fn runWorker(
    io: std.Io,
    allocator: std.mem.Allocator,
    shared: *draft.Shared,
    loop: *events.Loop,
    config: *const Config,
) !void {
    var http: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http.deinit();

    while (!shared.shouldStop()) {
        loadCatalog(&http, allocator, shared, loop, config) catch |err| {
            try setError(shared, loop, .reconnecting, err);
            try waitBeforeReconnect(io, shared);
            continue;
        };
        break;
    }

    while (!shared.shouldStop()) {
        runConnection(io, allocator, &http, shared, loop, config) catch |err| {
            if (shared.shouldStop()) return;
            try setError(shared, loop, .reconnecting, err);
            try waitBeforeReconnect(io, shared);
            continue;
        };
    }
}

fn loadCatalog(
    http: *std.http.Client,
    allocator: std.mem.Allocator,
    shared: *draft.Shared,
    loop: *events.Loop,
    config: *const Config,
) !void {
    try setStatus(shared, loop, .loading, "Loading teams and players");

    const base_url = try leagueBaseUrl(allocator, config);
    defer allocator.free(base_url);
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}?view=draftInit&view=kona_player_info",
        .{base_url},
    );
    defer allocator.free(url);

    const body = try fetchEspn(http, allocator, config, url, player_filter);
    defer allocator.free(body);
    if (shared.shouldStop()) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const teams = root.get("teams").?.array.items;
    const players = root.get("players").?.array.items;
    const lineup_slot_counts = root.get("settings").?.object
        .get("rosterSettings").?.object
        .get("lineupSlotCounts").?.object;

    {
        const state = shared.lock();
        defer shared.unlock();

        state.resetRosterSlots();
        for (roster_slot_order) |slot_id| {
            var slot_buffer: [8]u8 = undefined;
            const slot = std.fmt.bufPrint(&slot_buffer, "{d}", .{slot_id}) catch unreachable;
            const count: usize = @intCast(lineup_slot_counts.get(slot).?.integer);
            for (0..count) |_| try state.addRosterSlot(slot_id);
        }

        for (teams) |team_value| {
            const team = team_value.object;
            try state.addTeam(
                @intCast(team.get("id").?.integer),
                team.get("name").?.string,
                team.get("abbrev").?.string,
                team.get("logo").?.string,
            );
        }

        try addFantasyPlayers(state, players);
    }

    if (shared.shouldStop()) return;
    try setStatus(shared, loop, .connecting, "Connecting to live draft");
}

fn runConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    http: *std.http.Client,
    shared: *draft.Shared,
    loop: *events.Loop,
    config: *const Config,
) !void {
    try setStatus(shared, loop, .connecting, "Connecting to live draft");

    const base_url = try leagueBaseUrl(allocator, config);
    defer allocator.free(base_url);
    const security_url = try std.fmt.allocPrint(
        allocator,
        "{s}/teams/{d}/draftSecurity",
        .{ base_url, config.team_id },
    );
    defer allocator.free(security_url);

    const security_body = try fetchEspn(http, allocator, config, security_url, null);
    defer allocator.free(security_body);
    var security_json = try std.json.parseFromSlice(std.json.Value, allocator, security_body, .{});
    defer security_json.deinit();
    const security = security_json.value.integer;

    const now_real_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const path = try std.fmt.allocPrint(
        allocator,
        "/game-1/league-{d}/JOIN?1=1&2={d}&3={d}&4={s}&5=1:{d}:{d}:{s}:{d}&6=false&7=false&8=KONA&nocache={d}",
        .{
            config.league_id,
            config.league_id,
            config.team_id,
            config.member_id,
            config.league_id,
            config.team_id,
            config.member_id,
            security,
            now_real_ms,
        },
    );
    defer allocator.free(path);

    var client = try websocket.Client.init(io, allocator, .{
        .host = "fantasydraft.espn.com",
        .port = 443,
        .tls = true,
        .max_size = 128 * 1024,
        .connect_timeout_ms = 10_000,
    });
    defer client.deinit();

    try client.handshake(path, .{
        .timeout_ms = 10_000,
        .headers = "Host: fantasydraft.espn.com\r\n" ++
            "Origin: https://fantasy.espn.com\r\n" ++
            "User-Agent: Mozilla/5.0",
    });
    try client.readTimeout(500);
    try client.writeTimeout(1_000);

    const connected_at = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var last_ping_ms: i64 = 0;
    var last_tick_ms = connected_at;
    var automation: Automation = .{};
    while (!shared.shouldStop()) {
        const now_awake_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if ((last_ping_ms == 0 and now_awake_ms - connected_at >= 1_000) or
            (last_ping_ms != 0 and now_awake_ms - last_ping_ms >= 15_000))
        {
            var ping_buffer: [64]u8 = undefined;
            const ping = try std.fmt.bufPrint(
                &ping_buffer,
                "PING PING%20{d}\n",
                .{std.Io.Timestamp.now(io, .real).toMilliseconds()},
            );
            try client.writeText(ping);
            last_ping_ms = now_awake_ms;
        }

        if (now_awake_ms - last_tick_ms >= 1_000) {
            _ = try loop.tryPostEvent(.tick);
            last_tick_ms = now_awake_ms;
        }

        const message = client.read() catch |err| switch (err) {
            error.Closed => return error.DraftConnectionClosed,
            else => return err,
        } orelse {
            try runAutomation(
                &client,
                shared,
                &automation,
                std.Io.Timestamp.now(io, .awake).toMilliseconds(),
            );
            continue;
        };
        defer client.done(message);

        switch (message.type) {
            .text, .binary => try handleMessage(
                io,
                allocator,
                http,
                &client,
                shared,
                loop,
                config,
                std.mem.trimEnd(u8, message.data, "\x00\r\n"),
            ),
            .ping => try client.writePong(message.data),
            .pong => {},
            .close => return error.DraftConnectionClosed,
        }
    }

    try client.close(.{});
}

fn handleMessage(
    io: std.Io,
    allocator: std.mem.Allocator,
    http: *std.http.Client,
    client: *websocket.Client,
    shared: *draft.Shared,
    loop: *events.Loop,
    config: *const Config,
    message: []const u8,
) !void {
    var fields = std.mem.tokenizeAny(u8, message, " \t\r\n");
    const command = fields.next() orelse return;
    const now_awake_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();

    if (std.mem.eql(u8, command, "INIT")) {
        const encoded = fields.next().?;
        var snapshot = try init_decoder.decodeBase64(allocator, encoded);
        defer snapshot.deinit();

        for (snapshot.teams.items) |team| {
            if (team.team_id != config.team_id or team.autodraft_type_id == 0) continue;
            var disable_autodraft = "AUTODRAFT false\n".*;
            try client.writeText(&disable_autodraft);
            break;
        }

        var missing_player_ids: std.ArrayList(i32) = .empty;
        defer missing_player_ids.deinit(allocator);
        {
            const state = shared.lock();
            defer shared.unlock();
            for (snapshot.picks.items) |pick| {
                if (pick.player_id == -1 or state.hasPlayer(pick.player_id)) continue;
                if (std.mem.indexOfScalar(i32, missing_player_ids.items, pick.player_id) == null)
                    try missing_player_ids.append(allocator, pick.player_id);
            }
            if (snapshot.block) |block| {
                if (block.player_id != -1 and block.player_id != 0 and
                    !state.hasPlayer(block.player_id) and
                    std.mem.indexOfScalar(i32, missing_player_ids.items, block.player_id) == null)
                {
                    try missing_player_ids.append(allocator, block.player_id);
                }
            }
        }
        try loadFantasyPlayers(http, allocator, shared, config, missing_player_ids.items);

        {
            const state = shared.lock();
            defer shared.unlock();
            try state.applyInit(&snapshot, nowTimes(io));
        }
        _ = try loop.tryPostEvent(.draft_update);

        return;
    }

    if (std.mem.eql(u8, command, "BID")) {
        const team_id = try nextInt(i32, &fields);
        const player_id = try nextInt(i32, &fields);
        const amount = try nextInt(i32, &fields);
        _ = try nextInt(i64, &fields);
        const remaining = try nextInt(i64, &fields);
        try ensurePlayer(http, allocator, shared, config, player_id);
        {
            const state = shared.lock();
            defer shared.unlock();
            state.setBid(team_id, player_id, amount, remaining, now_awake_ms);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }

    if (std.mem.eql(u8, command, "CLOCK")) {
        _ = try nextIntOr(i32, &fields, -1);
        const time = try nextIntOr(i64, &fields, -1);
        const team_id = try nextIntOr(i32, &fields, -1);
        const player_id = try nextIntOr(i32, &fields, -1);
        const amount = try nextIntOr(i32, &fields, -1);
        if (player_id != -1 and player_id != 0)
            try ensurePlayer(http, allocator, shared, config, player_id);
        {
            const state = shared.lock();
            defer shared.unlock();
            state.setClockMessage(time, team_id, player_id, amount, now_awake_ms);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }

    if (std.mem.eql(u8, command, "NOMINATION")) {
        const team_id = try nextInt(i32, &fields);
        const remaining = try nextInt(i64, &fields);
        {
            const state = shared.lock();
            defer shared.unlock();
            state.setNomination(team_id, remaining, now_awake_ms);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }

    if (std.mem.eql(u8, command, "SOLD")) {
        const team_id = try nextInt(i32, &fields);
        const player_id = try nextInt(i32, &fields);
        const slot_id = try nextInt(i32, &fields);
        const amount = try nextInt(i32, &fields);
        try ensurePlayer(http, allocator, shared, config, player_id);
        {
            const state = shared.lock();
            defer shared.unlock();
            try state.applySold(team_id, player_id, slot_id, amount, now_awake_ms);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }

    if (std.mem.eql(u8, command, "AUTODRAFT")) {
        const team_id = try nextInt(i32, &fields);
        const enabled = std.mem.eql(u8, fields.next().?, "true");
        if (team_id == config.team_id and enabled) {
            var disable_autodraft = "AUTODRAFT false\n".*;
            try client.writeText(&disable_autodraft);
        }
        return;
    }

    if (std.mem.eql(u8, command, "ADJUSTED")) {
        const pick_number = try nextInt(i32, &fields);
        _ = try nextInt(i32, &fields);
        const new_price = try nextInt(i32, &fields);
        {
            const state = shared.lock();
            defer shared.unlock();
            state.applyAdjusted(pick_number, new_price);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }

    if (std.mem.eql(u8, command, "UNDONE")) {
        const pick_number = try nextInt(i32, &fields);
        {
            const state = shared.lock();
            defer shared.unlock();
            state.applyUndone(pick_number);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }

    if (std.mem.eql(u8, command, "SLOT_CHANGED")) {
        const team_id = try nextInt(i32, &fields);
        const player_id = try nextInt(i32, &fields);
        _ = try nextInt(i32, &fields);
        const new_slot_id = try nextInt(i32, &fields);
        {
            const state = shared.lock();
            defer shared.unlock();
            state.applySlotChanged(team_id, player_id, new_slot_id);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }

    if (std.mem.eql(u8, command, "ERROR")) {
        const status = try std.fmt.allocPrint(allocator, "ESPN rejected a draft command: {s}", .{message});
        defer allocator.free(status);
        {
            const state = shared.lock();
            defer shared.unlock();
            try state.setStatus(.command_error, status);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }
}

fn runAutomation(
    client: *websocket.Client,
    shared: *draft.Shared,
    automation: *Automation,
    now_ms: i64,
) !void {
    var outgoing: ?OutgoingAction = null;

    state_scope: {
        const state = shared.lock();
        defer shared.unlock();
        if (state.status != .live and state.status != .command_error) return;

        if (state.auction.nomination_team_id == state.user_team_id) {
            const remaining_ms = state.clockRemainingMs(now_ms);
            if (remaining_ms <= 0) return;

            if (automation.nomination_pick_number != state.next_pick_number) {
                const delay_ms: i64 = if (engine.priorityRosterComplete(state)) 1_000 else 5_000;
                automation.nomination_pick_number = state.next_pick_number;
                automation.nomination_due_ms = @min(
                    now_ms + delay_ms,
                    now_ms + @max(remaining_ms - 1_000, 0),
                );
                automation.nomination_sent = false;
            }

            if (!automation.nomination_sent and now_ms >= automation.nomination_due_ms) {
                if (engine.chooseNomination(state)) |nomination| {
                    outgoing = .{ .nominate = .{
                        .player_id = nomination.player_id,
                        .amount = nomination.amount,
                    } };
                    automation.nomination_sent = true;
                }
            }
        } else {
            automation.nomination_pick_number = null;
            automation.nomination_sent = false;
        }

        const player_id = state.auction.player_id orelse {
            automation.bid_player_id = null;
            automation.bid_sent = false;
            break :state_scope;
        };
        const bid = engine.decision(state, player_id);
        const bid_changed = automation.bid_player_id != player_id or
            automation.bid_amount != state.auction.bid_amount or
            automation.bid_team_id != state.auction.bid_team_id;
        if (bid_changed) {
            const is_counter_bid = automation.bid_player_id == player_id;
            automation.bid_player_id = player_id;
            automation.bid_amount = state.auction.bid_amount;
            automation.bid_team_id = state.auction.bid_team_id;
            automation.bid_due_ms = now_ms + @as(i64, if (is_counter_bid) 1_000 else 0);
            automation.bid_sent = false;
        }

        const remaining_ms = state.clockRemainingMs(now_ms);
        if (state.auction.bid_team_id == state.user_team_id or
            !bid.price_allowed or
            remaining_ms <= 0 or
            remaining_ms > 8_000 or
            automation.bid_sent or
            now_ms < automation.bid_due_ms)
        {
            break :state_scope;
        }

        outgoing = .{ .bid = .{ .player_id = player_id, .amount = bid.next_bid } };
        automation.bid_sent = true;
    }

    try sendAction(client, outgoing);
}

fn sendAction(client: *websocket.Client, outgoing: ?OutgoingAction) !void {
    const action = outgoing orelse return;
    var buffer: [64]u8 = undefined;
    const message = switch (action) {
        .bid => |bid| try std.fmt.bufPrint(&buffer, "BID {d} {d}\n", .{ bid.player_id, bid.amount }),
        .nominate => |nomination| try std.fmt.bufPrint(
            &buffer,
            "NOMINATE {d} {d}\n",
            .{ nomination.player_id, nomination.amount },
        ),
    };
    try client.writeText(message);
}

fn ensurePlayer(
    http: *std.http.Client,
    allocator: std.mem.Allocator,
    shared: *draft.Shared,
    config: *const Config,
    player_id: i32,
) !void {
    {
        const state = shared.lock();
        defer shared.unlock();
        if (state.hasPlayer(player_id)) return;
    }

    try loadFantasyPlayers(http, allocator, shared, config, &.{player_id});
}

fn loadFantasyPlayers(
    http: *std.http.Client,
    allocator: std.mem.Allocator,
    shared: *draft.Shared,
    config: *const Config,
    player_ids: []const i32,
) !void {
    if (player_ids.len == 0) return;

    const base_url = try leagueBaseUrl(allocator, config);
    defer allocator.free(base_url);
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}?view=draftInit&view=kona_player_info",
        .{base_url},
    );
    defer allocator.free(url);

    var filter: std.Io.Writer.Allocating = .init(allocator);
    defer filter.deinit();
    try filter.writer.writeAll("{\"players\":{\"filterIds\":{\"value\":[");
    for (player_ids, 0..) |player_id, index| {
        if (index != 0) try filter.writer.writeByte(',');
        try filter.writer.print("{d}", .{player_id});
    }
    try filter.writer.writeAll(
        "]},\"limit\":2000,\"sortDraftRanks\":{\"sortPriority\":1,\"sortAsc\":true,\"value\":\"PPR\"}}}",
    );

    const body = try fetchEspn(http, allocator, config, url, filter.written());
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const state = shared.lock();
    defer shared.unlock();
    try addFantasyPlayers(state, parsed.value.object.get("players").?.array.items);
}

fn addFantasyPlayers(state: *draft.State, players: []const std.json.Value) !void {
    for (players) |player_value| {
        const item = player_value.object;
        const player = item.get("player").?.object;
        const position_id: i32 = @intCast(player.get("defaultPositionId").?.integer);
        try state.addPlayer(
            @intCast(item.get("id").?.integer),
            player.get("fullName").?.string,
            positionName(position_id),
            @intCast(player.get("proTeamId").?.integer),
            @intCast(item.get("draftAuctionValue").?.integer),
        );
    }
}

fn ensureNominatedPlayer(
    http: *std.http.Client,
    allocator: std.mem.Allocator,
    shared: *draft.Shared,
    loop: *events.Loop,
    config: *const Config,
    player_id: i32,
) !void {
    try ensurePlayer(http, allocator, shared, config, player_id);

    const pro_team_id = image: {
        const state = shared.lock();
        defer shared.unlock();
        if (!state.requestPlayerImage(player_id)) return;
        break :image state.players.get(player_id).?.pro_team_id;
    };

    const url = if (player_id > 0)
        try std.fmt.allocPrint(
            allocator,
            "https://a.espncdn.com/i/headshots/nfl/players/full/{d}.png",
            .{player_id},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "https://a.espncdn.com/i/teamlogos/nfl/500/{s}.png",
            .{proTeamAbbreviation(pro_team_id)},
        );
    defer allocator.free(url);

    const image = fetchEspn(http, allocator, config, url, null) catch |err| {
        std.log.warn("could not load artwork for player {d}: {s}", .{ player_id, @errorName(err) });
        return;
    };
    {
        const state = shared.lock();
        defer shared.unlock();
        state.setPlayerImage(player_id, image);
    }
    _ = try loop.tryPostEvent(.draft_update);
}

fn proTeamAbbreviation(team_id: i32) []const u8 {
    return switch (team_id) {
        1 => "atl",
        2 => "buf",
        3 => "chi",
        4 => "cin",
        5 => "cle",
        6 => "dal",
        7 => "den",
        8 => "det",
        9 => "gb",
        10 => "ten",
        11 => "ind",
        12 => "kc",
        13 => "lv",
        14 => "lar",
        15 => "mia",
        16 => "min",
        17 => "ne",
        18 => "no",
        19 => "nyg",
        20 => "nyj",
        21 => "phi",
        22 => "ari",
        23 => "pit",
        24 => "lac",
        25 => "sf",
        26 => "sea",
        27 => "tb",
        28 => "was",
        29 => "car",
        30 => "jax",
        33 => "bal",
        34 => "hou",
        else => unreachable,
    };
}

fn fetchEspn(
    http: *std.http.Client,
    allocator: std.mem.Allocator,
    config: *const Config,
    url: []const u8,
    filter: ?[]const u8,
) ![]u8 {
    const cookie = try std.fmt.allocPrint(
        allocator,
        "espn_s2={s}; SWID={s}",
        .{ config.espn_s2, config.swid },
    );
    defer {
        @memset(cookie, 0);
        allocator.free(cookie);
    }

    var extra_headers: [4]std.http.Header = undefined;
    extra_headers[0] = .{ .name = "Accept", .value = "application/json" };
    extra_headers[1] = .{ .name = "X-Fantasy-Source", .value = "kona" };
    var extra_header_count: usize = 2;
    if (filter) |value| {
        extra_headers[extra_header_count] = .{ .name = "X-Fantasy-Filter", .value = value };
        extra_header_count += 1;
    }
    if (std.mem.startsWith(u8, url, "https://lm-api-reads.fantasy.espn.com/") or
        std.mem.startsWith(u8, url, "https://mystique-api.fantasy.espn.com/"))
    {
        extra_headers[extra_header_count] = .{ .name = "Cookie", .value = cookie };
        extra_header_count += 1;
    }

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const result = try http.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "Mozilla/5.0" },
        },
        .extra_headers = extra_headers[0..extra_header_count],
        .response_writer = &body.writer,
    });
    switch (result.status) {
        .ok => {},
        .bad_request => return error.EspnBadRequest,
        .unauthorized => return error.EspnUnauthorized,
        .forbidden => return error.EspnForbidden,
        .not_found => return error.EspnNotFound,
        else => return error.EspnHttpStatus,
    }
    return body.toOwnedSlice();
}

fn leagueBaseUrl(allocator: std.mem.Allocator, config: *const Config) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/{d}/segments/0/leagues/{d}",
        .{ config.season_id, config.league_id },
    );
}

fn setStatus(
    shared: *draft.Shared,
    loop: *events.Loop,
    status: draft.Status,
    message: []const u8,
) !void {
    {
        const state = shared.lock();
        defer shared.unlock();
        try state.setStatus(status, message);
    }
    _ = try loop.tryPostEvent(.draft_update);
}

fn setError(
    shared: *draft.Shared,
    loop: *events.Loop,
    status: draft.Status,
    err: anyerror,
) !void {
    {
        const state = shared.lock();
        defer shared.unlock();
        try state.setStatusError(status, err);
    }
    _ = try loop.tryPostEvent(.draft_update);
}

fn reportError(shared: *draft.Shared, loop: *events.Loop, err: anyerror) void {
    setError(shared, loop, .reconnecting, err) catch unreachable;
}

fn waitBeforeReconnect(io: std.Io, shared: *const draft.Shared) !void {
    var elapsed: u8 = 0;
    while (elapsed < 30 and !shared.shouldStop()) : (elapsed += 1) {
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

fn nextInt(comptime T: type, fields: anytype) !T {
    return std.fmt.parseInt(T, fields.next().?, 10);
}

fn nextIntOr(comptime T: type, fields: anytype, default: T) !T {
    const field = fields.next() orelse return default;
    return std.fmt.parseInt(T, field, 10);
}

fn nowTimes(io: std.Io) draft.Times {
    return .{
        .real_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .awake_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds(),
    };
}

fn positionName(position_id: i32) []const u8 {
    return switch (position_id) {
        1 => "QB",
        2 => "RB",
        3 => "WR",
        4 => "TE",
        5 => "K",
        16 => "D/ST",
        else => "--",
    };
}
