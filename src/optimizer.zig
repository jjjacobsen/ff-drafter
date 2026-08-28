const std = @import("std");

const bench_slot_ids = [_]i32{ 20, 22, 24 };
const beam_width = 32;
const quality_beam_width = 20;
const difference_beam_width = 8;
const max_plan_slots = 32;
const quality_candidates_per_position = 16;
const inflation_prior = 100;
const protected_difference = 12;
const unassigned_player = std.math.maxInt(i32);

const Candidate = struct {
    id: i32,
    position: []const u8,
    value: i32,
    expected_cost: i32,
    owned: bool,
    nominee: bool,
};

const Plan = struct {
    player_by_slot: [max_plan_slots]i32 = [1]i32{unassigned_player} ** max_plan_slots,
    starter_value: i32 = 0,
    bench_value: i32 = 0,
    future_value: i32 = 0,
    expected_spend: i32 = 0,
};

const PlanResult = struct {
    plan: Plan,
    floor_feasible: bool,
};

const Inflation = struct {
    numerator: i64 = inflation_prior,
    denominator: i64 = inflation_prior,
};

pub fn recommend(allocator: std.mem.Allocator, state: anytype, accepts: *const fn (i32, []const u8) bool) !@TypeOf(state.recommendation) {
    const player_id = state.auction.player_id orelse return .{};
    const player = state.players.get(player_id) orelse return .{};
    const team_index = state.teamIndexById(state.user_team_id) orelse return .{};
    const team = &state.teams.items[team_index];
    const nominated_value = playerValue(player.position, player.estimated_price);

    var drafted = std.AutoHashMap(i32, void).init(allocator);
    defer drafted.deinit();
    for (state.teams.items) |draft_team| {
        for (draft_team.roster.items) |purchase| try drafted.put(purchase.player_id, {});
    }
    if (drafted.contains(player_id)) return .{ .player_id = player_id, .estimated_value = nominated_value };

    const inflation = marketInflation(state);
    const nominated_expected_cost = expectedCost(player.position, nominated_value, inflation);
    const roster_size = state.roster_slots.items.len;
    if (roster_size > max_plan_slots or team.roster.items.len >= roster_size) {
        return .{
            .player_id = player_id,
            .estimated_value = nominated_value,
            .expected_cost = nominated_expected_cost,
        };
    }
    const empty_slots = roster_size - team.roster.items.len;
    const legal_max = @max(team.remaining_budget - @as(i32, @intCast(empty_slots - 1)), 0);
    if (legal_max == 0) return .{
        .player_id = player_id,
        .estimated_value = nominated_value,
        .expected_cost = nominated_expected_cost,
        .legal_max = legal_max,
    };

    var realized_difference: i32 = 0;

    var owned: std.ArrayList(Candidate) = .empty;
    defer owned.deinit(allocator);
    for (team.roster.items) |purchase| {
        const owned_player = state.players.get(purchase.player_id).?;
        const value = playerValue(owned_player.position, owned_player.estimated_price);
        realized_difference += value - purchase.cost;
        try owned.append(allocator, .{
            .id = purchase.player_id,
            .position = owned_player.position,
            .value = value,
            .expected_cost = 0,
            .owned = true,
            .nominee = false,
        });
    }
    std.mem.sort(Candidate, owned.items, {}, candidateIdOrder);

    var future: std.ArrayList(Candidate) = .empty;
    defer future.deinit(allocator);
    var players = state.players.iterator();
    while (players.next()) |entry| {
        if (drafted.contains(entry.key_ptr.*) or entry.key_ptr.* == player_id) continue;
        const candidate = entry.value_ptr;
        const value = playerValue(candidate.position, candidate.estimated_price);
        try future.append(allocator, .{
            .id = entry.key_ptr.*,
            .position = candidate.position,
            .value = value,
            .expected_cost = expectedCost(candidate.position, value, inflation),
            .owned = false,
            .nominee = false,
        });
    }
    std.mem.sort(Candidate, future.items, {}, futureOrder);
    reduceFutureCandidates(&future, roster_size);

    var baseline_candidates: std.ArrayList(Candidate) = .empty;
    defer baseline_candidates.deinit(allocator);
    try baseline_candidates.appendSlice(allocator, owned.items);
    try baseline_candidates.appendSlice(allocator, future.items);
    std.mem.sort(Candidate, baseline_candidates.items, {}, candidateIdOrder);

    const baseline = try solvePlan(
        allocator,
        state.roster_slots.items,
        baseline_candidates.items,
        team.remaining_budget,
        realized_difference,
        true,
        accepts,
    );
    const baseline_reaches_floor = if (baseline) |result|
        plannedDifference(result.plan, realized_difference) >= protected_difference
    else
        false;

    var forced_nominee_cost = @min(nominated_expected_cost, legal_max);
    var forced_candidates: std.ArrayList(Candidate) = .empty;
    defer forced_candidates.deinit(allocator);
    try forced_candidates.appendSlice(allocator, baseline_candidates.items);
    try forced_candidates.append(allocator, .{
        .id = player_id,
        .position = player.position,
        .value = nominated_value,
        .expected_cost = forced_nominee_cost,
        .owned = false,
        .nominee = true,
    });
    std.mem.sort(Candidate, forced_candidates.items, {}, candidateIdOrder);

    var forced_result = try solvePlan(
        allocator,
        state.roster_slots.items,
        forced_candidates.items,
        team.remaining_budget,
        realized_difference,
        baseline_reaches_floor,
        accepts,
    );
    if (forced_nominee_cost != 1 and
        (forced_result == null or (baseline_reaches_floor and !forced_result.?.floor_feasible)))
    {
        forced_nominee_cost = 1;
        for (forced_candidates.items) |*candidate| {
            if (candidate.nominee) candidate.expected_cost = forced_nominee_cost;
        }
        forced_result = try solvePlan(
            allocator,
            state.roster_slots.items,
            forced_candidates.items,
            team.remaining_budget,
            realized_difference,
            baseline_reaches_floor,
            accepts,
        );
    }
    const selected_forced_result = forced_result orelse return .{
        .player_id = player_id,
        .estimated_value = nominated_value,
        .expected_cost = nominated_expected_cost,
        .legal_max = legal_max,
        .starter_value = if (baseline) |result| result.plan.starter_value else 0,
        .bench_value = if (baseline) |result| result.plan.bench_value else 0,
    };
    const forced = selected_forced_result.plan;

    var improves_roster = true;
    var marginal_value = nominated_value;
    var avoided_expected_cost: i32 = 0;
    if (baseline) |baseline_result| {
        const baseline_plan = baseline_result.plan;
        const starter_change = forced.starter_value - baseline_plan.starter_value;
        const bench_change = forced.bench_value - baseline_plan.bench_value;
        improves_roster = starter_change > 0 or (starter_change == 0 and bench_change >= 0);
        marginal_value = if (starter_change > 0)
            starter_change
        else if (starter_change == 0 and bench_change > 0)
            bench_change
        else
            0;
        avoided_expected_cost = @max(
            baseline_plan.expected_spend - (forced.expected_spend - forced_nominee_cost),
            0,
        );
    }

    const nominee_slot = nomineeSlot(forced, player_id, roster_size).?;
    const projected_starter = !isBench(state.roster_slots.items[nominee_slot]);
    const other_expected_spend = forced.expected_spend - forced_nominee_cost;
    const budget_capacity = team.remaining_budget - other_expected_spend;
    const marginal_capacity = avoided_expected_cost + marginal_value;
    const difference_capacity = realized_difference + forced.future_value - other_expected_spend - protected_difference;
    const floor_required = baseline_reaches_floor;

    var max_bid: i32 = 0;
    if (improves_roster and (!floor_required or difference_capacity >= 1)) {
        max_bid = @min(legal_max, @min(budget_capacity, marginal_capacity));
        if (floor_required) max_bid = @min(max_bid, difference_capacity);
        max_bid = @max(max_bid, 0);
        if (std.mem.eql(u8, player.position, "D/ST")) max_bid = @min(max_bid, 1);
    }

    const next_bid = if (state.auction.bid_team_id == null and state.auction.bid_amount == 0)
        1
    else
        state.auction.bid_amount + 1;
    const action: @TypeOf(state.recommendation.action) = if (state.auction.bid_team_id == state.user_team_id)
        .hold
    else if (next_bid <= max_bid)
        .bid
    else
        .pass;

    return .{
        .action = action,
        .player_id = player_id,
        .estimated_value = nominated_value,
        .expected_cost = nominated_expected_cost,
        .marginal_value = marginal_value,
        .max_bid = max_bid,
        .legal_max = legal_max,
        .projected_starter = projected_starter,
        .starter_value = if (baseline) |result| result.plan.starter_value else forced.starter_value,
        .bench_value = if (baseline) |result| result.plan.bench_value else forced.bench_value,
    };
}

fn solvePlan(
    allocator: std.mem.Allocator,
    slots: []const i32,
    candidates: []const Candidate,
    remaining_budget: i32,
    realized_difference: i32,
    protect_difference: bool,
    accepts: *const fn (i32, []const u8) bool,
) !?PlanResult {
    const fallback = (try minimumCostPlan(allocator, slots, candidates, accepts)) orelse return null;
    if (fallback.expected_spend > remaining_budget) return null;

    var current: std.ArrayList(Plan) = .empty;
    defer current.deinit(allocator);
    var next: std.ArrayList(Plan) = .empty;
    defer next.deinit(allocator);
    try current.append(allocator, .{});

    for (candidates) |candidate| {
        if (!candidate.owned and !candidate.nominee) continue;
        next.clearRetainingCapacity();
        for (current.items) |plan| {
            for (slots, 0..) |slot_id, slot_index| {
                if (plan.player_by_slot[slot_index] != unassigned_player) continue;
                if (!accepts(slot_id, candidate.position)) continue;
                var placed = plan;
                placeCandidate(&placed, candidate, slot_id, slot_index);
                try next.append(allocator, placed);
            }
        }
        if (next.items.len == 0) return fallbackResult(fallback, realized_difference);
        try trimPlans(allocator, &next, slots.len);
        std.mem.swap(std.ArrayList(Plan), &current, &next);
    }

    for (slots, 0..) |slot_id, slot_index| {
        next.clearRetainingCapacity();
        for (current.items) |plan| {
            if (plan.player_by_slot[slot_index] != unassigned_player) {
                try next.append(allocator, plan);
                continue;
            }
            for (candidates) |candidate| {
                if (candidate.owned or candidate.nominee) continue;
                if (!accepts(slot_id, candidate.position)) continue;
                if (hasPlayer(plan, candidate.id, slots.len)) continue;
                var placed = plan;
                placeCandidate(&placed, candidate, slot_id, slot_index);
                if (!canFinishWithinBudget(placed, slots.len, remaining_budget)) continue;
                try next.append(allocator, placed);
            }
        }
        if (next.items.len == 0) return fallbackResult(fallback, realized_difference);
        try trimPlans(allocator, &next, slots.len);
        std.mem.swap(std.ArrayList(Plan), &current, &next);
    }

    var floor_feasible = false;
    for (current.items) |plan| {
        if (plannedDifference(plan, realized_difference) >= protected_difference) {
            floor_feasible = true;
            break;
        }
    }

    var best: ?Plan = null;
    for (current.items) |plan| {
        if (plan.expected_spend > remaining_budget) continue;
        if (protect_difference and
            floor_feasible and
            plannedDifference(plan, realized_difference) < protected_difference)
        {
            continue;
        }
        if (best == null or betterCompletePlan(plan, best.?, slots.len, realized_difference)) best = plan;
    }
    if (best) |plan| return .{ .plan = plan, .floor_feasible = floor_feasible };
    return fallbackResult(fallback, realized_difference);
}

fn fallbackResult(plan: Plan, realized_difference: i32) PlanResult {
    return .{
        .plan = plan,
        .floor_feasible = plannedDifference(plan, realized_difference) >= protected_difference,
    };
}

fn minimumCostPlan(
    allocator: std.mem.Allocator,
    slots: []const i32,
    candidates: []const Candidate,
    accepts: *const fn (i32, []const u8) bool,
) !?Plan {
    if (candidates.len < slots.len) return null;

    var mandatory_count: usize = 0;
    var max_expected_cost: i64 = 1;
    for (candidates) |candidate| {
        if (candidate.owned or candidate.nominee) mandatory_count += 1;
        max_expected_cost = @max(max_expected_cost, candidate.expected_cost);
    }
    if (mandatory_count > slots.len) return null;

    const spend_bound = max_expected_cost * @as(i64, @intCast(slots.len));
    const mandatory_bonus = spend_bound + 1;
    const impossible_cost = mandatory_bonus * @as(i64, @intCast(mandatory_count + 1)) + spend_bound + 1;
    const row_count = slots.len;
    const column_count = candidates.len;

    var u = try allocator.alloc(i64, row_count + 1);
    defer allocator.free(u);
    @memset(u, 0);
    var v = try allocator.alloc(i64, column_count + 1);
    defer allocator.free(v);
    @memset(v, 0);
    var matched_row = try allocator.alloc(usize, column_count + 1);
    defer allocator.free(matched_row);
    @memset(matched_row, 0);
    var previous_column = try allocator.alloc(usize, column_count + 1);
    defer allocator.free(previous_column);
    var minimum = try allocator.alloc(i64, column_count + 1);
    defer allocator.free(minimum);
    var used = try allocator.alloc(bool, column_count + 1);
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
                const candidate = candidates[candidate_column - 1];
                const mandatory = candidate.owned or candidate.nominee;
                const cost = if (accepts(slots[current_row - 1], candidate.position))
                    @as(i64, candidate.expected_cost) - (if (mandatory) mandatory_bonus else 0)
                else
                    impossible_cost;
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

    var candidate_by_slot: [max_plan_slots]usize = undefined;
    for (1..column_count + 1) |column| {
        if (matched_row[column] != 0) candidate_by_slot[matched_row[column] - 1] = column - 1;
    }

    var selected_mandatory: usize = 0;
    var plan: Plan = .{};
    for (candidate_by_slot[0..row_count], 0..) |candidate_index, slot_index| {
        const candidate = candidates[candidate_index];
        if (!accepts(slots[slot_index], candidate.position)) return null;
        if (candidate.owned or candidate.nominee) selected_mandatory += 1;
        placeCandidate(&plan, candidate, slots[slot_index], slot_index);
    }
    if (selected_mandatory != mandatory_count) return null;
    return plan;
}

fn placeCandidate(plan: *Plan, candidate: Candidate, slot_id: i32, slot_index: usize) void {
    plan.player_by_slot[slot_index] = candidate.id;
    if (isBench(slot_id)) {
        plan.bench_value += candidate.value;
    } else {
        plan.starter_value += candidate.value;
    }
    if (candidate.owned) return;
    plan.future_value += candidate.value;
    plan.expected_spend += candidate.expected_cost;
}

fn canFinishWithinBudget(plan: Plan, slot_count: usize, remaining_budget: i32) bool {
    var unfilled: i32 = 0;
    for (plan.player_by_slot[0..slot_count]) |player_id| {
        if (player_id == unassigned_player) unfilled += 1;
    }
    return plan.expected_spend + unfilled <= remaining_budget;
}

fn hasPlayer(plan: Plan, player_id: i32, slot_count: usize) bool {
    return std.mem.indexOfScalar(i32, plan.player_by_slot[0..slot_count], player_id) != null;
}

fn nomineeSlot(plan: Plan, player_id: i32, slot_count: usize) ?usize {
    return std.mem.indexOfScalar(i32, plan.player_by_slot[0..slot_count], player_id);
}

fn trimPlans(allocator: std.mem.Allocator, plans: *std.ArrayList(Plan), slot_count: usize) !void {
    if (plans.items.len <= beam_width) return;

    var selected: std.ArrayList(Plan) = .empty;
    defer selected.deinit(allocator);

    std.mem.sort(Plan, plans.items, slot_count, qualityPartialOrder);
    for (plans.items[0..@min(quality_beam_width, plans.items.len)]) |plan| {
        try selected.append(allocator, plan);
    }

    std.mem.sort(Plan, plans.items, slot_count, differencePartialOrder);
    for (plans.items) |plan| {
        if (selected.items.len >= quality_beam_width + difference_beam_width) break;
        if (!containsPlan(selected.items, plan, slot_count)) try selected.append(allocator, plan);
    }

    std.mem.sort(Plan, plans.items, slot_count, cheapPartialOrder);
    for (plans.items) |plan| {
        if (selected.items.len == beam_width) break;
        if (!containsPlan(selected.items, plan, slot_count)) try selected.append(allocator, plan);
    }

    if (selected.items.len < beam_width) {
        std.mem.sort(Plan, plans.items, slot_count, qualityPartialOrder);
        for (plans.items) |plan| {
            if (selected.items.len == beam_width) break;
            if (!containsPlan(selected.items, plan, slot_count)) try selected.append(allocator, plan);
        }
    }

    plans.clearRetainingCapacity();
    try plans.appendSlice(allocator, selected.items);
}

fn containsPlan(plans: []const Plan, candidate: Plan, slot_count: usize) bool {
    for (plans) |plan| {
        if (std.mem.eql(i32, plan.player_by_slot[0..slot_count], candidate.player_by_slot[0..slot_count])) return true;
    }
    return false;
}

fn qualityPartialOrder(slot_count: usize, left: Plan, right: Plan) bool {
    if (left.starter_value != right.starter_value) return left.starter_value > right.starter_value;
    if (left.bench_value != right.bench_value) return left.bench_value > right.bench_value;
    const left_difference = left.future_value - left.expected_spend;
    const right_difference = right.future_value - right.expected_spend;
    if (left_difference != right_difference) return left_difference > right_difference;
    if (left.expected_spend != right.expected_spend) return left.expected_spend < right.expected_spend;
    return deterministicPlanOrder(left, right, slot_count);
}

fn differencePartialOrder(slot_count: usize, left: Plan, right: Plan) bool {
    const left_difference = left.future_value - left.expected_spend;
    const right_difference = right.future_value - right.expected_spend;
    if (left_difference != right_difference) return left_difference > right_difference;
    if (left.starter_value != right.starter_value) return left.starter_value > right.starter_value;
    if (left.bench_value != right.bench_value) return left.bench_value > right.bench_value;
    if (left.expected_spend != right.expected_spend) return left.expected_spend < right.expected_spend;
    return deterministicPlanOrder(left, right, slot_count);
}

fn cheapPartialOrder(slot_count: usize, left: Plan, right: Plan) bool {
    if (left.expected_spend != right.expected_spend) return left.expected_spend < right.expected_spend;
    if (left.starter_value != right.starter_value) return left.starter_value > right.starter_value;
    if (left.bench_value != right.bench_value) return left.bench_value > right.bench_value;
    return deterministicPlanOrder(left, right, slot_count);
}

fn betterCompletePlan(left: Plan, right: Plan, slot_count: usize, realized_difference: i32) bool {
    if (left.starter_value != right.starter_value) return left.starter_value > right.starter_value;
    if (left.bench_value != right.bench_value) return left.bench_value > right.bench_value;
    const left_difference = plannedDifference(left, realized_difference);
    const right_difference = plannedDifference(right, realized_difference);
    if (left_difference != right_difference) return left_difference > right_difference;
    if (left.expected_spend != right.expected_spend) return left.expected_spend < right.expected_spend;
    return deterministicPlanOrder(left, right, slot_count);
}

fn deterministicPlanOrder(left: Plan, right: Plan, slot_count: usize) bool {
    for (left.player_by_slot[0..slot_count], right.player_by_slot[0..slot_count]) |left_id, right_id| {
        if (left_id != right_id) return left_id < right_id;
    }
    return false;
}

fn plannedDifference(plan: Plan, realized_difference: i32) i32 {
    return realized_difference + plan.future_value - plan.expected_spend;
}

fn marketInflation(state: anytype) Inflation {
    var inflation: Inflation = .{};
    for (state.teams.items) |team| {
        for (team.roster.items) |purchase| {
            const player = state.players.get(purchase.player_id).?;
            const value = playerValue(player.position, player.estimated_price);
            inflation.numerator += @max(purchase.cost - 1, 0);
            inflation.denominator += @max(value - 1, 0);
        }
    }
    return inflation;
}

fn expectedCost(position: []const u8, value: i32, inflation: Inflation) i32 {
    if (std.mem.eql(u8, position, "D/ST")) return 1;
    const discretionary_value: i64 = @max(value - 1, 0);
    const adjusted = @divFloor(
        discretionary_value * inflation.numerator + @divFloor(inflation.denominator, 2),
        inflation.denominator,
    );
    return 1 + @as(i32, @intCast(adjusted));
}

fn reduceFutureCandidates(candidates: *std.ArrayList(Candidate), roster_size: usize) void {
    var group_start: usize = 0;
    var write_index: usize = 0;
    while (group_start < candidates.items.len) {
        var group_end = group_start + 1;
        while (group_end < candidates.items.len and
            std.mem.eql(u8, candidates.items[group_start].position, candidates.items[group_end].position))
        {
            group_end += 1;
        }

        const group_len = group_end - group_start;
        const quality_count = @min(quality_candidates_per_position, group_len);
        for (candidates.items[group_start .. group_start + quality_count]) |candidate| {
            candidates.items[write_index] = candidate;
            write_index += 1;
        }

        const cheap_start = @max(group_start + quality_count, group_end -| roster_size);
        for (candidates.items[cheap_start..group_end]) |candidate| {
            candidates.items[write_index] = candidate;
            write_index += 1;
        }
        group_start = group_end;
    }
    candidates.items.len = write_index;
}

fn playerValue(position: []const u8, estimated_price: i32) i32 {
    if (std.mem.eql(u8, position, "D/ST")) return 1;
    return estimated_price;
}

fn isBench(slot_id: i32) bool {
    return std.mem.indexOfScalar(i32, &bench_slot_ids, slot_id) != null;
}

fn candidateIdOrder(_: void, left: Candidate, right: Candidate) bool {
    return left.id < right.id;
}

fn futureOrder(_: void, left: Candidate, right: Candidate) bool {
    const position_order = std.mem.order(u8, left.position, right.position);
    if (position_order != .eq) return position_order == .lt;
    if (left.value != right.value) return left.value > right.value;
    return left.id < right.id;
}
