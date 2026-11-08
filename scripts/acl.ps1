#requires -Version 7.0
# 【分发版·备份机制第二版】由母版提取；仅参数默认值与文案调整，功能逻辑未改。
<#
  acl.ps1 — 层 3：文件级拒写（只对清单里 aclDeny 列出的单文件，不下到目录）
  动作：
    -Status  查看当前 deny 规则
    -Lock    加 deny（当前用户 W,D → 写入/删除被拒，purge 覆盖会显式失败）
    -Unlock  解除 deny（自己要编辑配置前执行）
  退出码：0 = 动作完成；1 = 失败
#>
[CmdletBinding()]
param(
  [ValidateSet('Status', 'Lock', 'Unlock', 'Check', 'Recover')][string]$Action = 'Status',
  [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 【分发版】路径解析：缺省取 vault 根（本脚本所在目录的父目录）下的 config-manifest.json ----
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config-manifest.json' }

$cfg = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$src = $cfg.dshHome
$me  = "$env:USERDOMAIN\$env:USERNAME"

$targets = @()
foreach ($rel in $cfg.aclDeny) {
  $p = Join-Path $src $rel
  $targets += [pscustomobject]@{ Rel = $rel; Path = $p; Exists = (Test-Path -LiteralPath $p) }
}

switch ($Action) {
  'Status' {
    foreach ($t in $targets) {
      if (-not $t.Exists) { Write-Host ("MISSING  {0}" -f $t.Path); continue }
      $acl   = Get-Acl -LiteralPath $t.Path
      $deny  = $acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' }
      if ($deny) {
        foreach ($d in $deny) {
          Write-Host ("DENIED   {0}  <- {1} [{2}]" -f $t.Path, $d.IdentityReference, $d.FileSystemRights)
        }
      } else {
        Write-Host ("WRITABLE {0}" -f $t.Path)
      }
    }
    exit 0
  }

  'Lock' {
    $fail = 0
    foreach ($t in $targets) {
      if (-not $t.Exists) { Write-Host ("SKIP missing: {0}" -f $t.Path); $fail++; continue }
      # 先清同类规则，避免重复叠加
      & icacls $t.Path /remove:d $me | Out-Null
      & icacls $t.Path /deny "${me}:(W,D)" | Out-Null
      if ($LASTEXITCODE -ne 0) { Write-Host ("FAIL icacls deny: {0}" -f $t.Path); $fail++; continue }
      Write-Host ("LOCKED {0}" -f $t.Path)
    }
    if ($fail -gt 0) { exit 1 }
    Write-Host 'PASS acl locked'
    exit 0
  }

  'Unlock' {
    foreach ($t in $targets) {
      if (-not $t.Exists) { Write-Host ("SKIP missing: {0}" -f $t.Path); continue }
      & icacls $t.Path /remove:d $me | Out-Null
      if ($LASTEXITCODE -ne 0) { Write-Host ("FAIL icacls remove: {0}" -f $t.Path); exit 1 }
      Write-Host ("UNLOCKED {0}" -f $t.Path)
    }
    Write-Host 'PASS acl unlocked（编辑完记得再 -Lock）'
    exit 0
  }

  'Check' {
    # P0-4 准入校验：任一 aclDeny 目标当前可写 / 缺失 → exit 1（供 gate 写前调用）
    $bad = 0
    foreach ($t in $targets) {
      if (-not $t.Exists) { Write-Host ("FAIL acl target missing: {0}" -f $t.Path); $bad++; continue }
      $deny = (Get-Acl -LiteralPath $t.Path).Access | Where-Object { $_.AccessControlType -eq 'Deny' }
      if (-not $deny) { Write-Host ("FAIL not denied (可写): {0}" -f $t.Path); $bad++ }
    }
    if ($bad -gt 0) { Write-Host ("FAIL acl check: {0} 项未受保护" -f $bad); exit 1 }
    Write-Host 'PASS acl check: 全部 aclDeny 项均已 deny'
    exit 0
  }

  'Recover' {
    # P0-4 自愈：上一次解锁窗口异常中断（进程被杀/^C）后补回 deny
    . (Join-Path $PSScriptRoot 'vault-common.ps1')
    $vaultRoot = Split-Path -Parent $PSScriptRoot
    if (Invoke-InflightRecover $vaultRoot $ManifestPath) { exit 0 } else { exit 1 }
  }
}
