const std = @import("std");

pub const Block = struct {
    nomination_team_id: i32,
    player_id: i32,
    high_bid_team_id: i32,
    high_bid_amount: i32,
    expiration_time_ms: ?u64,
};

pub const Pick = struct {
    pick_number: i32,
    team_id: i32,
    player_id: i32,
    slot_id: i32,
    bid_amount: i32,
};

pub const Team = struct {
    team_id: i32,
    draft_position: i32,
    autodraft_type_id: i32,
    amount_left: i32,
};

pub const RosterItem = struct {
    team_id: i32,
    slot_id: i32,
    player_id: i32,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    block: ?Block,
    picks: std.ArrayList(Pick) = .empty,
    teams: std.ArrayList(Team) = .empty,
    roster_items: std.ArrayList(RosterItem) = .empty,

    pub fn deinit(self: *Snapshot) void {
        self.picks.deinit(self.allocator);
        self.teams.deinit(self.allocator);
        self.roster_items.deinit(self.allocator);
    }
};

pub fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) !Snapshot {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try decoder.decode(decoded, encoded);
    return decode(allocator, decoded);
}

fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var reader: Reader = .{ .bytes = bytes };
    var snapshot: Snapshot = .{ .allocator = allocator, .block = null };
    errdefer snapshot.deinit();

    try reader.requireHeader(1);
    _ = try reader.readI32();
    _ = try reader.readI32();
    try decodeLeague(&reader, &snapshot);
    try skipDraftList(&reader);
    try skipNominationList(&reader);

    if (reader.index != bytes.len) return error.UnconsumedInitData;
    return snapshot;
}

fn decodeLeague(reader: *Reader, snapshot: *Snapshot) !void {
    try reader.requireHeader(1);
    _ = try reader.readI32();
    _ = try reader.readI32();
    _ = try reader.readI32();
    try reader.skipOptionalLong();
    _ = try reader.readI32();
    snapshot.block = try decodeBlock(reader);
    try skipDraftRules(reader);

    var count = try reader.readCount();
    while (count > 0) : (count -= 1) try skipDraftPosition(reader);

    count = try reader.readCount();
    while (count > 0) : (count -= 1) try skipDraftSlot(reader);

    count = try reader.readCount();
    while (count > 0) : (count -= 1) {
        if (try decodePick(reader)) |pick| try snapshot.picks.append(snapshot.allocator, pick);
    }

    count = try reader.readCount();
    while (count > 0) : (count -= 1) {
        if (try decodeTeam(reader, snapshot)) |team| try snapshot.teams.append(snapshot.allocator, team);
    }
}

fn decodeBlock(reader: *Reader) !?Block {
    if (!try reader.readHeader(1)) return null;
    _ = try reader.readI32();
    _ = try reader.readI32();
    const expiration_time_ms = try reader.readOptionalLong();
    const nomination_team_id = try reader.readI32();
    const player_id = try reader.readI32();
    const high_bid_team_id = try reader.readI32();
    _ = try reader.readI32();
    const high_bid_amount = try reader.readI32();
    return .{
        .nomination_team_id = nomination_team_id,
        .player_id = player_id,
        .high_bid_team_id = high_bid_team_id,
        .high_bid_amount = high_bid_amount,
        .expiration_time_ms = expiration_time_ms,
    };
}

fn decodePick(reader: *Reader) !?Pick {
    if (!try reader.readHeader(3)) return null;
    _ = try reader.readI32();
    const team_id = try reader.readI32();
    const pick_number = try reader.readI32();
    const player_id = try reader.readI32();
    const slot_id = try reader.readI32();
    const bid_amount = try reader.readI32();
    _ = try reader.readI32();
    _ = try reader.readBool();
    _ = try reader.readI32();
    _ = try reader.readI32();
    return .{
        .pick_number = pick_number,
        .team_id = team_id,
        .player_id = player_id,
        .slot_id = slot_id,
        .bid_amount = bid_amount,
    };
}

fn decodeTeam(reader: *Reader, snapshot: *Snapshot) !?Team {
    if (!try reader.readHeader(2)) return null;
    _ = try reader.readI32();
    const team_id = try reader.readI32();
    const draft_position = try reader.readI32();
    const autodraft_type_id = try reader.readI32();
    const amount_left = try reader.readI32();

    var count = try reader.readCount();
    while (count > 0) : (count -= 1) try skipOwner(reader);

    count = try reader.readCount();
    while (count > 0) : (count -= 1) {
        if (try decodeRosterItem(reader)) |item| try snapshot.roster_items.append(snapshot.allocator, item);
    }

    return .{
        .team_id = team_id,
        .draft_position = draft_position,
        .autodraft_type_id = autodraft_type_id,
        .amount_left = amount_left,
    };
}

fn skipDraftRules(reader: *Reader) !void {
    if (!try reader.readHeader(2)) return;
    try reader.skipInts(5);
    try skipBreakSchedule(reader);
    try skipAutodraftProtection(reader);
    try reader.skipInts(4);
    try reader.skipBytes(8 * 4);
    _ = try reader.readI32();
    _ = try reader.readBool();
    try reader.skipInts(3);
    _ = try reader.readBool();
    _ = try reader.readBool();
    try skipScoringSettings(reader);
    _ = try reader.readBool();
}

fn skipBreakSchedule(reader: *Reader) !void {
    if (!try reader.readHeader(1)) return;
    try reader.skipInts(3);
}

fn skipAutodraftProtection(reader: *Reader) !void {
    if (!try reader.readHeader(1)) return;
    try reader.skipInts(3);
}

fn skipScoringSettings(reader: *Reader) !void {
    if (!try reader.readHeader(1)) return;
    try reader.skipInts(2);
    var count = try reader.readCount();
    while (count > 0) : (count -= 1) {
        if (!try reader.readHeader(3)) continue;
        try reader.skipInts(2);
        try reader.skipBytes(8);
        _ = try reader.readBool();
    }
}

fn skipDraftPosition(reader: *Reader) !void {
    if (!try reader.readHeader(1)) return;
    try reader.skipInts(3);
}

fn skipDraftSlot(reader: *Reader) !void {
    if (!try reader.readHeader(1)) return;
    try reader.skipInts(3);
    var count = try reader.readCount();
    while (count > 0) : (count -= 1) {
        if (!try reader.readHeader(1)) continue;
        try reader.skipInts(3);
    }
}

fn skipOwner(reader: *Reader) !void {
    if (!try reader.readHeader(1)) return;
    try reader.skipInts(3);
    _ = try reader.readBool();
    _ = try reader.readBool();
    _ = try reader.readBool();
}

fn decodeRosterItem(reader: *Reader) !?RosterItem {
    if (!try reader.readHeader(1)) return null;
    _ = try reader.readI32();
    const team_id = try reader.readI32();
    const slot_id = try reader.readI32();
    const player_id = try reader.readI32();
    _ = try reader.readBool();
    return .{
        .team_id = team_id,
        .slot_id = slot_id,
        .player_id = player_id,
    };
}

fn skipDraftList(reader: *Reader) !void {
    if (!try reader.readHeader(1)) return;
    try reader.skipInts(2);
    _ = try reader.readBool();
    var count = try reader.readCount();
    while (count > 0) : (count -= 1) {
        if (!try reader.readHeader(1)) continue;
        try reader.skipInts(5);
    }
}

fn skipNominationList(reader: *Reader) !void {
    if (!try reader.readHeader(1)) return;
    try reader.skipInts(2);
    var count = try reader.readCount();
    while (count > 0) : (count -= 1) {
        if (!try reader.readHeader(1)) continue;
        try reader.skipInts(5);
    }
}

const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *Reader, length: usize) ![]const u8 {
        if (self.index + length > self.bytes.len) return error.TruncatedInitData;
        const result = self.bytes[self.index .. self.index + length];
        self.index += length;
        return result;
    }

    fn skipBytes(self: *Reader, length: usize) !void {
        _ = try self.take(length);
    }

    fn skipInts(self: *Reader, count: usize) !void {
        try self.skipBytes(count * 4);
    }

    fn readI32(self: *Reader) !i32 {
        return @bitCast(std.mem.readInt(u32, (try self.take(4))[0..4], .big));
    }

    fn readU64(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .big);
    }

    fn readBool(self: *Reader) !bool {
        return (try self.take(1))[0] == 1;
    }

    fn readCount(self: *Reader) !usize {
        const count = try self.readI32();
        return if (count > 0) @intCast(count) else 0;
    }

    fn readHeader(self: *Reader, expected_version: i32) !bool {
        if (try self.readI32() != 1) return false;
        if (try self.readI32() != expected_version) return error.UnsupportedInitVersion;
        return true;
    }

    fn requireHeader(self: *Reader, expected_version: i32) !void {
        if (!try self.readHeader(expected_version)) return error.MissingInitObject;
    }

    fn readOptionalLong(self: *Reader) !?u64 {
        return if (try self.readI32() != 0) try self.readU64() else null;
    }

    fn skipOptionalLong(self: *Reader) !void {
        _ = try self.readOptionalLong();
    }
};
