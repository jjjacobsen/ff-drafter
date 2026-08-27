const std = @import("std");

const bench_slot_ids = [_]i32{ 20, 22, 24 };

const Candidate = struct {
    id: i32,
    position: []const u8,
    value: i32,
    mandatory: bool,
    owned: bool,
    nominee: bool,
};

const Assignment = struct {
    player_by_slot: []usize,
    weighted_score: i64,
    starter_value: i64,
    bench_value: i64,
    nominee_slot: ?usize,

    fn deinit(self: Assignment, allocator: std.mem.Allocator) void {
        allocator.free(self.player_by_slot);
    }
};

const Allocation = struct {
    candidate_id: i32,
    slot_index: usize,
    amount: i32 = 1,
    weight: i64,
    remainder: i64 = 0,
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

    const roster_size = state.roster_slots.items.len;
    if (team.roster.items.len >= roster_size) return .{ .player_id = player_id, .estimated_value = nominated_value };
    const empty_slots = roster_size - team.roster.items.len;
    const legal_max = @max(team.remaining_budget - @as(i32, @intCast(empty_slots - 1)), 0);
    if (legal_max == 0) return .{
        .player_id = player_id,
        .estimated_value = nominated_value,
        .legal_max = legal_max,
    };

    var owned: std.ArrayList(Candidate) = .empty;
    defer owned.deinit(allocator);
    for (team.roster.items) |purchase| {
        const owned_player = state.players.get(purchase.player_id).?;
        try owned.append(allocator, .{
            .id = purchase.player_id,
            .position = owned_player.position,
            .value = playerValue(owned_player.position, owned_player.estimated_price),
            .mandatory = true,
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
        try future.append(allocator, .{
            .id = entry.key_ptr.*,
            .position = candidate.position,
            .value = playerValue(candidate.position, candidate.estimated_price),
            .mandatory = false,
            .owned = false,
            .nominee = false,
        });
    }
    std.mem.sort(Candidate, future.items, {}, futureOrder);
    reduceFutureCandidates(&future, roster_size);

    var without_candidates: std.ArrayList(Candidate) = .empty;
    defer without_candidates.deinit(allocator);
    try without_candidates.appendSlice(allocator, owned.items);
    try without_candidates.appendSlice(allocator, future.items);
    std.mem.sort(Candidate, without_candidates.items, {}, candidateIdOrder);

    const without = (try solveAssignment(
        allocator,
        state.roster_slots.items,
        without_candidates.items,
        accepts,
    )) orelse return .{
        .player_id = player_id,
        .estimated_value = nominated_value,
        .legal_max = legal_max,
    };
    defer without.deinit(allocator);

    var forced_candidates: std.ArrayList(Candidate) = .empty;
    defer forced_candidates.deinit(allocator);
    try forced_candidates.appendSlice(allocator, without_candidates.items);
    try forced_candidates.append(allocator, .{
        .id = player_id,
        .position = player.position,
        .value = nominated_value,
        .mandatory = true,
        .owned = false,
        .nominee = true,
    });
    std.mem.sort(Candidate, forced_candidates.items, {}, candidateIdOrder);

    const forced = (try solveAssignment(
        allocator,
        state.roster_slots.items,
        forced_candidates.items,
        accepts,
    )) orelse return .{
        .player_id = player_id,
        .estimated_value = nominated_value,
        .legal_max = legal_max,
        .starter_value = @intCast(without.starter_value),
        .bench_value = @intCast(without.bench_value),
    };
    defer forced.deinit(allocator);

    const nominee_slot = forced.nominee_slot.?;
    const projected_starter = !isBench(state.roster_slots.items[nominee_slot]);
    const nominee_weight: i64 = if (projected_starter) 4 else 1;
    const score_difference = forced.weighted_score - without.weighted_score;
    const marginal_value: i32 = if (score_difference > 0)
        @intCast(@divFloor(score_difference, nominee_weight))
    else
        0;
    const replacement_value = @max(nominated_value - marginal_value, 0);

    var max_bid: i32 = 0;
    if (score_difference >= 0) {
        max_bid = try nomineeAllocation(
            allocator,
            forced,
            forced_candidates.items,
            state.roster_slots.items,
            team.remaining_budget,
            empty_slots,
        );
        max_bid = @min(max_bid, legal_max);
        if (std.mem.eql(u8, player.position, "D/ST")) max_bid = @min(max_bid, 1);
    }

    const target_bid = @min(@max(nominated_value, 1), max_bid);
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
        .replacement_value = replacement_value,
        .marginal_value = marginal_value,
        .target_bid = target_bid,
        .max_bid = max_bid,
        .legal_max = legal_max,
        .projected_starter = projected_starter,
        .starter_value = @intCast(without.starter_value),
        .bench_value = @intCast(without.bench_value),
    };
}

fn solveAssignment(
    allocator: std.mem.Allocator,
    slots: []const i32,
    candidates: []const Candidate,
    accepts: *const fn (i32, []const u8) bool,
) !?Assignment {
    if (candidates.len < slots.len) return null;

    var max_absolute_value: i64 = 1;
    for (candidates) |candidate| {
        const value: i64 = candidate.value;
        max_absolute_value = @max(max_absolute_value, if (value < 0) -value else value);
    }
    const utility_bound = max_absolute_value * 4 * @as(i64, @intCast(slots.len));
    const mandatory_bonus = utility_bound * 2 + 1;
    const impossible_cost = mandatory_bonus * @as(i64, @intCast(slots.len + 1)) + utility_bound * 2 + 1;

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
                const cost = if (accepts(slots[current_row - 1], candidate.position))
                    -(slotWeight(slots[current_row - 1]) * @as(i64, candidate.value) +
                        (if (candidate.mandatory) mandatory_bonus else 0))
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

    const player_by_slot = try allocator.alloc(usize, row_count);
    errdefer allocator.free(player_by_slot);
    for (1..column_count + 1) |column| {
        if (matched_row[column] != 0) player_by_slot[matched_row[column] - 1] = column - 1;
    }

    var mandatory_selected: usize = 0;
    var mandatory_count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.mandatory) mandatory_count += 1;
    }

    var weighted_score: i64 = 0;
    var starter_value: i64 = 0;
    var bench_value: i64 = 0;
    var nominee_slot: ?usize = null;
    for (player_by_slot, 0..) |candidate_index, slot_index| {
        const candidate = candidates[candidate_index];
        if (!accepts(slots[slot_index], candidate.position)) {
            allocator.free(player_by_slot);
            return null;
        }
        if (candidate.mandatory) mandatory_selected += 1;
        if (candidate.nominee) nominee_slot = slot_index;
        weighted_score += slotWeight(slots[slot_index]) * @as(i64, candidate.value);
        if (isBench(slots[slot_index])) {
            bench_value += candidate.value;
        } else {
            starter_value += candidate.value;
        }
    }
    if (mandatory_selected != mandatory_count) {
        allocator.free(player_by_slot);
        return null;
    }

    return .{
        .player_by_slot = player_by_slot,
        .weighted_score = weighted_score,
        .starter_value = starter_value,
        .bench_value = bench_value,
        .nominee_slot = nominee_slot,
    };
}

fn nomineeAllocation(
    allocator: std.mem.Allocator,
    assignment: Assignment,
    candidates: []const Candidate,
    slots: []const i32,
    remaining_budget: i32,
    empty_slots: usize,
) !i32 {
    var allocations: std.ArrayList(Allocation) = .empty;
    defer allocations.deinit(allocator);

    for (assignment.player_by_slot, 0..) |candidate_index, slot_index| {
        const candidate = candidates[candidate_index];
        if (candidate.owned) continue;
        const weight = if (std.mem.eql(u8, candidate.position, "D/ST"))
            0
        else
            slotWeight(slots[slot_index]) * @as(i64, @max(candidate.value - 1, 0));
        try allocations.append(allocator, .{
            .candidate_id = candidate.id,
            .slot_index = slot_index,
            .weight = weight,
        });
    }

    const discretionary: i64 = @max(
        @as(i64, remaining_budget) - @as(i64, @intCast(empty_slots)),
        0,
    );
    var total_weight: i64 = 0;
    for (allocations.items) |allocation| total_weight += allocation.weight;

    if (total_weight > 0) {
        var distributed: i64 = 0;
        for (allocations.items) |*allocation| {
            if (allocation.weight == 0) continue;
            const numerator = discretionary * allocation.weight;
            const share = @divFloor(numerator, total_weight);
            allocation.amount += @intCast(share);
            allocation.remainder = @mod(numerator, total_weight);
            distributed += share;
        }
        var dollars_left = discretionary - distributed;
        while (dollars_left > 0) : (dollars_left -= 1) {
            var best: ?usize = null;
            for (allocations.items, 0..) |allocation, index| {
                if (allocation.weight == 0 or allocation.remainder < 0) continue;
                if (best == null or allocationRemainderOrder(allocation, allocations.items[best.?])) best = index;
            }
            allocations.items[best.?].amount += 1;
            allocations.items[best.?].remainder = -1;
        }
    } else {
        var eligible_count: usize = 0;
        for (allocations.items) |allocation| {
            const candidate = candidates[assignment.player_by_slot[allocation.slot_index]];
            if (!std.mem.eql(u8, candidate.position, "D/ST")) eligible_count += 1;
        }
        if (eligible_count != 0) {
            std.mem.sort(Allocation, allocations.items, {}, allocationIdOrder);
            const share = @divFloor(discretionary, @as(i64, @intCast(eligible_count)));
            var dollars_left = @mod(discretionary, @as(i64, @intCast(eligible_count)));
            for (allocations.items) |*allocation| {
                const candidate = candidates[assignment.player_by_slot[allocation.slot_index]];
                if (std.mem.eql(u8, candidate.position, "D/ST")) continue;
                allocation.amount += @intCast(share);
                if (dollars_left > 0) {
                    allocation.amount += 1;
                    dollars_left -= 1;
                }
            }
        }
    }

    for (allocations.items) |allocation| {
        const candidate = candidates[assignment.player_by_slot[allocation.slot_index]];
        if (candidate.nominee) return allocation.amount;
    }
    unreachable;
}

fn reduceFutureCandidates(candidates: *std.ArrayList(Candidate), limit: usize) void {
    var write_index: usize = 0;
    var position_count: usize = 0;
    var previous_position: ?[]const u8 = null;
    for (candidates.items) |candidate| {
        if (previous_position == null or !std.mem.eql(u8, previous_position.?, candidate.position)) {
            previous_position = candidate.position;
            position_count = 0;
        }
        if (position_count == limit) continue;
        candidates.items[write_index] = candidate;
        write_index += 1;
        position_count += 1;
    }
    candidates.items.len = write_index;
}

fn playerValue(position: []const u8, estimated_price: i32) i32 {
    if (std.mem.eql(u8, position, "D/ST")) return 1;
    return estimated_price;
}

fn slotWeight(slot_id: i32) i64 {
    return if (isBench(slot_id)) 1 else 4;
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

fn allocationRemainderOrder(left: Allocation, right: Allocation) bool {
    if (left.remainder != right.remainder) return left.remainder > right.remainder;
    if (left.candidate_id != right.candidate_id) return left.candidate_id < right.candidate_id;
    return left.slot_index < right.slot_index;
}

fn allocationIdOrder(_: void, left: Allocation, right: Allocation) bool {
    if (left.candidate_id != right.candidate_id) return left.candidate_id < right.candidate_id;
    return left.slot_index < right.slot_index;
}
