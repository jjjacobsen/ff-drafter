# Papercuts

## 2026-08-26: WebSocket probe blocked until socket timeout was explicit

A raw ESPN WebSocket probe in the repository stayed open and exhausted the command timeout because the TLS socket did not have a bounded read after the upgrade. Setting `sock.settimeout(10)` and stopping after the first `INIT` or `ERROR` message made the probe deterministic
