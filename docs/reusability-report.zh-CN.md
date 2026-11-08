# 可复用判定清单（源：`D:\dsh-config-vault`）

判定原则：**能不能拿到另一台机器上，只改配置就跑起来**。

- **可复用** = 只含逻辑，路径/机器信息可通过参数或清单指定 → 打包。
- **不可复用** = 含本机状态、日志、历史快照、机器名、盘符硬编码、一次性调研工具 → 不打包（但把「为什么」写清，方便你判断）。

---

## 一、可复用（已打包）

| 文件 | 作用 | 打包时的处理 | 判定理由 |
|---|---|---|---|
| `scripts/vault-common.ps1` | 公共库：读清单、文件锁（含 PID 重入/死进程清理）、快照摘要、保留策略（keep/protectedTags）、日志轮转、inflight 记录 | 原样（仅加分发版标题、注释里的本机路径改占位符） | 纯函数库，无本机路径；所有路径由调用方传入 |
| `scripts/snapshot.ps1` | 层1：按清单把配置复制成版本化快照，写 `_manifest.csv` / `_versions.json` / `snapshotDigest` | `$Vault`/`$ManifestPath` 默认值清空 → 缺省取脚本所在目录的父目录 | 逻辑通用；原默认值写死母版路径 |
| `scripts/restore.ps1` | 回滚：`-Plan` 只读清单、`-Force` 两阶段写入（staging → commit）、写前拍 `pre-restore-*` 安全快照、`-RequireIdle` 查 dsh 是否在跑 | 同上；**新增 D1（见第四节）** | 同上 |
| `scripts/acl.ps1` | 层3：`icacls` 对指定文件 deny Write/Delete/Synchronize；`Status/Check/Lock/Unlock/Recover` 五动作 | `$ManifestPath` 默认清空 | 逻辑通用，`aclDeny` 列表来自清单 |
| `scripts/purge-gate.ps1` | 层2：写入型操作前 fail-closed 快照闸门；四段指纹（dsh 版本 + purge 版本 + 快照清单哈希 + 配置内容摘要）不变即 SKIP | 同上 | 通用；`ApplyCommand` 本来就要按本机填 |
| `scripts/verify.ps1` | 自检：A 配置存在 / A2 removed 回归 / B 与基准快照比对 / B2 baseline 封存校验 / C ACL deny / D 计划任务 / E gate 状态 / E3 pending-post / F 资产表常量（可选）/ G 脚本编码 | 同上；F 项由 `Fail` 降为 `Warn`（分发版没有 detect 工具产出的两个文件） | 通用，缺的两个状态文件属本机调研产物 |
| `scripts/seal-baseline.ps1` | 把 `baseline` 快照的摘要外置封存到 `state/baseline-integrity.json`，防止「先改后拍」把漂移洗成基准 | 同上 | 通用 |
| `scripts/acceptance-r2.ps1` | 自验收：③ fail-closed 注入（把清单 dshHome 改坏 → gate 必须拒绝）⑤ 自检必须 0 FAIL；④ 恢复演练需显式不加 `-SkipRestore` | `$GoodHome/$BadHome` 默认清空 → 从清单 `dshHome` 派生 | 通用；原默认值写死本机路径 |
| `scripts/fix-bom.ps1` | 给目录下所有 `.ps1` 补 UTF-8 BOM（幂等） | 原样 | 通用小工具，防 Windows PowerShell 5.1 按 GBK 误读中文脚本 |
| `scripts/deploy.ps1` | **新写**：一键部署——建目录、探测本机有哪些配置、生成清单、拍基准、封存、可选上锁、跑自检 | 全新文件 | 母版没有引导脚本，客户机从零搭建需要它 |
| `config/config-manifest.template.json` | 清单模板：8 条候选保护项、`keep`/`logKeep`、`referenceTag`、`protectedTags`、`expectedWarn` | 路径全部写 `(待补充：…)`，`include` 全部 `pending` | 模板本身不含本机数据 |

## 二、不可复用（未打包）

| 内容 | 判定理由 |
|---|---|
| `snap/` 全部 20 个快照目录（`baseline`、`pre-0.2.1-rc.5-*`、`after-*`、`probe-digest`、`post-*` …） | 本机配置的**内容副本**，含 `prompt-inject.md`、`agent.cordis.yml`、`package.json` 等本机数据；客户机要从自己的配置重新拍基准 |
| `state/last-applied.json` | 记录本机 dsh/purge 版本与指纹，换机即失效 |
| `state/baseline-integrity.json` | 本机 baseline 摘要封存，客户机需自己 `seal-baseline.ps1` 生成 |
| `state/gate.log`、`state/acceptance-r2-*.log` | 本机运行日志 |
| `state/asset-table-keys.json`、`state/dsh-purge-pkg.sha256` | 本机 `dsh-purge` 检出调研产物（版本 1.6.84 的常量与包哈希），客户机版本未必相同 |
| `state/manifest.acceptance.bak` | 自验收过程产生的清单备份 |
| `state/gate.lock`、`state/unlock-inflight.json` | 运行期锁文件，若被打包且客户机残留会造成「锁被别人持有」的假象 |
| `scripts.bak-20261108-092219/`、`scripts.bak-bom-20261108-093918/` | 母版历史备份 |
| `scripts/detect-purge-master.ps1` | 一次性调研工具：硬编码 `D:\dsh-config-vault\dsh-purge-master`、`D:\dsh-home\node_modules\.bin\node`，依赖本机 dsh-purge 检出目录；客户机没有这个检出就跑不了 |
| `README.md`、`ACCEPTANCE-2026-11-08.md`、`EVAL-purge-master-integration.md`、`RECOVERY-GUIDE.md`、`SOP-restore.md` | 母版文档，内容绑定本机 20 个快照与那次事故经过；本次另写面向客户的说明文档 |
| 工作区里的 `patch_vault_*.py`、`build_package.py`、`test_prune.ps1`、`fix_seal.py`、`set_ref_tag.py`、`clean_purgegate.py`、`patch_dist_fix.py` 等 | 母版改造与打包用的一次性脚本，不是运行时组件 |

## 三、存在判断分歧的项（单列，不擅自处置）

1. **`scripts/acceptance-r2.ps1`（已纳入）**
   反对理由：它是「验收」脚本，含 ④ 恢复演练，会在真实配置目录上执行 `restore -Force`，对客户机有破坏性。
   纳入理由：③⑤ 两道验收是判断「这套机制到底有没有生效」的唯一客观手段，且 ④ 必须显式不加 `-SkipRestore` 才会跑；文档里把 ④ 标为**可选、需停机**。
   处置：纳入，文档中明确默认只跑 `-SkipRestore`。

2. **`scripts/verify.ps1` 的 F 项（保留但降级为 WARN）**
   反对理由：客户机没有 `asset-table-keys.json` / `dsh-purge-pkg.sha256`，会一直 WARN。
   纳入理由：删掉 F 项等于改变母版行为，违反「只提取不改行为」；保留可让客户在做过同类调研后自动生效。
   处置：`Fail` → `Warn`，并把 `optional-asset` 加入 `expectedWarn`，首跑不会算 unexpected。

3. **`config-manifest.template.json` 的 `include` 默认全 `pending`（已纳入）**
   分歧：全 `pending` 时 `snapshot` 会把「不存在的项」当 pending 跳过，导致**首次拍基准可能只拍到 2 个文件而不报错**。
   处置：模板保留 `pending`（因为客户机不知道有哪些项），但 `deploy.ps1` 会**按实际存在性**重写为 `known`/`pending`，并在 `verify` A 段逐项打印 `[known]/[pending]`；文档要求「拍完基准先看 verify A 段，known 项数应等于你实际保护的项数」。

4. **`dsh-purge` 相关机制、脚本是否整体适用**
   分歧：`purge-gate.ps1` / `acceptance-r2.ps1` 的 ③ 都围绕 `dsh-purge-community` 这个插件设计；客户机若不用该插件，这两块价值下降。
   处置：仍然纳入（`purge-gate.ps1` 可当「任何写入型操作前的快照闸门」用，`ApplyCommand` 留空即 snapshot-only），文档第 7、10 节说明如何降级使用。

## 四、分发版相对母版的差异（5 处；D1 只在分发版，其余母版已同步）

| 编号 | 文件 | 差异 | 原因 |
|---|---|---|---|
| P0 | 全部 9 个脚本 | `$Vault` / `$ManifestPath` 默认值由 `D:\dsh-config-vault` 改为空串，缺省取「脚本所在目录的父目录」 | 客户机路径未知，且不能让默认值指向不存在的盘 |
| D1 | `snapshot.ps1` / `restore.ps1` | `snapshot.ps1` 新增 `-AllowMissing`；`restore.ps1` 内部拍 `pre-restore-*` 时带上它 | **母版缺陷**：配置被清空后，`restore.ps1 -Force` 会先拍安全快照，而该快照遇到 known 项缺失会 `throw` → `restore BLOCKED`。也就是说「配置被清空」这个唯一需要恢复的场景，母版反而拒绝恢复（本次在临时演练中实测复现）。分发版让存证快照容忍缺失，恢复不再被自己的取证步骤挡住 |
| E1 | `verify.ps1` | F 项 `Fail` → `Warn`；新增 `gate-unused` / `optional-asset` 两个 expected 键 | 客户机全新部署时缺本机调研产物，不应算失败 |

> D1 只加在分发包里，母版 `D:\dsh-config-vault` 未改动（本任务约束：只提取不改造）。若母版也要修，把这两处 diff 搬回去即可。
| D2 | `snapshot.ps1` / `purge-gate.ps1` | 空 `dependencies` 时不再点 `.PSObject.Properties.Name`，改为先物化数组再比较 | **母版缺陷**：`profiles/web/package.json` 的 `dependencies` 为空（全新 dsh profile 常见）时，`Set-StrictMode -Version Latest` 下 `.PSObject.Properties.Name` 抛「在此对象上找不到属性“Name”」，`snapshot.ps1` 直接失败、`purge-gate.ps1` 同样失败。已同步修进母版 |
| E2 | `verify.ps1` | C 段区分「层3 整体未启用」（`WARN`，键 `acl-off`）与「层3 部分失效」（`FAIL`） | 层3 是可选层：没上锁不该算失败，但一半锁住一半没锁是真故障。母版已同步 |

## 五、仓库化（2026-11-08，目标 GitHub）

压缩包形态不适合长期维护（无版本历史、无 CI、无 issue 入口、`.gitattributes` 缺失会让 Windows 换行/BOM 被来回改写）。
因此把同一份内容重排为仓库：

| 新增/调整 | 作用 |
|---|---|
| `README.md`（英中双语） | 首屏讲清「为什么需要」「一条命令恢复」「脚本分工表」 |
| `LICENSE`（MIT）、`CONTRIBUTING.md`、`CHANGELOG.md` | 开源仓库三件套；CHANGELOG 用 Keep a Changelog 格式，缺陷写明「不修会怎样」 |
| `.gitattributes` | `*.ps1 text eol=crlf`（**不做** `working-tree-encoding`，避免 BOM 被剥） |
| `.editorconfig` | `*.ps1` 声明 `charset = utf-8-bom`，编辑器层先兜一次 |
| `.gitignore` | `snap/`、`state/`、`config-manifest.json`、`*.log`、`*.zip` 一律不入库（含真实配置副本） |
| `.github/workflows/ci.yml` | BOM 检查 → PowerShell 7 解析 → Windows PowerShell 5.1 解析 → 模板 JSON 校验 → 沙箱冒烟（deploy → 删文件 → restore -Force → verify） |
| `.github/ISSUE_TEMPLATE/bug_report.yml`、`PULL_REQUEST_TEMPLATE.md` | 强制要求附 `SUMMARY` 行与复现命令，减少无效 issue |
| `docs/guide.zh-CN.md` 新增第 11 节 | 仓库目录约定、三条硬规矩（BOM / 不入库 snap、state / 不硬编码路径）、发布流程、版本策略 |

文档改名：`docs/说明文档.md` → `docs/guide.zh-CN.md`，`docs/可复用判定.md` → `docs/reusability-report.zh-CN.md`
（ASCII 文件名便于 URL 引用与 issue 链接；内容不变，仅修订交叉引用）。

