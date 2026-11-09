# dsh-backup-pro 插件设计与实现（v2.1.1）

> 目标：把 `dsh-backup-pro` 从「PowerShell 脚本 + 文档」改造成**可被 dsh 安装的 bundle**，并具备
> 「把 dsh 的每一个版本各存一份、随时切换，用来适配 purge 的版本需求」的能力。
>
> 本文只描述**已落地**的实现与取舍；标注 `(待补充：…)` 的是需要在本机实测/上线后才能确定的项。

---

## 1. 现状梳理：脚本职责、调用关系、产物

### 1.1 脚本分工

| 脚本 | 层 | 职责 | 主要参数 |
|---|---|---|---|
| `deploy.ps1` | — | 一键部署：建目录、探测清单、拍 baseline、封存、可选定锁、跑体检 | `-DshHome`（必填）`-Vault` `-Tag` `-Lock` `-SkipSnapshot` |
| `vault-common.ps1` | — | 公共库：锁（PID 重入 + stale 清理）、哈希、保留策略、日志轮转 | 被 dot-source，不单独运行 |
| `snapshot.ps1` | 1 | 按清单把配置复制到 `snap/<tag>/`，写 `_manifest.csv`、`_versions.json`、digest | `-Tag` `-PruneWhatIf` `-AllowMissing` |
| `restore.ps1` | 1 | 从 tag 回滚；默认只读，`-Force` 走 staging → commit；自带 `pre-restore-*` 安全快照 | `-Tag` `-Plan` `-Force` `-RequireIdle` |
| `purge-gate.ps1` | 2 | 写前闸门：四段指纹判是否需先拍 pre 快照；fail-closed | `-DryRun` |
| `acl.ps1` | 3 | 对 `aclDeny` 项 `icacls` 拒写/拒删 | `-Action Status\|Check\|Lock\|Unlock\|Recover` |
| `verify.ps1` | — | 十段自检，输出 `SUMMARY: x FAIL / y WARN (a expected, b unexpected)` | `-Tag` `-Strict` |
| `seal-baseline.ps1` | — | 把 baseline 指纹封存到快照之外（防「先改后拍」） | `-Tag baseline` `-Force` |
| `acceptance-r2.ps1` | — | 自验收：fail-closed 注入 + 体检 | `-SkipRestore` |
| `fix-bom.ps1` | — | 幂等补 UTF-8 BOM | `-Path` |
| **`version-store.ps1`** | 新 | dsh 版本库：入库/列表/校验/清理 | `-Action List\|Show\|Save\|Verify\|Prune\|Path` `-Mode meta\|full` |
| **`switch-version.ps1`** | 新 | 切换 dsh 安装版本（含备份与自动回滚） | `-Action Status\|Plan\|Apply\|Rollback` |

### 1.2 调用关系

```
deploy.ps1 ──► snapshot.ps1 ──► seal-baseline.ps1 ──► acl.ps1(Lock) ──► verify.ps1
                  │                    │                                   ▲
purge-gate.ps1 ───┘（写前必拍 pre-*）  └─ state/baseline-integrity.json ──┘
restore.ps1 ──► snapshot.ps1(pre-restore-*) ──► 逐文件写回 ──► verify.ps1（人工复跑）
version-store.ps1 ◄── 只读 dsh 安装目录（不碰 vault 的 snap/state）
switch-version.ps1 ◄── 只动 dsh 安装目录（不碰 vault）
```

### 1.3 产物位置与格式

| 位置 | 内容 | 格式 |
|---|---|---|
| `<vault>/snap/<tag>/` | 配置副本 | 原文件 + `_manifest.csv`（RelPath,Sha256,Size）+ `_versions.json`（含 `snapshotDigest`/`manifestSha256`） |
| `<vault>/state/` | `last-applied.json`、`pending-post.json`、`baseline-integrity.json`、`gate.log` | JSON / 文本日志 |
| `<vault>/versions/<ver>/`（新） | `meta.json`、`core-manifest.txt`、`payload.zip`（仅 full） | 见第 2 节 |
| dsh 安装目录旁（新） | `<install>.bak-<ts>`、`<install>.rollback-<ts>`、`<install>.failed-<ts>` | 目录重命名备份 |

### 1.4 可直接复用 vs 需新增

- **直接复用（逻辑未改）**：`snapshot.ps1`、`restore.ps1`、`purge-gate.ps1`、`acl.ps1`、`verify.ps1`、
  `seal-baseline.ps1`、`deploy.ps1`、`vault-common.ps1`、`fix-bom.ps1` —— 插件只负责**调用**，不重新实现。
- **新增**：`version-store.ps1`、`switch-version.ps1`（本任务的核心），以及插件骨架
  `package.json` / `cordis.patch.yml` / `index.js` / `lib/{plugin,tools,ps}.js` / `locale/{en,zh}.json` / `icon.svg`。
- **顺带修掉的 3 个真缺陷**（原脚本在特定输入下会崩，插件会让它更容易被触发）：
  - D2：`package.json` 缺 `dependencies` 字段时 `$obj.dependencies.PSObject` 在 StrictMode 下抛错 →
    改为先取对象再判属性存在性。
  - D3：`verify.ps1` B 段在没有 `snap/` 目录时 `$selName` 未初始化 → `无法检索变量 '$selName'`；
    改为进入 B 段前 `$selName = ''`。
  - D4：`verify.ps1` 只给 `-ManifestPath`、不给 `-Vault` 时，`$Vault` 仍取脚本父目录（脚本被借用时指错地方）→
    改为优先从 `-ManifestPath` 的父目录推导 `$Vault`。

---

## 2. 多版本存储设计

### 2.1 存放位置

```
<vault>/versions/<version>/
├─ meta.json          版本元数据（唯一真源）
├─ core-manifest.txt  dsh 核心文件清单："rel  sha256  size"（按 rel 排序）
└─ payload.zip        仅 mode=full：整个安装目录（含 node_modules）的 zip
```

`<vault>` 解析顺序：插件 `config.vault` → 环境变量 `DSH_BACKUP_VAULT` → 插件包根目录。
**不放在** dsh 安装目录里：`npm i -g` 升级会整目录替换，版本库必须外置。

### 2.2 命名与版本标识来源

- 目录名 = 版本号原文（如 `0.2.1-rc.5`），来自 `<install>/package.json` 的 `version` 字段
  （`Get-InstalledVersion`）。**不猜、不排序推断**，避免 `rc.10 < rc.9` 之类的字典序陷阱。
- 安装目录解析（`Resolve-DshInstall`）：`-Source` → `npm root -g` + `@deepseek-ai/dsh` →
  `%APPDATA%\npm\node_modules\@deepseek-ai\dsh`。插件侧同序（`config.install` → `DSH_BACKUP_DSH_INSTALL` → 默认路径）。

### 2.3 meta.json 字段

```json
{
  "version": "0.2.1-rc.5",
  "package": "@deepseek-ai/dsh",
  "mode": "meta",
  "capturedAt": "2026-11-08T15:58:55.5727041+08:00",
  "source": "C:\\Users\\<user>\\AppData\\Roaming\\npm\\node_modules\\@deepseek-ai\\dsh",
  "coreFiles": 22,
  "coreBytes": 81213,
  "coreManifestSha": "9d556463…",
  "payloadSha256": null,
  "payloadBytes": 0,
  "sharedWith": null,
  "switchCapable": false
}
```

- `mode=meta`：只记录核心文件（根目录文件 + 各一级子目录，**跳过 node_modules**）。实测本机 dsh
  核心 = 22 文件 / 81 KB，秒级完成，但**不能切换**（没有 payload）。
- `mode=full`：额外 `Compress-Archive` 整个安装目录。本机实测 node_modules ≈ 693.5 MB，
  压缩后体积与耗时 `(待补充：首次 full 入库实测)`；接口按 30 分钟超时设计。
- `coreManifestSha` 取 `core-manifest.txt` **落盘文件字节**的 SHA256（不是文本哈希）——
  否则 `Set-Content` 的换行差异会让自校验必然失败（这个坑实测踩过）。

### 2.4 去重

`payloadSha256` 相同视为同一份内容：新记录写 `sharedWith=<已有版本名>`，`payload.zip` 只保留一份
（`Save` 时若目标 zip 已存在且未 `-Force`，直接复用不再压缩）。恢复/切换仍按版本目录定位，
所以「删 zip 只留 meta」不会破坏流程 —— 但该版本随之失去切换能力。

### 2.5 完整性校验

`version-store.ps1 -Action Verify`：

1. `meta.json` 是否存在且可解析；
2. `core-manifest.txt` 的文件字节 SHA256 是否等于 `meta.coreManifestSha`；
3. `mode=full` 时 `payload.zip` 的 SHA256 是否等于 `meta.payloadSha256`。

输出 `PASS <ver> : 完整性 OK (mode=...)` / `FAIL`，全通过 exit 0。插件侧 `dsh_backup_verify_store` 直接暴露。

---

## 3. 版本切换设计

### 3.1 输入

- 目标版本 `-Version <ver>`（必填，`plan`/`apply`）；
- 安装目录 `-Source`（可选，默认自动探测）；
- `-SkipIdleCheck`（默认关闭：**有 dsh 进程在跑就拒绝切换**）；
- `-KeepStaging`（保留展开目录便于排错）。

### 3.2 切换范围

**只动 dsh 安装目录本身**（整目录原子换名），不触碰：

- `<vault>/snap`、`<vault>/state`（配置备份与闸门状态）；
- 用户 dsh home（`prompt-inject.md`、`profiles/` 等）—— 这些由 `snapshot/restore` 管，与版本无关；
- 全局 npm 的其他包。

```
步骤 1/5  展开 payload.zip → <vault>/versions/<ver>/staging-<ts>
步骤 2/5  校验 staging/package.json.version == 目标版本（不符即中止，未改动安装目录）
步骤 3/5  Rename <install> → <install>.bak-<ts>          ← 备份点
步骤 4/5  Move staging → <install>
步骤 5/5  复核 <install>/package.json.version
```

### 3.3 失败回滚

- 步骤 4 失败：删除半成品 → 把 `.bak-<ts>` 改回原名 → exit 1。
- 步骤 5 复核不符：把新目录改名 `.failed-<ts>` → 把 `.bak-<ts>` 改回原名 → exit 1 并打印回滚后版本。
- 手工回滚：`switch-version.ps1 -Action Rollback`（默认取最近一次 `.bak-*`；也可 `-Version <ts>` 指定）。
  回滚同样先做空闲检查，被替换的版本保留为 `<install>.rollback-<ts>`。

### 3.4 切换后如何验证生效

1. 脚本自身已按 `package.json.version` 复核（步骤 5）；
2. `dsh_backup_list_versions` 会以 `*` 标出与 `installedVersion` 一致的版本；
3. 重开 dsh 后 `dsh --version` / 宿主关于信息应与目标版本一致；
4. 再跑 `dsh_backup_config_check`，确认配置层未被牵连（B/E/E3 段应仍 PASS）。

> 限制：切换前必须**退出 dsh**。本插件的空闲检查用 `Get-CimInstance Win32_Process` 找
> `node.exe`/`dsh.exe` 且命令行含 `dsh` 的进程 —— 在 dsh 自己的会话里调用 `apply` 必然被拒，
> 正确用法是在 dsh 之外的终端执行。

---

## 4. 与 purge 版本需求的适配

### 4.1 如何知道 purge 需要哪个 dsh 版本

1. **读 purge 的声明**（已核实，dsh-purge-community `1.6.84`）：

   | 字段 | 实测值 | 含义 |
   |---|---|---|
   | `peerDependencies` | `{"@deepseek-ai/cordis":"^4.0.1"}` | **不含 dsh**，不是硬约束 |
   | `peerDependenciesMeta` | 未声明 | 无 optional 标记 |
   | `dependencies` | `{"yaml":"2.9.1"}` | 与版本适配无关 |
   | `engines` | `{"node":">=18"}` | 只约束 Node |
   | `dsh.compatibility.dsh` | `>=0.2.1-rc.1 <0.3.0` | **真正的版本范围声明** |
   | `dsh.compatibility.dshReleases` | `0.2.1-rc.1/rc.2/rc.3/rc.5` = `compatible`；`0.2.1-rc.4`、`0.2.2-alpha.2` = `unknown` | 逐版本判定表 |

   结论：**purge 没有用 `peerDependencies` 约束 dsh**，版本适配信息在 `dsh.compatibility` 里；
   插件据此在 `dsh_backup_list_versions` 输出 `purgeCompat=compatible|unknown`（按 `dshReleases` 精确匹配，
   表里没有的版本一律 `unknown`，不猜）。探测需要 `dshHome`：插件配置 `dshHome`，或环境变量
   `DSH_BACKUP_DSH_HOME` / `DSH_HOME`。
2. **读闸门指纹**：`state/last-applied.json` 的 `fingerprint = <dshVer>|<purgeVer>|<manifestHash>|<contentDig>`，
   第一段就是上次放行时用的 dsh 版本。
3. **读版本库**：`dsh_backup_list_versions` 里 `switchCapable=true` 的版本才是可选集合。

### 4.2 选择逻辑（建议操作序列）

```
dsh_backup_list_versions            # 看已存版本 + 当前版本
dsh_backup_verify_store             # 确认目标版本 payload 完好
dsh_backup_switch_version  action=plan  version=<目标>
   → 退出 dsh
dsh_backup_switch_version  action=apply version=<目标> confirm=true
dsh_backup_purge_gate               # dry-run：看指纹是否变为「可放行」
```

### 4.3 不匹配时的提示

| 现象 | 含义 | 处理 |
|---|---|---|
| `plan` 返回 exit 2 + `缺少可切换 payload` | 该版本只有 meta | 装回该版本后 `dsh_backup_save_version(mode=full)`，或直接用 npm 装目标版本再存 |
| `apply` 被拒 `存在运行中的 dsh 进程` | 未退出 dsh | 退出 dsh（或确认风险后 `skipIdleCheck=true`） |
| `apply` 后复核不符自动回滚 | payload 不是该版本 | 检查 `meta.version` 与 payload 来源，重拍 full |
| `purge_gate` 报 `CHANGE detected: purge/dsh` | 指纹里的版本段变了 | 属预期（正是切换的目的），此时闸门会要求先拍 pre 快照 |

---

## 5. 插件骨架（实文件）

### 5.1 `package.json`（关键字段）

```json
{
  "name": "@hanghangworker-ui/dsh-backup-pro",
  "version": "2.1.1",
  "type": "module",
  "icon": "./icon.svg",
  "exports": { ".": "./index.js", "./locale/*.json": "./locale/*.json", "./icon": "./icon.svg" },
  "files": ["index.js", "lib/", "scripts/", "cordis.patch.yml", "locale/*.json", "icon.svg", "README.md", "docs/"],
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } },
  "engines": { "node": ">=22" }
}
```

`dsh.bundle.patch` 是 bundle 的充要条件；**没有** `dsh.client` —— 本插件是 Host-only，无 Web UI。

> **npm 包名（推荐名）：`@hanghangworker-ui/dsh-backup-pro`**。GitHub 仓库名为 `dsh-backup-pro`，两者解耦：
> 安装/发布用包名，`cordis.patch.yml` 的 `id` 恒为 `dsh-backup`。旧名 `dsh-backup` 在 npm 上已被他人占用
> （latest 0.1.1），直接 `dsh plugin add dsh-backup` 装到的是别人的包。

### 5.2 `cordis.patch.yml`

```yaml
- insert:
    - id: dsh-backup
      name: '@hanghangworker-ui/dsh-backup-pro'
```

### 5.3 `index.js`

```js
export { apply, inject, name } from './lib/plugin.js';
```

### 5.4 `lib/plugin.js`（装配 + 注册）

```js
export const name = 'dsh-backup';
export const inject = ['tools'];
export const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function apply(ctx, config = {}) {
  const registry = ctx?.tools ?? (typeof ctx?.get === 'function' ? ctx.get('tools') : undefined);
  if (!registry || typeof registry.register !== 'function') throw new Error('dsh-backup: 宿主未提供 tools 注册表');
  const vault = config.vault || process.env.DSH_BACKUP_VAULT || PLUGIN_ROOT;
  const env = { root: PLUGIN_ROOT, vault: path.resolve(vault), install: config.install || process.env.DSH_BACKUP_DSH_INSTALL };
  const disposers = [];
  for (const definition of createTools(env)) {
    const disposer = registry.register(definition);
    if (typeof disposer === 'function') disposers.push(disposer);
  }
  return () => disposers.reverse().forEach((d) => { try { d(); } catch {} });
}
```

工具用**普通对象**注册（不 import 任何 `@deepseek-ai/*` 值），与宿主 `dsh-ops` 的做法一致：

```js
{
  name: 'dsh_backup_switch_version',
  description: '…',
  parameters: { type: 'object', additionalProperties: false, properties: { /* … */ } },
  output: { schema: { type: 'object', additionalProperties: false, properties: { /* … */ } },
            render: (_args, value) => [{ type: 'text', text: value.text }] },
  async execute(args, exec) { /* spawn pwsh */ },
}
```

### 5.5 `lib/tools.js`（7 个工具）

| 工具 | 后端 | 危险级别 |
|---|---|---|
| `dsh_backup_list_versions` | 纯 JS 读 `versions/*/meta.json` | 只读 |
| `dsh_backup_save_version` | `version-store.ps1 -Action Save` | 写版本库（full 重） |
| `dsh_backup_verify_store` | `version-store.ps1 -Action Verify` | 只读 |
| `dsh_backup_switch_version` | `switch-version.ps1` | **改写安装目录**，`apply/rollback` 需 `confirm=true` |
| `dsh_backup_snapshot` | `snapshot.ps1` | 写 vault，临时解锁再上锁 |
| `dsh_backup_config_check` | `verify.ps1 -Strict` | 只读 |
| `dsh_backup_purge_gate` | `purge-gate.ps1 -DryRun` | 默认只演算 |

三个配置类工具在 `config-manifest.json` 缺失时**不抛栈**，而是返回可执行的部署提示（实测见第 7 节）。

### 5.6 `locale/en.json` / `locale/zh.json`

```json
{ "meta": { "title": "DSH 配置备份", "description": "配置快照、恢复、ACL 拒写，以及 dsh 版本库——按 purge 的版本需求切换 dsh 版本。" } }
```

### 5.7 `icon.svg`

64×64、单文件矢量（978 B ≤ 256 KiB 上限），蓝色渐变底 + 白色盾牌对勾 + 三格「版本」条。

---

## 6. 编码处理方案（中文不乱码）

| 侧 | 做法 | 原因 |
|---|---|---|
| `.ps1` 文件 | **UTF-8 with BOM**（CI 强制校验） | 无 BOM 的 UTF-8 在 PowerShell 5.1 下按 GBK 解码 → 中文字符串被撕成半截 → 几十条假语法错 |
| 脚本运行时 | 每个脚本头部 `[Console]::OutputEncoding = [Text.Encoding]::UTF8` + `$OutputEncoding` | 让子进程 stdout 的字节流确定是 UTF-8 |
| JS 侧 | `spawn` **不传 `encoding`**，stdio 收 Buffer，`Buffer.concat(chunks).toString('utf8')`，再剥 `^\uFEFF` | 交给 Node 按平台默认（Windows cp936）解码必乱码 |
| 环境 | `NO_COLOR=1`、`POWERSHELL_TELEMETRY_OPTOUT=1`、`DSH_BACKUP_UTF8=1` | 去掉 ANSI 与遥测噪声，避免污染可解析输出 |
| 输出体积 | 单流 1 MiB 上限，超出保留尾部并置 `truncated=true` | 防止 full 入库/大目录列表把上下文撑爆 |
| 终端人工排查 | `... | iconv -f GBK -t UTF-8`（Git Bash 管道里） | 仅影响人工观察，不影响插件通道 |

---

## 7. 安装与验收

### 7.1 安装

```text
plugin_manager({ action: "install_bundle", target: "D:\\path\\to\\dsh-backup" })
```

不要手写 profile 的 `package.json` / `cordis.patch.yml`，也不要在 `$DSH_HOME` 里建包 —— 让 `plugin_manager` 做。

### 7.2 确认生效

1. `profiles/<name>/package.json` 的 `dsh.profile.bundles` 出现 `@hanghangworker-ui/dsh-backup-pro`；
2. `profiles/<name>/node_modules/@hanghangworker-ui/dsh-backup-pro` 存在（位置由宿主决定）；
3. 会话工具列表出现 `dsh_backup_list_versions` 等 7 项。

### 7.3 已完成的验收（本机实测）

| 项 | 命令/方式 | 结果 |
|---|---|---|
| 静态可安装性 | `check_plugin_pkg.mjs`（对照 5.1 节检查项） | 25 项全 PASS |
| 入口契约 | `import index.js` | `apply` / `inject=["tools"]` / `name=dsh-backup` |
| 工具注册 | 假 ctx `{tools:{register}}` | 注册 7 个工具，`disposer` 可回收 7 个 |
| 版本库 meta 入库 | `version-store.ps1 -Action Save -Mode meta -Vault D:\dsh-config-vault` | `PASS saved version 0.2.1-rc.5 (mode=meta core=22 files)` |
| 版本库校验 | `Verify`（含 fake 目录的 full 用例） | 全 PASS；修复前曾 100% 失败（文本哈希 vs 文件字节） |
| 切换演练（假安装 9.9.9 ⇄ 8.8.8） | `Plan` → `Apply` → `Rollback` | `PASS switched: 9.9.9 → 8.8.8`、`.bak-<ts>` 生成、`PASS rolled back: 8.8.8 → 9.9.9` |
| 配置体检（真机） | `dsh_backup_config_check` → `verify.ps1 -Strict` | `SUMMARY: 0 FAIL / 1 WARN (1 expected, 0 unexpected)`，exit 0 |
| purge 闸门（真机 dry-run） | `dsh_backup_purge_gate` | `CHANGE detected: manifest (fp=…)` + `DRYRUN would snapshot as pre-…`，未落盘 |
| 缺清单守卫 | 指向不存在的 vault | 返回部署命令提示，不抛栈 |
| 双引擎解析 | pwsh 7.6.7 + powershell 5.1 | 12 个 `.ps1` 全部 BOM=True、parseErrors=0 |
| **真实安装** | `dsh plugin --profile web add "D:\dsh工作区\repo\dsh-backup-pro"` | pnpm 6s 完成；`dependencies["@hanghangworker-ui/dsh-backup-pro"]=link:…`；`dsh.profile.bundles` 自动追加 `@hanghangworker-ui/dsh-backup-pro` |
| **组合校验** | `dsh --profile web --dump-config` | 出现 `# == @hanghangworker-ui/dsh-backup-pro` → `- id: dsh-backup / name: '@hanghangworker-ui/dsh-backup-pro'` |
| **真实 DI 挂载** | 用 dsh 自带的 `@deepseek-ai/cordis` `Context` + `ctx.provide('tools')` + `ctx.plugin()` | 注册 7 个工具；`dispose` 后回收 7 个 |
| **full 模式入库（真机）** | `version-store.ps1 -Action Save -Mode full -Vault D:\dsh-config-vault` | payload `213.2 MB`（0.21 GB），耗时 `5.0 分钟`（bsdtar，693.6 MB / 62,574 文件） |

### 7.4 未覆盖 / 待补充

- **full 模式**：已实测 `213.2 MB / 5.0 分钟`（压缩比约 `0.31`）。
  踩坑记录：`Compress-Archive` 在该量级 10 分钟零增长（等同卡死），已改为优先 Windows 自带 `bsdtar`
  （`%SystemRoot%\System32\tar.exe`，`-c --format zip`），回退 `.NET ZipFile.CreateFromDirectory`；
  **不能**用 PATH 里 Git 的 GNU tar（不支持 `--format zip`，实测 exit 2）。
- **真实安装后的工具清单**：安装与组合已实机验证（见 7.3）；7 个工具在**重启 dsh 后**才进入该会话的
  工具清单（插件在启动时装配，热装不注入当前会话），因此“本会话工具列表”未观察，已用真实 cordis DI
  挂载代替验证注册路径。
- 切换期间必须无 dsh 进程；插件在 dsh 会话内调用 `apply` 会被空闲检查拒绝，这是设计而非限制缺陷。
- `mode=full` 的 payload 体积随 dsh 版本增长，长期保存建议只对「需要回退的版本」拍 full，其余用 meta。
