/**
 * bundle 的 Host 侧装配：解析 vault 根目录，把 `dsh_backup_*` 工具注册进宿主注册表。
 *
 * @module dsh-backup/lib/plugin
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createTools } from './tools.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** 插件包根目录（= scripts/ 的上一级）。 */
export const PLUGIN_ROOT = path.resolve(HERE, '..');

export const name = 'dsh-backup';

/** 只需要宿主的工具注册表；本 bundle 不申请 client / web 能力。 */
export const inject = ['tools'];

/**
 * @param {{tools: {register: Function}, get?: Function}} ctx 宿主插件上下文
 * @param {{vault?: string, install?: string}} [config] 插件配置（cordis config）
 */
export function apply(ctx, config = {}) {
  const registry = ctx?.tools ?? (typeof ctx?.get === 'function' ? ctx.get('tools') : undefined);
  if (!registry || typeof registry.register !== 'function') {
    throw new Error('dsh-backup: 宿主未提供 tools 注册表（inject: ["tools"] 未满足）');
  }

  const vault = config.vault || process.env.DSH_BACKUP_VAULT || PLUGIN_ROOT;
  const install = config.install || process.env.DSH_BACKUP_DSH_INSTALL || undefined;
  const dshHome = config.dshHome || process.env.DSH_BACKUP_DSH_HOME || process.env.DSH_HOME || undefined;
  const env = { root: PLUGIN_ROOT, vault: path.resolve(vault), install, dshHome };

  const disposers = [];
  for (const definition of createTools(env)) {
    const disposer = registry.register(definition);
    if (typeof disposer === 'function') disposers.push(disposer);
  }

  // 幂等回收：卸载期清理失败不应阻断宿主
  let disposed = false;
  const dispose = () => {
    if (disposed) return;
    disposed = true;
    for (const release of disposers.reverse()) {
      try {
        release();
      } catch {
        /* 卸载期的清理失败不应阻断宿主 */
      }
    }
  };

  // cordis 在 `apply(ctx)` 未拿到 config 对象时不会调用返回的 disposer（实测 arity=2 且
  // config 为 undefined 的情况），因此优先用 ctx.effect 绑定生命周期，再同时返回 disposer
  // 兼容只有 register 的简易上下文；dispose 幂等，两条路径都走到也不会重复回收。
  if (typeof ctx?.effect === 'function') {
    ctx.effect(() => dispose, 'dsh-backup: tools');
  }
  return dispose;
}
