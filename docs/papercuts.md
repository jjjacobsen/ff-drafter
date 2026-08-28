# Papercuts

## 2026-08-26: WebSocket probe blocked until socket timeout was explicit

A raw ESPN WebSocket probe in the repository stayed open and exhausted the command timeout because the TLS socket did not have a bounded read after the upgrade. Setting `sock.settimeout(10)` and stopping after the first `INIT` or `ERROR` message made the probe deterministic

## 2026-08-26: Zig 0.16 `std.http` did not emit privileged headers

ESPN returned `401` even though the `Cookie` header was supplied through `FetchOptions.privileged_headers`. Zig 0.16 stores privileged headers on the request and removes them after cross-origin redirects, but `Request.sendHead` only emits `extra_headers`. Sending the cookie as an extra header for direct requests to the authenticated ESPN host unblocked the REST client

## 2026-08-26: ESPN rejected lowercase WebSocket header names

`websocket.zig` sent the standard WebSocket request headers in lowercase and ESPN returned HTTP 400. The same request returned HTTP 101 when `Upgrade`, `Connection`, `Sec-WebSocket-Version`, and `Sec-WebSocket-Key` used standard capitalization. Vendoring the library and changing those four literals unblocked the Zig client

## 2026-08-26: Concurrent TLS close invalidated a WebSocket read

Closing `websocket.Client` from the UI thread while the worker was reading caused a segmentation fault inside the Zig TLS reader. Keeping all WebSocket operations on the worker and waiting for its bounded 500 ms read before shutdown removed the race

## 2026-08-26: A scripted pseudo-terminal did not answer Vaxis status queries

The macOS `script` command provides a pseudo-terminal but not a terminal emulator. Vaxis shutdown waited for its input reader after sending a device status query. Sending a device status response through the pseudo-terminal input allowed headless navigation validation to finish cleanly

## 2026-08-27: Uploaded ESPN team logos require authentication

Team logos from `mystique-api.fantasy.espn.com` returned HTTP 401 while custom and vector logo hosts were public. Sending the same ESPN cookies used for league data to the Mystique API unblocked uploaded team logos

## 2026-08-27: Vaxis bordered child dimensions exclude the border

`Window.child` returns the inner window after it draws a border. The seven-row team box therefore had only five usable rows, and writing the budget to row five was clipped. Increasing the outer box to eight rows provided the required six inner rows

## 2026-08-27: Vaxis retains grapheme slices until render

`Window.printSegment` stores slices into the supplied text instead of copying them. Formatted values held in function-local stack buffers became invalid before `Vaxis.render`, which produced corrupted budgets, prices, and clocks. A frame-scoped arena now keeps all formatted text valid through rendering

## 2026-08-27: Zig 0.16 removed `std.fs.File.stdout`

A temporary clock-format validation failed because the old stdout API no longer exists. Using `std.debug.print` confirmed that unsigned seconds format as `0:04` and `0:11`

## 2026-08-27: Ended ESPN draft league data returned 404

The previous league URL stopped exposing `draftInit` after the draft ended, so its roster configuration could not be inspected. A new live league confirmed 15 draftable roster slots per team: nine starters and six bench slots, with two IR slots excluded from the auction roster

## 2026-08-27: `SOLD` slot IDs can be player position IDs

Live purchases updated team budgets but some players did not appear in the roster table. The `SOLD` slot matched ESPN player position IDs for affected positions instead of configured lineup slot IDs, such as WR position `3` versus WR lineup slot `4`. Resolving each purchase into the first compatible open starter, flex, or bench slot prevents roster entries from becoming invisible

## 2026-08-27: Reconnect roster item slot IDs also require normalization

The `INIT` snapshot's draft roster items appeared to provide authoritative lineup slots, but a live reconnect showed the same missing players as the raw pick slots. Loading omitted drafted players before applying `INIT`, then running every snapshot purchase through the live purchase slot resolver, made reconnect and live updates use the same assignment behavior

## 2026-08-27: Zig rejected runtime control flow in an inline enum loop

The optimizer used `inline for` over enum tags and then used runtime conditions with `continue`. Zig reported `comptime control flow inside runtime block`. Changing both loops to normal `for` loops kept the enum iteration and allowed runtime filtering

## 2026-08-27: Zig could not infer mutually recursive error sets

The optimizer's roster search has two functions that recursively call each other. Zig reported an error-set dependency loop when both used inferred error sets. Declaring `anyerror!void` on both recursive functions broke the inference loop

## 2026-08-27: Combinatorial roster planning froze the live worker

Live process PID 75403 stayed at 100% CPU for minutes. A macOS sample showed the network worker recursively trapped in `optimizer.Search.allocatePlan` inside `refreshRecommendation` while it held the state mutex, so `q` and escape waited forever for worker shutdown. Replacing budget and position-plan enumeration with two bounded rectangular Hungarian assignments removed the recursive search. Each solve is now `O(S²C)` for `S` slots and `C` retained candidates

## 2026-08-27: Automation could act before applying a queued draft update

The first automation loop evaluated stored state before reading the next WebSocket frame. A queued `BID`, `CLOCK`, or `SOLD` could therefore invalidate an action immediately before it was sent. Running automation only after a bounded socket read returns with no message ensures all already-queued updates are applied first

## 2026-08-27: ESPN autodraft competed with optimizer bidding

The autonomous controller joined the room but left ESPN autodraft unchanged. ESPN could therefore bid for the user's team above the optimizer maximum while the application correctly displayed a lower limit. Reading `autodraftTypeId` from `INIT` and sending `AUTODRAFT false` when it is nonzero leaves only the optimizer in control

## 2026-08-27: A rejected draft command caused a reconnect storm

The message handler treated every ESPN `ERROR` as a broken socket. A rejected command therefore closed a healthy connection, rejoined, repeated the command, and failed again. Treating `ERROR` as a command-level failure keeps the socket open, stops automation, and shows ESPN's complete response without reconnecting

## 2026-08-27: ESPN rejected commands without a trailing newline

The browser bundle's WebSocket transport appends `\n` to every command before sending it. The controller included the newline on `PING` but omitted it from `AUTODRAFT`, `BID`, and `NOMINATE`, which caused `ERROR 1 Invalid arguments for command`. Adding the newline inside each WebSocket text frame made the commands match ESPN's browser protocol

## 2026-08-27: `INIT` includes transport padding after the Base64 payload

A read-only snapshot probe saved the complete text after the `INIT` command and the Base64 decoder returned `InvalidPadding`. ESPN had appended a space and `#` transport padding after the Base64 value. Decoding only the first whitespace-delimited field matched the production message parser and unblocked snapshot inspection

## 2026-08-27: Starter-only VORP concentrated the complete auction budget

A live draft recommended `$94` for Jahmyr Gibbs and `$87` for Bijan Robinson. A read-only calculation from the live ESPN catalog reproduced the optimizer exactly: `$1,850` discretionary dollars were spread across only 90 starters with `3,124.9` total VORP, so Gibbs received `$94`. The assignment and projection parsing were correct. A bench-aware expected player pool increased total VORP to `7,287.2` and reduced Gibbs to `$57`

## 2026-08-27: Zig 0.16 moved current-directory file reads to the I/O API

A temporary live-catalog optimizer test used the old `std.fs.cwd().readFileAlloc` API and failed to compile. Zig 0.16 uses `std.Io.Dir.cwd().readFileAlloc` with an explicit `std.Io`. The independent live-data calculation and normal project build were sufficient, so the temporary test was removed

## 2026-08-27: The INIT decoder discarded the active nomination team

The decoded draft block restored its clock but discarded the integer between the expiration time and player ID. This is the nomination team ID. Retaining it lets autonomous nomination resume when the application joins during the user's nomination turn

## 2026-08-27: Artwork requests blocked the draft command worker

Team logos loaded before the WebSocket connection, and nominated-player artwork loaded on the WebSocket worker. A slow image host could delay a mid-draft connection or consume the final bidding seconds. A separate artwork worker now loads all optional images without blocking state updates or draft commands
