#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-mac}"
case "$MODE" in mac|shared|all) ;; *) echo "usage: $0 [mac|shared|all]" >&2; exit 2 ;; esac
if [[ "$MODE" == mac || "$MODE" == all ]]; then
  swift test --package-path "$ROOT_DIR" --build-system native -j 2 \
    --scratch-path "${CODEX_PULSE_RESET_TEST_SCRATCH_PATH:-/tmp/codex-pulse-reset-regression}" \
    --filter 'Tibo|QuotaResetCompletion|CodexRadar|WidgetSnapshot|MobileSnapshot|MobileDetail|DashboardRadarRecovery'
fi
if [[ "$MODE" == shared || "$MODE" == all ]]; then
  swift test --package-path "$ROOT_DIR/mobile" --build-system native -j 2 \
    --scratch-path "${CODEX_PULSE_MOBILE_TEST_SCRATCH_PATH:-/tmp/codex-pulse-mobile-reset-regression}"
fi
echo "Reset behavior checks passed: $MODE"
