/**
 * PowerShell 调用通道。
 *
 * 编码约定（中文不乱码的关键）：
 *   1. 脚本侧：`[Console]::OutputEncoding = [Text.Encoding]::UTF8`（各脚本已设置），
 *      因此子进程 stdout 的字节流是 UTF-8。
 *   2. JS 侧：**不要**给 spawn 传 `encoding`，让 stdio 保持 Buffer，
 *      收齐后 `Buffer.concat(...).toString('utf8')`，再剥掉可能的 BOM。
 *      若交给 Node 按平台默认（Windows 为 GBK/cp936）解码，中文必乱。
 *   3. 环境变量 `NO_COLOR=1` + 脚本自身用 `Write-Host` 上色，
 *      在管道场景 ANSI 码会被 PowerShell 自动省略，无需额外处理。
 *
 * @module dsh-backup/lib/ps
 */
import { spawn } from 'node:child_process';
import path from 'node:path';

/** 单次调用保留的输出上限（超出只保留尾部，避免把上下文撑爆）。 */
const MAX_STREAM_BYTES = 1024 * 1024;

/** 解析可用的 pwsh 可执行文件。 */
export function resolvePwsh() {
  return process.env.DSH_BACKUP_PWSH || 'pwsh';
}

function decode(chunks) {
  const text = Buffer.concat(chunks).toString('utf8');
  return text.replace(/^\uFEFF/, '');
}

/**
 * 运行 `scripts/<script>`。
 *
 * @param {string} root 插件包根目录
 * @param {string} script 脚本文件名（如 `snapshot.ps1`）
 * @param {string[]} argv 传给脚本的参数
 * @param {{timeoutMs?: number}} options
 * @returns {Promise<{ok: boolean, exitCode: number|null, stdout: string, stderr: string, ms: number, timedOut: boolean, truncated: boolean}>}
 */
export function runScript(root, script, argv = [], options = {}) {
  const scriptPath = path.join(root, 'scripts', script);
  const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : 120_000;
  const args = [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-OutputFormat',
    'Text',
    '-File',
    scriptPath,
    ...argv,
  ];

  return new Promise((resolve) => {
    const startedAt = Date.now();
    const out = [];
    const err = [];
    let outBytes = 0;
    let errBytes = 0;
    let truncated = false;
    let settled = false;

    let child;
    try {
      child = spawn(resolvePwsh(), args, {
        cwd: root,
        windowsHide: true,
        // 不传 encoding：stdio 保持 Buffer，由 decode() 统一按 UTF-8 解码
        env: {
          ...process.env,
          DSH_BACKUP_UTF8: '1',
          NO_COLOR: '1',
          POWERSHELL_TELEMETRY_OPTOUT: '1',
          DOTNET_CLI_TELEMETRY_OPTOUT: '1',
        },
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      resolve({
        ok: false,
        exitCode: null,
        stdout: '',
        stderr: `无法启动 ${resolvePwsh()}：${error instanceof Error ? error.message : String(error)}`,
        ms: Date.now() - startedAt,
        timedOut: false,
        truncated: false,
      });
      return;
    }

    const timer = setTimeout(() => {
      if (settled) return;
      try {
        child.kill('SIGKILL');
      } catch {
        /* 进程可能已退出 */
      }
    }, timeoutMs);

    child.stdout.on('data', (chunk) => {
      outBytes += chunk.length;
      out.push(chunk);
      while (outBytes > MAX_STREAM_BYTES && out.length > 1) {
        outBytes -= out.shift().length;
        truncated = true;
      }
    });
    child.stderr.on('data', (chunk) => {
      errBytes += chunk.length;
      err.push(chunk);
      while (errBytes > MAX_STREAM_BYTES && err.length > 1) {
        errBytes -= err.shift().length;
        truncated = true;
      }
    });

    child.on('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({
        ok: false,
        exitCode: null,
        stdout: decode(out),
        stderr: `${decode(err)}${decode(err) ? '\n' : ''}spawn 失败：${error.message}\n提示：本插件要求 PowerShell 7（pwsh 在 PATH 中），可用 DSH_BACKUP_PWSH 指定绝对路径。`,
        ms: Date.now() - startedAt,
        timedOut: false,
        truncated,
      });
    });

    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const timedOut = Date.now() - startedAt >= timeoutMs && code === null;
      resolve({
        ok: code === 0,
        exitCode: code,
        stdout: decode(out),
        stderr: decode(err),
        ms: Date.now() - startedAt,
        timedOut: timedOut || (code === null && !settled),
        truncated,
      });
    });
  });
}
