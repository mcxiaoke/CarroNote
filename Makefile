#
# Copyright (C) Keshav Priyadarshi and others - All Rights Reserved.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# You may use, distribute and modify this code under the
# terms of the GPL-3.0+ license.
#
# You should have received a copy of the GNU General Public License v3.0 with
# this file. If not, please visit https://www.gnu.org/licenses/gpl-3.0.html
#
# See https://safenotes.dev for support or download.
#
# SafeNotes tasks, grouped into: deps / build / test.
# Cross-platform: flutter, dart, python, pwsh must be on PATH.
# On Windows prefer `task` (Taskfile.yml) or `just` (justfile) over make.

# ─────────────────────────────────────────────────────────────
# Dependencies & maintenance
# ─────────────────────────────────────────────────────────────

get: gen-build-info
	@echo "-> Fetch the current package's dependencies"
	flutter pub get

clean:
	@echo "-> Delete the build/ and .dart_tool/ directories"
	flutter clean

# ─────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────

# Generate build info (Git commit hash + build time) and inject it into lib/utils/build_info.dart
gen-build-info:
	@echo "-> Generate build info (git hash + build time)"
	dart run scripts/generate_build_info.dart

# Build the pure-Dart CLI as an AOT bundle (exe + sqlite3.dll). Requires a recent
# Dart SDK: `dart compile exe` cannot run build hooks (sqlite3), so use `dart build cli`.
cli-build: gen-build-info
	@echo "-> Build the pure-Dart CLI (AOT bundle)"
	dart build cli -t bin/safenotes_cli.dart -o build/cli

run: gen-build-info
	@echo "-> Run the app (debug)"
	flutter run

build-apk: gen-build-info
	@echo "-> Build Android APK (release)"
	flutter build apk --release

build-aab: gen-build-info
	@echo "-> Build Android AppBundle (release)"
	flutter build appbundle --release

build-windows: gen-build-info
	@echo "-> Build Windows desktop (release)"
	flutter build windows --release

build-linux: gen-build-info
	@echo "-> Build Linux desktop (release)"
	flutter build linux --release

build-macos: gen-build-info
	@echo "-> Build macOS desktop (release)"
	flutter build macos --release

apk: gen-build-info
	@echo "-> Build Android APK (debug)"
	flutter build apk --debug

exe: gen-build-info
	@echo "-> Build Windows executable (debug)"
	flutter build windows --debug

all: exe build-windows apk build-apk
	@echo "-> Windows + Android debug builds completed"

# Release packaging (multi-ABI split + AppBundle), inject latest build info first
release: gen-build-info
	@echo "-> Run the release packaging script"
	python scripts/release.py

# ─────────────────────────────────────────────────────────────
# Test & code quality
# ─────────────────────────────────────────────────────────────

analyze: gen-build-info
	@echo "-> Analyze the code for linting errors (app + core)"
	flutter analyze lib test
	dart analyze packages/core

# All tests: core (pure Dart) + app (Flutter)
test: gen-build-info
	@echo "-> Run all tests (core via dart test + app via flutter test)"
	dart test packages/core/test
	flutter test

# Core (pure Dart) tests only: fast feedback, no Flutter SDK needed in CI
test-core: gen-build-info
	@echo "-> Run core (pure Dart) tests only"
	dart test packages/core/test

# CLI end-to-end test script (needs a CLI build first: `make cli-build`)
e2e:
	@echo "-> Run the CLI end-to-end test script"
	pwsh scripts/cli-e2e-test.ps1

isort:
	@echo "-> Apply import_sorter to ensure proper imports ordering"
	dart run import_sorter:main

format:
	@echo "-> Fix formatting issues in the code"
	dart format .

valid: isort format analyze
	@echo "-> Code quality gates passed"

.PHONY: clean get gen-build-info cli-build run build-apk build-aab build-windows build-linux build-macos release apk exe all analyze test test-core e2e isort format valid
