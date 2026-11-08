# dsh-backup

**Snapshot · gate · lock — a three-layer configuration backup for [dsh](https://www.npmjs.com/package/@deepseek-ai/dsh).**
If a plugin or an automated cleanup wipes your dsh config, one command puts it back.

[![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-blue)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![CI](https://github.com/hanghangworker-ui/dsh-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/hanghangworker-ui/dsh-backup/actions/workflows/ci.yml)

> 中文速查见下方 [快速开始](#快速开始中文)，完整手册：[docs/guide.zh-CN.md](docs/guide.zh-CN.md)

---

## Why

dsh keeps its real configuration in a home directory (`prompt-inject.md`, `.agent-presets/`, `whale-roles/`,
`profiles/web/*.yml`, `profiles/web/package.json`, `skills/` …). Cleanup plugins and self-updates can rewrite
or delete those files. A backup that only *copies* is not enough — you also need to notice the change and to
survive the case where the files are already gone.

This repo is that mechanism, extracted from a production vault:

```
layer 1  snapshot.ps1      versioned copy of the config  → <vault>/snap/<tag>/  (+ per-file sha256)
layer 2  purge-gate.ps1    fail-closed pre-write gate    → no snapshot, no change
layer 3  acl.ps1           icacls deny W/D/SYN           → the file cannot be deleted at all
         verify.ps1        ten-section self check        → tells you which layer is broken
```

## Requirements

- Windows 10/11 / Server 2019+
- **PowerShell 7+** (`pwsh`). Windows PowerShell 5.1 can *parse* these scripts but not run them
  (`#requires -Version 7.0`).
- All `.ps1` files are UTF-8 **with BOM** on purpose — PowerShell 5.1 decodes BOM-less UTF-8 as GBK and then
  reports dozens of fake syntax errors. If an editor strips the BOM, run `scripts/fix-bom.ps1`.

## Quick start (English)

```powershell
# 1) clone as your vault (do NOT put it inside the dsh config directory)
git clone https://github.com/hanghangworker-ui/dsh-backup.git D:\dsh-config-vault

# 2) one-shot deploy: probe config → write manifest → snapshot → seal → lock → self-check
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\deploy.ps1" `
     -DshHome "<YOUR_DSH_HOME>" `
     -Vault   "D:\dsh-config-vault" `
     -Lock

# 3) expect:  SUMMARY: 0 FAIL / 5 WARN (5 expected, 0 unexpected)
```

After the config is wiped:

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\verify.ps1"                                    # what is missing
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\restore.ps1" -Tag baseline -Plan               # dry run
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\restore.ps1" -Tag baseline -RequireIdle -Force  # restore (close dsh first)
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\verify.ps1"                                    # 0 FAIL = back
```

## 快速开始（中文）

```powershell
git clone https://github.com/hanghangworker-ui/dsh-backup.git D:\dsh-config-vault

pwsh -NoProfile -File "D:\dsh-config-vault\scripts\deploy.ps1" `
     -DshHome "D:\dsh-home" `
     -Vault   "D:\dsh-config-vault" `
     -Lock
```

`deploy.ps1` 会：探测本机有哪些配置 → 生成 `config-manifest.json` → 拍 `baseline` 基准快照 →
封存摘要到 `state\baseline-integrity.json` → 可选上 ACL 锁 → 跑 `verify.ps1` 自检。
最后一行 `SUMMARY: 0 FAIL / 5 WARN (5 expected, 0 unexpected)` 就算部署成功（其中 `acl-off` = 没加 `-Lock`，属正常；加了 `-Lock` 会变成 `0 FAIL / 9 WARN (9 expected, …)`）。

配置被清空后（**先关掉 dsh**）：

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\verify.ps1"                                     # 看缺了什么
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\restore.ps1" -Tag baseline -Plan                # 只读预览
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\restore.ps1" -Tag baseline -RequireIdle -Force  # 真恢复
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\verify.ps1"                                     # 复验 0 FAIL
```

完整手册（架构、清单字段、换基准、闸门集成、缺口说明）见 **[docs/guide.zh-CN.md](docs/guide.zh-CN.md)**。

## Scripts

| Script | Layer | What it does | Main parameters |
|---|---|---|---|
| `deploy.ps1` | — | one-shot bootstrap: directories, manifest probe, baseline snapshot, seal, optional lock, verify | `-DshHome` (required) `-Vault` `-Tag` `-Lock` `-SkipSnapshot` |
| `vault-common.ps1` | — | shared library: lock (PID re-entry, stale cleanup), hashing, retention, log rotation. Dot-sourced, never run alone | — |
| `snapshot.ps1` | 1 | copy the config per manifest into `snap/<tag>`, write `_manifest.csv` + `_versions.json` + digest | `-Tag` `-PruneWhatIf` `-AllowMissing` |
| `restore.ps1` | 1 | roll back from a tag; read-only by default, `-Force` writes via staging → commit | `-Tag` `-Plan` `-Force` `-RequireIdle` |
| `purge-gate.ps1` | 2 | fail-closed gate: snapshot first, then (optional) `ApplyCommand`; 4-part fingerprint for idempotence | `-DryRun` |
| `acl.ps1` | 3 | `icacls` deny write/delete on the `aclDeny` list | `-Action Status\|Check\|Lock\|Unlock\|Recover` |
| `verify.ps1` | — | ten-section self check, prints `SUMMARY: x FAIL / y WARN (a expected, b unexpected)` | `-Tag` `-Strict` |
| `seal-baseline.ps1` | — | store the baseline digest outside the snapshot (defeats "edit first, snapshot later") | `-Tag baseline` `-Force` |
| `acceptance-r2.ps1` | — | self-acceptance: fail-closed injection test + self-check | `-SkipRestore` (recommended) |
| `fix-bom.ps1` | — | add UTF-8 BOM to `.ps1` files (idempotent) | `-Path` |

## Repository layout

```
dsh-backup/
├─ scripts/            PowerShell 7 tooling (UTF-8 + BOM)
├─ config/             config-manifest.template.json
├─ docs/
│  ├─ guide.zh-CN.md              full manual (deploy / baseline / restore / verify / gaps)
│  └─ reusability-report.zh-CN.md what was reused from the source vault and why
├─ .github/workflows/ci.yml       BOM + parse check on windows-latest
├─ CHANGELOG.md
└─ LICENSE (MIT)
```

## State directory (created at runtime, git-ignored)

```
<vault>/snap/<tag>/          snapshots (your config lives here — never commit)
<vault>/state/gate.log       gate log
<vault>/state/last-applied.json
<vault>/state/baseline-integrity.json
<vault>/config-manifest.json your manifest (machine specific)
```

## Design notes

- **`known` vs `pending`** — a manifest item marked `known` that disappears makes `snapshot.ps1` fail hard.
  That is intentional: silently "protecting" a file that no longer exists is the bug this tool exists to catch.
- **Reference tag, not latest tag** — `verify.ps1` compares against `referenceTag`, so re-snapshotting after an
  unwanted change cannot launder it into the baseline.
- **Restore never gets blocked by its own evidence step** — when the config is already wiped, the pre-restore
  safety snapshot runs with `-AllowMissing` and records the残 state instead of aborting the restore (see CHANGELOG 2.0.1).
- **ACL is the last wall** — `snapshot`/`restore` unlock and re-lock automatically; a crash leaves
  `state/unlock-inflight.json` behind and `acl.ps1 -Action Recover` re-locks.

## Contributing

Issues and PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Please keep every `.ps1` UTF-8 **with BOM**
and make sure `pwsh -NoProfile -File scripts/verify.ps1` still reports `0 FAIL` (CI enforces the parse part).

## License

[MIT](LICENSE) © 2026 hanghangworker-ui
