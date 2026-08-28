const std = @import("std");
const init_decoder = @import("init_decoder.zig");

pub const Status = enum {
    loading,
    connecting,
    live,
    command_error,
    reconnecting,
};

pub const Player = struct {
    name: []u8,
    position: []u8,
    pro_team_id: i32,
    estimated_price: i32,
    image_requested: bool = false,
    image: ?[]u8 = null,

    fn deinit(self: *Player, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.position);
        if (self.image) |image| allocator.free(image);
    }
};

pub const Purchase = struct {
    pick_number: i32,
    player_id: i32,
    slot_id: i32,
    cost: i32,
};

pub const Team = struct {
    id: i32,
    name: []u8,
    abbreviation: []u8,
    logo_url: []u8,
    logo_requested: bool = false,
    logo: ?[]u8 = null,
    draft_position: i32 = 0,
    remaining_budget: i32 = 0,
    roster: std.ArrayList(Purchase) = .empty,

    fn deinit(self: *Team, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.abbreviation);
        allocator.free(self.logo_url);
        if (self.logo) |logo| allocator.free(logo);
        self.roster.deinit(allocator);
    }
};

pub const Auction = struct {
    player_id: ?i32 = null,
    bid_team_id: ?i32 = null,
    nomination_team_id: ?i32 = null,
    bid_amount: i32 = 0,
    clock_duration_ms: i64 = 0,
    clock_set_at_ms: i64 = 0,
};

pub const RecentSale = struct {
    pick_number: i32,
    team_id: i32,
    player_id: i32,
    cost: i32,
    sold_at_ms: i64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    user_team_id: i32,
    teams: std.ArrayList(Team) = .empty,
    roster_slots: std.ArrayList(i32) = .empty,
    players: std.AutoHashMap(i32, Player),
    auction: Auction = .{},
    status: Status = .loading,
    status_message: []u8,
    completed_picks: usize = 0,
    total_picks: usize = 0,
    next_pick_number: i32 = 1,
    recent_sale: ?RecentSale = null,

    pub fn init(allocator: std.mem.Allocator, user_team_id: i32) !State {
        return .{
            .allocator = allocator,
            .user_team_id = user_team_id,
            .players = std.AutoHashMap(i32, Player).init(allocator),
            .status_message = try allocator.dupe(u8, "Loading draft"),
        };
    }

    pub fn deinit(self: *State) void {
        for (self.teams.items) |*team| team.deinit(self.allocator);
        self.teams.deinit(self.allocator);
        self.roster_slots.deinit(self.allocator);

        var players = self.players.valueIterator();
        while (players.next()) |player| player.deinit(self.allocator);
        self.players.deinit();
        self.allocator.free(self.status_message);
    }

    pub fn setStatus(self: *State, status: Status, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        self.allocator.free(self.status_message);
        self.status = status;
        self.status_message = owned;
    }

    pub fn setStatusError(self: *State, status: Status, err: anyerror) !void {
        const message = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ @tagName(status), @errorName(err) });
        self.allocator.free(self.status_message);
        self.status = status;
        self.status_message = message;
    }

    pub fn addTeam(
        self: *State,
        id: i32,
        name: []const u8,
        abbreviation: []const u8,
        logo_url: []const u8,
    ) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_abbreviation = try self.allocator.dupe(u8, abbreviation);
        errdefer self.allocator.free(owned_abbreviation);
        const owned_logo_url = try self.allocator.dupe(u8, logo_url);
        errdefer self.allocator.free(owned_logo_url);
        try self.teams.append(self.allocator, .{
            .id = id,
            .name = owned_name,
            .abbreviation = owned_abbreviation,
            .logo_url = owned_logo_url,
        });
    }

    pub fn requestTeamLogo(self: *State, id: i32) bool {
        const team = &self.teams.items[self.teamIndexById(id).?];
        if (team.logo_requested) return false;
        team.logo_requested = true;
        return true;
    }

    pub fn setTeamLogo(self: *State, id: i32, logo: []u8) void {
        self.teams.items[self.teamIndexById(id).?].logo = logo;
    }

    pub fn resetRosterSlots(self: *State) void {
        self.roster_slots.clearRetainingCapacity();
    }

    pub fn addRosterSlot(self: *State, slot_id: i32) !void {
        try self.roster_slots.append(self.allocator, slot_id);
    }

    pub fn addPlayer(
        self: *State,
        id: i32,
        name: []const u8,
        position: []const u8,
        pro_team_id: i32,
        estimated_price: i32,
    ) !void {
        const player: Player = .{
            .name = try self.allocator.dupe(u8, name),
            .position = try self.allocator.dupe(u8, position),
            .pro_team_id = pro_team_id,
            .estimated_price = estimated_price,
        };
        errdefer {
            self.allocator.free(player.name);
            self.allocator.free(player.position);
        }

        if (try self.players.fetchPut(id, player)) |old| {
            var previous = old.value;
            previous.deinit(self.allocator);
        }
    }

    pub fn hasPlayer(self: *const State, id: i32) bool {
        return self.players.contains(id);
    }

    pub fn requestPlayerImage(self: *State, id: i32) bool {
        const player = self.players.getPtr(id).?;
        if (player.image_requested) return false;
        player.image_requested = true;
        return true;
    }

    pub fn setPlayerImage(self: *State, id: i32, image: []u8) void {
        self.players.getPtr(id).?.image = image;
    }

    pub fn teamIndexById(self: *const State, id: i32) ?usize {
        for (self.teams.items, 0..) |team, index| {
            if (team.id == id) return index;
        }
        return null;
    }

    pub fn applyInit(self: *State, snapshot: *const init_decoder.Snapshot, now: Times) !void {
        for (self.teams.items) |*team| team.roster.clearRetainingCapacity();

        for (snapshot.teams.items) |draft_team| {
            const team = &self.teams.items[self.teamIndexById(draft_team.team_id).?];
            team.draft_position = draft_team.draft_position;
            team.remaining_budget = draft_team.amount_left;
        }

        self.completed_picks = 0;
        self.total_picks = snapshot.picks.items.len;
        self.next_pick_number = 1;
        self.recent_sale = null;
        for (snapshot.picks.items) |pick| {
            if (pick.player_id == -1) continue;
            self.completed_picks += 1;
            const team = &self.teams.items[self.teamIndexById(pick.team_id).?];
            const requested_slot_id = snapshotRosterSlot(snapshot, pick.team_id, pick.player_id);
            try team.roster.append(self.allocator, .{
                .pick_number = pick.pick_number,
                .player_id = pick.player_id,
                .slot_id = self.resolveRosterSlot(team, pick.player_id, requested_slot_id),
                .cost = pick.bid_amount,
            });
            self.next_pick_number = @max(self.next_pick_number, pick.pick_number + 1);
        }

        std.mem.sort(Team, self.teams.items, {}, lessThanDraftPosition);

        self.auction = .{};
        if (snapshot.block) |block| {
            if (block.nomination_team_id > 0) self.auction.nomination_team_id = block.nomination_team_id;
            if (block.player_id != -1 and block.player_id != 0) {
                self.auction.player_id = block.player_id;
                self.auction.nomination_team_id = null;
            }
            if (block.high_bid_team_id > 0) self.auction.bid_team_id = block.high_bid_team_id;
            self.auction.bid_amount = block.high_bid_amount;
            if (block.expiration_time_ms) |expiration| {
                const remaining: i64 = @max(@as(i64, @intCast(expiration)) - now.real_ms, 0);
                self.setClock(remaining, now.awake_ms);
            }
        }

        try self.setStatus(.live, "Live and synchronized");
    }

    pub fn setBid(
        self: *State,
        team_id: i32,
        player_id: i32,
        amount: i32,
        time_remaining_ms: i64,
        now_ms: i64,
    ) void {
        self.auction.player_id = player_id;
        self.auction.bid_team_id = team_id;
        self.auction.nomination_team_id = null;
        self.auction.bid_amount = amount;
        self.setClock(time_remaining_ms, now_ms);
    }

    pub fn setClockMessage(
        self: *State,
        time_remaining_ms: i64,
        team_id: i32,
        player_id: i32,
        amount: i32,
        now_ms: i64,
    ) void {
        const has_player = player_id != -1 and player_id != 0;
        if (has_player and self.auction.player_id != player_id) {
            self.auction.bid_team_id = null;
            self.auction.bid_amount = 0;
        }
        if (has_player) {
            self.auction.player_id = player_id;
            self.auction.nomination_team_id = null;
        }
        if (team_id > 0) self.auction.bid_team_id = team_id;
        if (amount >= 0) self.auction.bid_amount = amount;
        self.setClock(time_remaining_ms, now_ms);
    }

    pub fn setNomination(self: *State, team_id: i32, time_remaining_ms: i64, now_ms: i64) void {
        self.auction = .{ .nomination_team_id = team_id };
        self.setClock(time_remaining_ms, now_ms);
    }

    pub fn applySold(
        self: *State,
        team_id: i32,
        player_id: i32,
        slot_id: i32,
        cost: i32,
        now_ms: i64,
    ) !void {
        const pick_number = self.next_pick_number;
        const team = &self.teams.items[self.teamIndexById(team_id).?];
        const roster_slot_id = self.resolveRosterSlot(team, player_id, slot_id);
        try team.roster.append(self.allocator, .{
            .pick_number = pick_number,
            .player_id = player_id,
            .slot_id = roster_slot_id,
            .cost = cost,
        });
        self.completed_picks += 1;
        self.next_pick_number += 1;
        team.remaining_budget -= cost;
        self.recent_sale = .{
            .pick_number = pick_number,
            .team_id = team_id,
            .player_id = player_id,
            .cost = cost,
            .sold_at_ms = now_ms,
        };
        if (self.players.getPtr(player_id)) |player| {
            if (player.image) |image| self.allocator.free(image);
            player.image = null;
        }
        self.auction = .{};
    }

    pub fn applyAdjusted(self: *State, pick_number: i32, new_price: i32) void {
        for (self.teams.items) |*team| {
            for (team.roster.items) |*purchase| {
                if (purchase.pick_number != pick_number) continue;
                team.remaining_budget += purchase.cost - new_price;
                purchase.cost = new_price;
                if (self.recent_sale) |*sale| {
                    if (sale.pick_number == pick_number) sale.cost = new_price;
                }
                return;
            }
        }
        unreachable;
    }

    pub fn applyUndone(self: *State, pick_number: i32) void {
        for (self.teams.items) |*team| {
            for (team.roster.items, 0..) |purchase, index| {
                if (purchase.pick_number != pick_number) continue;
                team.remaining_budget += purchase.cost;
                _ = team.roster.orderedRemove(index);
                self.completed_picks -= 1;
                self.next_pick_number = pick_number;
                if (self.recent_sale) |sale| {
                    if (sale.pick_number == pick_number) self.recent_sale = null;
                }
                return;
            }
        }
        unreachable;
    }

    pub fn applySlotChanged(self: *State, team_id: i32, player_id: i32, new_slot_id: i32) void {
        const team = &self.teams.items[self.teamIndexById(team_id).?];
        for (team.roster.items) |*purchase| {
            if (purchase.player_id != player_id) continue;
            purchase.slot_id = new_slot_id;
            return;
        }
        unreachable;
    }

    pub fn clockRemainingMs(self: *const State, now_ms: i64) i64 {
        return @max(self.auction.clock_duration_ms - (now_ms - self.auction.clock_set_at_ms), 0);
    }

    fn resolveRosterSlot(self: *const State, team: *const Team, player_id: i32, requested_slot_id: i32) i32 {
        const position = self.players.get(player_id).?.position;
        if (slotAcceptsPosition(requested_slot_id, position) and
            self.rosterSlotHasSpace(team, requested_slot_id))
        {
            return requested_slot_id;
        }

        for (self.roster_slots.items) |slot_id| {
            if (slot_id == 20) continue;
            if (!slotAcceptsPosition(slot_id, position)) continue;
            if (self.rosterSlotHasSpace(team, slot_id)) return slot_id;
        }

        if (self.rosterSlotHasSpace(team, 20)) return 20;
        unreachable;
    }

    fn rosterSlotHasSpace(self: *const State, team: *const Team, slot_id: i32) bool {
        var capacity: usize = 0;
        for (self.roster_slots.items) |roster_slot_id| {
            if (roster_slot_id == slot_id) capacity += 1;
        }

        var occupied: usize = 0;
        for (team.roster.items) |purchase| {
            if (purchase.slot_id == slot_id) occupied += 1;
        }
        return occupied < capacity;
    }

    fn setClock(self: *State, duration_ms: i64, now_ms: i64) void {
        self.auction.clock_duration_ms = @max(duration_ms, 0);
        self.auction.clock_set_at_ms = now_ms;
    }
};

pub const Times = struct {
    real_ms: i64,
    awake_ms: i64,
};

pub const Shared = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    state: State,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, user_team_id: i32) !Shared {
        return .{ .io = io, .state = try .init(allocator, user_team_id) };
    }

    pub fn deinit(self: *Shared) void {
        self.state.deinit();
    }

    pub fn lock(self: *Shared) *State {
        self.mutex.lockUncancelable(self.io);
        return &self.state;
    }

    pub fn unlock(self: *Shared) void {
        self.mutex.unlock(self.io);
    }

    pub fn shouldStop(self: *const Shared) bool {
        return self.stop.load(.acquire);
    }
};

pub fn slotAcceptsPosition(slot_id: i32, position: []const u8) bool {
    return switch (slot_id) {
        0, 1 => std.mem.eql(u8, position, "QB"),
        2 => std.mem.eql(u8, position, "RB"),
        3 => std.mem.eql(u8, position, "RB") or std.mem.eql(u8, position, "WR"),
        4 => std.mem.eql(u8, position, "WR"),
        5 => std.mem.eql(u8, position, "WR") or std.mem.eql(u8, position, "TE"),
        6 => std.mem.eql(u8, position, "TE"),
        7 => std.mem.eql(u8, position, "QB") or
            std.mem.eql(u8, position, "RB") or
            std.mem.eql(u8, position, "WR") or
            std.mem.eql(u8, position, "TE"),
        8 => std.mem.eql(u8, position, "DT"),
        9 => std.mem.eql(u8, position, "DE"),
        10 => std.mem.eql(u8, position, "LB"),
        11 => std.mem.eql(u8, position, "DL"),
        12 => std.mem.eql(u8, position, "CB"),
        13 => std.mem.eql(u8, position, "S"),
        14 => std.mem.eql(u8, position, "DB"),
        15 => std.mem.eql(u8, position, "DP"),
        16 => std.mem.eql(u8, position, "D/ST"),
        17 => std.mem.eql(u8, position, "K"),
        18 => std.mem.eql(u8, position, "P"),
        19 => std.mem.eql(u8, position, "HC"),
        20, 22, 24 => true,
        23 => std.mem.eql(u8, position, "RB") or
            std.mem.eql(u8, position, "WR") or
            std.mem.eql(u8, position, "TE"),
        else => unreachable,
    };
}

fn snapshotRosterSlot(snapshot: *const init_decoder.Snapshot, team_id: i32, player_id: i32) i32 {
    for (snapshot.roster_items.items) |item| {
        if (item.team_id == team_id and item.player_id == player_id) return item.slot_id;
    }
    unreachable;
}

fn lessThanDraftPosition(_: void, left: Team, right: Team) bool {
    return left.draft_position < right.draft_position;
}
