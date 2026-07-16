---
name: codex-balance-dashboard
description: Use when installing, running, packaging, troubleshooting, or customizing the native macOS Codex balance floating dashboard that reads local ~/.codex/sessions token_count logs.
---

# 算力码表 Dashboard

Help users install, run, package, troubleshoot, or customize the native macOS Codex balance floating dashboard.

## Guardrails

- Treat `~/.codex/sessions` as private user data.
- Never upload, paste, or summarize raw session logs unless the user explicitly asks and understands the privacy impact.
- Prefer read-only checks. The app and scripts should not write to `~/.codex`.
- The app may write small aggregated device usage snapshots to iCloud Drive; do not copy raw Codex logs there.
- Keep the compact window visually simple: show the 7-day balance plus rolling 24-hour token/cost data.
- Never write legacy `*-codex.json` files; v2 writes schema 4 `*-codex-v2.json` only.

## Common Workflows

### Check Environment

Run:

```bash
./skills/codex-balance-dashboard/scripts/check-environment.sh
```

This checks Swift availability and whether the Codex sessions directory exists.

### Build And Launch

Run from the repository root:

```bash
./script/build_and_run.sh
```

It builds the Swift package, creates `dist/Codex算力码表.app`, and opens the app.

### Custom Codex Home

If Codex data lives somewhere else:

```bash
CODEX_HOME=/path/to/.codex ./script/build_and_run.sh
```

### Run Tests

```bash
swift test
```

Tests cover JSONL parsing, model/cached-token accounting, rolling 24-hour boundaries, pricing, exchange-rate fallback, and iCloud schemas.

### Two Mac Usage Sync

The app syncs aggregated JSON snapshots through:

```bash
~/Library/Mobile Documents/com~apple~CloudDocs/算力码表/设备统计
```

Schema 2/3 files are read-only compatibility inputs. Schema 4 output uses `<device>-codex-v2.json` and includes per-model hourly buckets, never currency results.

Override device detection when needed:

```bash
CODEX_BALANCE_DEVICE_ID=macbook-pro ./script/build_and_run.sh
CODEX_BALANCE_DEVICE_ID=mac-studio ./script/build_and_run.sh
```

### Package Release DMG

```bash
./script/package_release.sh
```

## App Structure

- `Sources/CodexBalanceCore`: read-only JSONL scanning, rate limit parsing, reset countdown formatting, token stats.
- `Sources/CodexBalance`: SwiftUI/AppKit floating window UI.
- `script/build_and_run.sh`: local release app bundling and launch.

## Troubleshooting

- If no data appears, verify `~/.codex/sessions` exists and contains `.jsonl` files.
- If another Mac is missing, open Codex算力码表 once on that Mac and verify iCloud Drive is syncing `算力码表/设备统计`.
- If percentages look stale, run Codex once and then refresh the app; the dashboard can only show the newest `token_count` event written by Codex.
- If the app cannot launch from Finder, rebuild with `./script/build_and_run.sh`.
- If Gatekeeper blocks a downloaded release, explain that early unsigned builds may require right-click Open, then recommend signed/notarized releases once available.
