# Safe Notes

> Encrypted, private, local-first note manager — **end-to-end encrypted (E2EE) sync edition**

Safe Notes is a privacy-focused note-taking app: all notes are **encrypted at rest on your device by default** (AES-256-GCM), with no dependency on any third-party cloud.

This project is a fork of the upstream [keshav-space/safenotes](https://github.com/keshav-space/safenotes) with extensive modifications. The centerpiece is a **complete end-to-end encrypted multi-device sync subsystem**: a client-side `SyncEngine` + a pluggable backend abstraction (WebDAV / self-hosted HTTP service / local filesystem), accompanied by two reference server implementations (SafeServer) in **Go and Node.js**.

> [!IMPORTANT]
> Security & responsibility: no matter how strong the encryption, you must **remember your master passphrase**. The passphrase lives only in your head — nobody can recover it for you.

---

## Features

**Core capabilities (inherited from upstream)**
- Local AES-256 encrypted storage; notes never touch disk in plaintext
- Biometric unlock (fingerprint / face)
- Android background snapshot protection, stealth keyboard, screenshot protection
- Brute-force protection, inactivity auto-lock guard
- Arctic Nord light/dark theme, list/grid views, colored notes
- Encrypted backup export/import (seamless migration to a new device)

**New capabilities (this fork)**
- End-to-end encrypted sync: **MK + dataKey two-layer key hierarchy**, password change in O(1), atomic
- Backend-agnostic: WebDAV (Jianguoyun / NextCloud / self-hosted), self-hosted SafeServer HTTP, or local filesystem
- Content-addressable (content hash) storage with natural deduplication; soft-delete / tombstone sync
- Multi-device sync + LWW conflict resolution + historical version retention
- Sync diagnostics page, sync status visualization

---

## Project Structure

```
lib/               Flutter client: UI, state assembly, platform injection (entry: lib/main.dart)
packages/core/     Pure-Dart core package: crypto, SQLite DB, models, SyncEngine (no Flutter dependency)
bin/               Pure-Dart CLI client: reads/writes the encrypted DB without the Flutter SDK
server/            SafeServer reference implementations in Go and Node.js (excluded by .gitignore)
docs/              Design docs, protocol specs, and the developer guide
test/              App-side and integration tests
```

The core logic (crypto / database / sync engine) lives in a pure Dart package `packages/core` (Flutter dependencies are forbidden and enforced by the pub workspace compiler). The app side only keeps UI and state assembly, importing through the single entry point `package:core/core.dart`. A pure Dart CLI `bin/safenotes_cli.dart` is also provided (read/write the encrypted note database without the Flutter SDK; can be compiled to an AOT native binary).

---

## Documentation

- **Developer guide** — code structure, build, and testing workflow: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
- Detailed design, protocol specs, and daily change logs live in the `docs/` directory (see `docs/DEVELOPMENT.md` for an index).

---

## License

GPL-3.0-or-later. © Keshav Priyadarshi and others. See `LICENSE`, `AUTHORS.md`, `SECURITY.md`.
