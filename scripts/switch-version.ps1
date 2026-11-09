# 版本切换 —— 把 dsh 安装目录切换到版本库里的某个版本（适配 purge 的版本需求）
#
# 安全设计
#   * 只切换整目录：<install> → <install>.bak-<ts>，再把 <versions>\<ver> 的 payload 展开进去
#   * 切换前强制空闲检查（node.exe / dsh.exe 且命令行含 dsh 即拒绝），除非 -SkipIdleCheck
#   * 切换后按 package.json 的 version 复核；复核失败自动回滚（把 .bak 改回原名）
#   * -Action Rollback 可手工回到最近一次 .bak（-Action Rollback -Version 指定具体备份）
#
# 用法
#   switch-version.ps1 -Action Status
#   switch-version.ps1 -Action Plan     -Version 0.2.1-rc.5
#   switch-version.ps1 -Action Apply    -Version 0.2.1-rc.5
#   switch-version.ps1 -Action Rollback
# 退出码：0 = OK；1 = 失败/复核不通过；2 = 前提不满足（无 payload、非空闲、目录不对）

#requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('Status','Plan','Apply','Rollback')]
  [string]$Action = 'Status',
  [string]$Version,
  [string]$Source,
  [string]$Vault = '',
  [switch]$SkipIdleCheck,
  [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
$versionsRoot = Join-Path $Vault 'versions'

function Write-Ok($m)  { Write-Host "PASS $m" -ForegroundColor Green }
function Write-Bad($m) { Write-Host "FAIL $m" -ForegroundColor Red }
function Write-Info($m){ Write-Host $m }

function Resolve-DshInstall([string]$Hint) {
  $c = @()
  if (-not [string]::IsNullOrWhiteSpace($Hint)) { $c += $Hint }
  $npmRoot = $null
  try { $npmRoot = (& npm root -g 2>$null | Select-Object -First 1) } catch { $npmRoot = $null }
  if ($npmRoot) { $c += (Join-Path $npmRoot '@deepseek-ai\dsh') }
  $c += (Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh')
  foreach ($x in $c) { if ($x -and (Test-Path -LiteralPath (Join-Path $x 'package.json'))) { return (Resolve-Path -LiteralPath $x).Path } }
  return $null
}
function Get-InstalledVersion([string]$Dir) {
  $p = Join-Path $Dir 'package.json'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).version
}
function Get-Meta($v) { Join-Path $versionsRoot "$v\meta.json" }
function Get-Payload($v) { Join-Path $versionsRoot "$v\payload.zip" }

function Assert-Idle {
  $busy = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      ($_.Name -in @('node.exe', 'dsh.exe')) -and $_.CommandLine -and ($_.CommandLine -match 'dsh')
    })
  if ($busy.Count -gt 0) {
    foreach ($b in $busy) { Write-Bad ("占用中: pid={0} {1} :: {2}" -f $b.ProcessId, $b.Name, ($b.CommandLine.Substring(0, [Math]::Min(120, $b.CommandLine.Length)))) }
    Write-Bad '存在运行中的 dsh 进程，切换会破坏运行中的实例；退出 dsh 后重试（或 -SkipIdleCheck 强制）'
    exit 2
  }
}

function Find-LatestBackup([string]$InstallDir) {
  $parent = Split-Path -Parent $InstallDir
  $name = Split-Path -Leaf $InstallDir
  $baks = @(Get-ChildItem -LiteralPath $parent -Directory -Filter "$name.bak-*" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending)
  return ,$baks
}

$install = Resolve-DshInstall $Source
if (-not $install) { Write-Bad '未找到 dsh 安装目录（可用 -Source 指定）'; exit 2 }
$current = Get-InstalledVersion $install

switch ($Action) {
  'Status' {
    Write-Info "install       = $install"
    Write-Info "currentVersion= $current"
    Write-Info "versionsRoot  = $versionsRoot"
    $baks = Find-LatestBackup $install
    if ($baks.Count -gt 0) { Write-Info ("lastBackup   = {0}" -f $baks[0].FullName) } else { Write-Info 'lastBackup    = (none)' }
    if (Test-Path -LiteralPath $versionsRoot) {
      $rows = @()
      foreach ($d in Get-ChildItem -LiteralPath $versionsRoot -Directory) {
        $m = Join-Path $d.FullName 'meta.json'
        if (-not (Test-Path -LiteralPath $m)) { continue }
        $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
        $rows += [pscustomobject]@{ version = $o.version; mode = $o.mode; switchCapable = $o.switchCapable; active = ($o.version -eq $current) }
      }
      if ($rows.Count) { $rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Host }
    }
    Write-Ok 'status OK'
  }

  'Plan' {
    if (-not $Version) { Write-Bad '需要 -Version'; exit 2 }
    if ($Version -eq $current) { Write-Info "INFO 当前已是 $Version，无需切换"; exit 0 }
    $m = Get-Meta $Version
    if (-not (Test-Path -LiteralPath $m)) { Write-Bad "版本库无该版本: $Version（先 version-store.ps1 -Action Save -Mode full）"; exit 2 }
    $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
    $zip = Get-Payload $Version
    $canSwap = ($o.mode -eq 'full') -and (Test-Path -LiteralPath $zip)
    Write-Info "PLAN  install : $install"
    Write-Info "PLAN  from    : $current"
    Write-Info "PLAN  to      : $Version"
    Write-Info "PLAN  payload : $(if ($canSwap) { $zip } else { '(无 payload，meta-only 不能切换)' })"
    Write-Info "PLAN  backup  : $install.bak-<ts>  （保留，用于 Rollback）"
    Write-Info "PLAN  action  : rename 现目录 → 展开 payload → 复核 package.json.version"
    if (-not $canSwap) {
      Write-Bad "缺少可切换 payload：请先 version-store.ps1 -Action Save -Mode full -Version $Version"
      exit 2
    }
    Write-Ok 'plan ready（未做任何改动）'
  }

  'Apply' {
    if (-not $Version) { Write-Bad '需要 -Version'; exit 2 }
    if ($Version -eq $current) { Write-Info "INFO 当前已是 $Version，无需切换"; exit 0 }
    $m = Get-Meta $Version
    if (-not (Test-Path -LiteralPath $m)) { Write-Bad "版本库无该版本: $Version"; exit 2 }
    $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
    $zip = Get-Payload $Version
    if ($o.mode -ne 'full' -or -not (Test-Path -LiteralPath $zip)) {
      Write-Bad "缺少 payload（mode=$($o.mode)），无法切换；先 version-store.ps1 -Action Save -Mode full"
      exit 2
    }
    if (-not $SkipIdleCheck) { Assert-Idle }

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $staging = Join-Path $versionsRoot "$Version\staging-$ts"
    $bak = "$install.bak-$ts"

    Write-Info "STEP 1/5 展开 payload → $staging"
    Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force

    Write-Info 'STEP 2/5 校验展开内容'
    $stagedVer = Get-InstalledVersion $staging
    if ($stagedVer -ne $Version) {
      Write-Bad "payload 内版本为 '$stagedVer'，与目标 '$Version' 不符；已中止，未改动安装目录"
      if (-not $KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force }
      exit 1
    }

    Write-Info "STEP 3/5 备份现目录 → $bak"
    try { Rename-Item -LiteralPath $install -NewName (Split-Path -Leaf $bak) -ErrorAction Stop }
    catch { Write-Bad "无法重命名安装目录（可能被占用）: $($_.Exception.Message)"; exit 1 }

    Write-Info "STEP 4/5 就位 → $install"
    try {
      Move-Item -LiteralPath $staging -Destination $install -ErrorAction Stop
    } catch {
      Write-Bad "移动失败，正在回滚: $($_.Exception.Message)"
      if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force -ErrorAction SilentlyContinue }
      Rename-Item -LiteralPath $bak -NewName (Split-Path -Leaf $install) -ErrorAction SilentlyContinue
      exit 1
    }

    Write-Info 'STEP 5/5 复核生效'
    $now = Get-InstalledVersion $install
    if ($now -ne $Version) {
      Write-Bad "复核失败：安装目录版本为 '$now'，期望 '$Version'；自动回滚"
      $failed = "$install.failed-$ts"
      Rename-Item -LiteralPath $install -NewName (Split-Path -Leaf $failed) -ErrorAction SilentlyContinue
      Rename-Item -LiteralPath $bak -NewName (Split-Path -Leaf $install) -ErrorAction SilentlyContinue
      Write-Bad "已回滚到之前版本: $(Get-InstalledVersion $install)"
      exit 1
    }
    if (-not $KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok "switched: $current → $Version"
    Write-Info "回滚命令：pwsh -NoProfile -File `"$PSCommandPath`" -Action Rollback"
  }

  'Rollback' {
    if (-not $SkipIdleCheck) { Assert-Idle }
    $parent = Split-Path -Parent $install
    $leaf = Split-Path -Leaf $install
    if ($Version) {
      $bak = Join-Path $parent "$leaf.bak-$Version"
      if (-not (Test-Path -LiteralPath $bak)) { Write-Bad "指定的备份不存在: $bak"; exit 2 }
    } else {
      $baks = Find-LatestBackup $install
      if ($baks.Count -eq 0) { Write-Bad '没有可用的 .bak 备份'; exit 2 }
      $bak = $baks[0].FullName
    }
    $bakVer = Get-InstalledVersion $bak
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $cur = "$install.rollback-$ts"
    Write-Info "ROLLBACK 现版本 $current → 备份 $bakVer ($bak)"
    Rename-Item -LiteralPath $install -NewName (Split-Path -Leaf $cur)
    Move-Item -LiteralPath $bak -Destination $install
    $now = Get-InstalledVersion $install
    if ($now -ne $bakVer) {
      Write-Bad "回滚后版本异常：'$now'，期望 '$bakVer'（现版本仍保留在 $cur）"
      exit 1
    }
    Write-Ok "rolled back: $current → $now（被替换的版本保留在 $cur）"
  }
}
exit 0
