/**
 * dsh-backup —— Host 侧入口。
 *
 * 本包是「Host-only bundle」：没有 Web UI，只向宿主注册工具（tools），
 * 由宿主 Agent 调用；真正的备份/恢复/版本切换动作仍由 `scripts/*.ps1` 完成。
 *
 * 安装方式（不要手写 profile 的 package.json）：
 *   plugin_manager({ action: "install_bundle", target: "<本包目录的绝对路径>" })
 *
 * 对外契约：
 *   name   —— bundle 名称（与 cordis.patch.yml 的 id 一致）
 *   inject —— 依赖的宿主服务；`tools` 即工具注册表
 *   apply  —— 注册全部 dsh_backup_* 工具
 */
export { apply, inject, name } from './lib/plugin.js';
