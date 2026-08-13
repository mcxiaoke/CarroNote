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
get: gen
    flutter pub get

clean:
    flutter clean

# ── Code generation ────────────────────────────────────────
# 所有构建/测试前置的代码生成任务（生成的文件已提交，内容未变化时不重写）。
# 统一用 dart run：CI 有 Flutter 环境就必有 dart，不再依赖 python。
gen: gen-build-info gen-theme-seeds

gen-build-info:
    dart run scripts/generate_build_info.dart

gen-theme-seeds:
    dart run scripts/generate_theme_seeds.dart

# ── Build ───────────────────────────────────────────────────
cli-build: gen
    dart build cli -t bin/safenotes_cli.dart -o build/cli

run: gen
    flutter run

build-apk: gen
    flutter build apk --release

build-aab: gen
    flutter build appbundle --release

build-windows: gen
    flutter build windows --release

build-linux: gen
    flutter build linux --release

build-macos: gen
    flutter build macos --release

apk: gen
    flutter build apk --debug

exe: gen
    flutter build windows --debug

all: exe apk

release: gen
    python scripts/release.py

# ── Test & code quality ─────────────────────────────────────
analyze: gen
    flutter analyze lib test
    dart analyze packages/core

test: gen
    dart test packages/core/test
    flutter test

test-core: gen
    dart test packages/core/test

e2e:
    pwsh scripts/cli-e2e-test.ps1

isort:
    dart run import_sorter:main

format:
    dart format .

valid: isort format analyze
