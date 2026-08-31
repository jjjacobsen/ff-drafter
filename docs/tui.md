# Draft watcher TUI

## Scope

The application watches and autonomously controls ESPN Fantasy Football auction drafts

The autonomous engine always places bids and nominations after live synchronization. When `INIT` reports that ESPN autodraft is enabled, the application disables ESPN autodraft

## Start the application

Pass the complete ESPN draft page URL as the first argument

```sh
mise x -- zig build run -- 'https://fantasy.espn.com/football/draft?leagueId=LEAGUE_ID&seasonId=2026&teamId=TEAM_ID&memberId=%7BMEMBER_ID%7D'
```

The application parses these query parameters from the URL:

- `leagueId`
- `seasonId`
- `teamId`
- `memberId`

It reads `espn_s2` and `SWID` from `.env`

Starting the application synchronizes the live draft state and then enables autonomous bidding and nominations

## Main screen

The top bar contains all teams in draft order. Each team box shows its name, ESPN team logo, remaining auction budget, and the difference between ESPN value and real spend. The difference is green when it is positive and red when it is negative. A green line and the current bid amount appear below the current high bidder. They move when another team takes the lead. For three seconds after a purchase, the winning team box also shows the price and player name. Terminals without Kitty graphics support show the team abbreviation instead of the logo

The center panel shows one of these states:

- Before the scheduled start, a live `Draft starts in` countdown from ESPN's draft date
- The nominated player, ESPN headshot or NFL team logo, position, ESPN auction value, current bid, leading team, time remaining, completed pick count, and engine maximum bid
- The team that must nominate and its time remaining
- A waiting message between auctions

Two decision lines appear below the player, current bid, leading team, and clock. The first shows `max $XX -Y`, where `XX` is the current engine maximum and `Y` is its difference from the ESPN value. A maximum above the ESPN value uses `+Y`. The line is green when the next bid is within the maximum and gray when the next bid is too expensive

The second line shows `$USER • DIFF • $AVERAGE`. `USER` is the user's remaining budget, `AVERAGE` is the average remaining budget of all other teams, and `DIFF` is the signed difference between them. A positive or zero difference is green. A negative difference is red

The footer centers connection status above `hjkl navigation • esc/q exit`. These controls remain visible while draft data loads. Pressing `q` or `esc` opens an exit confirmation dialog. Press `y` or `enter` to exit, or press `n` or `esc` to cancel. A second `q` does not exit

The screen starts without a focused team. Press `k` to focus the team from `teamId` in the draft URL. After moving with `h` or `l`, the application remembers that team when `j` clears focus and `k` restores it. Press `enter` to open the focused team

Press `esc` or `q` to exit, including while teams and players are loading

## Team screen

The heading shows the team name, remaining auction budget, and number of roster slots still open. A second summary line shows total ESPN value, total real purchase cost, and the difference between them

The table always shows every configured starter and bench slot from ESPN. The rows use a fixed vertical interval and are centered in the table. Filled slots show the player name, purchase cost, and ESPN value. Unfilled slots remain blank

The team screen redraws after every draft update, including purchases and lineup slot changes. Live purchases and reconnect snapshots are both normalized into the first compatible open starter slot, then flex, then bench

Press `esc` or `q` to return to the main screen

## State synchronization

The network worker first requests `draftInit` together with `kona_player_info`. This provides the scheduled draft date, team names, roster slot counts, all NFL players, positions, and ESPN auction values. The main screen shows the scheduled-start countdown while the worker connects or reconnects

The worker then gets a temporary draft security token and joins the ESPN WebSocket room

The first `INIT` WebSocket message is Base64-encoded binary data. `src/init_decoder.zig` decodes the current ESPN transcoder versions and restores:

- Draft order
- Team budgets
- Completed auction purchases and their normalized roster assignments
- The current player and bid state, or the active nomination turn

A future pick has `playerId = -1`. Other negative IDs are valid for team defenses and must not be treated as empty picks

After initialization, these messages update the state:

- `BID`
- `CLOCK`
- `NOMINATION`
- `SOLD`
- `ADJUSTED`
- `UNDONE`
- `SLOT_CHANGED`

The engine reads this synchronized state before every action. This lets it start during an active draft without separate history

The `INIT` decoder reads the user's `autodraftTypeId`. The WebSocket worker sends `AUTODRAFT false` only when that value reports enabled autodraft. It also handles live `AUTODRAFT {teamId} true` updates and immediately disables ESPN autodraft again

An ESPN `ERROR` is a command-level response, not a disconnected socket. The worker keeps the connection and autonomous engine active, marks the rejected action as already sent, and shows the complete error instead of reconnecting or repeating the same action

The WebSocket worker waits until the final eight seconds to bid. It waits one second after a counter bid. Nominations wait five seconds, or one second after the priority starting lineup is full. Every action is checked against the current player, turn, roster, budget, and clock before the worker sends it

The WebSocket and autonomous engine run in one worker. A four-worker artwork pool loads optional team logos and player images in parallel, so image requests cannot delay draft commands or make all logos wait for one slow host. The UI reads shared state under a mutex and receives Vaxis events when the state changes

See [Autonomous draft engine](engine.md) for the maximum bid formula and nomination rules

## Connection behavior

Only one ESPN connection can own the same member and team. Starting this application can disconnect the ESPN browser page and can immediately affect the live draft after synchronization

The worker sends ESPN application-level `PING` messages, responds to WebSocket ping frames, uses bounded reads, and reconnects after an unexpected close. Every reconnect gets a new security token and applies a new `INIT` snapshot

## Vendored WebSocket patch

`vendor/websocket/` is `karlseguin/websocket.zig` at commit `efa879736bd438bea8b86a91f220ba408de57273`

ESPN rejects lowercase WebSocket request header names even though HTTP header names are normally case-insensitive. The vendored patch changes these four request headers to standard capitalization:

- `Upgrade`
- `Connection`
- `Sec-WebSocket-Version`
- `Sec-WebSocket-Key`

All frame, TLS, timeout, ping/pong, and close handling remains in `websocket.zig`
