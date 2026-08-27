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
