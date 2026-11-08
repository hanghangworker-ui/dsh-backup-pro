# Contributing

欢迎 issue / PR。这个仓库的目标很小：**让 dsh 的配置在被人或插件清空之后，还能一条命令恢复**。
改动只要不破坏这个目标、不引入本机专属内容，都欢迎。

## 硬性要求

1. **所有 `.ps1` / `.psm1` / `.psd1` 必须是 UTF-8 with BOM，行尾 CRLF。**
   Windows PowerShell 5.1 会把无 BOM 的 UTF-8 按 GBK 解码，于是把中文字符串撕成半截，
   报出一堆「字符串缺少终止符 / 语句块缺少右 }」的假错误。CI 会检查 BOM。
   本地被编辑器剥了 BOM 就跑：

   ```powershell
   pwsh -NoProfile -File scripts/fix-bom.ps1
   ```

2. **不要把运行时产物提交上来**：`snap/`、`state/`、`config-manifest.json`、`*.log`、`*.zip` 已在
   `.gitignore` 里排除。`snap/` 里是真实配置内容副本，误提交等于泄露配置。

3. **不要硬编码本机路径**：脚本一律通过参数或 `config-manifest.json` 取路径；
   新增脚本请沿用既有约定——`$Vault` / `$ManifestPath` 默认空串，缺省取「脚本所在目录的父目录」。

4. **不要在不改行为的前提下顺手改行为**：若要修逻辑，请在 `CHANGELOG.md` 里写清「为什么」，
   并在 PR 描述里给出复现方式（哪一步、什么命令、期望 vs 实际）。

## 提交前自检

```powershell
# 1) 双引擎解析 + BOM + JSON 可解析（等价于 CI 的前三个 step）
pwsh -NoProfile -File scripts/verify.ps1        # G 段会打印脚本编码与 JSON 检查结果

# 2) 沙箱里跑一遍「部署 → 清空 → 恢复 → 复验」（不要在你的真实 dsh home 上做）
pwsh -NoProfile -File scripts/deploy.ps1 -DshHome <沙箱>\home -Vault <沙箱>\vault
pwsh -NoProfile -File scripts/restore.ps1 -Tag baseline -Plan
pwsh -NoProfile -File scripts/restore.ps1 -Tag baseline -Force
pwsh -NoProfile -File scripts/verify.ps1
```

`verify.ps1` 输出的 `SUMMARY` 必须是 `0 FAIL`，且 `unexpected` 为 0。

## 报告问题

请附上：

- Windows 版本、`pwsh -v` 输出；
- `scripts/verify.ps1` 的完整输出（`SUMMARY` 行必须有）；
- 复现步骤：哪条命令、改了什么、期望什么、实际什么；
- 如果涉及恢复失败，附 `restore.ps1 -Tag <tag> -Plan` 的输出（不含敏感内容）。

**不要**贴真实的 `prompt-inject.md`、`agent.cordis.yml`、`package.json` 全文——用占位符替换。
