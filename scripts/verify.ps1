#requires -Version 7.0
# 【分发版·备份机制第二版】由母版提取；仅参数默认值与文案调整，功能逻辑未改。
<#
  verify.ps1 — 一次性自检：三层是否真的生效
  检查项：
    A. 清单里 known 项是否都存在（配置是否已被清除）
    B. 最新快照与当前源是否一致（快照链路是否在跑）
    C. ACL deny 是否生效
    D. 计划任务 DshPurgeUpdateWatch 是否存在且上次运行成功
    E. purge-gate 是否已有状态记录（gateMode 必须齐备，postOk=false 判 FAIL）
    F. asset-table 常量清单与 package.json 指纹是否存在（缺失=FAIL）
    B2. 快照自完整性（_manifest.csv 与 _versions.json 记录哈希一致）+ baseline 对照 INFO
    G. 脚本编码自检（.ps1/.psm1/.psd1 必须 UTF-8 BOM，否则 Windows PowerShell 5.1 按 GBK 误读 → 假报语法错误）
    A2. removed 项回归（已判定不用的路径重新出现 → WARN）
    E2. referenceTag 必须存在且有 digest（防止参考基线被裁剪/误删）
    E3. pending post-snapshot（snapshot-only 模式下 purge 后未取证 → WARN，键 pending-post）
  参数：-Tag 覆盖默认对照快照；-Strict 让「非预期 WARN」也 exit 1
  退出码：0 = 全部 PASS 或仅 WARN；1 = 存在 FAIL
#>
[CmdletBinding()]
param(
  [string]$Tag,
  [string]$Vault = '',
  [string]$ManifestPath = '',
  [string]$TaskName = 'DshPurgeUpdateWatch',
  [switch]$Strict
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 【分发版】路径解析：不硬编码本机路径；缺省 = 本脚本所在目录的父目录（vault 根） ----
if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $Vault 'config-manifest.json' }

. (Join-Path $PSScriptRoot 'vault-common.ps1')

$fail = 0; $warn = 0
function Pass([string]$m) { Write-Host ("PASS  {0}" -f $m) }
$script:expectedHits = @()
$script:expectedKeys = @()
# P1-2：预期 WARN 必须可枚举（config-manifest.json: expectedWarn），
# 否则常驻的 D 项 WARN 会训练人忽略告警，真正的漂移就被淹掉。
function Warn([string]$m, [string]$Key) {
  if ($Key -and ($script:expectedKeys -contains $Key)) {
    Write-Host ("WARN  {0} (expected)" -f $m)
    $script:expectedHits += $Key
  } else {
    Write-Host ("WARN  {0}" -f $m)
  }
  $script:warn++
}
function Fail([string]$m) { Write-Host ("FAIL  {0}" -f $m); $script:fail++ }

$cfg = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$src = $cfg.dshHome
$script:expectedKeys = @(Get-ManifestField $cfg 'expectedWarn' @())

# ---- A. 配置存在性 ----
Write-Host '--- A. config presence ---' -ForegroundColor Cyan
foreach ($item in $cfg.include) {
  if ($item.status -eq 'removed') { continue }   # 已从清单移除的项（确认 dsh 不用），不检查
  $p = Join-Path $src $item.path
  if (Test-Path -LiteralPath $p) {
    Pass ("{0} [{1}]" -f $item.path, $item.status)
  } elseif ($item.status -eq 'known') {
    Fail ("known config missing: {0}" -f $p)
  } else {
    Warn ("pending path not present (待确认位置): {0}" -f $item.path) 'pending-item'
  }
}

# ---- A2. removed 项回归检查（P2-3） ----
# 判定 removed 的路径若重新出现，说明 dsh 行为变了，需要重新评估是否纳入保护。
foreach ($item in $cfg.include) {
  if ($item.status -ne 'removed') { continue }
  $p = Join-Path $src $item.path
  if (Test-Path -LiteralPath $p) {
    Warn ("已判定 removed 的项重新出现: {0}（dsh 行为可能变化，需重新评估是否纳入保护）" -f $item.path)
  }
}

# ---- B. 最新快照一致性 ----
Write-Host '--- B. snapshot freshness ---' -ForegroundColor Cyan
$snapRoot = Join-Path $Vault 'snap'
if (-not (Test-Path -LiteralPath $snapRoot)) { Fail 'no snapshot directory' }
else {
  # P1-1：默认对照 referenceTag（固化基准），不再「取最新快照」——
  # 否则任何「先改后拍」都会把漂移洗成基准（package.json 漂移就是这么发生的）。
  $refTag  = [string](Get-ManifestField $cfg 'referenceTag' '')
  $selName = if ($Tag) { $Tag } elseif ($refTag) { $refTag } else { '' }
  $sel = if ($selName) { Join-Path $snapRoot $selName } else {
    Get-ChildItem -LiteralPath $snapRoot -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  }
  # E2：参考基线必须存在，缺了就是 FAIL（而不是悄悄退化成「最新快照」）
  if ($selName -and -not (Test-Path -LiteralPath $sel)) {
    Fail ("reference snapshot 不存在: {0}（跑 snapshot.ps1 -Tag {0}，或检查 protectedTags 是否把它裁掉）" -f $selName)
    $sel = $null
  }
  if (-not $sel -and -not $selName) { Fail 'no snapshot found' }
  else {
    $dir = if ($sel -is [string]) { $sel } else { $sel.FullName }
    $csv = Join-Path $dir '_manifest.csv'
    if (-not (Test-Path -LiteralPath $csv)) { Fail ("snapshot incomplete: {0}" -f $dir) }
    else {
      $rows   = Import-Csv -LiteralPath $csv
      $drift  = @()
      $locked = @()
      foreach ($r in $rows) {
        $cur = Join-Path $src $r.RelPath
        if (-not (Test-Path -LiteralPath $cur)) { $drift += "$($r.RelPath) (missing)"; continue }
        # 层3 生效时，aclDeny 项的源文件被 icacls Deny 拦读，Get-FileHash 会 AccessDenied。
        # 这类文件按设计就是锁着的（drift 不可能来自正常修改，锁被破坏属 C 项范畴），
        # 故跳过、不计 drift，只记入 $locked 供汇总提示。
        try {
          if ((Get-FileHash -LiteralPath $cur -Algorithm SHA256).Hash -ne $r.Sha256) { $drift += $r.RelPath }
        } catch [System.UnauthorizedAccessException] {
          $locked += $r.RelPath
        }
      }
      if ($locked.Count -gt 0) {
        Write-Host ("    (层3 锁中，跳过 {0} 个 aclDeny 源文件: {1})" -f $locked.Count, ($locked -join ', ')) -ForegroundColor DarkGray
      }
      if ($drift.Count -eq 0) { Pass ("snapshot {0} matches source ({1} files checked, {2} locked-skipped)" -f (Split-Path -Leaf $dir), ($rows.Count - $locked.Count), $locked.Count) }
      else { Warn ("源与快照有 {0} 处差异（正常=你改过配置；异常=被插件改过，先 diff 再 restore）: {1}" -f $drift.Count, ($drift -join ', ')) }
    }
  }
}

# ---- B2. 快照自完整性 + baseline 对照（P0-8 / P0-7） ----
# 完整性不符 = FAIL（快照基准被改动，restore 会把篡改内容写回配置）；
# baseline 对照仅 INFO（baseline 与当前源的差异是正常演进，不是错误）。
$integTargets = @()
if ($selName) { $integTargets += (Join-Path $snapRoot $selName) }
else {
  $latestDir = Get-ChildItem -LiteralPath $snapRoot -Directory -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if ($latestDir) { $integTargets += $latestDir.FullName }
}
foreach ($d in $integTargets) {
  if (-not (Test-Path -LiteralPath (Join-Path $d '_versions.json'))) { continue }
  $integ = Test-SnapshotIntegrity $d
  if ($integ -eq $false) {
    Fail ("snapshot integrity mismatch: {0}（_manifest.csv 与 _versions.json 记录哈希不符）" -f (Split-Path -Leaf $d))
  } elseif ($null -eq $integ) {
    Write-Host ("    (INFO 旧版快照无完整性字段，跳过: {0})" -f (Split-Path -Leaf $d)) -ForegroundColor DarkGray
  } else {
    Pass ("snapshot integrity OK: {0}" -f (Split-Path -Leaf $d))
  }
}
$bDir = Join-Path $snapRoot 'baseline'
if (Test-Path -LiteralPath (Join-Path $bDir '_manifest.csv')) {
  $bRows  = Import-Csv -LiteralPath (Join-Path $bDir '_manifest.csv')
  $bDrift = @()
  foreach ($r in $bRows) {
    $cur = Join-Path $src $r.RelPath
    if (-not (Test-Path -LiteralPath $cur)) { $bDrift += ($r.RelPath + '(missing)'); continue }
    try {
      if ((Get-FileHash -LiteralPath $cur -Algorithm SHA256).Hash -ne $r.Sha256) { $bDrift += $r.RelPath }
    } catch [System.UnauthorizedAccessException] { }
  }
  $bHint = if ($bDrift.Count -gt 0) { '：' + (($bDrift | Select-Object -First 5) -join ', ') } else { '' }
  Write-Host ("    (INFO baseline 对照：{0} 个文件与当前源不同{1})" -f $bDrift.Count, $bHint) -ForegroundColor DarkGray
}

# P2-1：baseline 是历史快照（无 snapshotDigest），其目录内容被改动时原本无法察觉。
# 不改写 baseline 的定位，改用外置封存凭证 state\baseline-integrity.json 校验。
$sealFile = Join-Path $Vault 'state\baseline-integrity.json'
if (Test-Path -LiteralPath (Join-Path $bDir '_manifest.csv')) {
  if (Test-Path -LiteralPath $sealFile) {
    try {
      $seal = Get-Content -LiteralPath $sealFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $cur  = Get-SnapshotDigest $bDir
      if ($cur.snapshotDigest -eq $seal.snapshotDigest) {
        Pass ("baseline integrity OK (sealed {0}, {1} files)" -f $seal.sealedAt, $seal.files)
      } else {
        Fail 'baseline 与封存凭证不一致（baseline 目录被改动过，恢复前先核对）'
      }
    } catch {
      Warn 'baseline-integrity.json 无法解析（重跑 seal-baseline.ps1）' 'baseline-seal'
    }
  } else {
    Warn 'baseline 未封存（跑 seal-baseline.ps1 生成 state\baseline-integrity.json）' 'baseline-seal'
  }
}

# ---- C. ACL deny ----
Write-Host '--- C. ACL deny ---' -ForegroundColor Cyan
# 层3 是可选层：全部未加锁 = 未启用（WARN，键 acl-off，不算 FAIL）；
# 只要有一项加了锁、其余没加 = 真的坏了（FAIL）——这才是需要人看的故障。
$aclRows = @()
foreach ($rel in $cfg.aclDeny) {
  $p = Join-Path $src $rel
  if (-not (Test-Path -LiteralPath $p)) { $aclRows += [pscustomobject]@{ Rel = $rel; State = 'missing' }; continue }
  $deny = (Get-Acl -LiteralPath $p).Access | Where-Object { $_.AccessControlType -eq 'Deny' }
  $aclRows += [pscustomobject]@{ Rel = $rel; State = $(if ($deny) { 'denied' } else { 'open' }) }
}
$nDenied = @($aclRows | Where-Object { $_.State -eq 'denied' }).Count
$nOpen   = @($aclRows | Where-Object { $_.State -eq 'open' }).Count
foreach ($r in $aclRows) {
  if ($r.State -eq 'missing') { Warn ("acl target missing: {0}" -f $r.Rel); continue }
  if ($r.State -eq 'denied')  { Pass ("denied: {0}" -f $r.Rel); continue }
  if ($nDenied -eq 0)         { continue }
  Fail ("NOT denied: {0}" -f $r.Rel)
}
if ($nOpen -gt 0 -and $nDenied -eq 0) {
  Warn ("ACL 未启用：{0} 个 aclDeny 项均未加锁（层3 为可选层；acl.ps1 -Action Lock 后此处转 PASS）" -f $nOpen) 'acl-off'
}

# ---- D. 计划任务 ----
Write-Host '--- D. scheduled task ---' -ForegroundColor Cyan
try {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  $info = Get-ScheduledTaskInfo -TaskName $TaskName
  if ($t.State -eq 'Disabled') { Warn ("task '{0}' exists but Disabled" -f $TaskName) }
  else { Pass ("task '{0}' state={1}" -f $TaskName, $t.State) }
  if ($null -ne $info.LastTaskResult -and $info.LastTaskResult -ne 0) {
    Fail ("task last result = 0x{0:X}" -f $info.LastTaskResult)
  } else {
    Pass ("task last result OK (last run {0})" -f $info.LastRunTime)
  }
} catch {
  Warn ("task '{0}' not found on this machine (未部署计划任务时可忽略；键 scheduled-task)" -f $TaskName) 'scheduled-task'
}

# ---- E. gate 状态 ----
Write-Host '--- E. purge-gate state ---' -ForegroundColor Cyan
$stateFile = Join-Path $Vault 'state\last-applied.json'
if (Test-Path -LiteralPath $stateFile) {
  $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
  # P0-3：有 applyCommand 却没有 gateMode = 审计记录无法判定真实执行方式，不能静默降级
  $hasCmd  = [bool]($s.PSObject.Properties['applyCommand'] -and $s.applyCommand)
  $hasMode = [bool]($s.PSObject.Properties['gateMode'] -and $s.gateMode)
  if ($hasCmd -and -not $hasMode) {
    Fail 'last-applied.json 有 applyCommand 但缺 gateMode（无法判定真实执行方式，需重跑 gate）'
  } else {
    $mode = if ($hasMode) { $s.gateMode } else { 'snapshot-only(legacy)' }
    Pass ("gate has applied state: dsh={0} purge={1} at={2} mode={3}" -f $s.dshVersion, $s.purgeVersion, $s.appliedAt, $mode)
  }
  # P0-1：postOk=false 说明 apply 之后清洗态未固化
  if ($s.PSObject.Properties['postOk'] -and ($s.postOk -eq $false)) {
    Fail 'last-applied.json postOk=false（apply 后无 post 快照，清洗后状态未固化）'
  }
} else {
  Warn 'gate 尚未执行过（首次运行 purge-gate.ps1 后出现）' 'gate-unused'
}

# ---- E3. pending post-snapshot（purge 后取证缺口，P1-4） ----
Write-Host '--- E3. pending post-snapshot ---' -ForegroundColor Cyan
$ppFile = Join-Path $Vault 'state\pending-post.json'
if (-not (Test-Path -LiteralPath $ppFile)) {
  Pass 'no pending post-snapshot'
} else {
  try {
    $ppj  = Get-Content -LiteralPath $ppFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $ppAt = ([datetime]$ppj.at).ToUniversalTime()
    $newer = @(Get-ChildItem -LiteralPath $snapRoot -Directory |
               Where-Object { $_.Name -match '^(after-|post-)' -and $_.LastWriteTimeUtc -gt $ppAt })
    if ($newer.Count -gt 0) {
      Pass ("pending post 已补拍: {0}（可删除 state\pending-post.json 或由 gate 自动清理）" -f $newer[0].Name)
    } else {
      Warn ("pending post-snapshot：purge 后未取证（preTag={0} at={1}）；补拍 snapshot.ps1 -Tag after-purge-<ts>" -f $ppj.preTag, $ppj.at) 'pending-post'
    }
  } catch {
    Warn 'pending-post.json 无法解析'
  }
}

# ---- F. asset-table 常量指纹（P1 交叉校验，可选） ----
# 实测 (m00226)：lib/asset-table.js 导出 4 常量 IV/MASK/SLOT/TAG，无 dump CLI。
# 本项读取 state/asset-table-keys.json（detect-purge-master.ps1 落盘的常量清单）
# 与 state/dsh-purge-pkg.sha256（package.json 指纹），确认 dsh-purge-master 检出可定位。
# 缺失或损坏均为 WARN（P1 为可选增强，非 fail-closed 主链路）。
Write-Host '--- F. asset-table constants (optional) ---' -ForegroundColor Cyan
$assetKeysFile = Join-Path $Vault 'state\asset-table-keys.json'
$pkgShaFile    = Join-Path $Vault 'state\dsh-purge-pkg.sha256'
if (Test-Path -LiteralPath $assetKeysFile) {
  $ak = Get-Content -LiteralPath $assetKeysFile -Raw | ConvertFrom-Json
  $expect = @('IV','MASK','SLOT','TAG')
  if (-not $ak.keys) { Warn 'asset-table-keys.json 缺少 keys 字段' }
  else {
    # @(...) 强制数组：Where-Object 0 条时得 @() 而非 $null，.Count 在 StrictMode 下安全
    $missing = @($expect | Where-Object { $_ -notin $ak.keys })
    if ($missing.Count -eq 0) { Pass ("asset-table keys: {0}" -f ($ak.keys -join ',')) }
    else { Warn ("asset-table keys 缺少: {0}" -f ($missing -join ',')) }
  }
} else {
  Warn 'asset-table-keys.json 不存在（F 项为可选增强，分发版默认跳过；如需启用先跑 detect 工具）' 'optional-asset'
}
if (Test-Path -LiteralPath $pkgShaFile) {
  $sha = (Get-Content -LiteralPath $pkgShaFile -Raw).Trim()
  if ($sha -match '^[0-9a-fA-F]{64}$') { Pass ("dsh-purge package.json sha256: {0}" -f $sha) }
  else { Warn ("dsh-purge-pkg.sha256 格式异常: {0}" -f $sha) }
} else {
  Warn 'dsh-purge-pkg.sha256 不存在（F 项为可选增强，分发版默认跳过）' 'optional-asset'
}

Write-Host ''
Write-Host '--- G. script encoding (PS 5.1 兼容) ---' -ForegroundColor Cyan
# 2026-11-08 事故：8 个 .ps1 存成 UTF-8 无 BOM，在 Windows PowerShell 5.1 下
# Parser::ParseFile 按 GBK 误读 → 中文字符串被撕成半截 → 假报 38 处语法错误
# （pwsh 7 解析全 OK、运行全 OK）。此项把「编码回退」变成可失败的验收项。
# P1-3：把 .psm1/.psd1 与子目录一并纳入（编码隐患的载体是「脚本」而非「这一层的 .ps1」）
$psFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')
$noBom = @()
foreach ($f in $psFiles) {
  $fs = [System.IO.File]::OpenRead($f.FullName)
  try {
    $head = New-Object byte[] 3
    [void]$fs.Read($head, 0, 3)
  } finally { $fs.Dispose() }
  if (-not ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)) { $noBom += $f.Name }
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
  $eCount = @($errs).Count
  if ($eCount -gt 0) {
    Fail ("{0} 解析失败 {1} 处（首个 L{2}: {3}）" -f $f.Name, $eCount, $errs[0].Extent.StartLineNumber, $errs[0].Message)
  }
}
if ($noBom.Count -gt 0) {
  Fail ("缺 UTF-8 BOM: {0}（Windows PowerShell 5.1 会按 GBK 误读，假报语法错误；pwsh 7 不受影响）" -f ($noBom -join ', '))
} else {
  Pass ("脚本编码 OK: {0} 个脚本（ps1/psm1/psd1）均为 UTF-8 BOM 且可解析" -f $psFiles.Count)
}

# JSON 可解析性：清单/状态文件被手改坏时立刻暴露（含 state\*.json）
$jsonFiles = @()
foreach ($jd in @($Vault, (Join-Path $Vault 'state'))) {
  if (Test-Path -LiteralPath $jd) { $jsonFiles += @(Get-ChildItem -LiteralPath $jd -Filter '*.json' -File) }
}
$jsonBad = 0
foreach ($j in $jsonFiles) {
  try { $null = Get-Content -LiteralPath $j.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Fail ("JSON 解析失败: {0}" -f $j.Name); $jsonBad++ }
}
if ($jsonFiles.Count -gt 0 -and $jsonBad -eq 0) { Pass ("JSON 可解析: {0} 个文件" -f $jsonFiles.Count) }


Write-Host ''
$expected = @($expectedHits).Count
$unexpected = $warn - $expected
Write-Host ("SUMMARY: {0} FAIL / {1} WARN ({2} expected, {3} unexpected)" -f $fail, $warn, $expected, $unexpected)
if ($fail -gt 0) { exit 1 }
if ($Strict -and $unexpected -gt 0) {
  Write-Host ("-Strict: {0} 个非预期 WARN 视为失败" -f $unexpected)
  exit 1
}
exit 0
