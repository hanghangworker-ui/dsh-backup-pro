#requires -Version 7.0
# 【分发版·备份机制第二版】由母版提取；仅参数默认值与文案调整，功能逻辑未改。
<#
  acceptance-r2.ps1 — 三道验收一次跑完（自愈式）
    ③ V2  fail-closed 注入测试：把 manifest 的 dshHome 改坏 → 跑 gate → 必须 exit 1，且 apply 未执行
    ④ V4  恢复演练：安全快照 → restore -Tag baseline -Force → 复元快照
    ⑤ V5  恢复后 verify 复跑 → 必须 0 FAIL

  自愈保证：无论成败，finally 都把 config-manifest.json 的 dshHome 还原为 <DSH_HOME>；
            manifest 原文另存 state\manifest.acceptance.bak，可人工回退。
  退出码：0 = 三道全过；1 = 至少一项 FAIL（详见 SUMMARY）
  用法：
    pwsh -NoProfile -File <VAULT>\scripts\acceptance-r2.ps1
    pwsh -NoProfile -File <VAULT>\scripts\acceptance-r2.ps1 -SkipRestore   # 只跑 ③⑤，不动 <DSH_HOME>
#>
[CmdletBinding()]
param(
  [string]$Vault        = '',
  [string]$ManifestPath = '',
  [string]$BaselineTag  = 'baseline',
  [string]$GoodHome     = '',
  [string]$BadHome      = '',
  [switch]$SkipRestore,
  [switch]$KeepBaseline,
  [string]$RollForwardFrom = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 【分发版】路径解析：不硬编码本机路径；缺省 = 本脚本所在目录的父目录（vault 根） ----
if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $Vault 'config-manifest.json' }
$PSNativeCommandUseErrorActionPreference = $false   # 原生命令非零退出不抛异常，靠 $LASTEXITCODE 判断

# ---- 【分发版】good/bad home 缺省从清单取，避免硬编码本机路径 ----
if ([string]::IsNullOrWhiteSpace($GoodHome)) {
  $GoodHome = (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).dshHome
}
if ([string]::IsNullOrWhiteSpace($BadHome)) { $BadHome = $GoodHome + '-inject-test' }

$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = New-Object System.Collections.Generic.List[string]
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c; $script:log.Add($m) }
$script:fail = 0
function Pass([string]$m) { Say "PASS  $m" Green }
function Fail([string]$m) { Say "FAIL  $m" Red; $script:fail++ }
function Warn([string]$m) { Say "WARN  $m" Yellow }
function Step([string]$m) { Write-Host ''; Say "=== $m ===" Cyan }

$gate   = Join-Path $Vault 'scripts\purge-gate.ps1'
$snapP  = Join-Path $Vault 'scripts\snapshot.ps1'
$restP  = Join-Path $Vault 'scripts\restore.ps1'
$verP   = Join-Path $Vault 'scripts\verify.ps1'
$marker = Join-Path $Vault 'state\APPLY_RAN.marker'
$snapRoot = Join-Path $Vault 'snap'
$bakFile  = Join-Path $Vault 'state\manifest.acceptance.bak'
$pendingPost = Join-Path $Vault 'state\pending-post.json'
$pendingPostBefore = Test-Path -LiteralPath $pendingPost   # 演练前是否已有真实标记（有则保留，不误删）

# ---------- 工具函数 ----------
# 注意：参数不能叫 $home —— 它是 PowerShell 只读自动变量，赋值会抛「无法覆盖变量 home」
function Set-DshHome([string]$targetHome) {
  $raw    = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
  $repl   = $targetHome.Replace('\', '\\')          # 逐字符替换：每个 \ 变两个 \（合法 JSON 转义）
  $new    = [regex]::Replace($raw, '(?m)^(\s*"dshHome"\s*:\s*")[^"]*(")', ('${1}' + $repl + '${2}'))
  if ($new -eq $raw) { throw "Set-DshHome 未产生变化，dshHome 行可能已被改写: $targetHome" }
  Set-Content -LiteralPath $ManifestPath -Value $new -Encoding UTF8 -NoNewline
}
function Get-DshHome { (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).dshHome }
function Get-SnapNames { @(Get-ChildItem -LiteralPath $snapRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) }
function Run-Pwsh([string[]]$argv) {
  $out  = & pwsh -NoProfile @argv 2>&1 | Out-String
  [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}
function Test-VerifyNow([string]$label) {
  $r = Run-Pwsh @('-File', $verP)
  Say ("--- verify ({0}) ---" -f $label)
  Say $r.Out.TrimEnd()
  Say '--- end ---'
  $sum = ($r.Out -split "`n" | Where-Object { $_ -match 'SUMMARY' } | Select-Object -Last 1)
  if ($r.Code -eq 0) { Pass ("verify({0}) exit = 0" -f $label) } else { Fail ("verify({0}) exit = {1}" -f $label, $r.Code) }
  if ($sum -match '0 FAIL') { Pass ("verify({0}) {1}" -f $label, $sum.Trim()) }
  elseif ($sum) { Fail ("verify({0}) {1}" -f $label, $sum.Trim()) }
  else { Fail ("verify({0}) 未打印 SUMMARY（可能中途崩溃）" -f $label) }
}

# ---------- 0. 前置检查 + 备份 ----------
Step '0. preflight'
foreach ($f in @($gate, $snapP, $restP, $verP)) {
  if (Test-Path -LiteralPath $f) { Pass ("script present: {0}" -f (Split-Path $f -Leaf)) }
  else { Fail ("script missing: {0}" -f $f) }
}
if ($script:fail -gt 0) { throw 'preflight failed, aborting' }

New-Item -ItemType Directory -Path (Split-Path -Parent $bakFile) -Force | Out-Null
Copy-Item -LiteralPath $ManifestPath -Destination $bakFile -Force
$origHome = Get-DshHome
Say ("manifest backup -> {0}" -f $bakFile)
if ($origHome -ne $GoodHome) { Warn ("当前 dshHome = {0}（非 {1}），将先归位" -f $origHome, $GoodHome); Set-DshHome $GoodHome }
Pass ("dshHome baseline = {0}" -f (Get-DshHome))

$snapsBefore = Get-SnapNames
Say ("snapshots before: {0} 个 -> {1}" -f $snapsBefore.Count, ($snapsBefore -join ', '))

# 清理「没有 _manifest.csv 且完全为空」的快照目录：这类目录会让 verify 的 B 项
# 按 LastWriteTimeUtc 选中后报 snapshot incomplete（假失败）。只删空目录，绝不碰有内容的。
foreach ($n in $snapsBefore) {
  $d = Join-Path $snapRoot $n
  if (-not (Test-Path -LiteralPath (Join-Path $d '_manifest.csv'))) {
    $cnt = @(Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue).Count
    if ($cnt -eq 0) { Remove-Item -LiteralPath $d -Force; Warn ("已清理空快照残留目录: {0}" -f $n) }
    else { Warn ("不完整快照（缺 _manifest.csv 且有内容，未动）: {0} / {1} 项" -f $n, $cnt) }
  }
}
$snapsBefore = Get-SnapNames

try {
  # ================= ③ V2 fail-closed 注入测试 =================
  Step '3. V2 fail-closed injection test'

  Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue


  # P0-2：注入目标必须「不存在」。若 <DSH_HOME>-inject-test 真实存在，
  # gate 会正常完成快照并 exit 0 ⇒「fail-closed 通过」是假阳性，测试永久失效。
  if (Test-Path -LiteralPath $BadHome) {
    Fail ("{0} 已存在 ⇒ 注入测试无效（gate 会成功）；先清理该目录或改用 -BadHome" -f $BadHome)
    throw 'injection-home-exists'
  }
  Set-DshHome $BadHome
  Pass ("injected dshHome = {0}" -f (Get-DshHome))

  # gate 的 ApplyCommand 只要被执行就会落 marker；fail-closed 生效时 marker 必须不存在
  $applyCmd = "New-Item -ItemType File -Path '$marker' -Force | Out-Null"
  $r = Run-Pwsh @('-File', $gate, '-ApplyCommand', $applyCmd)
  Say '--- gate output (injected) ---'
  Say $r.Out.TrimEnd()
  Say '--- end ---'

  if ($r.Code -eq 1) { Pass ("gate exit = 1 (fail-closed)") } else { Fail ("gate exit = {0}，期望 1" -f $r.Code) }
  if ($r.Out -match 'DSH_HOME not found') { Pass 'gate 报 DSH_HOME not found' } else { Fail 'gate 未报 DSH_HOME not found' }
  if (Test-Path -LiteralPath $marker) { Fail 'apply 被执行了（marker 存在）→ fail-closed 失效' }
  else { Pass 'apply 未执行（marker 不存在）' }

  $snapsMid = Get-SnapNames
  if ($snapsMid.Count -eq $snapsBefore.Count) { Pass ("失败路径未产生新快照（仍 {0} 个）" -f $snapsMid.Count) }
  else { Warn ("失败路径新增了快照: {0}" -f (($snapsMid | Where-Object { $_ -notin $snapsBefore }) -join ',')) }

  # 还原 manifest，并确认指纹回到原值 → gate 应走 SKIP 幂等分支
  Set-DshHome $GoodHome
  Pass ("restored dshHome = {0}" -f (Get-DshHome))

  $r2 = Run-Pwsh @('-File', $gate)
  Say '--- gate output (restored) ---'
  Say $r2.Out.TrimEnd()
  Say '--- end ---'
  if ($r2.Code -eq 0) { Pass 'gate exit = 0 (restored)' } else { Fail ("gate exit = {0}，期望 0" -f $r2.Code) }
  if ($r2.Out -match 'SKIP') { Pass 'gate 命中 SKIP 幂等分支' } else { Warn 'gate 未打印 SKIP（指纹可能因快照而变，需看输出）' }
  if (Test-Path -LiteralPath $marker) { Fail 'marker 意外存在' } else { Pass 'marker 仍不存在' }
  Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

  # ================= ④ V4 恢复演练 =================
  if ($SkipRestore) {
    Warn '-SkipRestore：跳过 ④ 恢复演练'
  } else {
    Step '4. V4 restore drill'

    $safetyTag = "pre-restore-drill-$ts"
    $r3 = Run-Pwsh @('-File', $snapP, '-Tag', $safetyTag)
    Say $r3.Out.TrimEnd()
    if ($r3.Code -eq 0) { Pass ("安全快照已建: {0}" -f $safetyTag) } else { Fail ("安全快照失败 exit={0}" -f $r3.Code) }

    if ($script:fail -eq 0) {
      # 先 dry diff（不加 -Force，exit 2 = 有差异未写入）
      $r4 = Run-Pwsh @('-File', $restP, '-Tag', $BaselineTag)
      Say '--- restore dry-diff ---'
      Say $r4.Out.TrimEnd()
      Say '--- end ---'
      if ($r4.Code -in 0, 2) { Pass ("restore dry-diff exit = {0}（0=一致 / 2=有差异未写）" -f $r4.Code) }
      else { Fail ("restore dry-diff exit = {0}" -f $r4.Code) }

      # 真恢复
      $r5 = Run-Pwsh @('-File', $restP, '-Tag', $BaselineTag, '-Force')
      Say '--- restore -Force ---'
      Say $r5.Out.TrimEnd()
      Say '--- end ---'
      if ($r5.Code -eq 0) { Pass 'restore -Force exit = 0' } else { Fail ("restore -Force exit = {0}" -f $r5.Code) }
      if ($r5.Out -match 'RELOCKED|restored') { Pass 'restore 输出含 restored/RELOCKED' } else { Warn 'restore 输出未见 restored/RELOCKED' }

      # 复元快照：让 verify 的「最新快照」与恢复后的源一致
      $afterTag = "after-restore-drill-$ts"
      $r6 = Run-Pwsh @('-File', $snapP, '-Tag', $afterTag)
      Say $r6.Out.TrimEnd()
      if ($r6.Code -eq 0) { Pass ("复元快照已建: {0}" -f $afterTag) } else { Fail ("复元快照失败 exit={0}" -f $r6.Code) }
      Say ("回退用：pwsh -NoProfile -File {0} -Tag {1} -Force" -f $restP, $safetyTag)
    }
  }

  # ================= ⑤ V5 恢复后 verify 复跑 =================
  Step '5. V5 verify after restore'
  Test-VerifyNow 'after-restore'

  # ================= ⑥ 回滚前滚：把演练改回原状 =================
  # ④ 的 restore baseline 会把 profiles/web/cordis.patch.yml 真的退回 baseline 版本（用户真实配置）。
  # 默认在 ⑤ 通过后立刻用 pre-restore-drill 安全快照把配置前滚回演练前状态，让系统回到原样。
  # 若上一次演练已把配置退回 baseline，用 -RollForwardFrom <旧安全快照 tag> 指定唯一的原状副本。
  $srcTag = if ($RollForwardFrom) { $RollForwardFrom }
            elseif ($SkipRestore -or $KeepBaseline) { '' }
            elseif ($safetyTag) { $safetyTag }
            else { '' }
  if ($srcTag) {
    Step ("6. roll-forward to pre-drill state (from {0})" -f $srcTag)
    $r8 = Run-Pwsh @('-File', $restP, '-Tag', $srcTag, '-Force')
    Say '--- restore roll-forward ---'
    Say $r8.Out.TrimEnd()
    Say '--- end ---'
    if ($r8.Code -eq 0) { Pass ("前滚 exit = 0（from {0}）" -f $srcTag) } else { Fail ("前滚 exit = {0}（from {1}）" -f $r8.Code, $srcTag) }

    $rfTag = "after-rollforward-$ts"
    $r9 = Run-Pwsh @('-File', $snapP, '-Tag', $rfTag)
    Say $r9.Out.TrimEnd()
    if ($r9.Code -eq 0) { Pass ("前滚后快照已建: {0}" -f $rfTag) } else { Fail ("前滚后快照失败 exit={0}" -f $r9.Code) }

    Test-VerifyNow 'after-rollforward'
  } elseif ($KeepBaseline) {
    Warn '-KeepBaseline：保留 baseline 版本，不做前滚（用户配置仍是 baseline）'
  }
}
catch {
  Fail ("未预期异常: {0}" -f $_.Exception.Message)
  Say ($_.ScriptStackTrace) Red
}
finally {
  # ---------- 自愈：无论如何都把 dshHome 归位 ----------
  try {
    $cur = Get-DshHome
    if ($cur -ne $GoodHome) {
      Set-DshHome $GoodHome
      Write-Host ("[self-heal] repaired dshHome: {0} -> {1}" -f $cur, $GoodHome) -ForegroundColor DarkGray
    }
    if ((Get-DshHome) -ne $GoodHome) { throw ("自愈后 dshHome 仍为 {0}，期望 {1}" -f (Get-DshHome), $GoodHome) }
    Write-Host ("[self-heal] dshHome = {0}" -f $GoodHome) -ForegroundColor DarkGray
  } catch {
    Write-Host ("[self-heal] FAILED: {0}；请手工改回 {1}（备份 {2}）" -f $_.Exception.Message, $GoodHome, $bakFile) -ForegroundColor Red
    $script:fail++
  }
  Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

  # ③ 注入演练会触发 gate 写入 pending-post 标记；演练前没有、现在有 = 演练残留，收尾时清掉
  # （marker 只能在这里删：③ 正文里删会早于 gate 写标记，等于没删）
  if ((-not $pendingPostBefore) -and (Test-Path -LiteralPath $pendingPost)) {
    Remove-Item -LiteralPath $pendingPost -Force -ErrorAction SilentlyContinue
    Write-Host '[self-heal] removed pending-post marker left by drill' -ForegroundColor DarkGray
  }

  $logPath = Join-Path $Vault ("state\acceptance-r2-$ts.log")
  $logText = ($log -join [Environment]::NewLine) + [Environment]::NewLine + ("SUMMARY: {0} FAIL" -f $script:fail)
  Set-Content -LiteralPath $logPath -Value $logText -Encoding UTF8
  Write-Host ''
  Write-Host ("=== SUMMARY: {0} FAIL ===" -f $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
  Write-Host ("log -> {0}" -f $logPath) -ForegroundColor DarkGray
}

exit $(if ($script:fail -eq 0) { 0 } else { 1 })
