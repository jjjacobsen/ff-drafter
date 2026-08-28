const std = @import("std");

const bench_slot_ids = [_]i32{ 20, 22, 24 };
const impossible_cost: i64 = 1_000_000_000_000_000;

const Candidate = struct {
    id: i32,
    position: []const u8,
    points: f64,
    points_units: i64,
};

const Replacement = struct {
    position: []const u8,
    points_units: i64 = 0,
    remaining_starters: usize = 0,
    full_starters: usize = 0,
    expected_players: usize = 0,
    bench_remainder: usize = 0,
};

pub fn recommend(allocator: std.mem.Allocator, state: anytype, accepts: *const fn (i32, []const u8) bool) !@TypeOf(state.recommendation) {
    const player_id = state.auction.player_id orelse return .{};
    const player = state.players.get(player_id) orelse return .{};
    const team_index = state.teamIndexById(state.user_team_id) orelse return .{};
    const team = &state.teams.items[team_index];

    var drafted = std.AutoHashMap(i32, void).init(allocator);
    defer drafted.deinit();
    for (state.teams.items) |draft_team| {
        for (draft_team.roster.items) |purchase| try drafted.put(purchase.player_id, {});
    }
    if (drafted.contains(player_id)) return .{
        .player_id = player_id,
        .projected_points = player.projected_points,
    };

    var remaining: std.ArrayList(Candidate) = .empty;
    defer remaining.deinit(allocator);
    var players = state.players.iterator();
    while (players.next()) |entry| {
        if (drafted.contains(entry.key_ptr.*)) continue;
        try remaining.append(allocator, candidate(entry.key_ptr.*, entry.value_ptr));
    }
    std.mem.sort(Candidate, remaining.items, {}, candidateOrder);

    var league_slots: std.ArrayList(i32) = .empty;
    defer league_slots.deinit(allocator);
    for (state.teams.items) |draft_team| {
        try appendOpenSlots(allocator, &league_slots, state.roster_slots.items, draft_team.roster.items, true);
    }

    const league_assignment = try maximumAssignment(allocator, league_slots.items, remaining.items, null, accepts);
    defer allocator.free(league_assignment);

    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(allocator);
    for (league_assignment) |candidate_index| {
        if (candidate_index >= remaining.items.len) continue;
        const selected = remaining.items[candidate_index];
        const index = try replacementIndexOrAppend(allocator, &replacements, selected.position);
        replacements.items[index].remaining_starters += 1;
        replacements.items[index].full_starters += 1;
    }
    for (state.teams.items) |draft_team| {
        for (draft_team.roster.items) |purchase| {
            if (isBench(purchase.slot_id)) continue;
            const owned_player = state.players.get(purchase.player_id).?;
            const index = try replacementIndexOrAppend(allocator, &replacements, owned_player.position);
            replacements.items[index].full_starters += 1;
        }
    }

    var open_bench_slots: usize = 0;
    for (state.teams.items) |draft_team| {
        open_bench_slots += countOpenBenchSlots(state.roster_slots.items, draft_team.roster.items);
    }
    var full_starter_count: usize = 0;
    for (replacements.items) |replacement| full_starter_count += replacement.full_starters;
    var allocated_bench_slots: usize = 0;
    if (full_starter_count > 0) {
        for (replacements.items) |*replacement| {
            const numerator = open_bench_slots * replacement.full_starters;
            const bench_players = numerator / full_starter_count;
            replacement.expected_players = replacement.remaining_starters + bench_players;
            replacement.bench_remainder = numerator % full_starter_count;
            allocated_bench_slots += bench_players;
        }
        std.mem.sort(Replacement, replacements.items, {}, benchAllocationOrder);
        for (replacements.items[0 .. open_bench_slots - allocated_bench_slots]) |*replacement| {
            replacement.expected_players += 1;
        }
    }

    var valued_players: std.ArrayList(usize) = .empty;
    defer valued_players.deinit(allocator);
    var position_players: std.ArrayList(usize) = .empty;
    defer position_players.deinit(allocator);
    for (replacements.items) |*replacement| {
        position_players.clearRetainingCapacity();
        for (remaining.items, 0..) |remaining_player, candidate_index| {
            if (std.mem.eql(u8, remaining_player.position, replacement.position))
                try position_players.append(allocator, candidate_index);
        }
        std.mem.sort(usize, position_players.items, remaining.items, projectedCandidateIndexOrder);
        const selected_count = @min(replacement.expected_players, position_players.items.len);
        if (selected_count == 0) continue;
        try valued_players.appendSlice(allocator, position_players.items[0..selected_count]);
        replacement.points_units = remaining.items[position_players.items[selected_count - 1]].points_units;
    }

    const nominee_index = candidateIndex(remaining.items, player_id).?;
    const nominee = remaining.items[nominee_index];
    const replacement_units = if (replacementIndex(replacements.items, nominee.position)) |index|
        replacements.items[index].points_units
    else
        0;
    const vorp_units = @max(nominee.points_units - replacement_units, 0);

    var remaining_money: i64 = 0;
    var remaining_roster_slots: i64 = 0;
    for (state.teams.items) |draft_team| {
        remaining_money += draft_team.remaining_budget;
        remaining_roster_slots += @as(i64, @intCast(state.roster_slots.items.len -| draft_team.roster.items.len));
    }
    const discretionary_dollars = @max(remaining_money - remaining_roster_slots, 0);
    const fair_value = fairValue(
        remaining.items,
        valued_players.items,
        replacements.items,
        nominee_index,
        discretionary_dollars,
    );

    const empty_slots = state.roster_slots.items.len -| team.roster.items.len;
    const legal_max = if (empty_slots == 0)
        0
    else
        @max(team.remaining_budget - @as(i32, @intCast(empty_slots - 1)), 0);
    const has_roster_slot = hasOpenCompatibleSlot(state.roster_slots.items, team.roster.items, nominee.position, accepts);

    var starter_slots: std.ArrayList(i32) = .empty;
    defer starter_slots.deinit(allocator);
    for (state.roster_slots.items) |slot_id| {
        if (!isBench(slot_id)) try starter_slots.append(allocator, slot_id);
    }

    var owned: std.ArrayList(Candidate) = .empty;
    defer owned.deinit(allocator);
    for (team.roster.items) |purchase| {
        const owned_player = state.players.get(purchase.player_id).?;
        try owned.append(allocator, candidate(purchase.player_id, &owned_player));
    }
    std.mem.sort(Candidate, owned.items, {}, candidateOrder);

    const baseline = try maximumAssignment(allocator, starter_slots.items, owned.items, null, accepts);
    defer allocator.free(baseline);
    const baseline_points = assignmentPoints(baseline, owned.items);

    var with_nominee: std.ArrayList(Candidate) = .empty;
    defer with_nominee.deinit(allocator);
    try with_nominee.appendSlice(allocator, owned.items);
    try with_nominee.append(allocator, nominee);
    std.mem.sort(Candidate, with_nominee.items, {}, candidateOrder);
    const personal_nominee_index = candidateIndex(with_nominee.items, player_id).?;
    const forced = try maximumAssignment(allocator, starter_slots.items, with_nominee.items, player_id, accepts);
    defer allocator.free(forced);
    const forced_points = assignmentPoints(forced, with_nominee.items);
    const nominee_starts = std.mem.indexOfScalar(usize, forced, personal_nominee_index) != null;

    var open_compatible_starter = false;
    for (baseline, starter_slots.items) |candidate_index, slot_id| {
        if (candidate_index >= owned.items.len and accepts(slot_id, nominee.position)) {
            open_compatible_starter = true;
            break;
        }
    }
    const improves_lineup = nominee_starts and forced_points > baseline_points;
    const role: @TypeOf(state.recommendation.role) = if (open_compatible_starter or improves_lineup) .starter else .bench;
    const personal_marginal_units = if (role == .starter) @max(forced_points - baseline_points, 0) else 0;

    var max_bid = @min(fair_value, legal_max);
    if (role == .bench) max_bid = @min(max_bid, 1);
    if (nominee.points_units < replacement_units) max_bid = 0;
    if (!has_roster_slot or legal_max == 0) max_bid = 0;
    if (std.mem.eql(u8, nominee.position, "D/ST")) max_bid = @min(max_bid, 1);

    const reason: @TypeOf(state.recommendation.reason) = if (!has_roster_slot)
        .no_compatible_roster_slot
    else if (legal_max == 0)
        .no_legal_budget
    else if (nominee.points_units < replacement_units)
        .below_replacement_level
    else if (role == .bench and max_bid == 0)
        .does_not_improve_starting_lineup
    else
        .none;

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
        .projected_points = nominee.points,
        .replacement_points = unitsToPoints(replacement_units),
        .vorp_points = unitsToPoints(vorp_units),
        .personal_marginal_points = unitsToPoints(personal_marginal_units),
        .fair_value = fair_value,
        .max_bid = max_bid,
        .legal_max = legal_max,
        .role = role,
        .reason = reason,
    };
}

fn candidate(id: i32, player: anytype) Candidate {
    return .{
        .id = id,
        .position = player.position,
        .points = player.projected_points,
        .points_units = pointsToUnits(player.projected_points),
    };
}

fn pointsToUnits(points: f64) i64 {
    return @intFromFloat(@round(@max(points, 0) * 1000));
}

fn unitsToPoints(units: i64) f64 {
    return @as(f64, @floatFromInt(units)) / 1000;
}

fn appendOpenSlots(
    allocator: std.mem.Allocator,
    open: *std.ArrayList(i32),
    configured: []const i32,
    roster: anytype,
    starters_only: bool,
) !void {
    for (configured, 0..) |slot_id, index| {
        if (starters_only and isBench(slot_id)) continue;
        var occurrence: usize = 0;
        for (configured[0..index]) |previous| {
            if (previous == slot_id) occurrence += 1;
        }
        var occupied: usize = 0;
        for (roster) |purchase| {
            if (purchase.slot_id == slot_id) occupied += 1;
        }
        if (occupied <= occurrence) try open.append(allocator, slot_id);
    }
}

fn countOpenBenchSlots(configured: []const i32, roster: anytype) usize {
    var open: usize = 0;
    for (configured, 0..) |slot_id, index| {
        if (!isBench(slot_id)) continue;
        var occurrence: usize = 0;
        for (configured[0..index]) |previous| {
            if (previous == slot_id) occurrence += 1;
        }
        var occupied: usize = 0;
        for (roster) |purchase| {
            if (purchase.slot_id == slot_id) occupied += 1;
        }
        if (occupied <= occurrence) open += 1;
    }
    return open;
}

fn hasOpenCompatibleSlot(
    configured: []const i32,
    roster: anytype,
    position: []const u8,
    accepts: *const fn (i32, []const u8) bool,
) bool {
    for (configured, 0..) |slot_id, index| {
        if (!accepts(slot_id, position)) continue;
        var occurrence: usize = 0;
        for (configured[0..index]) |previous| {
            if (previous == slot_id) occurrence += 1;
        }
        var occupied: usize = 0;
        for (roster) |purchase| {
            if (purchase.slot_id == slot_id) occupied += 1;
        }
        if (occupied <= occurrence) return true;
    }
    return false;
}

fn maximumAssignment(
    allocator: std.mem.Allocator,
    slots: []const i32,
    candidates: []const Candidate,
    preferred_id: ?i32,
    accepts: *const fn (i32, []const u8) bool,
) ![]usize {
    const row_count = slots.len;
    const column_count = candidates.len + row_count;
    const result = try allocator.alloc(usize, row_count);
    if (row_count == 0) return result;

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
                const candidate_index = candidate_column - 1;
                const cost = if (candidate_index >= candidates.len)
                    @as(i64, 0)
                else if (!accepts(slots[current_row - 1], candidates[candidate_index].position))
                    impossible_cost
                else
                    -(candidates[candidate_index].points_units * 2 +
                        @as(i64, if (preferred_id == candidates[candidate_index].id) 1 else 0));
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

fn assignmentPoints(assignment: []const usize, candidates: []const Candidate) i64 {
    var total: i64 = 0;
    for (assignment) |candidate_index| {
        if (candidate_index < candidates.len) total += candidates[candidate_index].points_units;
    }
    return total;
}

fn fairValue(
    candidates: []const Candidate,
    assignment: []const usize,
    replacements: []const Replacement,
    nominee_index: usize,
    discretionary_dollars: i64,
) i32 {
    if (std.mem.indexOfScalar(usize, assignment, nominee_index) == null) return 1;

    var total_vorp: i64 = 0;
    for (assignment) |candidate_index| {
        if (candidate_index >= candidates.len) continue;
        total_vorp += candidateVorp(candidates[candidate_index], replacements);
    }
    if (total_vorp == 0) return 1;

    const nominee_vorp = candidateVorp(candidates[nominee_index], replacements);
    const numerator = discretionary_dollars * nominee_vorp;
    var share = @divFloor(numerator, total_vorp);
    const nominee_remainder = @mod(numerator, total_vorp);

    var floor_total: i64 = 0;
    for (assignment) |candidate_index| {
        if (candidate_index >= candidates.len) continue;
        floor_total += @divFloor(
            discretionary_dollars * candidateVorp(candidates[candidate_index], replacements),
            total_vorp,
        );
    }
    const leftover = discretionary_dollars - floor_total;
    var remainder_rank: i64 = 0;
    for (assignment) |candidate_index| {
        if (candidate_index >= candidates.len or candidate_index == nominee_index) continue;
        const selected = candidates[candidate_index];
        const remainder = @mod(discretionary_dollars * candidateVorp(selected, replacements), total_vorp);
        if (remainder > nominee_remainder or
            (remainder == nominee_remainder and selected.id < candidates[nominee_index].id))
        {
            remainder_rank += 1;
        }
    }
    if (remainder_rank < leftover) share += 1;
    return 1 + @as(i32, @intCast(share));
}

fn candidateVorp(value: Candidate, replacements: []const Replacement) i64 {
    const replacement = if (replacementIndex(replacements, value.position)) |index|
        replacements[index].points_units
    else
        0;
    return @max(value.points_units - replacement, 0);
}

fn replacementIndexOrAppend(
    allocator: std.mem.Allocator,
    replacements: *std.ArrayList(Replacement),
    position: []const u8,
) !usize {
    if (replacementIndex(replacements.items, position)) |index| return index;
    try replacements.append(allocator, .{ .position = position });
    return replacements.items.len - 1;
}

fn replacementIndex(replacements: []const Replacement, position: []const u8) ?usize {
    for (replacements, 0..) |replacement, index| {
        if (std.mem.eql(u8, replacement.position, position)) return index;
    }
    return null;
}

fn candidateIndex(candidates: []const Candidate, id: i32) ?usize {
    for (candidates, 0..) |value, index| {
        if (value.id == id) return index;
    }
    return null;
}

fn isBench(slot_id: i32) bool {
    return std.mem.indexOfScalar(i32, &bench_slot_ids, slot_id) != null;
}

fn projectedCandidateIndexOrder(candidates: []const Candidate, left: usize, right: usize) bool {
    if (candidates[left].points_units != candidates[right].points_units)
        return candidates[left].points_units > candidates[right].points_units;
    return candidates[left].id < candidates[right].id;
}

fn benchAllocationOrder(_: void, left: Replacement, right: Replacement) bool {
    if (left.bench_remainder != right.bench_remainder) return left.bench_remainder > right.bench_remainder;
    return std.mem.order(u8, left.position, right.position) == .lt;
}

fn candidateOrder(_: void, left: Candidate, right: Candidate) bool {
    return left.id < right.id;
}
