const std = @import("std");
const websocket = @import("websocket");
const config_module = @import("config.zig");
const draft = @import("draft.zig");
const events = @import("events.zig");
const init_decoder = @import("init_decoder.zig");

const Config = config_module.Config;
const player_filter =
    \\{"players":{"limit":2000,"sortDraftRanks":{"sortPriority":1,"sortAsc":true,"value":"PPR"}}}
;
const roster_slot_order = [_]i32{
    0, 1, 2, 3, 4, 5, 6, 23, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 22, 24, 20,
};
const nomination_candidate_limit = 64;

const Automation = struct {
    bid_player_id: ?i32 = null,
    bid_amount: i32 = 0,
    bid_due_ms: i64 = 0,
    bid_sent: bool = false,
    nomination_pick_number: ?i32 = null,
    nomination_player_id: i32 = 0,
    nomination_due_ms: i64 = 0,
    nomination_sent: bool = false,
};

const OutgoingAction = union(enum) {
    bid: struct { player_id: i32, amount: i32 },
    nominate: struct { player_id: i32, amount: i32 },
};

const NominationCandidate = struct {
    player_id: i32,
    espn_value: i32,
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
            );
        }

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

    for (teams) |team_value| {
        if (shared.shouldStop()) return;

        const team = team_value.object;
        const logo = try fetchEspn(http, allocator, config, team.get("logo").?.string, null);
        if (shared.shouldStop()) {
            allocator.free(logo);
            return;
        }

        const state = shared.lock();
        defer shared.unlock();
        state.setTeamLogo(@intCast(team.get("id").?.integer), logo);
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
            const action_time_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
            try runAutomation(allocator, &client, shared, &automation, action_time_ms);
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
        var disable_autodraft = "AUTODRAFT false".*;
        try client.writeText(&disable_autodraft);
        const encoded = fields.next().?;
        var snapshot = try init_decoder.decodeBase64(allocator, encoded);
        defer snapshot.deinit();

        for (snapshot.picks.items) |pick| {
            if (pick.player_id != -1) try ensurePlayer(http, allocator, shared, config, pick.player_id);
        }
        if (snapshot.block) |block| {
            if (block.player_id != -1 and block.player_id != 0)
                try ensurePlayer(http, allocator, shared, config, block.player_id);
        }

        {
            const state = shared.lock();
            defer shared.unlock();
            try state.applyInit(&snapshot, nowTimes(io));
            try state.refreshRecommendation(true);
        }
        _ = try loop.tryPostEvent(.draft_update);

        if (snapshot.block) |block| {
            if (block.player_id != -1 and block.player_id != 0)
                try ensureNominatedPlayer(http, allocator, shared, loop, config, block.player_id);
        }
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
            try state.refreshRecommendation(false);
        }
        _ = try loop.tryPostEvent(.draft_update);
        try ensureNominatedPlayer(http, allocator, shared, loop, config, player_id);
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
            try state.refreshRecommendation(false);
        }
        _ = try loop.tryPostEvent(.draft_update);
        if (player_id != -1 and player_id != 0)
            try ensureNominatedPlayer(http, allocator, shared, loop, config, player_id);
        return;
    }

    if (std.mem.eql(u8, command, "NOMINATION")) {
        const team_id = try nextInt(i32, &fields);
        const remaining = try nextInt(i64, &fields);
        {
            const state = shared.lock();
            defer shared.unlock();
            state.setNomination(team_id, remaining, now_awake_ms);
            try state.refreshRecommendation(false);
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
            try state.refreshRecommendation(true);
        }
        _ = try loop.tryPostEvent(.draft_update);
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
            try state.refreshRecommendation(true);
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
            try state.refreshRecommendation(true);
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
            try state.refreshRecommendation(true);
        }
        _ = try loop.tryPostEvent(.draft_update);
        return;
    }

    if (std.mem.eql(u8, command, "ERROR")) return error.EspnDraftError;
}

fn runAutomation(
    allocator: std.mem.Allocator,
    client: *websocket.Client,
    shared: *draft.Shared,
    automation: *Automation,
    now_ms: i64,
) !void {
    var outgoing: ?OutgoingAction = null;

    state_scope: {
        const state = shared.lock();
        defer shared.unlock();

        if (state.status != .live) return;

        if (state.auction.nomination_team_id == state.user_team_id) {
            const remaining_ms = state.clockRemainingMs(now_ms);
            if (remaining_ms <= 0) return;

            if (automation.nomination_pick_number != state.next_pick_number) {
                const player_id = try chooseNominee(allocator, state) orelse return;
                const delay_ms = jitter(5_000, 10_000, entropy(now_ms, player_id, state.next_pick_number));
                const latest_ms = now_ms + @max(remaining_ms - 3_000, 0);
                automation.nomination_pick_number = state.next_pick_number;
                automation.nomination_player_id = player_id;
                automation.nomination_due_ms = @min(now_ms + delay_ms, latest_ms);
                automation.nomination_sent = false;
            }

            if (!automation.nomination_sent and now_ms >= automation.nomination_due_ms) {
                if (!state.isPlayerDrafted(automation.nomination_player_id)) {
                    const recommendation = try state.calculatePlayerRecommendation(automation.nomination_player_id);
                    if (recommendation.max_bid >= 1 and recommendation.legal_max >= 1) {
                        outgoing = .{ .nominate = .{
                            .player_id = automation.nomination_player_id,
                            .amount = 1,
                        } };
                        automation.nomination_sent = true;
                    } else {
                        automation.nomination_pick_number = null;
                    }
                } else {
                    automation.nomination_pick_number = null;
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
        const recommendation = state.recommendation;
        const next_bid = if (state.auction.bid_team_id == null and state.auction.bid_amount == 0)
            1
        else
            state.auction.bid_amount + 1;
        const remaining_ms = state.clockRemainingMs(now_ms);

        if (recommendation.player_id != player_id or
            recommendation.action != .bid or
            next_bid > recommendation.max_bid or
            next_bid > recommendation.legal_max or
            remaining_ms <= 0)
        {
            automation.bid_player_id = null;
            automation.bid_sent = false;
            break :state_scope;
        }

        if (automation.bid_player_id != player_id or automation.bid_amount != next_bid) {
            const action_entropy = entropy(now_ms, player_id, next_bid);
            const delay_ms = if (next_bid <= recommendation.target_bid)
                jitter(2_000, 5_000, action_entropy)
            else
                jitter(1_000, 3_000, action_entropy);
            const safety_ms = jitter(2_000, 3_000, action_entropy ^ 0xa0761d6478bd642f);
            const latest_ms = now_ms + @max(remaining_ms - safety_ms, 0);

            automation.bid_player_id = player_id;
            automation.bid_amount = next_bid;
            automation.bid_due_ms = @min(now_ms + delay_ms, latest_ms);
            automation.bid_sent = false;
        }

        if (!automation.bid_sent and now_ms >= automation.bid_due_ms) {
            outgoing = .{ .bid = .{ .player_id = player_id, .amount = next_bid } };
            automation.bid_sent = true;
        }
    }

    try sendAction(client, outgoing);
}

fn sendAction(client: *websocket.Client, outgoing: ?OutgoingAction) !void {
    const action = outgoing orelse return;
    var buffer: [64]u8 = undefined;
    const message = switch (action) {
        .bid => |bid| try std.fmt.bufPrint(&buffer, "BID {d} {d}", .{ bid.player_id, bid.amount }),
        .nominate => |nomination| try std.fmt.bufPrint(
            &buffer,
            "NOMINATE {d} {d}",
            .{ nomination.player_id, nomination.amount },
        ),
    };
    try client.writeText(message);
}

fn chooseNominee(allocator: std.mem.Allocator, state: *const draft.State) !?i32 {
    var candidates: std.ArrayList(NominationCandidate) = .empty;
    defer candidates.deinit(allocator);

    var players = state.players.iterator();
    while (players.next()) |entry| {
        if (state.isPlayerDrafted(entry.key_ptr.*)) continue;
        try candidates.append(allocator, .{
            .player_id = entry.key_ptr.*,
            .espn_value = entry.value_ptr.estimated_price,
        });
    }
    std.mem.sort(NominationCandidate, candidates.items, {}, nominationValueOrder);

    var selected_player_id: ?i32 = null;
    var selected_decoy_value: i32 = -1;
    var selected_espn_value: i32 = -1;
    for (candidates.items, 0..) |candidate, index| {
        if (index >= nomination_candidate_limit and selected_player_id != null) break;
        const recommendation = try state.calculatePlayerRecommendation(candidate.player_id);
        if (recommendation.max_bid < 1 or recommendation.legal_max < 1) continue;
        const decoy_value = candidate.espn_value - recommendation.marginal_value;
        if (decoy_value > selected_decoy_value or
            (decoy_value == selected_decoy_value and candidate.espn_value > selected_espn_value) or
            (decoy_value == selected_decoy_value and candidate.espn_value == selected_espn_value and
                (selected_player_id == null or candidate.player_id < selected_player_id.?)))
        {
            selected_player_id = candidate.player_id;
            selected_decoy_value = decoy_value;
            selected_espn_value = candidate.espn_value;
        }
    }
    return selected_player_id;
}

fn nominationValueOrder(_: void, left: NominationCandidate, right: NominationCandidate) bool {
    if (left.espn_value != right.espn_value) return left.espn_value > right.espn_value;
    return left.player_id < right.player_id;
}

fn entropy(now_ms: i64, player_id: i32, amount: i32) u64 {
    return @as(u64, @intCast(now_ms)) ^
        (@as(u64, @as(u32, @bitCast(player_id))) << 32) ^
        @as(u64, @as(u32, @bitCast(amount)));
}

fn jitter(min_ms: i64, max_ms: i64, seed: u64) i64 {
    var value = seed;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    value *%= 0x2545f4914f6cdd1d;
    const range: u64 = @intCast(max_ms - min_ms + 1);
    return min_ms + @as(i64, @intCast(value % range));
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

    const url = try std.fmt.allocPrint(
        allocator,
        "https://site.api.espn.com/apis/common/v3/sports/football/nfl/athletes/{d}",
        .{player_id},
    );
    defer allocator.free(url);
    const body = try fetchEspn(http, allocator, config, url, null);
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const athlete = parsed.value.object.get("athlete").?.object;
    const state = shared.lock();
    defer shared.unlock();
    try state.addPlayer(
        player_id,
        athlete.get("fullName").?.string,
        athlete.get("position").?.object.get("abbreviation").?.string,
        0,
        0,
    );
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
