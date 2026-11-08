#requires -Version 7.0
# 【分发版·备份机制第二版】由母版提取；仅参数默认值、文案与恢复兼容开关（-AllowMissing/D1）调整，主流程未改。
<#
  restore.ps1 — 从快照恢复，默认只 diff 不覆盖
  退出码：0 = 已一致或恢复成功；2 = 有差异但未加 -Force（未写入）；1 = 失败
  用法：
    pwsh -NoProfile -File <VAULT>\scripts\restore.ps1 -Tag baseline            # 只看差异
    pwsh -NoProfile -File <VAULT>\scripts\restore.ps1 -Tag baseline -Force     # 真的恢复
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Tag,
  [switch]$Force,
  [switch]$Plan,
  [switch]$RequireIdle,
  [switch]$AcceptTampered,
  [string]$Vault = '',
  [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 【分发版】路径解析：不硬编码本机路径；缺省 = 本脚本所在目录的父目录（vault 根） ----
if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $Vault 'config-manifest.json' }

# P2-2：-RequireIdle —— restore 是逐文件写入（非原子），
# 与运行中的 dsh 并发写同一批文件会产出半写状态。写回前先确认没有 dsh 在跑。
if ($RequireIdle) {
  $busy = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('node.exe', 'dsh.exe') -and $_.CommandLine -and $_.CommandLine -match 'dsh' })
  if ($busy.Count -gt 0) {
    $ids = ($busy | ForEach-Object { $_.ProcessId }) -join ','
    Write-Host ("FAIL -RequireIdle: dsh 相关进程仍在运行 (pid {0})；先关闭 dsh 再恢复" -f $ids)
    exit 1
  }
  Write-Host 'OK idle: no dsh process'
}

$snapDir = Join-Path $Vault (Join-Path 'snap' $Tag)
$snapCsv = Join-Path $snapDir '_manifest.csv'
if (-not (Test-Path -LiteralPath $snapCsv)) {
  Write-Host "FAIL snapshot not found or incomplete: $snapDir"
  exit 1
}

. (Join-Path $PSScriptRoot 'vault-common.ps1')

# ---- P0-5 并发互斥 ----
$lockPath = Enter-VaultLock $Vault 'restore'
if (-not $lockPath) {
  Write-Host 'FAIL 另一个 vault 操作正在进行（state\gate.lock），本次放弃'
  exit 1
}

# ---- P0-8 快照自完整性（恢复前校验基准没被改动） ----
# $true = 一致；$false = 被改动；$null = 旧版快照无字段（兼容跳过）
$integ = Test-SnapshotIntegrity $snapDir
if ($integ -eq $false) {
  Write-Host 'FAIL 快照 _manifest.csv 与 _versions.json 记录的哈希不符（快照可能被改动）' -ForegroundColor Red
  if ($AcceptTampered) {
    Write-Host 'WARN 已指定 -AcceptTampered，继续恢复（后果：可能恢复出被篡改的内容）' -ForegroundColor Yellow
  } else {
    Write-Host '     确认无误后加 -AcceptTampered 强制继续' -ForegroundColor Yellow
    Exit-VaultLock $lockPath
    exit 1
  }
} elseif ($null -eq $integ) {
  Write-Host ("INFO 旧版快照无完整性字段，跳过校验（建议重建：snapshot.ps1 -Tag {0}）" -f $Tag) -ForegroundColor DarkGray
}

try {

$cfg = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$src = $cfg.dshHome

$rows = Import-Csv -LiteralPath $snapCsv

# ---- 1. diff：比 hash，不看时间戳 ----
# 层3 锁着时 Get-FileHash 读受锁文件被 NTFS 拦截，先临时解锁 aclDeny 项
$me = "$env:USERDOMAIN\$env:USERNAME"
$diffPreUnlocked = @()
foreach ($rel in $cfg.aclDeny) {
  $p = Join-Path $src $rel
  if (Test-Path -LiteralPath $p) {
    $deny = (Get-Acl -LiteralPath $p).Access | Where-Object { $_.AccessControlType -eq 'Deny' }
    if ($deny) {
      & icacls $p /remove:d $me | Out-Null
      $diffPreUnlocked += $rel
    }
  }
}
  # P0-4：解锁窗口落盘记录，进程被杀后可用 acl.ps1 -Action Recover 补锁
  if ($diffPreUnlocked.Count -gt 0) {
    Save-Inflight $Vault 'restore-diff' $Tag $diffPreUnlocked
    Write-Host ("TEMPORARILY UNLOCKED for diff: {0}" -f ($diffPreUnlocked -join ', '))
  }

$diff = @()
$hashReadFailed = @()
foreach ($r in $rows) {
  $cur = Join-Path $src $r.RelPath
  if (-not (Test-Path -LiteralPath $cur)) {
    $diff += [pscustomobject]@{ RelPath = $r.RelPath; State = 'MISSING-IN-SOURCE' }
    continue
  }
  try {
    $h = (Get-FileHash -LiteralPath $cur -Algorithm SHA256).Hash
    if ($h -ne $r.Sha256) {
      $diff += [pscustomobject]@{ RelPath = $r.RelPath; State = 'CHANGED' }
    }
  } catch {
    # 读源文件被拒（非层3 解锁范围内的残留 ACL 或系统占用）：按"与快照不一致"处理，不静默通过
    $hashReadFailed += $r.RelPath
    $diff += [pscustomobject]@{ RelPath = $r.RelPath; State = 'READ-DENIED' }
  }
}

# diff 完成，无论后续是否 -Force，都先把临时解锁的重新上锁
foreach ($rel in $diffPreUnlocked) {
  & icacls (Join-Path $src $rel) /deny "${me}:(W,D)" | Out-Null
}
if ($diffPreUnlocked.Count -gt 0) {
  Clear-Inflight $Vault
  Write-Host ("RELOCKED after diff: {0}" -f ($diffPreUnlocked -join ', '))
}

if ($diff.Count -eq 0) {
  Write-Host "PASS no difference between source and snapshot '$Tag'"
  exit 0
}

Write-Host ("DIFF ({0} file(s)) vs snapshot '{1}':" -f $diff.Count, $Tag)
$diff | Format-Table -AutoSize | Out-String | Write-Host

# P2-2：-Plan 只打印写入计划（含逐文件清单），绝不写盘
if ($Plan) {
  Write-Host ("PLAN: snapshot '{0}' -> {1}，将写入 {2} 个文件：" -f $Tag, $src, $diff.Count)
  $diff | ForEach-Object { Write-Host ("  OVERWRITE {0}" -f $_.RelPath) }
  Write-Host 'PLAN ONLY: nothing written.'
  exit 2
}

if (-not $Force) {
  Write-Host 'READ-ONLY: nothing written. Re-run with -Force to restore.'
  exit 2
}

# ---- 2. 恢复前先把"当前状态"再存一份（避免恢复本身成为不可逆操作） ----
$preTag = 'pre-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
& (Join-Path $Vault 'scripts\snapshot.ps1') -Tag $preTag -Vault $Vault -ManifestPath $ManifestPath -AllowMissing
# 【分发版 D1】-AllowMissing：配置已被清空时，安全快照遇到 missing 不得阻断恢复（否则永远救不回来）
if ($LASTEXITCODE -ne 0) {
  Write-Host 'FAIL pre-restore snapshot failed -> restore BLOCKED'
  exit 1
}
Write-Host ("safety snapshot: {0}" -f (Join-Path $Vault "snap\$preTag"))

# ---- 2.5 恢复前临时解除 aclDeny 文件写锁（恢复后重新上锁） ----
$denied = @()
foreach ($rel in $cfg.aclDeny) {
  $p = Join-Path $src $rel
  if (Test-Path -LiteralPath $p) {
    $acl  = Get-Acl -LiteralPath $p
    $deny = $acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' }
    if ($deny) {
      $me = "$env:USERDOMAIN\$env:USERNAME"
      & icacls $p /remove:d $me | Out-Null
      $denied += $rel
    }
  }
}
if ($denied.Count -gt 0) {
  Save-Inflight $Vault 'restore-write' $Tag $denied
  Write-Host ("TEMPORARILY UNLOCKED: {0}" -f ($denied -join ', '))
}

# ---- 3. 写入（P2-2：两阶段 —— 先全量暂存，再逐个提交） ----
$stage = Join-Path $Vault ('state\restore-staging-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
try {
  # 3.1 暂存：任何一步失败都不触碰 $src
  foreach ($d in $diff) {
    $from = Join-Path $snapDir $d.RelPath
    $to   = Join-Path $stage $d.RelPath
    $parent = Split-Path -Parent $to
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $from -Destination $to -Force
  }
  Write-Host ("staged {0} file(s) -> {1}" -f $diff.Count, $stage)

  # 3.2 提交
  foreach ($d in $diff) {
    $from = Join-Path $stage $d.RelPath
    $to   = Join-Path $src $d.RelPath
    $parent = Split-Path -Parent $to
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $from -Destination $to -Force
    Write-Host ("restored: {0}" -f $d.RelPath)
  }
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
  # 写入失败也要把锁重新加回去，避免配置处于无锁窗口
  foreach ($rel in $denied) {
    & icacls (Join-Path $src $rel) /deny "${me}:(W,D)" 2>$null | Out-Null
  }
  Clear-Inflight $Vault
  Write-Host ("FAIL restore: {0}" -f $_.Exception.Message)
  if (Test-Path -LiteralPath $stage) { Write-Host ("暂存目录已保留（可重试提交）：{0}" -f $stage) }
  Write-Host ("可用安全快照回退：{0}" -f (Join-Path $Vault "snap\$preTag"))
  exit 1
}

# ---- 3.5 恢复成功后重新上锁 ----
if ($denied.Count -gt 0) {
  foreach ($rel in $denied) {
    & icacls (Join-Path $src $rel) /deny "${me}:(W,D)" | Out-Null
  }
  Clear-Inflight $Vault
  Write-Host ("RELOCKED: {0}" -f ($denied -join ', '))
}

Write-Host ("PASS restored {0} file(s) from '{1}'" -f $diff.Count, $Tag)
exit 0

}
finally {
  Exit-VaultLock $lockPath
}
