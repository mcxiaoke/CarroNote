# Safe Notes

> Encrypted, private, local-first note manager — **end-to-end encrypted (E2EE) sync edition**

Safe Notes is a privacy-focused note-taking app: all notes are **encrypted at rest on your device by default** (AES-256-GCM) with no dependency on any third-party cloud.

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

## Architecture Overview

### Layered layout

```
┌──────────────────────────────────────────────┐
│  Flutter Client                              │
│  ├─ UI layer (views / widgets / dialogs)     │
│  ├─ State management Provider (models)       │
│  └─ State assembly / platform injection (main)│
└──────────────┬───────────────────────────────┘
               ▼
┌──────────────────────────────────────────────┐
│  packages/core (pure Dart core, no Flutter)  │
│  ├─ Data layer SQLite (db/database_handler)  │
│  ├─ Crypto layer (crypto/*)                  │
│  ├─ Model layer (models/*)                   │
│  └─ Sync layer SyncEngine (sync/*)           │
│         │ depends on SyncBackend interface   │
└──────────────┬───────────────────────────────┘
               │ SyncBackend (pluggable)
   ┌───────────┼───────────────┬──────────────┐
   ▼           ▼               ▼              ▼
 WebDAV     SafeServer HTTP   Local FS      (extensible)
 (cloud)    (Go / Node.js)   (single-device/test)
```

The core logic (crypto / database / sync engine) lives in a pure Dart package `packages/core` (Flutter dependencies are forbidden and enforced by the pub workspace compiler). The app side only keeps UI and state assembly, importing through the single entry point `package:core/core.dart`. A pure Dart CLI `bin/safenotes_cli.dart` is also provided (read/write the encrypted note database without the Flutter SDK; can be compiled to an AOT native binary — see [CLI Client](#cli-client)).

### App-side directory structure (`lib/`)

| Directory / file | Responsibility |
|------|------|
| `lib/main.dart` | App entry: initializes Provider, database, sync services; injects platform capabilities (db factory / log directory) |
| `lib/app.dart` | `MaterialApp` root, route & theme assembly |
| `lib/authwall.dart` | Auth gate: shows password/biometric login page until unlocked |
| `lib/data/` | App-side preference/config persistence (core DB logic lives in `packages/core`) |
| `lib/models/` | App-side state models: session, app_theme, editor_state, biometric_auth, etc. |
| `lib/routes/` | `route_generator.dart`: route table & navigation |
| `lib/sync/` | App-side sync assembly: `sync_service.dart` (mutex / state broadcast), `sync_config.dart` (configuration) |
| `lib/dialogs/` | Common dialogs: backup import/export, delete confirmation, sign out, etc. |
| `lib/widgets/` | Reusable components: note cards/tiles, search box, drawer, login button, etc. |
| `lib/views/` | Pages: `home`, `add_edit_note`, `note_view`, `deleted_notes`, `change_passphrase`, auth page, settings (incl. sync settings / diagnostics page) |
| `lib/utils/` | App-side utilities: device info, lifecycle, styling, time, password strength, etc. |

### Core package (`packages/core/`)

| Directory / file | Responsibility |
|------|------|
| `lib/core.dart` | Single public export of the core package (unified `import 'package:core/core.dart'`) |
| `lib/src/ports.dart` | Platform capability injection points: PathProvider / KeyValueStore / SecretStore / LogSink |
| `lib/src/crypto/` | Crypto layer: `aes_encryption.dart` (local AES-256-GCM / CBC), `crypto.dart` (PBKDF2 / AES / dataKey wrap-unwrap) |
| `lib/src/db/` | `database_handler.dart`: SQLite CRUD (`dbFactoryOverride` / `dbPathOverride` injection) |
| `lib/src/models/` | Data models: `safenote`, `parse_import` |
| `lib/src/logger/` | Unified logging: `app_logger.dart` (`logDirResolverOverride` injection), `log_webserver.dart` |
| `lib/src/sync/` | Sync core (see below) |

### Sync subsystem (`packages/core/lib/src/sync/`)

| File | Responsibility |
|------|------|
| `crypto.dart` | **Key core**: PBKDF2-HMAC-SHA256 derives MK (600k iterations), AES-256-GCM, dataKey wrap / unwrap |
| `keyring.dart` | Keyring management: vault_id, salt, manifest version, password change, multi-device re-auth coordination |
| `sync_models.dart` | Remote manifest / item data models (hash, deleted, updatedAt) |
| `sync_backend.dart` | **SyncBackend abstraction**: `getManifest / putManifest / getBlob / putBlob` |
| `sync_engine.dart` | Sync engine: 5-step flow, manifest diff, LWW conflicts, optimistic-lock retry |
| `journal.dart` | Sync event log (cross-process resumption, crash self-healing) |
| `backends/local_fs_backend.dart` | Backend impl: local filesystem (single-device / test) |
| `backends/webdav_backend.dart` | Backend impl: WebDAV (Jianguoyun / NextCloud, RFC4918 `If-Match` optimistic locking) |
| `backends/safe_server_backend.dart` | Backend impl: self-hosted SafeServer HTTP (Bearer Token + ETag) |

### Crypto & keys (two-layer architecture)

```
Password layer (changes on password change)
  MK = PBKDF2-HMAC-SHA256(password, salt, 600k)
  MK only encrypts the dataKey, never the notes themselves
        ↓ encrypt
Data layer (never changes; the key that actually encrypts notes)
  dataKey = random 32 bytes (generated on first sync enablement)
  encryptedDataKey = AES-GCM(MK, dataKey)  ← stored in manifest, synced with versions
        ↓ encrypts each note
Note layer
  envelope = AES-256-GCM(dataKey, nonce, AAD=note_id, content)
```

**Key design decisions**
- `dataKey` never changes → changing the password only re-wraps the 32-byte dataKey with the new MK (O(1), a single atomic manifest PUT), no need to re-encrypt all notes
- `encryptedDataKey` is synced with the manifest, so no separate keystore sync layer is needed, avoiding multi-key conflicts
- Envelope nonces are random; AAD binds the note id to prevent replay

### Sync flow (5 steps)

1. `GET /manifest` → pull the remote manifest ciphertext and decrypt it with MK
2. Diff local vs. remote manifest (upload / download / conflict / skip)
3. Perform transfers: upload new blobs / download remote blobs / LWW loser marked deleted or overwritten
4. Produce a merged manifest (version = remote + 1)
5. `PUT /manifest` (with `If-Match` optimistic lock) → 200 on success; on 412 conflict, loop back to step 1 and retry (max 3 times)

Conflicts use **LWW (Last-Write-Wins)**; optimistic locking only happens at the manifest layer (one PUT). Blobs referenced by old hashes are not deleted immediately, so they can be restored as historical versions.

### Sync server (`server/`)

This fork ships a SafeServer reference implementation, **protocol version v2.2**, with Go and Node.js implementations that are **protocol-identical and interchangeable**. The `server/` directory is excluded by `.gitignore` and intended for local testing and reference only.

- `server/go/`: Go 1.21+, **standard library only**
- `server/nodejs/`: JavaScript (ESM), **built-in modules only**

The server follows a **zero-knowledge** principle: it only handles ciphertext — no content parsing, no hash computation, no version counters. It implements optimistic locking via ETag (`SHA-256(ciphertext)`), atomic writes (`tmp + fsync + rename`) against TOCTOU, plus Bearer Token auth, rate limiting, path-traversal protection, and graceful shutdown. The storage layer is abstracted behind `Storage + Vault` interfaces and can be swapped for SQLite or object storage.

> Note: the WebDAV backend requires **zero server-side development** — just use your own cloud drive (Jianguoyun / NextCloud). SafeServer is only worth self-hosting when you need multi-user, push notifications, rate limiting, and other advanced capabilities.

---

## CLI Client

A **second frontend** for the core logic (the app is the first): pure Dart, no Flutter SDK needed, reads and writes the encrypted note database directly. It is the primary tool for **real-flow testing** (multi-directory multi-device sync, key migration, conflicts, password changes, etc.). Pass `--data-dir` to designate a data directory as **one device instance**; use two directories to simulate two devices syncing.

```bash
# Compile to an AOT native binary (no build-hooks noise, ~58x faster than dart run; distribute the whole bundle)
make cli-build        # = task cli-build = just cli-build
                      # Output: build/cli/bundle/bin/safenotes_cli.exe + bundle/lib/sqlite3.dll

# Common commands (run directly once the binary is on PATH)
safenotes_cli.exe --data-dir temp/dev-a --password P keyring init
safenotes_cli.exe --data-dir temp/dev-a --password P note add --title Title --body Body
safenotes_cli.exe --data-dir temp/dev-a --password P note list
safenotes_cli.exe --data-dir temp/dev-a --password P sync setup --type localfs --path temp/vault
safenotes_cli.exe --data-dir temp/dev-a --password P sync run
safenotes_cli.exe --data-dir temp/dev-a --password P export --out backup.json
safenotes_cli.exe --data-dir temp/dev-a --password P db info
```

Command groups: `db` (info / wipe), `keyring` (init / unlock / status / verify / change-password),
`note` (add / list / get / update / delete / restore / hard-delete / purge-deleted),
`export` / `import`, `sync` (setup / run / repair / status), `log` / `journal`, `meta`.
Exit-code convention: `0` success, `1` user-anticipated error, `2` abnormal crash. Full documentation in
`docs/cli-client-design.md`; end-to-end tests in [Testing](#testing) under `e2e`.

---

## Logging System

Safe Notes ships an **app-wide unified logging system** covering all important business operations and uncaught exceptions, enabled equally on desktop (Windows / macOS / Linux) and mobile (Android / iOS). The log core lives in `packages/core/lib/src/logger/`; the platform directory is injected by the app side via `logDirResolverOverride`.

### Core design
- **Unified entry points**: `Log.app` / `Log.note` / `Log.db` / `Log.auth` / `Log.sync` / `Log.backup` / `Log.settings` / `Log.crypto` / `Log.web` / `Log.ui` — ten leveled log categories (trace / debug / info / warn / error / fatal).
- **Three output sinks**: ① `console` during debugging; ② an in-memory ring buffer (debug panel / real-time log web server); ③ date-rotated log files (`safenotes-YYYYMMDD.log`, retained 7 days).
- **All platforms**: desktop logs land in `logs/` next to the executable; mobile logs in the app-private data directory `logs/`.

### Coverage
- Note create / edit / delete / restore / permanent delete (including uuid and content hash for locating specific notes)
- Database create / upgrade / migration / re-encryption / deletion
- Login / logout / password change / biometric auth
- Backup import / export
- All sync engine actions (upload / download / delete / conflict / migration / repair)
- **All uncaught `Exception` / `Error`** (global fallback via `FlutterError.onError` / `PlatformDispatcher.onError` / `runZonedGuarded` in `main.dart`)

### Log web server
Starts automatically when entering the home page and provides a real-time log viewer in the browser; stops on app exit. Default at `http://127.0.0.1:8888/`.

---

## Tech Stack

- **Framework**: Flutter ≥ 3.44.0 / Dart ≥ 3.12
- **Core package**: `packages/core` (pure Dart, pub workspace, Flutter dependencies forbidden — enforced by the compiler)
- **Local storage**: `sqflite` (mobile), `sqflite_common_ffi` (desktop / tests / CLI)
- **Secure storage**: `flutter_secure_storage` (passphrase / MK cached in the OS keychain)
- **Crypto**: `cryptography` + `cryptography_flutter` (AES-256-GCM / PBKDF2, hardware accelerated), `crypto` (SHA-256 content hash)
- **Networking**: `http` (WebDAV client)
- **State management**: `provider`
- **Biometrics**: `local_auth`; **i18n**: `easy_localization`
- **CLI parsing**: `args` (CommandRunner); **task management**: `make` / `task` / `just` (three equivalent)
- **Sync server**: Go (standard library) / Node.js (built-in modules)

---

## Build & Run

**Task management**: `make` (Makefile), `task` (Taskfile.yml), and `just` (justfile) are **fully equivalent**,
organized into dependency / build / test groups. All provide `get`, `clean`, `run`, `cli-build`, `build-*`, `test`,
`test-core`, `analyze`, `e2e`, etc. On Windows `make` is usually not on PATH, so `task` or `just` is recommended
(`task --list` / `just --list` shows all tasks).

```bash
# Install dependencies
make get              # = task get = just get (auto-injects the latest build info)

# Debug run
make run              # = task run = just run

# Build the CLI client (AOT native binary; see "CLI Client")
make cli-build

# Build Android release packages
make build-apk        # APK (release)
make build-aab        # AppBundle (release)

# Desktop (Windows / macOS / Linux, uses sqflite_common_ffi)
flutter config --enable-<platform>-desktop
make build-windows / build-linux / build-macos
flutter run -d <platform>

# List all tasks
task --list
just --list
```

> On first launch you must set a master password; notes are encrypted locally before being written to SQLite. To enable sync, configure a backend under "Settings → Sync".

---

## Build Info Injection (Version / Git / Build Time)

Every build injects the **Git commit hash, branch, tag, working-tree dirtiness, cumulative commit count** and the **build time** into the app, then prints a version report on startup to help reproduce issues and trace back to the exact build.

Implementation: before building, `scripts/generate_build_info.py` generates `lib/utils/build_info.dart` (compile-time constants, zero runtime overhead); `_initLogging()` in `lib/main.dart` reads and prints it at startup.

**Always build via `make` targets** (they auto-inject the latest build info first; `task` / `just` behave the same):

```bash
make run            # Debug run (auto-injected)
make build-apk      # Android APK (release)
make build-aab      # Android AppBundle (release)
make build-windows  # Windows desktop (release)
make build-linux    # Linux desktop (release)
make build-macos    # macOS desktop (release)
make release        # Release packaging (multi-ABI split + AppBundle; injects latest info first)
```

> If you run `flutter run` / `flutter build` directly, the **previously generated** values in `lib/utils/build_info.dart` are reused (the file always exists and compiles fine; the info may just be stale). Use the `make` targets above for fresh metadata.

**Generate / refresh build info manually:**

```bash
make gen-build-info
# or
python scripts/generate_build_info.py
```

`BuildInfo` exposes: `version` / `buildNumber` / `versionString` / `gitHash` / `gitHashShort` / `gitBranch` / `gitTag` / `gitCommitCount` / `gitDirty` / `buildDate`(UTC) / `buildDateReadable`, plus convenience getters `summary` (one line) and `detail` (multi-line, usable in an About/Debug panel).

Startup log example:

```
════════ SafeNotes startup ════════
Version: 2.3.0 (build 10)
Git: 0a4d888 @ sync-refact-dev (uncommitted changes in workspace)
Commit: 0a4d888c82a636d3394d6b6c939c61e2adfe4b7d
Tag: v2.3.0-188-g0a4d888 (cumulative commits 608)
Build time: 2026-08-02 12:21:18 (UTC 2026-08-02T04:21:18Z)
Platform: windows Microsoft Windows [Version 10.0.22631.0]
Dart: 3.44.8
```

---

## Testing

The core logic is a pure Dart package, so **core tests run without the Flutter SDK**; app-side tests need Flutter.

```bash
# Run all tests (core + app)
make test                # = task test = just test; dart test packages/core/test + flutter test

# Core package tests only (pure Dart, no Flutter SDK required)
make test-core           # dart test packages/core/test
dart test packages/core/test/sync/crypto_test.dart    # crypto only
dart test packages/core/test/sync                # sync engine / multi-device / long-running only

# CLI end-to-end tests (requires `make cli-build` first; the script prefers the compiled binary)
make e2e                 # = task e2e = just e2e

# App-side tests (requires Flutter)
flutter test
```

**Sync integration tests** (`packages/core/test/sync/safe_server_integration_test.dart`) need a running SafeServer:
- Default uses the **Go** implementation (the test `setUpAll` auto-builds the `server/go` binary and starts it)
- Switch to the **Node.js** implementation: run `flutter test` with `$env:SN_SERVER="node"` (PowerShell)
- Coverage: first sync, new-device sync, incremental sync, LWW conflicts, tombstone sync, idempotency, HTTP protocol (404 / 401 / 412 / ETag), v2.2 resource layer, rate limiting
- Cleanup script: `test/scripts/test-cleanup.ps1` (kills leftover processes + cleans temp files)

---

## Documentation

Detailed design, protocol specs, and review records live in the `docs/` directory:
- `docs/server-api-spec.md`: server HTTP API spec (endpoints, ETag, auth)
- `docs/simplified-sync-design.md` / `docs/sync-feature-design.md`: sync architecture design
- `docs/server-implementation.md` / `docs/server-backup-design.md`: SafeServer implementation docs
- `docs/manifest-reliability-design.md` / `docs/spec-manifest.md` / `docs/spec-blob.md` / `docs/spec-journal.md`: manifest / blob / journal spec details
- `docs/cli-client-design.md`: CLI client design (command tree / acceptance checklist / implementation notes)
- `docs/crypto-overview-20260810.md`: crypto layer overview
- `docs/backup-encryption-design-20260810.md`: backup encryption design
- `docs/CHANGES-YYYYMMDD.md`: daily change logs (archived by date)

---

## Main Differences from Upstream

| Dimension | Upstream | This fork |
|------|------|---------|
| Sync | None (local-only) | Complete E2EE multi-device sync subsystem |
| Server | None | Go / Node.js SafeServer v2.2 reference implementations |
| Crypto | Local AES encryption | Local encryption + sync-layer MK + dataKey two-layer key hierarchy |
| Core layering | Mixed with UI | Core logic extracted into pure Dart package `packages/core` (no Flutter dependency; independently drivable by CLI / tests) |
| Testing | Basic widget tests | New crypto vectors, SyncEngine, multi-device / chaos / integration tests (core tests run without the Flutter SDK) |
| Settings page | Basic | Added sync settings, sync diagnostics page, recently deleted |

---

## License

GPL-3.0-or-later. © Keshav Priyadarshi and others. See `LICENSE`, `AUTHORS.md`, `SECURITY.md`.
