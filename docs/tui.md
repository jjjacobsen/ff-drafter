# Draft watcher TUI

## Scope

The application is a read-only watcher and bid advisor for ESPN Fantasy Football auction drafts

It does not nominate players, place bids, or change autodraft settings. ESPN must already have autodraft enabled if the room must continue without input

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

## Main screen

The top bar contains all teams in draft order. Each team box shows its name, ESPN team logo, and remaining auction budget. A green line and the current bid amount appear below the current high bidder. They move when another team takes the lead. For three seconds after a purchase, the winning team box also shows the price and player name. Terminals without Kitty graphics support show the team abbreviation instead of the logo

The center panel shows one of these states:

- The nominated player, ESPN headshot or NFL team logo, position, ESPN auction value, current bid, leading team, time remaining, completed pick count, and optimizer recommendation
- The team that must nominate and its time remaining
- A waiting message between auctions

The optimizer recommendation appears in a separate section below the player, current bid, leading team, and clock. It shows `BID`, `HOLD`, or `PASS` together with its target bid, maximum bid, ESPN legal maximum, replacement value, marginal value, and projected starter or bench role. A player without a complete budget-feasible roster fit gets a zero maximum and a clear explanation

The footer centers connection status above `hjkl navigation • esc/q exit`. These controls remain visible while draft data loads

The screen starts without a focused team. Press `k` to focus the team from `teamId` in the draft URL. After moving with `h` or `l`, the application remembers that team when `j` clears focus and `k` restores it. Press `enter` to open the focused team

Press `esc` or `q` to exit, including while teams and players are loading

## Team screen

The heading shows the team name, remaining auction budget, and number of roster slots still open. A second summary line shows total ESPN value, total real purchase cost, and the difference between them

The table always shows every configured starter and bench slot from ESPN. The rows use a fixed vertical interval and are centered in the table. Filled slots show the player name, purchase cost, and ESPN value. Unfilled slots remain blank

The team screen redraws after every draft update, including purchases and lineup slot changes. Live purchases and reconnect snapshots are both normalized into the first compatible open starter slot, then flex, then bench

Press `esc` or `q` to return to the main screen

## State synchronization

The network worker first requests `draftInit` together with `kona_player_info`. This provides team names, roster slot counts, all NFL players, positions, and ESPN auction values

The worker then gets a temporary draft security token and joins the ESPN WebSocket room

The first `INIT` WebSocket message is Base64-encoded binary data. `src/init_decoder.zig` decodes the current ESPN transcoder versions and restores:

- Draft order
- Team budgets
- Completed auction purchases and their normalized roster assignments
- The current player and bid state

A future pick has `playerId = -1`. Other negative IDs are valid for team defenses and must not be treated as empty picks

After initialization, these messages update the state:

- `BID`
- `CLOCK`
- `NOMINATION`
- `SOLD`
- `ADJUSTED`
- `UNDONE`
- `SLOT_CHANGED`

The decision engine recalculates under the same state mutex after these updates. The UI only renders the stored recommendation and never runs optimization work itself

The WebSocket runs in one worker. The UI reads shared state under a mutex and receives Vaxis events when the state changes

See [Dynamic roster optimizer](optimizer.md) for the planning model and bid-value definitions

## Connection behavior

Only one ESPN connection can own the same member and team. Starting this application can disconnect the ESPN browser page

The worker sends ESPN application-level `PING` messages, responds to WebSocket ping frames, uses bounded reads, and reconnects after an unexpected close. Every reconnect gets a new security token and applies a new `INIT` snapshot

## Vendored WebSocket patch

`vendor/websocket/` is `karlseguin/websocket.zig` at commit `efa879736bd438bea8b86a91f220ba408de57273`

ESPN rejects lowercase WebSocket request header names even though HTTP header names are normally case-insensitive. The vendored patch changes these four request headers to standard capitalization:

- `Upgrade`
- `Connection`
- `Sec-WebSocket-Version`
- `Sec-WebSocket-Key`

All frame, TLS, timeout, ping/pong, and close handling remains in `websocket.zig`
