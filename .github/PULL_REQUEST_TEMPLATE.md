## 做了什么

<!-- 一句话说清改动 -->

## 为什么

<!-- 复现步骤 / 触发场景 / 期望 vs 实际。修 D1 这类缺陷请写明「不修会怎样」 -->

## 影响面

- [ ] 只动文档 / 注释
- [ ] 只动分发版默认值（路径参数化等）
- [ ] 改了脚本逻辑（请在 CHANGELOG.md 记录）
- [ ] 改了 config-manifest 字段（需同步 `config/config-manifest.template.json` 与 `docs/guide.zh-CN.md`）

## 自检

- [ ] 所有 `.ps1/.psm1/.psd1` 仍是 UTF-8 **with BOM**（CI 会查）
- [ ] `pwsh` 与 `powershell.exe`（5.1）都能 `Parser::ParseFile` 通过
- [ ] 沙箱里跑过 `deploy.ps1` → 删配置 → `restore.ps1 -Force` → `verify.ps1`，结果 `0 FAIL`
- [ ] 没有把 `snap/`、`state/`、`config-manifest.json`、`*.log` 加进提交
- [ ] 没有硬编码本机路径（`D:\dsh-home`、`C:\Users\<名字>` 等）
