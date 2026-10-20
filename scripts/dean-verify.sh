#!/bin/bash
# Local mirror of upstream CI's analyzer-and-tests job (.github/workflows/ci.yml).
# Dean's branch only. Usage: scripts/dean-verify.sh [--skip-tests]
set -u
export PATH=/opt/homebrew/bin:$PATH
cd "$(dirname "$0")/.."

step() { echo; echo "### $* ($(date +%H:%M:%S))"; }

step "flutter pub get"
flutter pub get || exit 1

step "build_runner (app)"
dart run build_runner build --delete-conflicting-outputs || exit 1

for dir in packages/*; do
  if [ -f "$dir/pubspec.yaml" ] && grep -q '^  build_runner:' "$dir/pubspec.yaml"; then
    step "build_runner ($dir)"
    (cd "$dir" && dart run build_runner build --delete-conflicting-outputs) || exit 1
  fi
done

step "platform UI lint (vs upstream/main)"
dart tool/platform_ui_lint.dart --base-ref upstream/main || exit 1

step "ARB validators"
dart run tool/validate_arb_locales.dart || exit 1
dart run tool/verify_arb_descriptions.dart || exit 1

step "package boundaries"
dart run tool/check_package_boundaries.dart || exit 1

step "flutter analyze"
flutter analyze --no-fatal-warnings --no-fatal-infos || exit 1

if [ "${1:-}" != "--skip-tests" ]; then
  step "test shards"
  dart run tool/run_test_shards.dart || exit 1
fi

step "done"
