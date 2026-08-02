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

clean:
	@echo "-> Delete the build/ and .dart_tool/ directories"
	flutter clean

# Generate build info (Git commit hash + build time) and inject it into lib/utils/build_info.dart
gen-build-info:
	@echo "-> Generate build info (git hash + build time)"
	python scripts/generate_build_info.py

get: gen-build-info
	@echo "-> Get the current package's dependencies"
	flutter pub get

analyze: gen-build-info
	@echo "-> Analyze the code for linting errors (app + core)"
	flutter analyze lib test
	dart analyze packages/core

isort:
	@echo "-> Apply import_sorter to ensure proper imports ordering"
	dart run import_sorter:main

format:
	@echo "-> Fix formatting issues in the code"
	dart format .

valid: isort format check analyze

test: gen-build-info
	@echo "-> Run all tests (core via dart test + app via flutter test)"
	dart test packages/core/test
	flutter test

# 只跑核心纯 Dart 测试：秒级反馈，CI 里不需要 Flutter SDK
test-core: gen-build-info
	@echo "-> Run core (pure Dart) tests only"
	dart test packages/core/test

# ── One-click run / build (auto-inject build info first) ──────────────────────
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

# ── Debug builds (Windows + Android by default) ──────────────────────────────
apk: gen-build-info
	@echo "-> Build Android APK (debug)"
	flutter build apk --debug

exe: gen-build-info
	@echo "-> Build Windows executable (debug)"
	flutter build windows --debug

all: exe apk
	@echo "-> Windows + Android debug builds completed"

# Release packaging (multi-ABI split + AppBundle), inject latest build info first
release: gen-build-info
	@echo "-> Run the release packaging script"
	python scripts/release.py

.PHONY: clean get check test isort format valid gen-build-info run build-apk build-aab build-windows build-linux build-macos release apk exe all