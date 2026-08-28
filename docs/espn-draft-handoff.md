# ESPN Draft Integration Handoff

## Purpose

This document records what was learned while connecting to a live ESPN Fantasy Football practice auction and implementing the production draft controller

The Zig application now synchronizes the live room, places optimizer-approved bids, and nominates players automatically. The temporary `/tmp` listener described below was used only during the initial protocol investigation

## What the user must provide

The future application needs these inputs:

1. `espn_s2` and `SWID` in `.env`
2. The ESPN draft page URL for the active draft

The user does not need to copy the WebSocket URL

The draft page URL contains all stable draft identifiers:

```text
https://fantasy.espn.com/football/draft?leagueId=2060277817&seasonId=2026&teamId=6&memberId=%7BMEMBER-ID%7D
```

Parse these query parameters:

- `leagueId`
- `seasonId`
- `teamId`
- `memberId`

Decode `memberId` so it retains its surrounding braces

Each practice draft can have a different `leagueId`, so the user must provide the current draft page URL for each draft

## Get the ESPN cookies

Use a normal Chrome session because ESPN login did not initialize correctly in Lightpanda

1. Sign in to ESPN in Chrome
2. Open `https://fantasy.espn.com`
3. Open Chrome DevTools
4. Select **Application**
5. Under **Storage**, expand **Cookies**
6. Select the ESPN cookie domain
7. Find `espn_s2`
8. Copy its complete **Value**
9. Find `SWID`
10. Copy its complete **Value**, including the surrounding braces
11. Put both values in the project `.env` file

Use this format:

```dotenv
espn_s2='REPLACE_WITH_VALUE'
SWID='{REPLACE-WITH-VALUE}'
```

`.env` is already excluded by `.gitignore`

Treat `espn_s2` as a password. Do not commit it, print it, or include it in logs

The copied values do not include cookie expiration metadata. In Chrome DevTools, use the **Expires / Max-Age** column to see the browser expiration date

Replace the values when ESPN returns `401`, `403`, an authentication error, or an unexpected private-league visibility error

## REST API

Use this base URL:

```text
https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/{seasonId}/segments/0/leagues/{leagueId}
```

Send these headers:

```text
Accept: application/json
X-Fantasy-Source: kona
User-Agent: Mozilla/5.0
Cookie: espn_s2={espn_s2}; SWID={SWID}
```

### Draft initialization

```text
GET {baseUrl}?view=draftInit
```

This response includes:

- League data
- Teams
- The available player pool
- Draft status
- Draft settings

The player records use this shape:

```json
{
  "id": 4258173,
  "player": {
    "id": 4258173,
    "fullName": "Nico Collins"
  }
}
```

Map names with `players[].player.fullName`, not `players[].fullName`

### League-scoring projections

The combined `draftInit` and `kona_player_info` response includes projections in `players[].player.stats[]`. Select the current-season record with:

```text
statSourceId = 1
statSplitTypeId = 0
scoringPeriodId = 0
seasonId = league season
```

Some filtered compact responses omit `seasonId` and `scoringPeriodId`. For those records, match `externalId` to the decimal league season while still requiring `statSourceId = 1` and `statSplitTypeId = 0`

Read projected season fantasy points from `appliedTotal`. The value uses the league scoring settings. Treat a missing matching record as zero projected points

These ESPN source and split meanings were inferred from observed responses and are not based on official ESPN documentation

The available-player response can omit drafted players and the player who is already up for bid. Resolve all missing completed-pick and current-block IDs in one authenticated league request to `draftInit` with `kona_player_info`. Send an `X-Fantasy-Filter` with a `players.filterIds.value` array, then read `fullName`, `defaultPositionId`, `proTeamId`, `draftAuctionValue`, and the matching projection from the returned fantasy player records

### Draft security token

```text
GET {baseUrl}/teams/{teamId}/draftSecurity
```

The response is an integer token

Build the complete WebSocket security value as:

```text
1:{leagueId}:{teamId}:{memberId}:{draftSecurityResponse}
```

The first value is ESPN Fantasy Football game ID `1`

The token is temporary. Generate it for each connection instead of asking the user to copy it from Chrome

### `mDraftDetail` limitation

```text
GET {baseUrl}?view=mDraftDetail
```

For the tested practice drafts, this endpoint reported `inProgress: true` and returned 150 draft slots, but it returned zero completed picks

Do not use `mDraftDetail` to watch a live practice draft. The live state comes from the draft WebSocket

A completed non-practice league draft can still expose picks through `mDraftDetail`, including `playerId`, `teamId`, `nominatingTeamId`, and `bidAmount`

## WebSocket connection

Construct this URL from the draft page URL and the generated security token:

```text
wss://fantasydraft.espn.com/game-1/league-{leagueId}/JOIN?1=1&2={leagueId}&3={teamId}&4={memberId}&5={securityValue}&6=false&7=false&8=KONA&nocache={randomNumber}
```

Example parameter meanings:

| Parameter | Value |
| --- | --- |
| `1` | Game ID, always `1` for ESPN Fantasy Football |
| `2` | League ID |
| `3` | Team ID |
| `4` | Member ID with braces |
| `5` | Complete generated security value |
| `6` | `false` |
| `7` | `false` |
| `8` | `KONA` |
| `nocache` | A changing random or timestamp-derived number |

### Critical URL rule

Do not percent-encode the braces and colon delimiters in parameters `4` and `5`

The failed tests used a generic query encoder, which changed values such as `:` and `{}` into percent escapes. ESPN then returned the misleading error:

```text
No team with ID 6 found in league ID: 2060277817
```

Construct the query string so these values remain in the same raw form used by ESPN's browser client

A correct connection returns:

```text
HTTP/1.1 101 Switching Protocols
```

It then sends an `INIT` message

## Connection ownership

ESPN permits only one active draft connection for the same member and team

Starting the headless connection disconnects the Chrome draft page and shows a **Duplicate Connection** dialog in Chrome. This is acceptable for this project because the headless process will control and observe the draft without the Chrome UI

Do not reconnect Chrome while the headless watcher is running because Chrome will replace the headless connection

## Live protocol

Messages are space-delimited text inside WebSocket frames

The most important auction messages are:

```text
BID {teamId} {playerId} {bidAmount} {timeTotal} {timeRemaining}
CLOCK {phase} {time} {teamId} {playerId} {amount}
NOMINATION {teamId} {timeToPick}
SOLD {teamId} {playerId} {slotId} {bidAmount}
```

A completed auction purchase is therefore available immediately from `SOLD`. The `slotId` can be an ESPN player position ID rather than a configured lineup slot ID, so the watcher must resolve it to an open compatible starter, flex, or bench slot

Example parsed result:

```text
SOLD | Nico Collins | We Play to Win | $32
```

Other observed or supported messages include:

- `INIT`
- `SELECTING`
- `SELECTED`
- `STATE`
- `AUTODRAFT`
- `ADJUSTED`
- `UNDONE`
- `SLOT_CHANGED`
- `ERROR`
- `PONG`

### Initial state

`INIT` contains a Base64 payload, not JSON

ESPN decodes it with custom binary transcoders in the draft JavaScript bundle. Relevant decoder versions observed in the current bundle are:

- `DraftInitStorableTranscoder` version 1
- `DraftLeagueStorableTranscoder` version 1
- `DraftPickStorableTranscoder` version 3

A decoded draft pick contains:

- `leagueId`
- `teamId`
- `pickNumber`
- `playerId`
- `slotId`
- `bidAmount`
- `nominatingTeamId`
- `isKeeper`
- `autodraftTypeId`
- `selectorUserProfileId`

The production implementation must decode `INIT` to recover purchases that happened before the watcher connected. This makes it possible to start the watcher during an active draft and reconstruct all earlier purchases in that room

A practice draft can only be recovered while ESPN still has its live room state. After the room expires, its picks might not be available because the tested practice drafts did not persist purchases in `mDraftDetail`

`INIT` also contains `DraftTeam` records with:

- `leagueId`
- `teamId`
- `draftPosition`
- `autodraftTypeId`
- `amountLeft`
- Owners
- `draftRosterItems`

Each draft roster item contains:

- `leagueId`
- `teamId`
- `slotId`
- `playerId`
- `isKeeper`

The watcher can therefore reconstruct each team's roster and remaining auction budget when it connects. It must then maintain that state from `SOLD`, `ADJUSTED`, `UNDONE`, and `SLOT_CHANGED` messages

The temporary listener only confirms receipt of `INIT` and records new `SOLD` messages. It does not decode the initial state

The current ESPN draft bundle used during investigation was:

```text
https://cdn1.espn.net/kona/5e254affd13e-1.467/_next/32e26e94-6d6f-4af2-aaf7-601eb88d74ba/page/football/draft.js
```

This URL and the minified symbol names can change with ESPN deployments. Search a new bundle for `DraftInitStorableTranscoder`, `DraftPickStorableTranscoder`, `fantasydraft.`, or `case"SOLD"` if the protocol changes

## Draft control commands

The headless process can control the draft by sending WebSocket messages directly. It does not need a graphical browser or simulated button clicks

Nominate an auction player with an opening bid:

```text
NOMINATE {playerId} {initialBid}
```

Place a bid on the current player:

```text
BID {playerId} {bidAmount}
```

The ESPN browser client calls these methods:

```text
sendNominationMessage(playerId, initialBid)
sendBidMessage(playerOnBlock.playerId, bidAmount)
```

Every outgoing command must end with a newline inside the WebSocket frame. ESPN can reject an otherwise valid command as `Invalid arguments for command` when the newline is missing

Other supported outgoing commands include:

```text
PRENOMINATE {playerId} 1 ...
AUTO_NOMINATION {playerId}
AUTODRAFT true
AUTODRAFT false
SELECT {playerId}
LEAVE
```

The production controller confirms all relevant state immediately before it sends a newline-terminated action:

- It is our nomination or bidding turn
- The player is still available
- The auction is still for the expected player
- The requested bid is greater than the current bid
- The requested bid does not exceed the team's maximum legal bid
- Enough money remains to fill every empty roster slot
- No newer `CLOCK`, `BID`, `SOLD`, or state message invalidated the decision

ESPN should reject invalid commands, but the application must not depend on server rejection as its primary safety check

The proof-of-concept listener was monitor-only. The production Zig controller reads the user's `autodraftTypeId` from `INIT`, sends `AUTODRAFT false` only when needed, then sends optimizer-controlled `NOMINATE` and `BID` commands

## Keepalive behavior

The browser client sends application-level `PING` messages in addition to normal WebSocket control frames

It starts its first ping after approximately one second and then sends one approximately every 15 seconds. The production watcher must also answer WebSocket ping frames with pong frames and maintain ESPN's application-level ping flow

Use bounded socket read timeouts. An early probe blocked until the command timeout because the upgraded TLS socket had no explicit read timeout

## Confirmed live test

The successful test used league `2060277817`, team `6`, and the member ID from the supplied draft page URL

The headless connection received:

```text
HTTP/1.1 101 Switching Protocols
INIT received
```

It then observed live purchases including:

- A.J. Brown to Let Him Cook for $31
- Nico Collins to We Play to Win for $32
- Garrett Wilson to Let Him Cook for $31

This confirmed that `SOLD` contains the team, player, roster slot, and auction cost required by the future draft watcher

## Temporary listener from this investigation

No production watcher was added to the repository

The proof-of-concept files were temporary:

```text
/tmp/espn-draft-listener.py
/tmp/espn-draft-listener.log
/tmp/espn-draft-listener.pid
```

The listener process was stopped after the connection test. The files can still exist until macOS clears `/tmp`, but they are not part of the project

The script was started with `uv run python` and uses only the Python standard library. It performs the REST authentication, opens a raw WebSocket, confirms `INIT`, and logs new `SOLD` events

Do not treat the raw WebSocket implementation as the final architecture. The production Zig implementation should use a maintained WebSocket library if a suitable one is available

## Recommended next implementation steps

1. Parse the supplied ESPN draft page URL
2. Load `espn_s2` and `SWID` from `.env`
3. Fetch `draftInit`
4. Build team and player lookup tables
5. Fetch `draftSecurity`
6. Construct the WebSocket URL without encoding the token delimiters
7. Connect as the only client for the member and team
8. Decode `INIT`, disable ESPN autodraft when the user's `autodraftTypeId` is nonzero, and populate picks, team rosters, and remaining budgets
9. Apply `SOLD`, `ADJUSTED`, `UNDONE`, and `SLOT_CHANGED` updates
10. Batch-resolve missing player IDs from the authenticated fantasy player endpoint
11. Validate turn, player, bid, roster, and budget state before every outgoing action
12. Send `NOMINATE` and `BID` commands when the draft strategy requests them
13. Reconnect with backoff when ESPN closes an unexpected connection
14. Stop cleanly when the draft reaches its completed state

## Reproduction checklist

For a future draft, the user must only:

1. Refresh `espn_s2` and `SWID` in `.env` if they expired
2. Start or join the ESPN practice draft
3. Give the application the current ESPN draft page URL
4. Keep Chrome disconnected after the headless watcher connects

The user does not need to inspect DevTools or copy the WebSocket URL again
