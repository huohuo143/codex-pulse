#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"
case "$MODE" in mac|ipad|harmony|all) ;; *) echo "usage: $0 [mac|ipad|harmony|all]" >&2; exit 2 ;; esac
if [[ "$MODE" == mac || "$MODE" == all ]]; then
  swift test --package-path "$ROOT_DIR" --build-system native -j 2 \
    --scratch-path "${CODEX_PULSE_RESET_TEST_SCRATCH_PATH:-/tmp/codex-pulse-reset-regression}" \
    --filter 'Tibo|QuotaResetCompletion|CodexRadar|WidgetSnapshot|MobileSnapshot|MobileDetail|DashboardRadarRecovery'
fi
if [[ "$MODE" == ipad || "$MODE" == all ]]; then
  swift test --package-path "$ROOT_DIR/mobile" --build-system native -j 2 \
    --scratch-path "${CODEX_PULSE_MOBILE_TEST_SCRATCH_PATH:-/tmp/codex-pulse-mobile-reset-regression}"
  python3 "$ROOT_DIR/mobile/apple/scripts/tests/test_renewal_source.py"
fi
if [[ "$MODE" == harmony || "$MODE" == all ]]; then
  NODE="${PULSE_HARMONY_NODE:-/Applications/DevEco-Studio.app/Contents/tools/node/bin/node}"
  for test in reset_arrival_test.cjs radar_test.cjs history_chart_test.cjs dashboard_math_test.mjs; do
    "$NODE" "$ROOT_DIR/mobile/harmony/tests/$test"
  done
fi
echo "Reset behavior checks passed: $MODE"
