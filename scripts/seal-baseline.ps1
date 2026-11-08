#requires -Version 7.0
# 【分发版·备份机制第二版】由母版提取；仅参数默认值与文案调整，功能逻辑未改。
<#
  seal-baseline.ps1 — 给已有快照生成外置完整性封存凭证（不改动快照内容）
  背景：baseline 是历史快照，_versions.json 里没有 snapshotDigest，
        目录被改动时 restore.ps1 只能打 INFO、verify.ps1 无从校验。
  做法：把快照当前的 snapshotDigest / manifestSha256 / 文件数封存到
        <Vault>\state\baseline-integrity.json，由 verify.ps1 E 段比对。
  退出码：0 = 已封存或已一致；2 = 已有凭证且不一致但未加 -Force（未写入）；1 = 失败
  用法：
    pwsh -NoProfile -File <VAULT>\scripts\seal-baseline.ps1
    pwsh -NoProfile -File <VAULT>\scripts\seal-baseline.ps1 -Force   # 覆盖旧凭证
#>
[CmdletBinding()]
param(
  [string]$Tag = 'baseline',
  [switch]$Force,
  [string]$Vault = '',
  [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 【分发版】路径解析：不硬编码本机路径；缺省 = 本脚本所在目录的父目录（vault 根） ----
if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $Vault 'config-manifest.json' }
. (Join-Path $PSScriptRoot 'vault-common.ps1')

$stateDir = Get-VaultStateDir $Vault
$snapDir  = Join-Path $Vault (Join-Path 'snap' $Tag)
$csv      = Join-Path $snapDir '_manifest.csv'
$sealFile = Join-Path $stateDir 'baseline-integrity.json'

if (-not (Test-Path -LiteralPath $csv)) {
  Write-Host ("FAIL snapshot not found or incomplete: {0}" -f $snapDir)
  exit 1
}

try {
  $dig = Get-SnapshotDigest $snapDir
} catch {
  Write-Host ("FAIL 计算 digest 失败: {0}" -f $_.Exception.Message)
  exit 1
}

$files = @(Get-ChildItem -LiteralPath $snapDir -Recurse -File -Force |
           Where-Object { $_.Name -notin @('_versions.json', '_manifest.csv') })

$seal = [ordered]@{
  tag            = $Tag
  sealedAt       = (Get-Date).ToString('o')
  files          = $files.Count
  snapshotDigest = $dig.snapshotDigest
  manifestSha256 = $dig.manifestSha256
  digestAlgo     = 'sha256-relpath-sorted'
  note           = '由 seal-baseline.ps1 生成；verify.ps1 E 段据此判定 baseline 是否被改动'
}

if (Test-Path -LiteralPath $sealFile) {
  $old = $null
  try { $old = Get-Content -LiteralPath $sealFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $old = $null }
  if ($old -and $old.snapshotDigest -eq $seal.snapshotDigest) {
    Write-Host ("PASS 已封存且一致（sealed {0}，{1} files，digest {2}）" -f $old.sealedAt, $old.files, $old.snapshotDigest.Substring(0, 12))
    exit 0
  }
  if (-not $Force) {
    Write-Host 'DIFF 封存凭证与当前快照不一致：'
    Write-Host ("  旧: {0}" -f $old.snapshotDigest)
    Write-Host ("  新: {0}" -f $seal.snapshotDigest)
    Write-Host '未写入（确认快照本身可信后再加 -Force 覆写凭证）'
    exit 2
  }
}

if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$json = ($seal | ConvertTo-Json -Depth 4)
Set-Content -LiteralPath $sealFile -Value $json -Encoding UTF8 -NoNewline

Write-Host ("PASS sealed: {0}" -f $sealFile)
Write-Host ("  tag={0} files={1} digest={2} manifestSha256={3}" -f $Tag, $seal.files, $seal.snapshotDigest, $seal.manifestSha256)
exit 0
