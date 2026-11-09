# Changelog

本项目的所有重要变更都记录在此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [2.1.1] - 2026-11-09

### Added
- `dsh_backup_list_versions` 输出 `purgeCompat=compatible|unknown`：读 `dsh-purge-community` 的
  `dsh.compatibility.dshReleases` 精确匹配（表里没有的版本记 `unknown`，不推断）。探测源：`dshHome`
  配置或 `DSH_BACKUP_DSH_HOME` / `DSH_HOME`。
- 插件配置项 `dshHome`；README 补配置项表。

### Changed
- `mode=full` 打包后端改为「Windows 自带 bsdtar（`--format zip`）→ `.NET ZipFile` 回退」。
  `Compress-Archive` 在 693.6 MB / 62,574 文件量级实测 10 分钟零增长（等同卡死）。
- 工具回收改为 `ctx.effect` + 幂等 disposer 双保险：cordis 在 `apply` 未拿到 config 对象时不会调用
  返回值，原先存在卸载后工具残留的风险（实测已复现并修复）。
- **npm 包名改为 `@hanghangworker-ui/dsh-backup-pro`**（`dsh-backup` 在 npm 上已被他人占用，latest 0.1.1）。
  `cordis.patch.yml` 的 `id` 仍为 `dsh-backup`（与包名解耦），`insert[].name` 与 `package.json` 的 `name`
  同步为新名；`private` 改为 `false`。装过旧名的机器需先 `remove` 再 `add`，避免两个身份并存。

### Verified（真机）
- 真实安装：`dsh plugin --profile web add <path>` → `pnpm` 6 s，`dsh.profile.bundles` 自动追加
  `@hanghangworker-ui/dsh-backup-pro`，`--dump-config` 出现该 patch 层。
- 真实 DI 挂载：dsh 自带 cordis `Context` + `ctx.provide('tools')` + `ctx.plugin()` → 注册 7 工具，
  dispose 回收 7 工具。
- full 模式入库：payload `213.2 MB`，耗时约 `5.0 分钟`。

## [2.1.0] - 2026-11-08

### Added
- **可作为 dsh 插件（Host-only bundle）安装**：新增 `package.json`（`dsh.bundle.patch`）、`cordis.patch.yml`、
  `index.js`（导出 `apply`/`inject`/`name`）、`lib/{plugin,tools,ps}.js`、`locale/{en,zh}.json`、`icon.svg`。
  安装：`plugin_manager({ action: "install_bundle", target: "<包目录绝对路径>" })`。
- **7 个 `dsh_backup_*` 工具**：`list_versions`、`save_version`、`verify_store`、`switch_version`、
  `snapshot`、`config_check`、`purge_gate`。`switch_version` 的 `apply`/`rollback` 需 `confirm=true`，
  切换前做 dsh 进程空闲检查。
- **`scripts/version-store.ps1`**：dsh 版本库。`meta` 模式只记核心清单（实测 22 文件 / 81 KB，秒级），
  `full` 模式额外打 `payload.zip`（含 node_modules，可切换）。含 `sharedWith` 去重与三段完整性校验
  （meta 可解析 / 核心清单指纹 / payload SHA256）。
- **`scripts/switch-version.ps1`**：`status/plan/apply/rollback` 四态版本切换；`apply` 走
  「展开 → 校验 → 备份改名 → 就位 → 复核」，任一步失败自动回滚；`rollback` 回到最近 `.bak-*`。
- `docs/plugin.zh-CN.md`：插件设计文档（脚本梳理 / 多版本存储 / 切换 / purge 适配 / 骨架 / 编码 / 验收）。

### Fixed
- **verify.ps1（D3）**：没有 `snap/` 目录时 B 段 `$selName` 未初始化，StrictMode 下抛
  「无法检索变量 '$selName'，因为它尚未被设置」；改为进入 B 段前 `$selName = ''`，
  并把 `no snapshot directory` 的 FAIL 消息补上具体路径。
- **verify.ps1（D4）**：只传 `-ManifestPath`（借用本包脚本、指向别处 vault）时，`$Vault` 仍取脚本父目录，
  导致 B 段去错误的 `snap/` 下找快照；改为优先从 `-ManifestPath` 的父目录推导 `$Vault`。
- **version-store.ps1**：核心清单指纹改为「落盘文件字节的 SHA256」（原先是文本哈希，`Set-Content` 的
 换行差异导致 `Verify` 100% 失败）；`Find-LatestBackup` 返回 `,$baks` 保持数组形状（0/1 个备份时
  `$baks.Count` 在 StrictMode 下会抛错）；核心文件枚举改为「根目录 + 各一级子目录，跳过 node_modules」，
  并修正 node_modules 过滤必须基于相对路径（安装目录本身就在 node_modules 下，原先会把核心文件全过滤掉）。

### Changed
- 配置类工具在 `config-manifest.json` 缺失时返回部署命令提示，而不是把 PowerShell 的栈直接抛给模型。
- `README.md` 增加「作为 dsh 插件安装」一节与工具表；`Scripts` 表补两个新脚本。

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
