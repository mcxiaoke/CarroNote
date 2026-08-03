# SafeNotes just command runner
# Usage: just <recipe>
#   just --list    # list all recipes
#   just cli-build # build the pure-Dart CLI executable
#
# Recipes are grouped into: deps / build / test.
# Cross-platform: flutter, dart, python, pwsh must be on PATH.

# Force pwsh on Windows so recipes behave identically there; Unix keeps the default shell.
set windows-shell := ["pwsh", "-Command"]

default:
    just --list

# ── Dependencies & maintenance ──────────────────────────────
get: gen-build-info
    flutter pub get

clean:
    flutter clean

# ── Build ───────────────────────────────────────────────────
gen-build-info:
    python scripts/generate_build_info.py

cli-build: gen-build-info
    dart build cli -t bin/safenotes_cli.dart -o build/cli

run: gen-build-info
    flutter run

build-apk: gen-build-info
    flutter build apk --release

build-aab: gen-build-info
    flutter build appbundle --release

build-windows: gen-build-info
    flutter build windows --release

build-linux: gen-build-info
    flutter build linux --release

build-macos: gen-build-info
    flutter build macos --release

apk: gen-build-info
    flutter build apk --debug

exe: gen-build-info
    flutter build windows --debug

all: exe apk

release: gen-build-info
    python scripts/release.py

# ── Test & code quality ─────────────────────────────────────
analyze: gen-build-info
    flutter analyze lib test
    dart analyze packages/core

test: gen-build-info
    dart test packages/core/test
    flutter test

test-core: gen-build-info
    dart test packages/core/test

e2e:
    pwsh scripts/cli-e2e-test.ps1

isort:
    dart run import_sorter:main

format:
    dart format .

valid: isort format analyze
