# Draft watcher TUI

## Scope

The application is a read-only watcher for ESPN Fantasy Football auction drafts

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

The top bar contains all teams in draft order. Each team box shows its name, ESPN team logo, and remaining auction budget. For three seconds after a purchase, the winning team box also shows the price and player name. Terminals without Kitty graphics support show the team abbreviation instead of the logo

The center panel shows one of these states:

- The nominated player, ESPN headshot or NFL team logo, position, ESPN auction value, current bid, leading team, time remaining, and completed pick count
- The team that must nominate and its time remaining
- A waiting message between auctions

The footer shows connection status

The screen starts without a focused team. Press `k` to focus the team from `teamId` in the draft URL. After moving with `h` or `l`, the application remembers that team when `j` clears focus and `k` restores it. Press `enter` to open the focused team

Press `esc` or `q` to exit

## Team screen

The heading shows the team name and remaining auction budget

The table always shows every configured starter and bench slot from ESPN. Filled slots show the player name and purchase cost. Unfilled slots remain blank

The team screen redraws after every draft update, including purchases and lineup slot changes

Press `esc` or `q` to return to the main screen

## State synchronization

The network worker first requests `draftInit` together with `kona_player_info`. This provides team names, roster slot counts, all NFL players, positions, and ESPN auction values

The worker then gets a temporary draft security token and joins the ESPN WebSocket room

The first `INIT` WebSocket message is Base64-encoded binary data. `src/init_decoder.zig` decodes the current ESPN transcoder versions and restores:

- Draft order
- Team budgets
- Completed auction purchases
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

The WebSocket runs in one worker. The UI reads shared state under a mutex and receives Vaxis events when the state changes

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
