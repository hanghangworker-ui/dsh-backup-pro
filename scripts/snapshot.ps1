#requires -Version 7.0
# 【分发版·备份机制第二版】由母版提取；仅参数默认值、文案与恢复兼容开关（-AllowMissing/D1）调整，主流程未改。
<#
  snapshot.ps1 — 层 1：配置外置 + 版本化快照
  退出码：0 = 成功；1 = 失败（fail-closed，调用方必须中止后续写入）
  用法：
    pwsh -NoProfile -File <VAULT>\scripts\snapshot.ps1
    pwsh -NoProfile -File <VAULT>\scripts\snapshot.ps1 -Tag pre-0.2.1-rc.6
    pwsh -NoProfile -File <VAULT>\scripts\snapshot.ps1 -Tag probe -PruneWhatIf
      # 只演练保留策略（keep / protectedTags），打印将删除哪些快照与日志，不真删
    pwsh -NoProfile -File <VAULT>\scripts\snapshot.ps1 -Tag x -AllowMissing
      # 仅 restore.ps1 内部使用：配置被清空时仍允许拍"当前残状"存证快照
#>
[CmdletBinding()]
param(
  [string]$Tag,
  [string]$Vault = '',
  [string]$ManifestPath = '',
  # 仅演练保留策略，不真删（P2：让 protectedTags / keep 可被验证而不冒删数据风险）
  [switch]$PruneWhatIf,
  # 【分发版 D1】容忍 known 项缺失：只用于 restore.ps1 的「恢复前安全快照」。
  # 配置被清空时该快照必然遇到 missing，硬失败会让恢复永远无法执行。
  [switch]$AllowMissing
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 【分发版】路径解析：不硬编码本机路径；缺省 = 本脚本所在目录的父目录（vault 根） ----
if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $Vault 'config-manifest.json' }

if ([string]::IsNullOrWhiteSpace($Tag)) { $Tag = (Get-Date -Format 'yyyyMMdd-HHmmss') }

# ---- 0. 读清单（缺失即失败，不做默认值兜底） ----
if (-not (Test-Path -LiteralPath $ManifestPath)) {
  Write-Host "FAIL manifest missing: $ManifestPath"
  exit 1
}
$cfg  = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$src  = $cfg.dshHome
if (-not (Test-Path -LiteralPath $src)) {
  Write-Host "FAIL DSH_HOME not found: $src"
  exit 1
}

$dst = Join-Path $Vault (Join-Path 'snap' $Tag)
if (Test-Path -LiteralPath $dst) {
  Write-Host "FAIL snapshot tag already exists (拒绝覆盖历史快照): $dst"
  exit 1
}

. (Join-Path $PSScriptRoot 'vault-common.ps1')

# ---- P0-5 并发互斥 ----
$lockPath = Enter-VaultLock $Vault 'snapshot'
if (-not $lockPath) {
  Write-Host 'FAIL 另一个 vault 操作正在进行（state\gate.lock），本次放弃'
  exit 1
}

# ---- P0-4：$me/$unlocked 必须在 try 之前初始化 ----
# 否则 try 内提前 throw（如 New-Item 失败）时，catch/finally 引用未定义变量，
# Set-StrictMode Latest 会再抛一次错，遮掉真实错误并跳过重锁。
$me         = "$env:USERDOMAIN\$env:USERNAME"
$unlocked   = @()
$inflightOn = $false

try {
  New-Item -ItemType Directory -Path $dst -Force | Out-Null

  $missing  = @()
  $expected = 0

  # ---- 0.5 层3 交互：被 deny 的源文件无法被 Copy-Item（NTFS 拦截写/读路径），
  #          复制前先临时解锁 aclDeny 项，复制完在 finally 里重新上锁 ----
  foreach ($rel in $cfg.aclDeny) {
    $p = Join-Path $src $rel
    if (Test-Path -LiteralPath $p) {
      $deny = (Get-Acl -LiteralPath $p).Access | Where-Object { $_.AccessControlType -eq 'Deny' }
      if ($deny) {
        & icacls $p /remove:d $me | Out-Null
        $unlocked += $rel
      }
    }
  }
  # P0-4：解锁窗口落盘记录，进程被杀后可用 acl.ps1 -Action Recover 补锁
  if ($unlocked.Count -gt 0) {
    Save-Inflight $Vault 'snapshot' $Tag $unlocked
    $inflightOn = $true
    Write-Host ("TEMPORARILY UNLOCKED for copy: {0}" -f ($unlocked -join ', '))
  }

  foreach ($item in $cfg.include) {
    if ($item.status -eq 'removed') { continue }   # 已确认 dsh 不用的项，直接跳过
    $p = Join-Path $src $item.path
    if (-not (Test-Path -LiteralPath $p)) {
      $missing += $item.path
      if ($item.status -eq 'known' -and -not $AllowMissing) {
        # known 项消失 = 配置可能已被清除，必须硬失败
        throw "known config path missing (可能已被清除): $p"
      }
      if ($item.status -eq 'known' -and $AllowMissing) {
        # 【分发版 D1】恢复场景：不阻断，只记录（该快照仅用于还原前存证）
        Write-Host ("WARN known config path missing (tolerated by -AllowMissing): {0}" -f $item.path) -ForegroundColor Yellow
      }
      continue
    }
    $expected++
    $t      = Join-Path $dst $item.path
    $parent = Split-Path -Parent $t
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if ($item.kind -eq 'dir') {
      Copy-Item -LiteralPath $p -Destination $t -Recurse -Force
    } else {
      Copy-Item -LiteralPath $p -Destination $t -Force
    }
  }

  # ---- 1. 内容清单（SHA256） ----
  $files = Get-ChildItem -LiteralPath $dst -Recurse -File
  if ($files.Count -eq 0) { throw '快照为空：没有复制到任何文件' }

  $rows = foreach ($f in $files) {
    [pscustomobject]@{
      RelPath = $f.FullName.Substring($dst.Length + 1)
      Sha256  = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
      Bytes   = $f.Length
      Utc     = $f.LastWriteTimeUtc.ToString('o')
    }
  }
  $rows | Export-Csv -LiteralPath (Join-Path $dst '_manifest.csv') -NoTypeInformation -Encoding UTF8

  # ---- 2. 版本锚（判断"是否真的发生了变更"） ----
  # P0-6：自适应定位（不再硬编码用户名路径）
  $dshPkg   = Resolve-DshPkgPath
  $dshVer   = if ($dshPkg -and (Test-Path -LiteralPath $dshPkg)) { (Get-Content -LiteralPath $dshPkg -Raw | ConvertFrom-Json).version } else { 'unknown' }
  $profPkg  = Join-Path $src 'profiles\web\package.json'
  $purgeVer = 'unknown'
  if (Test-Path -LiteralPath $profPkg) {
    # D2（2026-11-08）：两种空情形都要容错 ——
    #   ① dependencies 字段整体缺失（全新 profile 只写 bundles 时常见）
    #   ② dependencies 存在但为空对象 {}
    # 旧写法直接点 .dependencies / .PSObject.Properties.Name，在 Set-StrictMode Latest 下
    # 会抛「在此对象上找不到属性」，导致快照直接失败。
    $profObj = Get-Content -LiteralPath $profPkg -Raw | ConvertFrom-Json
    $deps    = if ($profObj.PSObject.Properties['dependencies']) { $profObj.dependencies } else { $null }
    $depNames = if ($null -eq $deps) { @() } else { @($deps.PSObject.Properties | ForEach-Object { $_.Name }) }
    $purgeVer = if ($depNames -contains 'dsh-purge-community') { [string]$deps.'dsh-purge-community' } else { 'absent' }
  }

  # P0-8：快照自完整性（_manifest.csv 哈希 + 全量内容摘要），供 restore/verify 校验
  $dig = Get-SnapshotDigest $dst
  [pscustomobject]@{
    tag            = $Tag
    capturedAt     = (Get-Date).ToString('o')
    dshVersion     = $dshVer
    purgeVersion   = $purgeVer
    expectedItems  = $expected
    copiedFiles    = $files.Count
    missing        = $missing
    manifestSha256 = $dig.manifestSha256
    snapshotDigest = $dig.snapshotDigest
    digestAlgo     = $dig.digestAlgo
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dst '_versions.json') -Encoding UTF8

  # ---- 3. 保留策略（P0-2：baseline / after-* / drill 记录永不裁剪，其余按 keep 滚动） ----
  $protectTags = @(Get-ManifestField $cfg 'protectedTags' @('baseline.*','after-.*','post-.*','pre-restore-drill-.*'))
  $pruneWhatIf = [bool]$PruneWhatIf.IsPresent
  if ($pruneWhatIf) { Write-Host 'PRUNE-PLAN (WhatIf): 以下只演练，不删除任何快照/日志' }
  Invoke-SnapshotPrune -Vault $Vault -Keep ([int]$cfg.keep) -ProtectPatterns $protectTags -WhatIf:$pruneWhatIf
  Invoke-StateLogPrune -Vault $Vault -KeepLogs ([int](Get-ManifestField $cfg 'logKeep' 50)) -WhatIf:$pruneWhatIf

  # ---- 4. pending-post 销项（P1-2：purge 后补拍的 after-/post- 快照即视为已取证） ----
  if ($Tag -match '^(after-|post-)') {
    $pp = Join-Path $Vault 'state\pending-post.json'
    if (Test-Path -LiteralPath $pp) {
      Remove-Item -LiteralPath $pp -Force -ErrorAction Stop
      Write-Host ('CLEARED pending-post marker (post-snapshot evidence recorded by {0})' -f $Tag)
    }
  }

  Write-Host ("PASS snapshot: {0} ({1} files, dsh={2}, purge={3})" -f $dst, $files.Count, $dshVer, $purgeVer)
  if ($missing.Count -gt 0) { Write-Host ("WARN skipped pending items: {0}" -f ($missing -join ', ')) }
  exit 0
}
catch {
  Write-Host ("FAIL snapshot: {0}" -f $_.Exception.Message)
  # 复制/流程失败也要把锁补回去，不留下无锁窗口
  if ($unlocked.Count -gt 0) {
    foreach ($rel in $unlocked) {
      & icacls (Join-Path $src $rel) /deny "${me}:(W,D)" 2>$null | Out-Null
    }
    Write-Host ("RELOCKED after failure: {0}" -f ($unlocked -join ', '))
  }
  exit 1
}
finally {
  # 正常结束也要重新上锁
  if ($unlocked.Count -gt 0) {
    foreach ($rel in $unlocked) {
      if (-not (Test-Path -LiteralPath (Join-Path $src $rel))) { continue }
      $deniedNow = (Get-Acl -LiteralPath (Join-Path $src $rel)).Access | Where-Object { $_.AccessControlType -eq 'Deny' }
      if (-not $deniedNow) {
        & icacls (Join-Path $src $rel) /deny "${me}:(W,D)" | Out-Null
      }
    }
    Write-Host ("RELOCKED: {0}" -f ($unlocked -join ', '))
  }
  # P0-4：锁已补回，清掉 inflight 记录；P0-5：释放互斥锁
  if ($inflightOn) { Clear-Inflight $Vault }
  if ($lockPath) { Exit-VaultLock $lockPath }
}
