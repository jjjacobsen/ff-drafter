const std = @import("std");
const draft = @import("draft.zig");

const budget_gap_threshold = 20;
const budget_adjustment_step = 10;
const flex_penalty = 2;
const pre_running_back_wr_penalty = 5;
const priority_quality_goal = 20;
const priority_quality_fallback = 18;
const priority_quality_overpay = 3;
const impossible_cost: i64 = 1_000_000_000_000;

pub const Decision = struct {
    max_bid: i32,
    next_bid: i32,
    price_allowed: bool,
};

pub const Nomination = struct {
    player_id: i32,
    amount: i32,
};

const Candidate = struct {
    id: i32,
    position: []const u8,
    value: i32,
};

const CorePlan = struct {
    allocator: std.mem.Allocator,
    player_ids: []i32,
    open_slots: usize,
    target_per_slot: i32,
    late_stage: bool,

    fn deinit(self: *const CorePlan) void {
        self.allocator.free(self.player_ids);
    }

    fn contains(self: *const CorePlan, player_id: i32) bool {
        return std.mem.indexOfScalar(i32, self.player_ids, player_id) != null;
    }
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
    const normal_max = normalMaxBid(state, team, &player);
    if (normal_max == 0) return normal_max;

    const plan = buildCorePlan(state, team) catch unreachable;
    defer plan.deinit();
    return forcedMaxBid(state, team, player_id, &player, normal_max, &plan);
}

pub fn chooseNomination(state: *const draft.State) ?Nomination {
    const team_index = state.teamIndexById(state.user_team_id) orelse return null;
    const team = &state.teams.items[team_index];
    const plan = buildCorePlan(state, team) catch unreachable;
    defer plan.deinit();

    const pressure_player_id = bestPressurePlayer(state, team, &plan);
    if (plan.player_ids.len > 0 and (plan.open_slots == 1 or pressure_player_id != null)) {
        const player_id = if (plan.open_slots == 1)
            bestPlannedPlayer(state, &plan)
        else
            pressure_player_id.?;
        const player = state.players.get(player_id).?;
        const maximum = forcedMaxBid(
            state,
            team,
            player_id,
            &player,
            normalMaxBid(state, team, &player),
            &plan,
        );
        const amount = if (plan.open_slots == 1)
            @max(@min(plan.target_per_slot, maximum), 1)
        else
            1;
        return .{ .player_id = player_id, .amount = amount };
    }

    var filled_choice: ?i32 = null;
    var fallback_choice: ?i32 = null;
    var players = state.players.iterator();
    while (players.next()) |entry| {
        const player_id = entry.key_ptr.*;
        const player = entry.value_ptr;
        if (isPlayerDrafted(state, player_id) or
            !hasOpenCompatibleSlot(state, team, player.position, false))
        {
            continue;
        }

        if (betterNominee(state, player_id, fallback_choice)) fallback_choice = player_id;
        if (!hasOpenCompatibleSlot(state, team, player.position, true) and
            betterNominee(state, player_id, filled_choice))
        {
            filled_choice = player_id;
        }
    }

    const player_id = filled_choice orelse fallback_choice orelse return null;
    return .{ .player_id = player_id, .amount = 1 };
}

pub fn priorityRosterComplete(state: *const draft.State) bool {
    const team_index = state.teamIndexById(state.user_team_id) orelse return false;
    const team = &state.teams.items[team_index];
    for (state.roster_slots.items, 0..) |slot_id, index| {
        if (isCoreSlot(slot_id) and rosterSlotOccurrenceOpen(state, team, index)) return false;
    }
    return true;
}

fn normalMaxBid(state: *const draft.State, team: *const draft.Team, player: *const draft.Player) i32 {
    const legal_max = legalMax(state, team);
    if (legal_max == 0 or !hasOpenCompatibleSlot(state, team, player.position, false)) return 0;
    if (std.mem.eql(u8, player.position, "D/ST") or std.mem.eql(u8, player.position, "K"))
        return @min(legal_max, 1);
    if (!hasOpenCompatibleSlot(state, team, player.position, true)) return @min(legal_max, 1);

    const raw_max = adjustedEspnValue(state, team, player.estimated_price) -
        rosterPenalty(state, team, player.position);
    return @min(@max(raw_max, 1), legal_max);
}

fn forcedMaxBid(
    state: *const draft.State,
    team: *const draft.Team,
    player_id: i32,
    player: *const draft.Player,
    normal_max: i32,
    plan: *const CorePlan,
) i32 {
    if (!plan.contains(player_id)) return normal_max;

    const cap = if (plan.late_stage)
        plan.target_per_slot
    else cap: {
        const slot_cap = switch (plan.open_slots) {
            0 => 0,
            1 => plan.target_per_slot,
            2 => player.estimated_price + 5,
            3 => player.estimated_price + 2,
            else => player.estimated_price,
        };
        const quality_cap = if (isQualityPressurePlayer(player))
            player.estimated_price + priority_quality_overpay
        else
            0;
        break :cap @max(slot_cap, quality_cap);
    };
    const penalty = if (plan.late_stage) 0 else rosterPenalty(state, team, player.position);
    const planned_value = if (plan.late_stage)
        @max(plan.target_per_slot, adjustedEspnValue(state, team, player.estimated_price))
    else
        @min(plan.target_per_slot, cap);
    const forced_value = planned_value - penalty;
    return @max(normal_max, @min(@max(forced_value, 1), legalMax(state, team)));
}

fn bestPressurePlayer(
    state: *const draft.State,
    team: *const draft.Team,
    plan: *const CorePlan,
) ?i32 {
    var best_id: ?i32 = null;
    for (plan.player_ids) |player_id| {
        const player = state.players.get(player_id).?;
        const normal_max = normalMaxBid(state, team, &player);
        if (forcedMaxBid(state, team, player_id, &player, normal_max, plan) <= normal_max) continue;
        if (betterNominee(state, player_id, best_id)) best_id = player_id;
    }
    return best_id;
}

fn isQualityPressurePlayer(player: *const draft.Player) bool {
    return !std.mem.eql(u8, player.position, "QB") and
        player.estimated_price >= priority_quality_fallback and
        player.estimated_price <= priority_quality_goal;
}

fn buildCorePlan(state: *const draft.State, team: *const draft.Team) !CorePlan {
    const allocator = state.allocator;
    var priority_slots: std.ArrayList(i32) = .empty;
    defer priority_slots.deinit(allocator);
    var remaining_slots: std.ArrayList(i32) = .empty;
    defer remaining_slots.deinit(allocator);

    for (state.roster_slots.items, 0..) |slot_id, index| {
        if (!rosterSlotOccurrenceOpen(state, team, index)) continue;
        try remaining_slots.append(allocator, slot_id);
        if (isCoreSlot(slot_id)) try priority_slots.append(allocator, slot_id);
    }

    const late_stage = priority_slots.items.len == 0;
    const planning_slots = if (late_stage) remaining_slots.items else priority_slots.items;
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    var players = state.players.iterator();
    while (players.next()) |entry| {
        if (isPlayerDrafted(state, entry.key_ptr.*) or
            (!late_stage and !isCorePosition(entry.value_ptr.position)) or
            !fitsAnySlot(planning_slots, entry.value_ptr.position))
        {
            continue;
        }
        try candidates.append(allocator, .{
            .id = entry.key_ptr.*,
            .position = entry.value_ptr.position,
            .value = entry.value_ptr.estimated_price,
        });
    }
    std.mem.sort(Candidate, candidates.items, {}, candidateIdOrder);

    const assignment = try maximumValueAssignment(allocator, planning_slots, candidates.items);
    defer allocator.free(assignment);
    var player_ids: std.ArrayList(i32) = .empty;
    errdefer player_ids.deinit(allocator);
    for (assignment) |candidate_index| {
        if (candidate_index < candidates.items.len)
            try player_ids.append(allocator, candidates.items[candidate_index].id);
    }

    const reserved_budget: i32 = if (late_stage)
        0
    else
        @intCast(remaining_slots.items.len - priority_slots.items.len);
    const target_per_slot = if (planning_slots.len == 0)
        0
    else
        @divFloor(
            @max(team.remaining_budget - reserved_budget, 0),
            @as(i32, @intCast(planning_slots.len)),
        );
    return .{
        .allocator = allocator,
        .player_ids = try player_ids.toOwnedSlice(allocator),
        .open_slots = planning_slots.len,
        .target_per_slot = target_per_slot,
        .late_stage = late_stage,
    };
}

fn maximumValueAssignment(
    allocator: std.mem.Allocator,
    slots: []const i32,
    candidates: []const Candidate,
) ![]usize {
    const row_count = slots.len;
    const column_count = candidates.len + row_count;
    const result = try allocator.alloc(usize, row_count);
    errdefer allocator.free(result);
    if (row_count == 0) return result;

    const u = try allocator.alloc(i64, row_count + 1);
    defer allocator.free(u);
    @memset(u, 0);
    const v = try allocator.alloc(i64, column_count + 1);
    defer allocator.free(v);
    @memset(v, 0);
    const matched_row = try allocator.alloc(usize, column_count + 1);
    defer allocator.free(matched_row);
    @memset(matched_row, 0);
    const previous_column = try allocator.alloc(usize, column_count + 1);
    defer allocator.free(previous_column);
    const minimum = try allocator.alloc(i64, column_count + 1);
    defer allocator.free(minimum);
    const used = try allocator.alloc(bool, column_count + 1);
    defer allocator.free(used);

    for (1..row_count + 1) |row| {
        matched_row[0] = row;
        @memset(minimum, std.math.maxInt(i64));
        @memset(used, false);
        var column: usize = 0;

        while (true) {
            used[column] = true;
            const current_row = matched_row[column];
            var delta: i64 = std.math.maxInt(i64);
            var next_column: usize = 0;

            for (1..column_count + 1) |candidate_column| {
                if (used[candidate_column]) continue;
                const candidate_index = candidate_column - 1;
                const cost = if (candidate_index >= candidates.len)
                    @as(i64, 0)
                else if (!draft.slotAcceptsPosition(
                    slots[current_row - 1],
                    candidates[candidate_index].position,
                ))
                    impossible_cost
                else
                    -@as(i64, candidates[candidate_index].value);
                const reduced_cost = cost - u[current_row] - v[candidate_column];
                if (reduced_cost < minimum[candidate_column]) {
                    minimum[candidate_column] = reduced_cost;
                    previous_column[candidate_column] = column;
                }
                if (minimum[candidate_column] < delta) {
                    delta = minimum[candidate_column];
                    next_column = candidate_column;
                }
            }

            for (0..column_count + 1) |candidate_column| {
                if (used[candidate_column]) {
                    u[matched_row[candidate_column]] += delta;
                    v[candidate_column] -= delta;
                } else {
                    minimum[candidate_column] -= delta;
                }
            }
            column = next_column;
            if (matched_row[column] == 0) break;
        }

        while (true) {
            const prior = previous_column[column];
            matched_row[column] = matched_row[prior];
            column = prior;
            if (column == 0) break;
        }
    }

    for (1..column_count + 1) |column| {
        if (matched_row[column] != 0) result[matched_row[column] - 1] = column - 1;
    }
    return result;
}

fn bestPlannedPlayer(state: *const draft.State, plan: *const CorePlan) i32 {
    var best_id: ?i32 = null;
    for (plan.player_ids) |player_id| {
        if (betterNominee(state, player_id, best_id)) best_id = player_id;
    }
    return best_id.?;
}

fn candidateIdOrder(_: void, left: Candidate, right: Candidate) bool {
    return left.id < right.id;
}

fn adjustedEspnValue(state: *const draft.State, user_team: *const draft.Team, espn_value: i32) i32 {
    if (state.teams.items.len <= 1)
        return espn_value - @as(i32, @intCast(playerValueDiscount(espn_value)));

    var other_budgets: i64 = 0;
    for (state.teams.items) |team| {
        if (team.id != user_team.id) other_budgets += team.remaining_budget;
    }
    const average = @divFloor(other_budgets, @as(i64, @intCast(state.teams.items.len - 1)));
    const gap = @as(i64, user_team.remaining_budget) - average;
    const baseline_discount = @min(phaseDiscount(average), playerValueDiscount(espn_value));
    const catch_up = if (gap > budget_gap_threshold)
        @divFloor(gap - budget_gap_threshold, budget_adjustment_step)
    else
        0;
    const capped_value = @min(
        @as(i64, espn_value) - baseline_discount + catch_up,
        espn_value,
    );
    const above_espn = @divFloor(
        @max(@as(i64, user_team.remaining_budget) - 2 * average, 0),
        budget_adjustment_step,
    );
    return @intCast(capped_value + above_espn);
}

fn phaseDiscount(average_budget: i64) i64 {
    if (average_budget >= 101) return 4;
    if (average_budget >= 76) return 3;
    if (average_budget >= 51) return 2;
    if (average_budget >= 26) return 1;
    return 0;
}

fn playerValueDiscount(espn_value: i32) i64 {
    if (espn_value >= 36) return 4;
    if (espn_value >= 21) return 3;
    if (espn_value >= 11) return 2;
    if (espn_value >= 6) return 1;
    return 0;
}

fn legalMax(state: *const draft.State, team: *const draft.Team) i32 {
    const empty_slots = state.roster_slots.items.len -| team.roster.items.len;
    if (empty_slots == 0) return 0;
    return @max(team.remaining_budget - @as(i32, @intCast(empty_slots - 1)), 0);
}

fn rosterPenalty(state: *const draft.State, team: *const draft.Team, position: []const u8) i32 {
    const slot_penalty: i32 = if (hasOpenDirectStarterSlot(state, team, position)) 0 else flex_penalty;
    const first_running_back_penalty: i32 = if (std.mem.eql(u8, position, "WR") and
        !teamHasPosition(state, team, "RB"))
        pre_running_back_wr_penalty
    else
        0;
    return slot_penalty + first_running_back_penalty;
}

fn teamHasPosition(
    state: *const draft.State,
    team: *const draft.Team,
    position: []const u8,
) bool {
    for (team.roster.items) |purchase| {
        if (std.mem.eql(u8, state.players.get(purchase.player_id).?.position, position)) return true;
    }
    return false;
}

fn hasOpenDirectStarterSlot(
    state: *const draft.State,
    team: *const draft.Team,
    position: []const u8,
) bool {
    for (state.roster_slots.items, 0..) |slot_id, index| {
        if (isBenchSlot(slot_id) or !isDirectSlot(slot_id, position)) continue;
        if (rosterSlotOccurrenceOpen(state, team, index)) return true;
    }
    return false;
}

fn hasOpenCompatibleSlot(
    state: *const draft.State,
    team: *const draft.Team,
    position: []const u8,
    starters_only: bool,
) bool {
    for (state.roster_slots.items, 0..) |slot_id, index| {
        if (starters_only and isBenchSlot(slot_id)) continue;
        if (!draft.slotAcceptsPosition(slot_id, position)) continue;
        if (rosterSlotOccurrenceOpen(state, team, index)) return true;
    }
    return false;
}

fn rosterSlotOccurrenceOpen(state: *const draft.State, team: *const draft.Team, index: usize) bool {
    const slot_id = state.roster_slots.items[index];
    var occurrence: usize = 0;
    for (state.roster_slots.items[0..index]) |previous_slot| {
        if (previous_slot == slot_id) occurrence += 1;
    }

    var occupied: usize = 0;
    for (team.roster.items) |purchase| {
        if (purchase.slot_id == slot_id) occupied += 1;
    }
    return occupied <= occurrence;
}

fn fitsAnySlot(slots: []const i32, position: []const u8) bool {
    for (slots) |slot_id| {
        if (draft.slotAcceptsPosition(slot_id, position)) return true;
    }
    return false;
}

fn isCorePosition(position: []const u8) bool {
    return std.mem.eql(u8, position, "QB") or
        std.mem.eql(u8, position, "RB") or
        std.mem.eql(u8, position, "WR") or
        std.mem.eql(u8, position, "TE");
}

fn isCoreSlot(slot_id: i32) bool {
    return slot_id == 0 or slot_id == 2 or slot_id == 3 or
        slot_id == 4 or slot_id == 5 or slot_id == 6 or slot_id == 23;
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
