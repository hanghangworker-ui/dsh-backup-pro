# Changelog

本项目的所有重要变更都记录在此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [2.0.1] - 2026-11-08

### Fixed
- **restore.ps1 / snapshot.ps1（D1）**：配置被清空后 `restore.ps1 -Force` 会先拍「恢复前安全快照」，
  而该快照遇到 `known` 项缺失会 `throw`，导致 `FAIL pre-restore snapshot failed -> restore BLOCKED` ——
  即最需要恢复的场景反而恢复不了。新增 `snapshot.ps1 -AllowMissing`，`restore.ps1` 内部调用时始终带上，
  让存证快照容忍缺失、只记录残状，恢复不再被自己的取证步骤挡住。
- **snapshot.ps1 / purge-gate.ps1（D2）**：`profiles/web/package.json` 的 `dependencies` 为空时（全新 dsh profile
  常见），`$deps.PSObject.Properties.Name` 在 `Set-StrictMode -Version Latest` 下抛「在此对象上找不到属性“Name”」，
  导致 `snapshot.ps1` 直接失败、`purge-gate.ps1` 也失败。改为先 `@(... | ForEach-Object { $_.Name })` 物化再比较。
- **verify.ps1（E2）**：C 段区分「层3 整体未启用」与「层3 部分失效」——一个都没上锁时打 `WARN (键 acl-off)`
  而不是 `FAIL`（层3 本就是可选层），但只要**有一项上了锁、其余没上锁**仍然 `FAIL`。
- **verify.ps1（E1）**：F 项（资产表常量）在全新部署时缺调研产物，由 `Fail` 降为 `Warn`；
  新增 `gate-unused`、`optional-asset`、`acl-off`、`pending-item` 四个 expected 键，`deploy.ps1` 生成的清单同步包含，
  首跑即 `0 FAIL / 5 WARN (5 expected, 0 unexpected)`（带 `-Lock` 且清单含 pending 项时 9 个以上）。

### Changed
- 「备份机制第二版」改为适合 GitHub 发布的仓库结构：`README.md`（英中双语）、`docs/`（手册 + 可复用性判定）、
  `.gitattributes`（`.ps1` 强制 CRLF 且不动 BOM）、`.editorconfig`（`.ps1` 声明 `utf-8-bom`）、
  `.gitignore`（`snap/`、`state/`、`config-manifest.json` 不入库）、`LICENSE`（MIT）、`CHANGELOG.md`、
  `CONTRIBUTING.md`、`.github/workflows/ci.yml`（BOM + 双引擎解析 + 模板 JSON + 沙箱冒烟：清空→恢复→复验）。

## [2.0.0] - 2026-11-08

### Added
- `deploy.ps1`：一键部署（探测本机配置 → 生成清单 → 拍基准 → 封存 → 可选上锁 → 自检）。
- `seal-baseline.ps1`：把基准快照摘要外置封存到 `state/baseline-integrity.json`，防「先改后拍」洗漂移。
- `verify.ps1`：A/A2/B/B2/C/D/E/E3/F/G 十段自检，`-Strict` 下 `unexpected > 0` 即退出码 1。
- `restore.ps1 -Plan`：只读预览（列出 `OVERWRITE` 清单，退出码 2）；`-RequireIdle`：检测 dsh 进程占用。
- `restore.ps1` 两阶段写入：先全量暂存到 `state/restore-staging-<ts>`，再逐个提交。
- `snapshot.ps1 -PruneWhatIf`：只演练保留策略（`keep` / `protectedTags`），不真删。
- `purge-gate.ps1` 四段指纹（dsh 版本 / purge 版本 / 快照清单哈希 / 配置内容摘要），内容漂移也会触发新快照。
- 清单驱动的保留策略：`keep`、`logKeep`、`protectedTags`、`referenceTag`、`expectedWarn`。
- 分发版路径参数化：`$Vault` / `$ManifestPath` 缺省取「脚本所在目录的父目录」，不再硬编码本机路径。

### Changed
- `verify.ps1` B 段默认对照 `referenceTag`（固化基准），不再默认「取最新快照」——避免先改后拍把漂移洗成基准。
- G 段改为递归检查 `*.ps1/*.psm1/*.psd1`，并校验 `config-manifest.json` 与 `state/*.json` 可解析。

## [1.0.0] - 2026-11-07

### Added
- 三层配置保护的初版：`snapshot.ps1`（层1 快照）、`purge-gate.ps1`（层2 写入前 fail-closed 闸门）、
  `acl.ps1`（层3 `icacls` 拒写）、`verify.ps1`（自检）、`vault-common.ps1`（公共库）。
- `acceptance-r2.ps1`：fail-closed 注入测试与恢复演练的自验收骨架。
