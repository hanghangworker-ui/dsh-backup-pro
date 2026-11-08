#requires -Version 7.0
# 【分发版·备份机制第二版】由母版提取；仅参数默认值与文案调整，功能逻辑未改。
<#
  vault-common.ps1 — vault 脚本共用工具（被 purge-gate / snapshot / restore / acl / verify dot-source）
  提供：
    1) Enter-VaultLock / Exit-VaultLock        并发互斥（P0-5）
    2) Save-Inflight / Clear-Inflight / Invoke-InflightRecover   解锁窗口自愈（P0-4）
    3) Get-SnapshotDigest / Test-SnapshotIntegrity               快照自完整性（P0-8）
    4) Invoke-SnapshotPrune                    保留策略白名单（P0-2）
    5) Get-ContentAddressedTag                 内容寻址 tag（P0-2）
    6) Resolve-DshPkgPath                      $dshPkg 自适应（P0-6）
  约定：只做单件事；失败以 throw / $false / $null 暴露，不吞异常、不降级为警告。
#>

function Get-VaultStateDir([string]$Vault) {
    $d = Join-Path $Vault 'state'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

# ---- P0-6：dsh package.json 定位（不再硬编码用户名路径） ----
function Resolve-DshPkgPath {
    $p = $null
    try {
        $root = (& npm root -g 2>$null | Select-Object -First 1)
        if ($root) { $p = Join-Path $root '@deepseek-ai\dsh\package.json' }
    } catch { $p = $null }
    if (-not ($p -and (Test-Path -LiteralPath $p))) {
        $alt = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\package.json'
        if (Test-Path -LiteralPath $alt) { $p = $alt } else { $p = $null }
    }
    return $p
}

# ---- P0-5：并发互斥（CreateNew + Share.None，进程崩溃遗留锁按 pid 存活判定清理）
# 返回 @{ path; owned } ；同进程重入（父脚本 & 调用子脚本，$PID 相同）返回 owned=$false，
# 由父脚本负责释放 —— 否则 purge-gate → snapshot、restore → snapshot 会自己把自己锁死。
function Enter-VaultLock([string]$Vault, [string]$Who) {
    $stateDir = Get-VaultStateDir $Vault
    $lockPath = Join-Path $stateDir 'gate.lock'
    if (Test-Path -LiteralPath $lockPath) {
        try {
            $cur = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cur.pid -eq $PID) {
                Write-Host ("LOCK reentrant (owned by pid {0} / {1})" -f $PID, $cur.who) -ForegroundColor DarkGray
                return [pscustomobject]@{ path = $lockPath; owned = $false }
            }
        } catch { }
    }
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $fs = [System.IO.File]::Open($lockPath, 'CreateNew', 'Write', 'None')
            $payload = (@{ pid = $PID; who = $Who; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
            $bytes   = [Text.Encoding]::UTF8.GetBytes($payload)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Close()
            return [pscustomobject]@{ path = $lockPath; owned = $true }
        } catch [System.IO.IOException] {
            $stale = $false
            try {
                $j = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not (Get-Process -Id $j.pid -ErrorAction SilentlyContinue)) { $stale = $true }
            } catch { $stale = $true }
            if ($stale -and $i -eq 0) {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                continue
            }
            return $null
        }
    }
    return $null
}

function Exit-VaultLock($Lock) {
    if ($null -eq $Lock) { return }
    if ($Lock -is [string]) { $p = [string]$Lock; $owned = $true }
    else { $p = [string]$Lock.path; $owned = [bool]$Lock.owned }
    if (-not $owned) { return }   # 借用的锁不释放，交由父脚本
    if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

# ---- P0-4：解锁窗口 inflight 记录与自愈 ----
function Get-InflightPath([string]$Vault) { return (Join-Path (Get-VaultStateDir $Vault) 'unlock-inflight.json') }

function Save-Inflight([string]$Vault, [string]$Script, [string]$Tag, [string[]]$Files) {
    $p = Get-InflightPath $Vault
    @{ pid = $PID; script = $Script; tag = $Tag; startedAt = (Get-Date).ToString('o'); files = @($Files) } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $p -Encoding UTF8
}

function Clear-Inflight([string]$Vault) {
    $p = Get-InflightPath $Vault
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

function Invoke-InflightRecover([string]$Vault, [string]$ManifestPath) {
    $p = Get-InflightPath $Vault
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host 'PASS 无残留 inflight（无未完成的解锁窗口）'
        return $true
    }
    $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    # StrictMode Latest 下缺字段访问会抛错，用 PSObject.Properties 安全取值
    $jPid   = if ($j.PSObject.Properties['pid']) { [int]$j.pid } else { 0 }
    $jWho   = if ($j.PSObject.Properties['script']) { [string]$j.script } else { 'unknown' }
    $jFiles = if ($j.PSObject.Properties['files']) { @($j.files) } else { @() }
    if ($jPid -gt 0 -and (Get-Process -Id $jPid -ErrorAction SilentlyContinue)) {
        Write-Host ("FAIL inflight 指向仍在运行的 pid {0}（{1}），拒绝补锁" -f $jPid, $jWho) -ForegroundColor Red
        return $false
    }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Write-Host ("FAIL manifest 缺失，无法定位源目录: {0}" -f $ManifestPath) -ForegroundColor Red
        return $false
    }
    $cfg = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $src = $cfg.dshHome
    $me  = "$env:USERDOMAIN\$env:USERNAME"
    $n   = 0
    foreach ($rel in $jFiles) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $f = Join-Path $src $rel
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $deny = (Get-Acl -LiteralPath $f).Access | Where-Object { $_.AccessControlType -eq 'Deny' }
        if (-not $deny) {
            & icacls $f /deny "${me}:(W,D)" | Out-Null
            Write-Host ("RECOVERED LOCK {0}" -f $f) -ForegroundColor Yellow
            $n++
        }
    }
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    Write-Host ("PASS inflight 自愈完成（补锁 {0} 个；崩溃 pid {1} 已不存在）" -f $n, $jPid) -ForegroundColor Green
    return $true
}

# ---- P0-8：快照自完整性 ----
function Get-SnapshotDigest([string]$SnapDir) {
    $csv = Join-Path $SnapDir '_manifest.csv'
    if (-not (Test-Path -LiteralPath $csv)) { throw "snapshot manifest missing: $csv" }
    $manifestSha = (Get-FileHash -LiteralPath $csv -Algorithm SHA256).Hash.ToLowerInvariant()
    $rows = @(Import-Csv -LiteralPath $csv)
    $acc  = (@($rows | Sort-Object RelPath | ForEach-Object { $_.RelPath + '=' + $_.Sha256 }) -join "`n")
    $digest = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($acc))) -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{
        manifestSha256 = $manifestSha
        snapshotDigest = $digest
        digestAlgo     = 'sha256-relpath-sorted'
        rowCount       = $rows.Count
    }
}

function Test-SnapshotIntegrity([string]$SnapDir) {
    # $true = 一致；$false = 不一致；$null = 旧版快照无字段（兼容，调用方自行提示重建）
    $verPath = Join-Path $SnapDir '_versions.json'
    if (-not (Test-Path -LiteralPath $verPath)) { return $null }
    $ver = Get-Content -LiteralPath $verPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($ver.PSObject.Properties['manifestSha256'] -and $ver.manifestSha256)) { return $null }
    $csv = Join-Path $SnapDir '_manifest.csv'
    if (-not (Test-Path -LiteralPath $csv)) { return $false }
    $now = (Get-FileHash -LiteralPath $csv -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($now -eq ([string]$ver.manifestSha256).ToLowerInvariant())
}

# ---- P0-2：保留策略（baseline / after-* / drill 记录永不裁剪） ----
function Invoke-SnapshotPrune {
    param(
        [string]$Vault,
        [int]$Keep = 20,
        [string[]]$ProtectPatterns,
        [switch]$WhatIf
    )
    $snapRoot = Join-Path $Vault 'snap'
    if (-not (Test-Path -LiteralPath $snapRoot)) { return }

    # P0-1（2026-11-08）：保护表改为数据驱动（config-manifest.json: protectedTags）。
    # 原实现把正则硬编码在这里，导致 post-session-copy-*（README 指定的日常对照基线）
    # 和 probe-* 不在保护表内 —— 快照数一旦超过 keep 就会被静默删掉。
    $pats = @(@($ProtectPatterns) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pats.Count -eq 0) { $pats = @('baseline.*', 'after-.*', 'post-.*', 'pre-restore-drill-.*') }
    $protect = '^(' + (($pats | ForEach-Object { $_.Trim() }) -join '|') + ')$'

    $cand = @(Get-ChildItem -LiteralPath $snapRoot -Directory |
              Where-Object { $_.Name -notmatch $protect } |
              Sort-Object LastWriteTimeUtc -Descending)
    $keepSet = @(Get-ChildItem -LiteralPath $snapRoot -Directory |
                 Where-Object { $_.Name -match $protect } | ForEach-Object { $_.Name })

    if ($cand.Count -le $Keep) {
        if ($WhatIf) {
            Write-Host ("DRYRUN prune: 0 candidate (total={0}, protected={1}, keep={2})" -f ($cand.Count + $keepSet.Count), $keepSet.Count, $Keep) -ForegroundColor DarkGray
        }
        return
    }
    $victims = @($cand | Select-Object -Skip $Keep)
    if ($WhatIf) {
        Write-Host ("DRYRUN prune: keep={0}, protected={1}, would delete {2}: {3}" -f $Keep, $keepSet.Count, $victims.Count, (($victims | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor DarkGray
        return
    }
    $victims | ForEach-Object {
        Write-Host ("PRUNE {0}" -f $_.Name) -ForegroundColor DarkGray
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
}

# P2-3：state\*.log 滚动裁剪（验收日志会持续累积）
function Invoke-StateLogPrune {
    param([string]$Vault, [int]$KeepLogs = 50, [switch]$WhatIf)
    $stateDir = Join-Path $Vault 'state'
    if (-not (Test-Path -LiteralPath $stateDir)) { return }
    $logs = @(Get-ChildItem -LiteralPath $stateDir -Filter '*.log' -File |
              Sort-Object LastWriteTimeUtc -Descending)
    if ($logs.Count -le $KeepLogs) { return }
    $old = @($logs | Select-Object -Skip $KeepLogs)
    if ($WhatIf) {
        Write-Host ("DRYRUN log-prune: would delete {0} log(s)" -f $old.Count) -ForegroundColor DarkGray
        return
    }
    $old | ForEach-Object {
        Write-Host ("PRUNE-LOG {0}" -f $_.Name) -ForegroundColor DarkGray
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# 从清单取可选字段（缺失时给默认值；StrictMode 下不能直接点属性）
function Get-ManifestField {
    param($Cfg, [string]$Name, $Default)
    $prop = $Cfg.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

# ---- P0-3：当前源内容的摘要（与 Get-SnapshotDigest 同算法，供 gate 指纹使用） ----
function Get-SourceContentDigest {
    param([string]$DshHome, [object[]]$Rows)
    $acc = @()
    foreach ($r in (@($Rows) | Sort-Object RelPath)) {
        if ($null -eq $r) { continue }
        $rel = [string]$r.RelPath
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $p = Join-Path $DshHome $rel
        $h = 'missing'
        if (Test-Path -LiteralPath $p) {
            try { $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
            catch { $h = 'unreadable' }
        }
        $acc += ($rel + '=' + $h)
    }
    $s = ($acc -join "`n")
    $ms = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($s))
    return (Get-FileHash -InputStream $ms -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ---- P0-2：内容寻址 tag（同一源状态只落一张快照） ----
function Get-ContentAddressedTag([string]$Prefix, [string]$Seed) {
    if ([string]::IsNullOrWhiteSpace($Seed)) { throw 'Get-ContentAddressedTag: seed 不能为空' }
    $h = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Seed))) -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($Prefix + '-' + $h.Substring(0, 8))
}
