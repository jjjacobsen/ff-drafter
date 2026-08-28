# FF Drafter

A terminal application that watches an ESPN Fantasy Football auction draft

## Run

Put `espn_s2` and `SWID` in `.env`, then pass the current ESPN draft page URL as the first argument

```sh
mise x -- zig build run -- 'https://fantasy.espn.com/football/draft?leagueId=LEAGUE_ID&seasonId=2026&teamId=TEAM_ID&memberId=%7BMEMBER_ID%7D'
```

The application gets all room identifiers from the URL. Use the new URL each time you join a different practice draft

The bid and nomination command transport remains available, but no decision engine currently selects or schedules actions

## Controls

- `k` focuses your team in the team bar
- `h` and `l` move across teams
- `j` clears the team focus
- `enter` opens the focused team
- `esc` or `q` returns from a team screen
- `esc` or `q` exits from the main screen

## Documentation

- [TUI architecture and behavior](docs/tui.md)
- [ESPN draft integration handoff](docs/espn-draft-handoff.md)
