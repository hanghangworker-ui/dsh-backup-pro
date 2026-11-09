# 备份机制第二版 · 使用手册

> 目标：让 dsh 的配置文件**可外置、可版本化、被清空后能一条命令恢复**。
> 适用：Windows + PowerShell 7（`pwsh`）。全部脚本已带 UTF-8 BOM，Windows PowerShell 5.1 可解析但**不能执行**（脚本首行 `#requires -Version 7.0`）。

阅读顺序建议：① 第 1 节看架构 → ② 第 2 节部署 → ③ 第 4 节建基准 → ④ 第 5 节恢复 → ⑤ 第 6 节校验。其余是按需查阅。

---

## 0. 部署前必须确认的环境项

| 项 | 说明 | 怎么查 |
|---|---|---|
| `(待补充：PowerShell 7 路径)` | 一般是 `C:\Program Files\PowerShell\7\pwsh.exe` | `pwsh -v`，应 ≥ 7.0 |
| `(待补充：dsh 配置根目录)` | 本机 dsh 把配置放在哪，例：`D:\dsh-home`、`C:\Users\<你>\.dsh` | 看 dsh 启动参数 / 安装目录，或 `Get-ChildItem $env:USERPROFILE -Filter .dsh -Force` |
| `(待补充：vault 根目录)` | 本包解压后的绝对路径，例：`D:\dsh-config-vault`、`C:\dsh-vault` | 你自己决定；**不要放在 dsh 配置根目录里面**，否则被一起清掉 |
| `(待补充：是否使用 dsh-purge-community)` | 用了才需要 `purge-gate.ps1` 与 `acceptance-r2.ps1` 的完整性能力 | 看 `profiles/web/package.json` 的 dependencies |

> 三项都可先留空跑 `deploy.ps1`，脚本会把空缺项以 `pending` 写入清单并提示；但要真正起到保护作用，`dshHome` 必须正确。

---

## 1. 这套机制在做什么（三层）

```
                     ┌─────────────────────────────────────────┐
  层1 外置+快照      │ snapshot.ps1  →  <VAULT>\snap\<tag>\     │  配置的版本化副本
  （可回滚的底牌）   │                 _manifest.csv (逐文件哈希)│
                     │                 _versions.json (摘要)     │
                     ├─────────────────────────────────────────┤
  层2 写入前闸门     │ purge-gate.ps1 → 写入型操作前先拍快照     │  拍不下来就不许改
  （fail-closed）    │                 指纹不变则 SKIP（幂等）    │
                     ├─────────────────────────────────────────┤
  层3 文件级拒写     │ acl.ps1 Lock   → icacls deny W/D/SYN     │  连误删都做不到
  （最后一道墙）     │ 改动前需显式 Unlock（snapshot/restore 自动）│
                     └─────────────────────────────────────────┘
                     verify.ps1  → 任何时候跑一遍，看这三层是否还在
```

为什么是三层：只有快照 → 被清空后你未必知道、也未必想得起来回滚；只有 ACL → 合法工具改不了配置反而误伤；只有闸门 → 绕过闸门的工具（如 MCP 直调）照样清。三层叠加后，**任一层失效，另两层仍能把配置救回来**。

## 2. 各部件作用（`scripts/`）

| 脚本 | 一句话作用 | 关键参数 |
|---|---|---|
| `vault-common.ps1` | 公共库（锁、哈希、保留策略、日志轮转），被其它脚本 dot-source，**不单独运行** | — |
| `deploy.ps1` | 一键部署：建目录、探测现有配置、生成清单、拍基准、封存、可选上锁、跑自检 | `-DshHome`（必填）`-Vault` `-Tag` `-Lock` `-SkipSnapshot` |
| `snapshot.ps1` | 按清单把配置复制成 `<VAULT>\snap\<tag>`，写逐文件哈希与整包摘要 | `-Tag` `-PruneWhatIf`（只演练保留策略） |
| `restore.ps1` | 从某个 tag 回滚；默认只读，`-Force` 才写 | `-Tag` `-Plan` `-Force` `-RequireIdle` |
| `purge-gate.ps1` | 写入型操作前的闸门：先快照，再（可选）执行 `ApplyCommand` | `-DryRun` |
| `acl.ps1` | 给 `aclDeny` 列表里的文件加/查/解 deny | `-Action Status\|Check\|Lock\|Unlock\|Recover` |
| `verify.ps1` | 十段自检，最后打印 `SUMMARY: x FAIL / y WARN (a expected, b unexpected)` | `-Tag` `-Strict` |
| `seal-baseline.ps1` | 把基准快照摘要外置封存，防「先改后拍」 | `-Tag baseline` `-Force` |
| `acceptance-r2.ps1` | 自验收：注入测试 + 自检必须通过（恢复演练需显式开启） | `-SkipRestore`（推荐） |
| `fix-bom.ps1` | 给目录下 `.ps1` 补 UTF-8 BOM（5.1 误读中文脚本的根因修复） | `-Path` |

`config/config-manifest.template.json` 是清单模板，`deploy.ps1` 会在 vault 根生成真正的 `config-manifest.json`。

## 3. 部署（客户机从零到可用，约 3 分钟）

### 3.1 解压

```powershell
# 解压到你自己定的 vault 根目录，例如 D:\dsh-config-vault
Expand-Archive -LiteralPath '备份机制第二版.zip' -DestinationPath 'D:\' -Force
# 解压后应存在：D:\备份机制第二版\scripts\*.ps1 、 config\ 、 docs\
Rename-Item 'D:\备份机制第二版' 'D:\dsh-config-vault'   # 改成你喜欢的名字
```

后续命令里的 `<VAULT>` 都指这个目录（下面示例用 `D:\dsh-config-vault`）。

### 3.2 一键部署

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\deploy.ps1" `
     -DshHome "(待补充：dsh 配置根目录)" `
     -Vault   "D:\dsh-config-vault" `
     -Lock
```

`deploy.ps1` 会依次做：

1. 建 `<VAULT>\state\`、`<VAULT>\snap\`；
2. 按 8 个候选项（`prompt-inject.md`、`.agent-presets`、`whale-roles`、`profiles/web/cordis.patch.yml`、`profiles/web/cordis.yml`、`profiles/web/package.json`、`dsh-purge/update-preferences.json`、`skills`）**逐个探测存在性**，写成 `known` / `pending`；
3. 生成 `<VAULT>\config-manifest.json`（`keep=20`、`logKeep=50`、`referenceTag=baseline`、`protectedTags` 六条、`expectedWarn` 六条）；
4. `snapshot.ps1 -Tag baseline` 拍基准；
5. `seal-baseline.ps1` 封存基准摘要到 `state\baseline-integrity.json`；
6. `-Lock` 存在时 `acl.ps1 -Action Lock` 上锁；
7. `verify.ps1` 自检，**退出码取自 verify**（0 = 可用）。

预期最后一行：

```
SUMMARY: 0 FAIL / 5 WARN (5 expected, 0 unexpected)
```

5 个 WARN 全是「全新部署的正常状态」：`scheduled-task`（没建计划任务）、`gate-unused`（还没跑过闸门）、`optional-asset` ×2（缺 dsh-purge 调研产物）、`acl-off`（层3 未上锁——没加 `-Lock` 时这是正常状态）。**只要 `unexpected=0` 就算部署成功**；若 `FAIL>0`，按第 6 节逐条查。

加上 `-Lock` 再跑一次会变成 `0 FAIL / 9 WARN (9 expected, 0 unexpected)`：多出来的是 `pending-item` ×N（清单里标 `pending`、本机确实还没有的配置项）。

### 3.3 只装脚本、手工写清单（可选）

不想让脚本探测，就自己复制模板：

```powershell
Copy-Item "D:\dsh-config-vault\config\config-manifest.template.json" `
          "D:\dsh-config-vault\config-manifest.json"
notepad "D:\dsh-config-vault\config-manifest.json"   # 至少改 dshHome / vault / referenceTag
```

然后手工拍第一份基准：

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\snapshot.ps1" -Tag baseline
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\seal-baseline.ps1" -Tag baseline
```

## 4. 按本机情况改配置（`config-manifest.json`）

```jsonc
{
  "dshHome": "D:\\dsh-home",              // 必改：dsh 配置根目录（绝对路径，反斜杠要双写）
  "vault":   "D:\\dsh-config-vault",      // 必改：本包根目录
  "keep": 20,                             // 保留多少个非保护快照
  "logKeep": 50,                          // 保留多少个 state\*.log
  "include": [                            // 要保护的条目；status: known / pending / removed
    { "path": "prompt-inject.md", "kind": "file", "status": "known" },
    { "path": "skills",           "kind": "dir",  "status": "known" }
    // pending = 本机暂缺，出现后自动纳入；removed = 已确认不用，跳过且回归时告警
  ],
  "aclDeny": [                            // 层3 拒写列表（相对 dshHome）
    "prompt-inject.md",
    ".agent-presets/unrestricted/agent.cordis.yml"
  ],
  "referenceTag": "baseline",             // 必改：verify B 段对照的「固化基准」
  "protectedTags": ["baseline.*","after-.*","post-.*","pre-session-copy-.*","probe-.*","pre-restore-.*"],
  "expectedWarn": ["scheduled-task","pending-post","gate-unused","optional-asset","acl-off","pending-item"]
}
```

改完清单的规矩：

- **`known` 项必须真实存在**，否则 `snapshot.ps1` 会硬失败（`known config path missing`）——这是故意的，防止「以为在保护，其实早就没了」。
- 不确定是否存在的项写 `pending`，`verify` A 段会打印 `[pending]`。
- 改完清单先跑 `verify.ps1` A 段，确认 `known` 数量 = 你实际想保护的项数。

**改了配置之后**（不是改清单）：配置本身变了，B 段会 WARN 差异，这是正常的；要么接受 WARN，要么把新状态固化成新基准（见 4.1）。

### 4.1 换基准的两种场景

| 场景 | 做法 |
|---|---|
| 你**有意**改了配置，想以新状态为准 | `snapshot.ps1 -Tag post-<说明>-<日期>`（如 `post-20261108`）→ 改清单 `referenceTag` 指向它 → `verify.ps1` |
| 配置被**插件自动改**了（例：依赖版本自动升级） | 先 `diff` 看改了什么（`restore.ps1 -Tag <当前基准>` 的 DIFF 段）→ 判断合理 → 同上换基准；不合理 → 第 5 节恢复 |

> 别用「先改再拍最新快照」来消 WARN：`verify` 的 B 段对照的是 `referenceTag`，不是「最新快照」，正是为了防这种洗漂移。

## 5. 配置被清空后如何恢复（核心场景）

### 5.1 先诊断

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\verify.ps1"
```

看到 `FAIL known config missing` 就是被清空的项；`WARN 源与快照有 N 处差异 … (missing)` 会列出全部。

### 5.2 看一眼要写什么（只读，不写盘）

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\restore.ps1" -Tag baseline -Plan
```

输出形如：

```
DIFF (6 file(s)) vs snapshot 'baseline':
RelPath                                      State
prompt-inject.md                             MISSING-IN-SOURCE
profiles\web\package.json                    MISSING-IN-SOURCE
...
PLAN: snapshot 'baseline' -> D:\dsh-home，将写入 6 个文件：
  OVERWRITE prompt-inject.md
  ...
PLAN ONLY: nothing written.
```

退出码 `2` = 只读计划（正常）。

### 5.3 真恢复

**先关掉 dsh**（重要：dsh 运行时会重写配置，边恢复边写会打架）。然后：

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\restore.ps1" -Tag baseline -RequireIdle -Force
```

- `-RequireIdle`：检测到 `node.exe` / `dsh.exe` 且命令行含 `dsh` 就拒绝，退出码 `1` 并列出 PID。
- 恢复流程：① 再拍一份 `pre-restore-<ts>` 安全快照（**配置已被清空时该快照只存证残状，不会阻断恢复**）→ ② 解除 `aclDeny` 文件的写锁 → ③ 全量暂存到 `state\restore-staging-<ts>\` → ④ 逐个提交到 `dshHome` → ⑤ 删 staging → ⑥ 重新上锁。

预期输出：

```
safety snapshot: D:\dsh-config-vault\snap\pre-restore-20261108-134859
staged 6 file(s) -> D:\dsh-config-vault\state\restore-staging-20261108-134900
restored: prompt-inject.md
...
PASS restored 6 file(s) from 'baseline'
```

**想恢复某个历史版本**：把 `-Tag baseline` 换成 `snap\` 下的任意 tag，例 `-Tag pre-0.2.1-rc.5-20261108-095625`。先 `Get-ChildItem D:\dsh-config-vault\snap` 看有哪些。

### 5.4 清空后的“找回顺序”建议

1. `snapshot` 的最新快照（多半就是 baseline 或 `post-*`）→ `restore -Plan` 看差异；
2. 差异太大或快照也坏了 → `verify` 的 B2 段如果 FAIL，说明 `state\baseline-integrity.json` 与快照不一致（快照被动过），改用别的 tag 或 `state\restore-staging-*` 里的暂存副本；
3. 全部快照都没了 → 只能从 `scripts.bak*` / 你自己的备份恢复，**这也说明 `keep` 与保护策略要调**。

## 6. 如何校验恢复结果

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\verify.ps1"
```

逐段含义与判读：

| 段 | 检查 | 期望 |
|---|---|---|
| A | 8 类配置存在性 | 全 `PASS … [known]` |
| A2 | 判定 `removed` 的项有没有重新出现 | 无输出最好；出现 = dsh 行为变了，需重新评估 |
| B | **当前源 vs `referenceTag` 快照**（逐文件 sha256） | `PASS … matches source`；差异会列出文件名与 `missing/changed` |
| B2 | `baseline` 外置封存摘要 vs 快照实况 | `PASS baseline integrity OK` |
| C | `aclDeny` 是否仍 deny（层3 是**可选层**） | 全上锁 → `PASS denied: …`；一个都没上锁 → `WARN (expected, 键 acl-off)`；**部分上锁部分没锁 → `FAIL`**（这才是真故障） |
| D | 计划任务 `DshPurgeUpdateWatch` | 没建过 → `WARN (expected)` |
| E | 闸门状态 `state\last-applied.json` | 跑过 `purge-gate` 后 PASS |
| E3 | `state\pending-post.json`（purge 后未补拍 after 快照） | `PASS no pending post-snapshot` |
| F | 资产表常量（可选） | 没有调研文件 → `WARN (expected)` |
| G | 所有 `.ps1/.psm1/.psd1` 是否 UTF-8 BOM 且可解析 + JSON 可解析 | 全 PASS |

**验收线**：`SUMMARY: 0 FAIL`。`unexpected` 必须是 0；`expected` 数字大不算问题（全新部署 5 个；带 `-Lock` 且清单含 pending 项时 9 个以上）。

加 `-Strict`：`unexpected > 0` 时退出码变 1，适合放进计划任务当哨兵。

想跑完整自验收（含 fail-closed 注入测试）：

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\acceptance-r2.ps1" -SkipRestore
```

它会临时把清单 `dshHome` 改成一个不存在的目录，要求闸门**必须拒绝**，然后在 `finally` 里自愈清单。**不要**省掉 `-SkipRestore`，除非你已停机并愿意让它在你真实配置上做一次 `restore -Force`（④ 恢复演练）。

## 7. 把闸门接进 purge 流程（可选，适用 dsh-purge-community）

`purge-gate.ps1` 的定位是「任何会改配置的动作之前，先确认快照拍得下来」。两种用法：

1. **只当快照闸门（snapshot-only）**：清单里不配 `ApplyCommand`，跑 `pwsh -File purge-gate.ps1`，它拍完 `pre-<版本>-<hash8>` 就放行，并写 `state\pending-post.json` 提醒你之后补拍 after 快照。
2. **闸门 + 真正执行清洗**：在清单加 `"ApplyCommand": "& '<NODE_EXE>' '<PURGE_JS>' --apply"`，gate 会在快照成功后执行它；失败则整条链 fail-closed。

指纹是四段：`dsh版本 | purge版本 | 快照清单哈希 | 配置内容摘要`。四段全不变 → `SKIP no change`（幂等，不会重复拍快照）；任何一段变了 → `CHANGE detected: <段名>` 并重新拍 pre 快照。

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\purge-gate.ps1" -DryRun   # 只看会发生什么
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\purge-gate.ps1"           # 真跑（拍快照）
```

## 8. 层3（ACL 拒写）日常操作

```powershell
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\acl.ps1"                 # Status：谁被 deny
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\acl.ps1" -Action Check   # Check：全部 deny 才 PASS（退出码 0）
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\acl.ps1" -Action Unlock  # 改配置前解锁
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\acl.ps1" -Action Lock    # 改完再上锁
pwsh -NoProfile -File "D:\dsh-config-vault\scripts\acl.ps1" -Action Recover # 崩溃后补锁（无 inflight 则直接 PASS）
```

注意：`snapshot.ps1` / `restore.ps1` 会**自动**临时解锁再上锁，并写 `state\unlock-inflight.json`；若进程被杀导致文件卡在解锁态，跑 `-Action Recover`。

## 9. 已知缺口与需补充项

1. **`(待补充：dsh 配置根目录)` 未知，无法预填清单**：必须部署时用 `-DshHome` 指定，或手工改 `config-manifest.json`。填错的表现是 `verify` A 段全 `FAIL known config missing` 且 `snapshot` 直接 `throw`。
2. **计划任务未纳入**：母版里 `DshPurgeUpdateWatch` 是「定期检查 purge 版本变化」的哨兵，属于本机自定义项，本包不含。想加就自己建一个每 15 分钟跑 `verify.ps1 -Strict` 的任务；`verify` D 段会自动从 `WARN` 转 `PASS`。
3. **F 项（资产表常量）需要额外调研产物**：`state\asset-table-keys.json`、`state\dsh-purge-pkg.sha256` 由母版的 `detect-purge-master.ps1` 生成，本包不含该工具（硬编码了母机路径）。客户机要做同类校验，需自行对本地 `dsh-purge` 检出提取 IV/MASK/SLOT/TAG 与包哈希。
4. **ACL 只保护两个文件**：`aclDeny` 是「最有价值且被 purge 反复重写」的项。想扩到整个 `profiles/web/` 也可以，但每次 dsh 写配置都会被挡，日常会很烦；建议保持最小集。
5. **恢复不是合并**：`restore.ps1` 以快照为准覆盖同名文件，**不会**保留你后来新增的项；恢复前先 `-Plan` 确认。
6. **跨机器不可直接搬快照**：`snap\` 下是本机配置内容，换机必须重新拍基准；`state\` 下的封存/状态文件同理。
7. **分发版的 3 处差异**（路径参数化 / D1 恢复兼容 / F 项降级）见《可复用性判定（reusability-report）》第四节；母版未改动。

## 10. 附录：本包发布前的端到端演练记录

在临时 vault + 临时 home（`<沙箱>\{vault,home}`）上跑完整链路，模拟「配置被清空」：

| 步骤 | 命令 | 结果 |
|---|---|---|
| 部署 | `deploy.ps1 -DshHome <沙箱>\home -Vault <沙箱>\vault` | 拍 `baseline`（8 files），`seal` 封存，verify `0 FAIL / 5 WARN (5 expected, 0 unexpected)`（其中 `acl-off` = 未加 `-Lock`，正常） |
| 模拟清空 | 删除 `prompt-inject.md`、`agent.cordis.yml`、`whale-roles\`、`cordis.patch.yml`、`package.json`、`skills\` | 6 个文件/目录消失 |
| 清空后自检 | `verify.ps1` | `5 FAIL`（known missing）+ `WARN 源与快照有 6 处差异 … (missing)` ← **故障被抓住** |
| 计划 | `restore.ps1 -Tag baseline -Plan` | 列出 6 条 `OVERWRITE`，`PLAN ONLY: nothing written.`，退出码 2 |
| 恢复 | `restore.ps1 -Tag baseline -Force` | 拍 `pre-restore-20261108-134859`（残状 2 files，`-AllowMissing` 容忍缺失）→ 恢复 6 个文件 → `PASS restored 6 file(s)` |
| 恢复后自检 | `verify.ps1` | `0 FAIL / 5 WARN (5 expected, 0 unexpected)` ← **恢复成功** |
| 上锁 | `acl.ps1 -Action Lock` | 两条 `LOCKED`，C 段转 `PASS` |
| 闸门 | `purge-gate.ps1 -DryRun` | `CHANGE detected: first-run` → `DRYRUN would snapshot as pre-0.2.1-rc.5-15166008` |

> 这次演练同时暴露并修掉了母版的一个真缺陷：配置被清空后 `restore.ps1 -Force` 会因「恢复前安全快照失败」而 `BLOCKED`，即最需要恢复的场景反而恢复不了。分发版用 `-AllowMissing` 修好（D1），演练记录见上表第 5 行。

---

---

## 11. 作为 GitHub 仓库维护

这个目录本身就是仓库内容（`https://github.com/hanghangworker-ui/dsh-backup-pro`），所以「部署」和「克隆」是同一步：

```powershell
git clone https://github.com/hanghangworker-ui/dsh-backup-pro.git D:\dsh-config-vault
```

### 11.1 目录约定

| 路径 | 作用 | 是否入库 |
|---|---|---|
| `scripts/` | 全部工具脚本（UTF-8 **with BOM** + CRLF） | 是 |
| `config/config-manifest.template.json` | 清单模板（`(待补充：…)` 占位） | 是 |
| `docs/` | 手册与可复用性判定 | 是 |
| `config-manifest.json` | 本机实清单（由 `deploy.ps1` 生成） | **否**（`.gitignore`） |
| `snap/`、`state/` | 快照与运行状态 | **否**（含真实配置副本，误提交等于泄露） |
| `.github/workflows/ci.yml` | CI：BOM 检查 + 双引擎解析 + 模板 JSON + 沙箱冒烟（清空→恢复→复验） | 是 |

### 11.2 三条必须守住的仓库规矩

1. **`.ps1` 必须带 BOM。** Windows PowerShell 5.1 会把无 BOM 的 UTF-8 按 GBK 解码，然后把中文字符串撕成半截，
   报一堆「字符串缺少终止符 / 缺少右 `}`」的假错误——这正是本机制第一版踩过的坑。
   `.editorconfig` 写了 `charset = utf-8-bom`，`.gitattributes` 固定 `*.ps1 text eol=crlf`，CI 再兜一层。
   被编辑器剥掉就跑 `scripts/fix-bom.ps1`。
2. **不要把 `snap/`、`state/`、`config-manifest.json` 提交上去。** 它们含真实配置内容与机器路径。
3. **不要在脚本里硬编码本机路径。** 一律 `$Vault` / `$ManifestPath` 参数，缺省取「脚本所在目录的父目录」。

### 11.3 发布/更新流程

```powershell
cd D:\dsh工作区\repo\dsh-backup-pro
pwsh -NoProfile -File scripts/verify.ps1          # 本地先自检，G 段会报编码/JSON
git add -A
git commit -m "feat: ..."
git branch -M main
git remote add origin https://github.com/hanghangworker-ui/dsh-backup-pro.git   # 首次
git push -u origin main
```

CI 会在 `windows-latest` 上跑：BOM 检查 → PowerShell 7 解析 → Windows PowerShell 5.1 解析 →
模板 JSON 校验 → 沙箱 `deploy → 删文件 → restore -Force → verify`。绿灯才发。

### 11.4 版本与变更记录

- 语义化版本：脚本行为/参数变动 = minor 或 major，纯文档/文案 = patch。
- 每次改逻辑都要在 `CHANGELOG.md` 写「为什么」，尤其是修缺陷（写清「不修会怎样」）。
- 已发布缺陷示例：**D1**（配置被清空后 restore 被自己的安全快照挡住）、
  **D2**（`dependencies` 为空、或 `dependencies` 字段整体缺失时，`snapshot.ps1` / `purge-gate.ps1` 在 `Set-StrictMode` 下抛「找不到属性 Name」；修法是先取对象再用 `PSObject.Properties['dependencies']` 判字段存在性）——
  两者都属于「最该工作的场景反而失败」，所以进了 CI 冒烟用例。

---

### 附：命令速查

```powershell
$V = 'D:\dsh-config-vault\scripts'

pwsh -NoProfile -File "$V\deploy.ps1"   -DshHome '<DSH_HOME>' -Vault 'D:\dsh-config-vault' -Lock
pwsh -NoProfile -File "$V\snapshot.ps1" -Tag baseline
pwsh -NoProfile -File "$V\seal-baseline.ps1"
pwsh -NoProfile -File "$V\verify.ps1"
pwsh -NoProfile -File "$V\restore.ps1"  -Tag baseline -Plan
pwsh -NoProfile -File "$V\restore.ps1"  -Tag baseline -RequireIdle -Force
pwsh -NoProfile -File "$V\acl.ps1"      -Action Check
pwsh -NoProfile -File "$V\purge-gate.ps1" -DryRun
pwsh -NoProfile -File "$V\acceptance-r2.ps1" -SkipRestore
pwsh -NoProfile -File "$V\fix-bom.ps1"
```

## 12. 作为 dsh 插件运行（可选）

本仓库同时是一个 **Host-only bundle**，可被 dsh 直接安装，装好后宿主会多出 7 个 `dsh_backup_*` 工具。

### 12.1 安装

```text
plugin_manager({ action: "install_bundle", target: "D:\\path\\to\\dsh-backup" })
```

不要手写 profile 的 `package.json` / `cordis.patch.yml`。装完确认：

1. `profiles/<name>/package.json` 的 `dsh.profile.bundles` 出现 `@hanghangworker-ui/dsh-backup-pro`；
2. `profiles/<name>/node_modules/@hanghangworker-ui/dsh-backup-pro` 存在；
3. 工具列表出现 `dsh_backup_list_versions` 等 7 项。

### 12.2 版本库与切换（适配 purge 的版本需求）

```powershell
# 1) 入库：meta 秒级（不可切换）；full 含 node_modules（可切换，体积大）
pwsh -NoProfile -File scripts/version-store.ps1 -Action Save -Mode meta  -Vault D:\dsh-config-vault
pwsh -NoProfile -File scripts/version-store.ps1 -Action Save -Mode full  -Vault D:\dsh-config-vault

# 2) 校验
pwsh -NoProfile -File scripts/version-store.ps1 -Action Verify -Vault D:\dsh-config-vault

# 3) 切换（必须没有 dsh 在跑）
pwsh -NoProfile -File scripts/switch-version.ps1 -Action Plan  -Version 0.2.1-rc.5 -Vault D:\dsh-config-vault
pwsh -NoProfile -File scripts/switch-version.ps1 -Action Apply -Version 0.2.1-rc.5 -Vault D:\dsh-config-vault
pwsh -NoProfile -File scripts/switch-version.ps1 -Action Rollback -Vault D:\dsh-config-vault
```

产物：`<vault>/versions/<ver>/{meta.json, core-manifest.txt, payload.zip}`；
安装目录旁会留 `<install>.bak-<ts>`（回滚点）、`<install>.rollback-<ts>`、`<install>.failed-<ts>`。

设计细节（存储字段、去重、切换五步与回滚、purge 版本适配、编码方案）见
[plugin.zh-CN.md](plugin.zh-CN.md)。

### 12.3 与既有三层的关系

- 插件**不替代**任何一层：`snapshot/restore/acl/purge-gate/verify` 逻辑未被改写，插件只是调用方；
- 版本库解决的是「dsh 本体版本」问题，三层解决的是「配置内容」问题，两者互不覆盖；
- 切换 dsh 版本后仍应跑 `dsh_backup_config_check`，确认配置层没有被牵连。
