# Draft watcher TUI

## Scope

The application watches and autonomously controls ESPN Fantasy Football auction drafts

Automation is active after live synchronization. It places optimizer-approved bids and nominates players when it is the user's turn. When `INIT` reports that ESPN autodraft is enabled, it disables ESPN autodraft so ESPN cannot bid independently of the optimizer

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

Starting the application enables bidding and nominations immediately after live state synchronization

## Main screen

The top bar contains all teams in draft order. Each team box shows its name, ESPN team logo, remaining auction budget, and the difference between ESPN value and real spend. The difference is green when it is positive and red when it is negative. A green line and the current bid amount appear below the current high bidder. They move when another team takes the lead. For three seconds after a purchase, the winning team box also shows the price and player name. Terminals without Kitty graphics support show the team abbreviation instead of the logo

The center panel shows one of these states:

- The nominated player, ESPN headshot or NFL team logo, position, ESPN auction value, current bid, leading team, time remaining, completed pick count, and optimizer recommendation
- The team that must nominate and its time remaining
- A waiting message between auctions

The optimizer recommendation appears in a separate section below the player, current bid, leading team, and clock. It shows `BID`, `HOLD`, or `PASS` together with its target bid, maximum bid, ESPN legal maximum, replacement value, marginal value, and projected starter or bench role. A player without a complete budget-feasible roster fit gets a zero maximum and a clear explanation

The footer centers connection status above `hjkl navigation • esc/q exit`. These controls remain visible while draft data loads. Pressing `q` or `esc` opens an exit confirmation dialog. Press `y` or `enter` to exit, or press `n` or `esc` to cancel. A second `q` does not exit

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

The `INIT` decoder reads the user's `autodraftTypeId`. The WebSocket worker sends `AUTODRAFT false` only when that value reports enabled autodraft. This prevents repeated no-op commands and keeps ESPN and the optimizer from controlling the same team at the same time

An ESPN `ERROR` is a command-level response, not a disconnected socket. The worker keeps the connection open, stops automation, and shows the complete error instead of reconnecting and repeating the rejected command

The WebSocket worker schedules and sends all actions. At or below the optimizer target, a bid waits 2 to 5 seconds. Above the target but within the optimizer maximum, it waits 1 to 3 seconds. The schedule is capped by a randomized 2 to 3 second deadline threshold. A newer bid cancels the old schedule and creates a new one from the updated state

Nominations wait 5 to 10 seconds and open at `$1`. The nomination evaluator starts with the 64 highest-valued available ESPN players and prefers the player with the most ESPN value that does not improve the user's optimized roster. It searches lower-valued players only when the first group has no legal `$1` nominee. Every action revalidates the turn, player, price, optimizer maximum, legal maximum, budget, and availability immediately before it is sent

The WebSocket runs in one worker. The UI reads shared state under a mutex and receives Vaxis events when the state changes

See [Dynamic roster optimizer](optimizer.md) for the planning model and bid-value definitions

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
