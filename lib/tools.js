/**
 * 全部 `dsh_backup_*` 工具定义。
 *
 * 只注册「普通对象」工具（不 import 任何 `@deepseek-ai/*` 值），
 * 与宿主 `dsh-ops` 的做法一致：`ctx.tools.register(definition)`，
 * `definition.execute(args, exec)` 由宿主的调度器调用。
 *
 * @module dsh-backup/lib/tools
 */
import fs from 'node:fs';
import path from 'node:path';
import { runScript } from './ps.js';

const LONG_MS = 30 * 60 * 1000; // 全量打包（含 node_modules）可能很慢
const NORMAL_MS = 5 * 60 * 1000;

/** 统一输出契约：一行 headline + 完整输出，模型读 text 即可。 */
const SHELL_OUTPUT = {
  schema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      ok: { type: 'boolean', required: true },
      exitCode: { type: 'number' },
      headline: { type: 'string', required: true },
      text: { type: 'string', required: true },
      truncated: { type: 'boolean' },
      hint: { type: 'string' },
    },
  },
  render: (_args, value) => [{ type: 'text', text: value.text }],
};

function renderShell({ title, result }) {
  const lines = [`[${result.ok ? 'OK' : 'FAIL'}] ${title}（exit=${result.exitCode ?? 'null'}, ${result.ms}ms）`];
  if (result.stdout.trim()) lines.push(result.stdout.replace(/\s+$/, ''));
  if (result.stderr.trim()) lines.push('--- stderr ---', result.stderr.replace(/\s+$/, ''));
  if (result.timedOut) lines.push('! 命令超时（可能仍在后台运行或已被杀）');
  if (result.truncated) lines.push('! 输出过长，已保留尾部');
  return lines.join('\n');
}

function toValue(title, result, hint) {
  const text = renderShell({ title, result });
  const value = {
    ok: result.ok,
    headline: `${title} -> ${result.ok ? 'OK' : 'FAIL'} (exit ${result.exitCode ?? 'null'})`,
    text,
    exitCode: result.exitCode ?? undefined,
    truncated: result.truncated,
  };
  if (hint) value.hint = hint;
  return value;
}

/** 读取一个目录下的 meta.json（不存在则返回空数组）。 */
function readMetas(dir) {
  if (!fs.existsSync(dir)) return [];
  const rows = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const metaPath = path.join(dir, entry.name, 'meta.json');
    if (!fs.existsSync(metaPath)) continue;
    try {
      const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8').replace(/^\uFEFF/, ''));
      rows.push({
        version: String(meta.version ?? entry.name),
        mode: String(meta.mode ?? 'unknown'),
        capturedAt: String(meta.capturedAt ?? ''),
        coreFiles: Number(meta.coreFiles ?? 0),
        payloadMB: Math.round((Number(meta.payloadBytes ?? 0) / 1048576) * 10) / 10,
        switchCapable: meta.switchCapable === true,
        sharedWith: meta.sharedWith ?? undefined,
      });
    } catch (error) {
      rows.push({
        version: entry.name,
        mode: 'broken',
        capturedAt: '',
        coreFiles: 0,
        payloadMB: 0,
        switchCapable: false,
        error: String(error?.message ?? error),
      });
    }
  }
  rows.sort((a, b) => a.version.localeCompare(b.version));
  return rows;
}

function readInstalledVersion(installDir) {
  const pkg = path.join(installDir, 'package.json');
  if (!fs.existsSync(pkg)) return undefined;
  try {
    return String(JSON.parse(fs.readFileSync(pkg, 'utf8').replace(/^\uFEFF/, '')).version ?? '');
  } catch {
    return undefined;
  }
}

/**
 * 解析 dsh 安装目录（与 scripts/*.ps1 的 Resolve-DshInstall 同序）。
 * 顺序：config.install → DSH_BACKUP_DSH_INSTALL → %APPDATA%\npm\node_modules\@deepseek-ai\dsh
 */
function resolveInstall(explicit) {
  const candidates = [];
  if (explicit) candidates.push(explicit);
  if (process.env.DSH_BACKUP_DSH_INSTALL) candidates.push(process.env.DSH_BACKUP_DSH_INSTALL);
  if (process.env.APPDATA) candidates.push(path.join(process.env.APPDATA, 'npm', 'node_modules', '@deepseek-ai', 'dsh'));
  for (const candidate of candidates) {
    if (candidate && fs.existsSync(path.join(candidate, 'package.json'))) return path.resolve(candidate);
  }
  return undefined;
}

/**
 * 读已装 dsh-purge-community 对 dsh 版本的适配声明（读不到返回 undefined）。
 *
 * purge 1.6.84 实测：`peerDependencies` 只声明 `@deepseek-ai/cordis`，**不含** dsh；
 * 真正的版本约束在 `dsh.compatibility`（`dsh` 范围 + `dshReleases` 逐版本判定）。
 */
function readPurgeCompat(dshHome) {
  if (!dshHome) return undefined;
  const pkg = path.join(dshHome, 'profiles', 'web', 'node_modules', 'dsh-purge-community', 'package.json');
  if (!fs.existsSync(pkg)) return undefined;
  try {
    const parsed = JSON.parse(fs.readFileSync(pkg, 'utf8').replace(/^\uFEFF/, ''));
    const compat = parsed?.dsh?.compatibility;
    if (!compat) return { version: String(parsed.version ?? ''), range: undefined, releases: undefined };
    return {
      version: String(parsed.version ?? ''),
      range: compat.dsh ? String(compat.dsh) : undefined,
      releases: compat.dshReleases && typeof compat.dshReleases === 'object' ? compat.dshReleases : undefined,
    };
  } catch {
    return undefined;
  }
}

/**
 * @param {{root: string, vault: string, install?: string, dshHome?: string}} env
 */
export function createTools(env) {
  const vaultArgv = () => ['-Vault', env.vault];
  const manifestPath = () => path.join(env.vault, 'config-manifest.json');
  /** 配置类脚本都依赖 config-manifest.json；缺失时给出可执行的提示，而不是抛宿主栈。 */
  const requireManifest = (tool) => {
    if (fs.existsSync(manifestPath())) return undefined;
    return {
      ok: false,
      headline: `${tool}: 缺少 config-manifest.json`,
      text: `[FAIL] ${tool}\n未找到 ${manifestPath()}\n请先在该 vault 目录执行一次部署：\n  pwsh -NoProfile -File "${path.join(env.root, 'scripts', 'deploy.ps1')}" -DshHome <配置目录> -Vault "${env.vault}"\n或把插件配置的 vault 指向已有 vault（当前 vault=${env.vault}）。`,
    };
  };
  const installArgv = () => {
    const install = resolveInstall(env.install);
    return install ? ['-Source', install] : [];
  };

  /** @type {object[]} */
  return [
    {
      name: 'dsh_backup_list_versions',
      description:
        '列出 dsh 版本库里的全部版本记录（只读）。返回当前 dsh 安装版本、每个已存版本的模式（meta=仅核心清单，full=含 payload 可切换）、是否有 payload。切换版本前先用它确认目标版本 switchCapable=true。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          install: { type: 'string', description: '可选：dsh 安装目录绝对路径（默认自动探测）。' },
        },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            ok: { type: 'boolean', required: true },
            vault: { type: 'string', required: true },
            install: { type: 'string' },
            installedVersion: { type: 'string' },
            versions: { type: 'array', required: true, items: { type: 'object' } },
            text: { type: 'string', required: true },
          },
        },
        render: (_args, value) => [{ type: 'text', text: value.text }],
      },
      execute(args) {
        const install = resolveInstall(args?.install ?? env.install);
        const installedVersion = install ? readInstalledVersion(install) : undefined;
        const versions = readMetas(path.join(env.vault, 'versions'));
        const lines = [
          `vault           = ${env.vault}`,
          `install         = ${install ?? '(未找到；用 install 参数或 DSH_BACKUP_DSH_INSTALL 指定)'}`,
          `installedVersion= ${installedVersion ?? '(未知)'}`,
          `versions        = ${versions.length}`,
        ];
        const purge = readPurgeCompat(env.dshHome);
        if (purge) {
          lines.push(
            `purge           = dsh-purge-community@${purge.version || '?'}  dsh范围=${purge.range ?? '(未声明)'}`,
          );
        } else {
          lines.push('purge           = (未探测：配置 dshHome 或设 DSH_BACKUP_DSH_HOME 可显示版本适配)');
        }
        for (const row of versions) {
          const mark = row.version === installedVersion ? '*' : ' ';
          const compat = purge?.releases ? (purge.releases[row.version] ?? 'unknown') : undefined;
          row.purgeCompat = compat;
          lines.push(
            `${mark} ${row.version}  mode=${row.mode}  core=${row.coreFiles}  payload=${row.payloadMB}MB  switchable=${row.switchCapable}${compat ? `  purgeCompat=${compat}` : ''}${row.sharedWith ? `  sharedWith=${row.sharedWith}` : ''}`,
          );
        }
        if (versions.length === 0) lines.push('（版本库为空：先调用 dsh_backup_save_version）');
        const text = lines.join('\n');
        return {
          ok: true,
          vault: env.vault,
          install: install ?? undefined,
          installedVersion,
          versions,
          text,
        };
      },
    },

    {
      name: 'dsh_backup_save_version',
      description:
        '把当前 dsh 安装（或指定目录）存进版本库。mode=meta 只记录核心文件清单（秒级，不可切换）；mode=full 额外打 payload.zip（含 node_modules，约 700MB，可能数分钟，之后可切换）。同一版本重复保存需 force=true。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          mode: { type: 'string', enum: ['meta', 'full'], description: '默认 meta。' },
          install: { type: 'string', description: '可选：dsh 安装目录绝对路径。' },
          force: { type: 'boolean', description: '覆盖已存在的 payload。' },
        },
      },
      output: SHELL_OUTPUT,
      async execute(args) {
        const mode = args?.mode === 'full' ? 'full' : 'meta';
        const argv = ['-Action', 'Save', '-Mode', mode, ...vaultArgv()];
        if (args?.install) argv.push('-Source', args.install);
        else argv.push(...installArgv());
        if (args?.force === true) argv.push('-Force');
        const result = await runScript(env.root, 'version-store.ps1', argv, {
          timeoutMs: mode === 'full' ? LONG_MS : NORMAL_MS,
        });
        return toValue(`版本入库（mode=${mode}）`, result, mode === 'meta' ? 'meta 模式不可切换；要能切换请用 mode=full。' : undefined);
      },
    },

    {
      name: 'dsh_backup_verify_store',
      description:
        '校验版本库完整性（只读）：meta.json 是否齐全、core-manifest.txt 指纹是否与 meta 记录一致、full 的 payload.zip SHA256 是否一致。切换版本前建议先跑一次。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: { version: { type: 'string', description: '可选：只校验某个版本。' } },
      },
      output: SHELL_OUTPUT,
      async execute(args) {
        const argv = ['-Action', 'Verify', ...vaultArgv()];
        if (args?.version) argv.push('-Version', String(args.version));
        const result = await runScript(env.root, 'version-store.ps1', argv, { timeoutMs: NORMAL_MS });
        return toValue('版本库完整性校验', result);
      },
    },

    {
      name: 'dsh_backup_switch_version',
      description:
        '切换 dsh 安装版本（适配 purge 的版本需求）。action=status 看现状；plan 只演算不改动；apply 真正切换（会先 -RequireIdle 式空闲检查，需 confirm=true）；rollback 回到上一次备份（也需 confirm=true）。apply/rollback 会重命名安装目录并在失败时自动回滚。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: { type: 'string', enum: ['status', 'plan', 'apply', 'rollback'], required: true },
          version: { type: 'string', description: 'plan/apply 的目标版本；rollback 可传具体备份时间戳。' },
          install: { type: 'string', description: '可选：dsh 安装目录绝对路径。' },
          skipIdleCheck: { type: 'boolean', description: '跳过「有 dsh 进程在跑」检查（危险，默认 false）。' },
          confirm: { type: 'boolean', description: 'apply/rollback 必须为 true，否则拒绝执行。' },
        },
      },
      output: SHELL_OUTPUT,
      async execute(args) {
        const action = String(args?.action ?? 'status').toLowerCase();
        if ((action === 'apply' || action === 'rollback') && args?.confirm !== true) {
          return {
            ok: false,
            headline: '需要 confirm=true',
            text: `[REFUSED] action=${action} 会改写 dsh 安装目录。确认目标版本可用、且当前不需要运行 dsh 后，再以 confirm=true 调用。\n建议顺序：dsh_backup_list_versions → dsh_backup_verify_store → action=plan → action=apply(confirm=true)。`,
          };
        }
        const argv = ['-Action', action.charAt(0).toUpperCase() + action.slice(1), ...vaultArgv()];
        if (args?.version) argv.push('-Version', String(args.version));
        if (args?.install) argv.push('-Source', args.install);
        else argv.push(...installArgv());
        if (args?.skipIdleCheck === true) argv.push('-SkipIdleCheck');
        const result = await runScript(env.root, 'switch-version.ps1', argv, { timeoutMs: LONG_MS });
        const hint =
          action === 'plan' && result.exitCode === 2
            ? '目标版本缺少 payload：先 dsh_backup_save_version(mode="full", install=<该版本安装目录>)，或用 npm 装回该版本后再存。'
            : undefined;
        return toValue(`版本切换 ${action}`, result, hint);
      },
    },

    {
      name: 'dsh_backup_snapshot',
      description:
        '对配置目录（manifest 的 dshHome）做一次受保护快照，写入 snap/<tag>。tag 省略时用时间戳。会临时解除层3 的 ACL 拒写并在 finally 里重新加锁（打 TEMPORARILY UNLOCKED / RELOCKED）。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          tag: { type: 'string', description: '快照标签；省略则自动时间戳。' },
        },
      },
      output: SHELL_OUTPUT,
      async execute(args) {
        const missing = requireManifest('dsh_backup_snapshot');
        if (missing) return missing;
        const argv = ['-Vault', env.vault, '-ManifestPath', manifestPath()];
        if (args?.tag) argv.push('-Tag', String(args.tag));
        const result = await runScript(env.root, 'snapshot.ps1', argv, { timeoutMs: NORMAL_MS });
        return toValue('配置快照', result);
      },
    },

    {
      name: 'dsh_backup_config_check',
      description:
        '十段式配置体检（只读）：配置存在性、快照新鲜度（对照 referenceTag）、baseline 封存、ACL 三态、计划任务、gate 状态、脚本编码与 JSON 可解析等。strict=true 时 unexpected WARN 会让退出码非 0。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: { strict: { type: 'boolean', description: '启用严格模式（默认 true）。' } },
      },
      output: SHELL_OUTPUT,
      async execute(args) {
        const missing = requireManifest('dsh_backup_config_check');
        if (missing) return missing;
        const argv = ['-Vault', env.vault, '-ManifestPath', manifestPath()];
        if (args?.strict !== false) argv.push('-Strict');
        const result = await runScript(env.root, 'verify.ps1', argv, { timeoutMs: NORMAL_MS });
        return toValue('配置体检', result);
      },
    },

    {
      name: 'dsh_backup_purge_gate',
      description:
        'purge 前的写前闸门（默认 dry-run，只演算）：对比 dsh/插件版本 + 清单指纹 + 内容摘要四段指纹，决定 purge 是否放行、是否需要先拍 pre 快照。dryRun=false 时才可能真正落盘快照。',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: { dryRun: { type: 'boolean', description: '默认 true。' } },
      },
      output: SHELL_OUTPUT,
      async execute(args) {
        const missing = requireManifest('dsh_backup_purge_gate');
        if (missing) return missing;
        const argv = ['-Vault', env.vault, '-ManifestPath', manifestPath()];
        if (args?.dryRun !== false) argv.push('-DryRun');
        const result = await runScript(env.root, 'purge-gate.ps1', argv, { timeoutMs: NORMAL_MS });
        return toValue('purge 闸门', result, result.stdout.includes('DRYRUN') ? 'DRYRUN 未落盘；确认无误后用 dryRun=false 执行。' : undefined);
      },
    },
  ];
}
