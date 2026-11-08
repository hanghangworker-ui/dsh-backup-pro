#requires -Version 7.0
<#
  deploy.ps1 — 【分发版】一键初始化本机「配置保护库」（备份机制第二版）
  依次做：建目录 → 按本机实际情况生成 config-manifest.json → 打基准快照
          → 生成 baseline 封存凭证 →（可选）加 ACL 拒写 → 跑 verify 自检
  退出码：0 = 初始化完成（verify 可能仍有预期 WARN）；1 = 初始化失败
  用法：
    pwsh -NoProfile -File <VAULT>\scripts\deploy.ps1 -DshHome <DSH_HOME>
    pwsh -NoProfile -File <VAULT>\scripts\deploy.ps1 -DshHome <DSH_HOME> -Tag baseline -Lock
    已初始化过、要重建清单：加 -Force（旧清单自动备份为 config-manifest.json.bak-<ts>）
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$DshHome,      # 必填：dsh 配置根目录，如 D:\dsh-home / C:\Users\you\.dsh
  [string]$Vault = '',                          # 缺省 = 本脚本所在目录的父目录
  [string]$Tag = 'baseline',                    # 基准快照 tag
  [switch]$Lock,                                # 顺便给 aclDeny 项加 deny
  [switch]$Force,                               # 已存在 manifest 时覆盖（先备份）
  [switch]$SkipSnapshot                         # 只生成清单，不拍快照
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 【分发版】路径解析：不硬编码任何本机路径 ----
if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
$Vault    = [IO.Path]::GetFullPath($Vault)
$DshHome  = [IO.Path]::GetFullPath($DshHome)
$manifestPath = Join-Path $Vault 'config-manifest.json'

Write-Host ("VAULT    = {0}" -f $Vault)
Write-Host ("DSH_HOME = {0}" -f $DshHome)

if (-not (Test-Path -LiteralPath $DshHome)) {
  Write-Host ("FAIL DSH_HOME 不存在: {0}" -f $DshHome)
  Write-Host '     先用 -DshHome 指定 dsh 配置根目录（问 dsh：配置目录在哪，或看 dsh 启动参数）'
  exit 1
}
if ((Test-Path -LiteralPath $manifestPath) -and (-not $Force)) {
  Write-Host ("FAIL 已存在清单，拒绝覆盖: {0}" -f $manifestPath)
  Write-Host '     确认要重建请加 -Force（旧清单会先备份），或直接用现有清单跑 snapshot.ps1'
  exit 1
}

foreach ($d in @($Vault, (Join-Path $Vault 'state'), (Join-Path $Vault 'snap'))) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

if (Test-Path -LiteralPath $manifestPath) {
  $bak = $manifestPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item -LiteralPath $manifestPath -Destination $bak -Force
  Write-Host ("BACKUP 旧清单 -> {0}" -f $bak)
}

# ---- 候选保护项：按客户机实际存在情况判 known / pending（pending 缺失只 WARN，不阻断） ----
$candidates = @(
  @{ path = 'prompt-inject.md';                 kind = 'file'; note = 'purge 注入文件（purge_apply 会写入）' },
  @{ path = '.agent-presets';                   kind = 'dir';  note = 'agent preset 目录（含 unrestricted/agent.cordis.yml）' },
  @{ path = 'whale-roles';                      kind = 'dir';  note = 'roles.json 角色配置' },
  @{ path = 'profiles/web/cordis.patch.yml';    kind = 'file'; note = 'profile patch 层：用户真实配置主体' },
  @{ path = 'profiles/web/cordis.yml';          kind = 'file'; note = 'profile 根（注释声明不要改，仍需保护）' },
  @{ path = 'profiles/web/package.json';        kind = 'file'; note = '插件清单（dsh-purge-community 版本锁在此）' },
  @{ path = 'dsh-purge/update-preferences.json';kind = 'file'; note = 'purge 自更新开关（autoCheck / autoInstall）' },
  @{ path = 'skills';                           kind = 'dir';  note = 'skills 根目录' }
)
$include = @()
foreach ($c in $candidates) {
  $full = Join-Path $DshHome $c.path
  $st = 'pending'
  if (Test-Path -LiteralPath $full) { $st = 'known' }
  $include += [pscustomobject]@{ path = $c.path; kind = $c.kind; status = $st; note = $c.note }
}
$knownCnt = @($include | Where-Object { $_.status -eq 'known' }).Count
if ($knownCnt -eq 0) {
  Write-Host 'FAIL 一个候选保护项都不存在，DSH_HOME 很可能指错了'
  exit 1
}

# aclDeny 只保留真实存在的文件（否则 acl.ps1 -Action Lock 会报错）
$aclDeny = @(@('prompt-inject.md', '.agent-presets/unrestricted/agent.cordis.yml') |
             Where-Object { Test-Path -LiteralPath (Join-Path $DshHome $_) })

$cfg = [ordered]@{
  version       = 1
  comment       = 'dsh 配置保护清单。known = 已确认存在且必须保护；pending = 本机暂缺（出现后自动纳入保护）；removed = 已核实 dsh 不用，脚本跳过。'
  dshHome       = $DshHome
  vault         = $Vault
  keep          = 20
  logKeep       = 50
  include       = $include
  aclDeny       = @($aclDeny)
  referenceTag  = $(if ($SkipSnapshot) { '' } else { $Tag })
  protectedTags = @('baseline.*', 'after-.*', 'post-.*', 'pre-session-copy-.*', 'probe-.*', 'pre-restore-.*')
  expectedWarn  = @('scheduled-task', 'pending-post', 'gate-unused', 'optional-asset', 'acl-off', 'pending-item')
}
$cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host ("WROTE manifest -> {0}（known={1} / pending={2} / aclDeny={3}）" -f `
  $manifestPath, $knownCnt, (@($include).Count - $knownCnt), @($aclDeny).Count)

function Invoke-Step([string]$name, [string[]]$argv) {
  Write-Host ''
  Write-Host ("=== {0} ===" -f $name)
  & pwsh -NoProfile @argv
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { return }
  if ($rc -eq 2) { Write-Host ("WARN {0} exit=2（有差异/待确认，属正常探测结果）" -f $name); return }
  Write-Host ("FAIL {0} exit={1}" -f $name, $rc)
  exit 1
}

$snapP = Join-Path $Vault 'scripts\snapshot.ps1'
$sealP = Join-Path $Vault 'scripts\seal-baseline.ps1'
$verP  = Join-Path $Vault 'scripts\verify.ps1'
$aclP  = Join-Path $Vault 'scripts\acl.ps1'

foreach ($p in @($snapP, $sealP, $verP, $aclP)) {
  if (-not (Test-Path -LiteralPath $p)) { Write-Host ("FAIL 缺少脚本: {0}" -f $p); exit 1 }
}

if (-not $SkipSnapshot) {
  Invoke-Step 'snapshot（基准快照）' @('-File', $snapP, '-Vault', $Vault, '-ManifestPath', $manifestPath, '-Tag', $Tag)
  if ($Tag -eq 'baseline') {
    Invoke-Step 'seal-baseline（封存基准）' @('-File', $sealP, '-Vault', $Vault, '-ManifestPath', $manifestPath, '-Tag', 'baseline')
  }
}
if ($Lock) {
  Invoke-Step 'acl Lock（层3 拒写）' @('-File', $aclP, '-ManifestPath', $manifestPath, '-Action', 'Lock')
}

Write-Host ''
Write-Host '=== verify（自检）==='
& pwsh -NoProfile -File $verP -Vault $Vault -ManifestPath $manifestPath
$vrc = $LASTEXITCODE

Write-Host ''
Write-Host '=== 下一步 ==='
Write-Host ("1) ACL 若还没加：pwsh -NoProfile -File `"{0}`" -Action Lock" -f $aclP)
Write-Host  '2) 想把快照闸门串进 purge 流程：见 说明文档.md 第 7 节（purge-gate.ps1）'
Write-Host ("3) 配置被清空后恢复：restore.ps1 -Tag {0} -Plan 先看差异，再 -Force 真恢复" -f $Tag)
Write-Host ("4) 自检随时跑：verify.ps1 -Vault `"{0}`"" -f $Vault)

exit $vrc
