const std = @import("std");
const draft = @import("draft.zig");

const baseline_discount = 4;
const budget_gap_threshold = 10;
const budget_adjustment_step = 5;
const flex_penalty = 2;
const bench_penalty = 4;
const scarce_bench_penalty = 8;

pub const Decision = struct {
    max_bid: i32,
    next_bid: i32,
    price_allowed: bool,
};

pub fn decision(state: *const draft.State, player_id: i32) Decision {
    const max_bid = maxBid(state, player_id);
    const next_bid = if (state.auction.bid_team_id == null and state.auction.bid_amount == 0)
        1
    else
        state.auction.bid_amount + 1;
    return .{
        .max_bid = max_bid,
        .next_bid = next_bid,
        .price_allowed = next_bid <= max_bid,
    };
}

pub fn maxBid(state: *const draft.State, player_id: i32) i32 {
    const player = state.players.get(player_id) orelse return 0;
    if (isPlayerDrafted(state, player_id)) return 0;
    const team_index = state.teamIndexById(state.user_team_id) orelse return 0;
    const team = &state.teams.items[team_index];
    const empty_slots = state.roster_slots.items.len -| team.roster.items.len;
    if (empty_slots == 0 or !hasOpenCompatibleSlot(state, team, player.position, false)) return 0;

    const legal_max = @max(team.remaining_budget - @as(i32, @intCast(empty_slots - 1)), 0);
    if (legal_max == 0) return 0;

    const roster_penalty: i32 = if (hasOpenDirectStarterSlot(state, team, player.position))
        0
    else if (hasOpenCompatibleSlot(state, team, player.position, true))
        flex_penalty
    else if (std.mem.eql(u8, player.position, "QB") or
        std.mem.eql(u8, player.position, "D/ST") or
        std.mem.eql(u8, player.position, "K"))
        scarce_bench_penalty
    else
        bench_penalty;

    const raw_max = player.estimated_price - baseline_discount - roster_penalty + budgetAdjustment(state, team);
    return @min(@max(raw_max, 1), legal_max);
}

pub fn chooseNominee(state: *const draft.State) ?i32 {
    const team_index = state.teamIndexById(state.user_team_id) orelse return null;
    const team = &state.teams.items[team_index];
    var filled_choice: ?i32 = null;
    var fallback_choice: ?i32 = null;

    var players = state.players.iterator();
    while (players.next()) |entry| {
        const player_id = entry.key_ptr.*;
        const player = entry.value_ptr;
        if (isPlayerDrafted(state, player_id) or maxBid(state, player_id) < 1) continue;

        if (betterNominee(state, player_id, fallback_choice)) fallback_choice = player_id;
        if (!hasOpenCompatibleSlot(state, team, player.position, true) and
            betterNominee(state, player_id, filled_choice))
        {
            filled_choice = player_id;
        }
    }

    return filled_choice orelse fallback_choice;
}

pub fn startingRosterComplete(state: *const draft.State) bool {
    const team_index = state.teamIndexById(state.user_team_id) orelse return false;
    const team = &state.teams.items[team_index];
    for (state.roster_slots.items) |slot_id| {
        if (!isBenchSlot(slot_id) and slotHasSpace(state, team, slot_id)) return false;
    }
    return true;
}

fn budgetAdjustment(state: *const draft.State, user_team: *const draft.Team) i32 {
    if (state.teams.items.len <= 1) return 0;

    var other_budgets: i64 = 0;
    for (state.teams.items) |team| {
        if (team.id != user_team.id) other_budgets += team.remaining_budget;
    }
    const average = @divFloor(other_budgets, @as(i64, @intCast(state.teams.items.len - 1)));
    const gap = @as(i64, user_team.remaining_budget) - average;
    if (gap <= budget_gap_threshold) return 0;
    return @intCast(@divFloor(gap - budget_gap_threshold + budget_adjustment_step - 1, budget_adjustment_step));
}

fn hasOpenDirectStarterSlot(
    state: *const draft.State,
    team: *const draft.Team,
    position: []const u8,
) bool {
    for (state.roster_slots.items) |slot_id| {
        if (isBenchSlot(slot_id) or !isDirectSlot(slot_id, position)) continue;
        if (slotHasSpace(state, team, slot_id)) return true;
    }
    return false;
}

fn hasOpenCompatibleSlot(
    state: *const draft.State,
    team: *const draft.Team,
    position: []const u8,
    starters_only: bool,
) bool {
    for (state.roster_slots.items) |slot_id| {
        if (starters_only and isBenchSlot(slot_id)) continue;
        if (!draft.slotAcceptsPosition(slot_id, position)) continue;
        if (slotHasSpace(state, team, slot_id)) return true;
    }
    return false;
}

fn slotHasSpace(state: *const draft.State, team: *const draft.Team, slot_id: i32) bool {
    var capacity: usize = 0;
    for (state.roster_slots.items) |configured_slot| {
        if (configured_slot == slot_id) capacity += 1;
    }

    var occupied: usize = 0;
    for (team.roster.items) |purchase| {
        if (purchase.slot_id == slot_id) occupied += 1;
    }
    return occupied < capacity;
}

fn isDirectSlot(slot_id: i32, position: []const u8) bool {
    return switch (slot_id) {
        0, 1 => std.mem.eql(u8, position, "QB"),
        2 => std.mem.eql(u8, position, "RB"),
        4 => std.mem.eql(u8, position, "WR"),
        6 => std.mem.eql(u8, position, "TE"),
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
        else => false,
    };
}

fn isBenchSlot(slot_id: i32) bool {
    return slot_id == 20 or slot_id == 22 or slot_id == 24;
}

fn isPlayerDrafted(state: *const draft.State, player_id: i32) bool {
    for (state.teams.items) |team| {
        for (team.roster.items) |purchase| {
            if (purchase.player_id == player_id) return true;
        }
    }
    return false;
}

fn betterNominee(state: *const draft.State, candidate_id: i32, current_id: ?i32) bool {
    const current = current_id orelse return true;
    const candidate_value = state.players.get(candidate_id).?.estimated_price;
    const current_value = state.players.get(current).?.estimated_price;
    return candidate_value > current_value or
        (candidate_value == current_value and candidate_id < current);
}
