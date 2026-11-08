#requires -Version 5.1
# 【分发版·备份机制第二版】由母版提取；仅参数默认值与文案调整，功能逻辑未改。
<#
  fix-bom.ps1 -- 给目录下所有 .ps1 补 UTF-8 BOM（幂等：只加不减，非 UTF-8 不动）

  背景（2026-11-08 事故）：
    Windows PowerShell 5.1 会把「无 BOM 的 UTF-8」按 ANSI(GBK) 解码，中文字符串被
    撕成半截，Parser::ParseFile 于是假报「字符串缺少终止符 / 语句块缺少右 }」。
    当天 8 个 .ps1 被一次假报 38 处语法错误，而 pwsh 7 解析、运行全部正常。
    同类风险的另一个来源：某些编辑器/工具落盘时会剥掉 BOM（本库的 agent edit 工具就会）。

  用法：
    pwsh -NoProfile -File <VAULT>\scripts\fix-bom.ps1
    pwsh -NoProfile -File <VAULT>\scripts\fix-bom.ps1 -Path D:\some\dir
    powershell.exe -NoProfile -File ...\fix-bom.ps1          # 5.1 也能跑

  退出码：0 = 全部已是 BOM 或已补好；1 = 存在非 UTF-8 文件被跳过（需人工处理）
#>
[CmdletBinding()]
param(
  [string]$Path = ''
)

# PS 5.1 下 param 默认值求值时 $PSScriptRoot 可能尚为空，这里做三级兜底
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Path) -and $PSCommandPath) { $Path = Split-Path -Parent $PSCommandPath }
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "path not found: $Path" -ForegroundColor Red; exit 1 }

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$fixed = @(); $ok = @(); $bad = @()

foreach ($f in @(Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File)) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $ok += $f.Name
    continue
  }
  try {
    [void]$utf8Strict.GetString($bytes)
  } catch {
    $bad += ("{0} (not valid UTF-8, left untouched)" -f $f.Name)
    continue
  }
  $out = New-Object byte[] ($bytes.Length + 3)
  $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
  [System.Array]::Copy($bytes, 0, $out, 3, $bytes.Length)
  [System.IO.File]::WriteAllBytes($f.FullName, $out)
  $fixed += $f.Name
}

foreach ($n in $fixed) { Write-Host ("BOM ADDED  {0}" -f $n) -ForegroundColor Green }
foreach ($n in $ok)    { Write-Host ("BOM OK     {0}" -f $n) }
foreach ($n in $bad)   { Write-Host ("SKIPPED    {0}" -f $n) -ForegroundColor Red }
Write-Host ("done: {0} added, {1} already had BOM, {2} skipped" -f $fixed.Count, $ok.Count, $bad.Count)
if ($bad.Count -gt 0) { exit 1 }
exit 0
