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
