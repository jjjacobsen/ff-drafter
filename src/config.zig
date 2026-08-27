const std = @import("std");

pub const Config = struct {
    allocator: std.mem.Allocator,
    season_id: i32,
    league_id: i64,
    team_id: i32,
    member_id: []u8,
    espn_s2: []u8,
    swid: []u8,

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        draft_url: []const u8,
    ) !Config {
        const uri = try std.Uri.parse(draft_url);
        var query_buffer: [4096]u8 = undefined;
        const query = try (uri.query orelse return error.DraftUrlMissingQuery).toRaw(&query_buffer);

        var season_id: ?i32 = null;
        var league_id: ?i64 = null;
        var team_id: ?i32 = null;
        var member_id: ?[]u8 = null;
        errdefer if (member_id) |value| allocator.free(value);

        var fields = std.mem.splitScalar(u8, query, '&');
        while (fields.next()) |field| {
            var pair = std.mem.splitScalar(u8, field, '=');
            const key = pair.next().?;
            const value = pair.next() orelse "";
            if (std.mem.eql(u8, key, "seasonId")) season_id = try std.fmt.parseInt(i32, value, 10);
            if (std.mem.eql(u8, key, "leagueId")) league_id = try std.fmt.parseInt(i64, value, 10);
            if (std.mem.eql(u8, key, "teamId")) team_id = try std.fmt.parseInt(i32, value, 10);
            if (std.mem.eql(u8, key, "memberId")) {
                if (member_id) |previous| allocator.free(previous);
                member_id = try allocator.dupe(u8, value);
            }
        }

        const env = try std.Io.Dir.cwd().readFileAlloc(io, ".env", allocator, .limited(64 * 1024));
        defer allocator.free(env);

        const espn_s2 = try readEnvValue(allocator, env, "espn_s2");
        errdefer allocator.free(espn_s2);
        const swid = try readEnvValue(allocator, env, "SWID");
        errdefer allocator.free(swid);

        return .{
            .allocator = allocator,
            .season_id = season_id orelse return error.DraftUrlMissingSeasonId,
            .league_id = league_id orelse return error.DraftUrlMissingLeagueId,
            .team_id = team_id orelse return error.DraftUrlMissingTeamId,
            .member_id = member_id orelse return error.DraftUrlMissingMemberId,
            .espn_s2 = espn_s2,
            .swid = swid,
        };
    }

    pub fn deinit(self: *Config) void {
        @memset(self.espn_s2, 0);
        @memset(self.swid, 0);
        self.allocator.free(self.espn_s2);
        self.allocator.free(self.swid);
        self.allocator.free(self.member_id);
    }
};

fn readEnvValue(allocator: std.mem.Allocator, contents: []const u8, wanted_key: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const equals = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        if (!std.mem.eql(u8, key, wanted_key)) continue;

        var value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (value.len >= 2 and
            ((value[0] == '\'' and value[value.len - 1] == '\'') or
                (value[0] == '"' and value[value.len - 1] == '"')))
        {
            value = value[1 .. value.len - 1];
        }
        return allocator.dupe(u8, value);
    }
    return error.MissingEnvironmentValue;
}
