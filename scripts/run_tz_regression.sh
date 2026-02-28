#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/timewarrior_tz_regression.lua"

TIMEZONES=(
  "UTC"
  "Europe/Berlin"
  "America/New_York"
  "Asia/Tokyo"
  "Pacific/Auckland"
)

for tz in "${TIMEZONES[@]}"; do
  echo "== Running timezone regression with TZ=$tz =="
  TZ="$tz" nvim --headless -u NONE -l "$SCRIPT"
  echo
 done

echo "All timezone regression checks passed"
