#requires -Version 7.0
# 【分发版·备份机制第二版】由母版提取；仅参数默认值与文案调整，功能逻辑未改。
<#
  purge-gate.ps1 — 层 2：写入前快照 + fail-closed
  语义：只有在快照成功之后，才允许调用 purge apply。
        快照失败 → 立即 exit 1，purge 一步都不执行。
  退出码：0 = 无变更或（快照成功 且 apply 成功）；1 = 阻断
  用法：
    # 纯快照闸门（不留 apply）：
    pwsh -NoProfile -File <VAULT>\scripts\purge-gate.ps1 -DryRun
    pwsh -NoProfile -File <VAULT>\scripts\purge-gate.ps1
    # 快照闸门 + 实测 dsh-purge-master apply（m00226 销项）：
    pwsh -NoProfile -File <VAULT>\scripts\purge-gate.ps1 -ApplyCommand "& '<NODE_EXE>' '<PURGE_JS>' --apply"
#>
[CmdletBinding()]
param(
  [string]$ApplyCommand = '',
  [switch]$DryRun,
  [string]$Vault = '',
  [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 【分发版】路径解析：不硬编码本机路径；缺省 = 本脚本所在目录的父目录（vault 根） ----
if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $Vault 'config-manifest.json' }

$snapshot   = Join-Path $Vault 'scripts\snapshot.ps1'
$stateDir   = Join-Path $Vault 'state'
$stateFile  = Join-Path $stateDir 'last-applied.json'
$logFile    = Join-Path $stateDir 'gate.log'

if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

function Write-GateLog([string]$msg) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $msg
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  Write-Host $line
}

. (Join-Path $PSScriptRoot 'vault-common.ps1')

# ---- 0. 并发互斥（P0-5）：同一 vault 同时只允许一个写操作 ----
$lockPath = Enter-VaultLock $Vault 'purge-gate'
if (-not $lockPath) {
  Write-Host 'FAIL 另一个 vault 操作正在进行（state\gate.lock），本次放弃' -ForegroundColor Red
  exit 1
}

try {

# ---- 1. 取当前版本指纹 ----
$cfg      = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
# P0-6：目标机自适应定位，不再硬编码用户名路径
$dshPkg = Resolve-DshPkgPath
if (-not $dshPkg) {
  Write-GateLog 'FAIL dsh package.json not found (npm root -g / %APPDATA%\npm 均未命中) -> abort (不执行 purge)'
  exit 1
}
$dshVer = (Get-Content -LiteralPath $dshPkg -Raw | ConvertFrom-Json).version

$profPkg  = Join-Path $cfg.dshHome 'profiles\web\package.json'
$purgeVer = 'unknown'
if (Test-Path -LiteralPath $profPkg) {
  $deps = (Get-Content -LiteralPath $profPkg -Raw | ConvertFrom-Json).dependencies
  # D2（2026-11-08）：空 dependencies 时 .PSObject.Properties.Name 在 StrictMode 下抛错，先物化数组
  $depNames = if ($null -eq $deps) { @() } else { @($deps.PSObject.Properties | ForEach-Object { $_.Name }) }
  if ($depNames -contains 'dsh-purge-community') { $purgeVer = [string]$deps.'dsh-purge-community' }
}

# 清单文件自身的 hash：清单变了也要重跑（否则新加入的保护项永远不生效）
$manifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
# P0-3（2026-11-08）：指纹必须包含「受保护内容的当前摘要」。
# 只锁版本+清单时，内容被改（如 plugins 往 package.json 加依赖）但版本未变 →
# 命中 SKIP no change → purge 前不留新 pre 快照，被清内容的最新版本可能不在库里。
$contentDig = 'n/a'
try {
  $newestCsv = @(Get-ChildItem -LiteralPath (Join-Path $Vault 'snap') -Directory -ErrorAction Stop |
                 Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 |
                 ForEach-Object { Join-Path $_.FullName '_manifest.csv' })
  if ($newestCsv.Count -gt 0 -and (Test-Path -LiteralPath $newestCsv[0])) {
    $rowsG = Import-Csv -LiteralPath $newestCsv[0]
    $contentDig = Get-SourceContentDigest -DshHome $cfg.dshHome -Rows $rowsG
  }
} catch { $contentDig = 'n/a' }
$fingerprint  = "$dshVer|$purgeVer|$manifestHash|$contentDig"
# 指纹短码：便于在日志里肉眼比对「同一源状态」而不必展开 64 位 hash
$fpShort = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($fingerprint))) -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant()

# ---- 2. 幂等判断 ----
if (Test-Path -LiteralPath $stateFile) {
  $last = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
  if ($last.fingerprint -eq $fingerprint) {
    Write-GateLog ("SKIP no change (fp=$fpShort dsh=$dshVer purge=$purgeVer)")
    exit 0
  }
  # 变化维度：一眼看出是「版本变了」还是「内容漂了」，避免误判成 purge 需要重跑
  $segNames = @('dsh', 'purge', 'manifest', 'content')
  $newSegs  = @($fingerprint -split '\|')
  $oldSegs  = @([string]$last.fingerprint -split '\|')
  if ($oldSegs.Count -ne $newSegs.Count) {
    $why = "legacy-fingerprint($($oldSegs.Count)->$($newSegs.Count) segs)"
  } else {
    $diffIdx = @(0..($newSegs.Count - 1) | Where-Object { $oldSegs[$_] -ne $newSegs[$_] })
    $why = $(if ($diffIdx.Count -eq 0) { 'unknown' } else { ($diffIdx | ForEach-Object { $segNames[$_] }) -join ',' })
  }
} else {
  $why = 'first-run'
}

Write-GateLog ("CHANGE detected: {0} (fp={1} dsh={2} purge={3})" -f $why, $fpShort, $dshVer, $purgeVer)

# ---- 3. 前置快照（fail-closed 的核心） ----
# P0-2：内容寻址 tag —— 同一源状态（fingerprint 相同）只落一张 pre 快照，
#        避免 snapshot-only 模式下每次 gate 都造新 pre-* 把恢复点挤出保留窗口。
$preTag = Get-ContentAddressedTag ('pre-' + $dshVer) $fingerprint
if ($DryRun) {
  Write-GateLog ("DRYRUN would snapshot as {0}, then run: {1}" -f $preTag, $(if ($ApplyCommand) { $ApplyCommand } else { '<ApplyCommand 未配置>' }))
  exit 0
}

$preDir = Join-Path $Vault (Join-Path 'snap' $preTag)
if (Test-Path -LiteralPath $preDir) {
  Write-GateLog ("REUSE 同源状态快照已存在：{0}（跳过新建）" -f $preTag)
} else {
  & $snapshot -Tag $preTag -Vault $Vault -ManifestPath $ManifestPath
  if ($LASTEXITCODE -ne 0) {
    Write-GateLog ("FAIL pre-snapshot exit={0} -> purge BLOCKED" -f $LASTEXITCODE)
    exit 1
  }
}

# 二次确认快照真的落盘（避免脚本"假装成功"）
$preDir = Join-Path $Vault (Join-Path 'snap' $preTag)
if (-not (Test-Path -LiteralPath (Join-Path $preDir '_manifest.csv'))) {
  Write-GateLog 'FAIL pre-snapshot manifest missing -> purge BLOCKED'
  exit 1
}

# ---- 3.5 准入校验（P0-4）：层3 必须处于已加锁状态 ----
# 解锁窗口如果上次异常中断（残留 inflight），本次 apply 会在无保护窗口内改文件。
$aclScript = Join-Path $Vault 'scripts\acl.ps1'
if (Test-Path -LiteralPath $aclScript) {
  & $aclScript -Action Check -ManifestPath $ManifestPath
  if ($LASTEXITCODE -ne 0) {
    Write-GateLog 'FAIL acl check 未通过（aclDeny 项未受保护，或上次解锁窗口未自愈）-> purge BLOCKED'
    Write-GateLog '     补救：pwsh -NoProfile -File <vault>\scripts\acl.ps1 -Action Recover'
    exit 1
  }
} else {
  Write-GateLog ("WARN acl.ps1 缺失，跳过准入校验：{0}" -f $aclScript)
}

# ---- 4. 执行 purge（仅在快照确认之后） ----
# 实测：dsh-purge-master 检出目录里的 bin\dsh-purge.js 是独立 CLI，apply 子命令存在；
# 默认（无 --apply）只是 status 只读，加 --apply 才真正清洗 patch。node 用本机 node.exe。
# 因此 ApplyCommand 推荐形态（gate 内执行，前置 pre 快照已 fail-closed 完成）：
#   & '<NODE_EXE>' '<PURGE_JS>' --apply
# 留空时 gate 仍作「快照闸门」放行（调用方 MCP purge_apply），gateMode=snapshot-only；
# 配上时 gateMode=snapshot-apply，apply 失败 exit 1 且 pre 快照保留可 restore。
if ([string]::IsNullOrWhiteSpace($ApplyCommand)) {
  Write-GateLog "PASS gate: pre-snapshot OK (dsh=$dshVer purge=$purgeVer)，ApplyCommand 未配置，以纯快照闸门放行"
  [pscustomobject]@{
    fingerprint  = $fingerprint
    dshVersion   = $dshVer
    purgeVersion = $purgeVer
    appliedAt    = (Get-Date).ToString('o')
    preTag       = $preTag
    postTag      = $null
    applyCommand = $null
    gateMode     = 'snapshot-only'
  } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

  # P1-4：snapshot-only 模式下真正的 purge 走 MCP purge_apply（在 gate 之外），
  # gate 无法自动补 post 快照 → 留 pending 标记，由 verify E3 追踪并在补拍后清除。
  [pscustomobject]@{
    preTag       = $preTag
    at           = (Get-Date).ToString('o')
    dshVersion   = $dshVer
    purgeVersion = $purgeVer
    hint         = 'purge 完成后补拍：snapshot.ps1 -Tag after-purge-<ts>'
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'pending-post.json') -Encoding UTF8
  exit 0
}

Write-GateLog ("RUN {0}" -f $ApplyCommand)
$applyExit = 0
try {
  $out = & pwsh -NoProfile -Command $ApplyCommand 2>&1
  $applyExit = $LASTEXITCODE
  $out | ForEach-Object { Add-Content -LiteralPath $logFile -Value ("    " + $_) -Encoding UTF8 }
}
catch {
  $applyExit = 1
  Write-GateLog ("FAIL apply threw: {0}" -f $_.Exception.Message)
}

if ($applyExit -ne 0) {
  Write-GateLog ("FAIL apply exit={0}；pre 快照保留在 {1}，可用 restore.ps1 回退" -f $applyExit, $preDir)
  exit 1
}

# ---- 5. 后置快照（留证：到底改了什么） ----
# P0-1：post 快照是「清洗后状态」的唯一固化点，失败不再降级为 WARN（假成功）。
$postTag = 'post-' + $dshVer + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$postOk  = $false
$postDir = Join-Path $Vault (Join-Path 'snap' $postTag)
& $snapshot -Tag $postTag -Vault $Vault -ManifestPath $ManifestPath
if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $postDir '_manifest.csv'))) {
  $postOk = $true
} else {
  Write-GateLog ("FAIL post-snapshot failed (exit={0})；apply 已执行但清洗后状态未固化，pre 快照保留：{1}" -f $LASTEXITCODE, $preTag)
}

# ---- 6. 落状态 ----
[pscustomobject]@{
  fingerprint  = $fingerprint
  dshVersion   = $dshVer
  purgeVersion = $purgeVer
  appliedAt    = (Get-Date).ToString('o')
  preTag       = $preTag
  postTag      = $(if ($postOk) { $postTag } else { $null })
  applyCommand = $ApplyCommand
  gateMode     = 'snapshot-apply'
  postOk       = $postOk
} | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

if (-not $postOk) {
  Write-GateLog ("FAIL gate: apply=OK  post=FAIL  pre={0}  补救：手工补 post 快照 snapshot.ps1 -Tag {1}" -f $preTag, $postTag)
  exit 1
}

# apply 路径已产出 post 快照 ⇒ 清除 pending 标记
$ppFile = Join-Path $stateDir 'pending-post.json'
if (Test-Path -LiteralPath $ppFile) { Remove-Item -LiteralPath $ppFile -Force -ErrorAction SilentlyContinue }
Write-GateLog ("PASS gate: {0} -> apply -> {1}" -f $preTag, $postTag)
exit 0

}
finally {
  Exit-VaultLock $lockPath
}
