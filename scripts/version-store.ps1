# 版本仓库（多版本存储）—— 为 dsh 的每个版本各存一份，供 switch-version.ps1 切换
#
# 设计要点
#   * 版本标识来源：dsh 安装目录 package.json 的 version 字段（唯一权威，不读 npm 缓存/registry）
#   * 存储位置：<vault>\versions\<version>\
#   * 两种模式：meta（默认，只存核心文件哈希清单，~1 MB，用于审计比对）
#               full（存 payload.zip，含 node_modules，可切换；实测本机 dsh 约 693 MB）
#   * 去重：payload.zip 的 sha256 相同则复用已有条目（shared-with 记录）
#   * 完整性：meta.json 记录 sha256（payload）与 coreManifestSha（核心清单哈希）
#
# 用法
#   version-store.ps1 -Action List
#   version-store.ps1 -Action Show   -Version 0.2.1-rc.5
#   version-store.ps1 -Action Save   -Mode meta
#   version-store.ps1 -Action Save   -Mode full
#   version-store.ps1 -Action Save   -Source D:\some\other\dsh -Mode full
#   version-store.ps1 -Action Verify            # 校验全部（或 -Version 单个）
#   version-store.ps1 -Action Prune  -Keep 5
# 退出码：0 = OK；1 = 失败/校验不通过；2 = 参数或前提不满足

#requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('List','Show','Save','Verify','Prune','Path')]
  [string]$Action = 'List',
  [string]$Version,
  [string]$Source,
  [ValidateSet('meta','full')]
  [string]$Mode = 'meta',
  [int]$Keep = 5,
  [string]$Vault = '',
  [string]$ManifestPath = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Vault)) { $Vault = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $Vault 'config-manifest.json' }

$versionsRoot = Join-Path $Vault 'versions'

function Write-Info($m) { Write-Host $m }
function Write-Ok($m)   { Write-Host "PASS $m" -ForegroundColor Green }
function Write-Bad($m)  { Write-Host "FAIL $m" -ForegroundColor Red }

# ---- 解析 dsh 安装目录 ----
function Resolve-DshInstall([string]$Hint) {
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($Hint)) { $candidates += $Hint }
  $npmRoot = $null
  try { $npmRoot = (& npm root -g 2>$null | Select-Object -First 1) } catch { $npmRoot = $null }
  if ($npmRoot) { $candidates += (Join-Path $npmRoot '@deepseek-ai\dsh') }
  $candidates += (Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh')
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c 'package.json'))) { return (Resolve-Path -LiteralPath $c).Path }
  }
  return $null
}

function Get-InstalledVersion([string]$InstallDir) {
  $pkg = Join-Path $InstallDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkg)) { return $null }
  (Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json).version
}

# 核心清单：dsh 自身的代码与清单（排除 node_modules），用于轻量审计与跨版本比对
function Get-CoreManifest([string]$InstallDir) {
  # 注意：dsh 安装目录本身位于 npm 的 node_modules 之下，因此 node_modules 过滤
  # 必须基于「相对安装目录的路径」，不能基于 FullName。
  $entries = @()
  foreach ($f in Get-ChildItem -LiteralPath $InstallDir -File -Force) {
    $entries += [pscustomobject]@{ Path = $f.FullName; Length = [long]$f.Length }
  }
  foreach ($d in Get-ChildItem -LiteralPath $InstallDir -Directory -Force) {
    if ($d.Name -eq 'node_modules') { continue }
    foreach ($f in Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force) {
      $relTry = ([IO.Path]::GetRelativePath($InstallDir, $f.FullName)) -replace '\\', '/'
      if ($relTry -like '*node_modules/*') { continue }
      $entries += [pscustomobject]@{ Path = $f.FullName; Length = [long]$f.Length }
    }
  }
  $rows = @()
  foreach ($e in $entries) {
    $rel = ([IO.Path]::GetRelativePath($InstallDir, $e.Path)) -replace '\\', '/'
    $rows += [pscustomobject]@{
      rel    = $rel
      sha256 = (Get-FileHash -LiteralPath $e.Path -Algorithm SHA256).Hash.ToLower()
      size   = [long]$e.Length
    }
  }
  $rows = @($rows | Sort-Object rel)
  $total = [long]0
  foreach ($r in $rows) { $total += [long]$r.size }
  $sb = [System.Text.StringBuilder]::new()
  foreach ($r in $rows) { [void]$sb.AppendLine("$($r.rel)  $($r.sha256)  $($r.size)") }
  $text = $sb.ToString()
  $sha = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
  ).Replace('-', '').ToLower()
  [pscustomobject]@{ Text = $text; Sha = $sha; Count = $rows.Count; Bytes = $total }
}

function Get-Meta($ver) { Join-Path $versionsRoot "$ver\meta.json" }
function Resolve-Bsdtar {
  # 只认 Windows 自带的 bsdtar：PATH 里排在前面的一般是 Git 的 GNU tar，它不支持 --format zip
  $candidates = @()
  if ($env:SystemRoot) { $candidates += (Join-Path $env:SystemRoot 'System32\tar.exe') }
  $cmd = Get-Command tar.exe -ErrorAction SilentlyContinue
  if ($cmd) { $candidates += $cmd.Source }
  foreach ($c in $candidates) {
    if (-not (Test-Path -LiteralPath $c)) { continue }
    $ver = (& $c --version 2>&1 | Out-String)
    if ($ver -match 'bsdtar') { return $c }
  }
  return $null
}

function New-PayloadZip([string]$SourceDir, [string]$Destination) {
  # 优先 bsdtar：690 MB / 6 万文件级别下比 Compress-Archive 快一到两个数量级
  # （Compress-Archive 在该量级实测 10 分钟零增长，等同卡死）
  $tar = Resolve-Bsdtar
  if ($tar) {
    & $tar -c --format zip -f $Destination -C $SourceDir .
    if ($LASTEXITCODE -ne 0) { throw "tar.exe 压缩失败（exit $LASTEXITCODE）" }
    return
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory(
    $SourceDir, $Destination, [System.IO.Compression.CompressionLevel]::Optimal, $false)
}

function Get-Payload($ver) { Join-Path $versionsRoot "$ver\payload.zip" }

function Save-Version([string]$InstallDir, [string]$Ver, [string]$M) {
  $dir = Join-Path $versionsRoot $Ver
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $core = Get-CoreManifest $InstallDir
  $cmPath = Join-Path $dir 'core-manifest.txt'
  Set-Content -LiteralPath $cmPath -Value $core.Text -Encoding utf8NoBOM
  # 清单指纹取「落盘文件字节」的 SHA256，避免文本换行/编码差异导致自校验失败
  $coreManifestSha = (Get-FileHash -LiteralPath $cmPath -Algorithm SHA256).Hash.ToLower()

  $payloadSha = $null; $payloadBytes = 0; $sharedWith = $null
  if ($M -eq 'full') {
    $zip = Get-Payload $Ver
    if ((Test-Path -LiteralPath $zip) -and -not $Force) {
      Write-Info "INFO payload 已存在，跳过压缩（-Force 覆盖）: $zip"
      $payloadSha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
      $payloadBytes = (Get-Item -LiteralPath $zip).Length
    } else {
      $tmp = "$zip.tmp"
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
      Write-Info "INFO 正在压缩 $InstallDir（含 node_modules，较慢）…"
      New-PayloadZip -SourceDir $InstallDir -Destination $tmp
      Move-Item -LiteralPath $tmp -Destination $zip -Force
      $payloadSha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
      $payloadBytes = (Get-Item -LiteralPath $zip).Length
    }
    # 去重：同 sha 的另一条记录 → 记 shared-with（不删 zip，保证单条可独立恢复）
    foreach ($other in Get-ChildItem -LiteralPath $versionsRoot -Directory) {
      if ($other.Name -eq $Ver) { continue }
      $om = Join-Path $other.FullName 'meta.json'
      if (-not (Test-Path -LiteralPath $om)) { continue }
      $o = Get-Content -LiteralPath $om -Raw | ConvertFrom-Json
      if ($o.payloadSha256 -eq $payloadSha) { $sharedWith = $other.Name; break }
    }
  }

  $meta = [ordered]@{
    version          = $Ver
    package          = '@deepseek-ai/dsh'
    mode             = $M
    capturedAt       = (Get-Date).ToString('o')
    source           = $InstallDir
    coreFiles        = $core.Count
    coreBytes        = $core.Bytes
    coreManifestSha  = $coreManifestSha
    payloadSha256    = $payloadSha
    payloadBytes     = $payloadBytes
    sharedWith       = $sharedWith
    switchCapable    = ($M -eq 'full')
  }
  $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-Meta $Ver) -Encoding utf8NoBOM
  Write-Ok "saved version $Ver (mode=$M core=$($core.Count) files, payload=$([math]::Round($payloadBytes/1MB,1)) MB)"
}

switch ($Action) {
  'Path' {
    $d = Resolve-DshInstall $Source
    if (-not $d) { Write-Bad 'dsh install not found'; exit 2 }
    Write-Output $d
  }
  'List' {
    if (-not (Test-Path -LiteralPath $versionsRoot)) { Write-Info 'INFO 版本库为空（尚未 Save）'; exit 0 }
    $rows = @()
    foreach ($d in Get-ChildItem -LiteralPath $versionsRoot -Directory | Sort-Object Name) {
      $m = Join-Path $d.FullName 'meta.json'
      if (-not (Test-Path -LiteralPath $m)) { continue }
      $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
      $rows += [pscustomobject]@{
        version = $o.version; mode = $o.mode; capturedAt = $o.capturedAt
        coreFiles = $o.coreFiles; payloadMB = [math]::Round(($o.payloadBytes / 1MB), 1)
        switchCapable = $o.switchCapable; sharedWith = $o.sharedWith
      }
    }
    if ($rows.Count -eq 0) { Write-Info 'INFO 版本库为空'; exit 0 }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Ok ("{0} 个版本记录（{1}）" -f $rows.Count, $versionsRoot)
  }
  'Show' {
    if (-not $Version) { Write-Bad '需要 -Version'; exit 2 }
    $m = Get-Meta $Version
    if (-not (Test-Path -LiteralPath $m)) { Write-Bad "未找到版本记录: $Version"; exit 1 }
    Get-Content -LiteralPath $m -Raw | Write-Host
  }
  'Save' {
    $d = Resolve-DshInstall $Source
    if (-not $d) { Write-Bad '未找到 dsh 安装目录（可用 -Source 指定）'; exit 2 }
    $ver = Get-InstalledVersion $d
    if (-not $ver) { Write-Bad "无法读取版本号: $d\package.json"; exit 1 }
    Save-Version $d $ver $Mode
  }
  'Verify' {
    $targets = @()
    if ($Version) { $targets = @($Version) }
    else {
      if (-not (Test-Path -LiteralPath $versionsRoot)) { Write-Info 'INFO 版本库为空'; exit 0 }
      $targets = @(Get-ChildItem -LiteralPath $versionsRoot -Directory | ForEach-Object { $_.Name })
    }
    $bad = 0
    foreach ($v in $targets) {
      $m = Get-Meta $v
      if (-not (Test-Path -LiteralPath $m)) { Write-Bad "$v : meta.json 缺失"; $bad++; continue }
      $o = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json
      $cm = Join-Path $versionsRoot "$v\core-manifest.txt"
      if (-not (Test-Path -LiteralPath $cm)) { Write-Bad "$v : core-manifest.txt 缺失"; $bad++; continue }
      $sha = (Get-FileHash -LiteralPath $cm -Algorithm SHA256).Hash.ToLower()
      if ($sha -ne $o.coreManifestSha) { Write-Bad "$v : core manifest 校验失败"; $bad++; continue }
      if ($o.mode -eq 'full') {
        $zip = Get-Payload $v
        if (-not (Test-Path -LiteralPath $zip)) { Write-Bad "$v : payload.zip 缺失"; $bad++; continue }
        $zs = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($zs -ne $o.payloadSha256) { Write-Bad "$v : payload 校验失败"; $bad++; continue }
      }
      Write-Ok "$v : 完整性 OK (mode=$($o.mode))"
    }
    if ($bad -gt 0) { Write-Bad "校验失败 $bad 项"; exit 1 }
    Write-Ok '全部版本记录完整性 OK'
  }
  'Prune' {
    if (-not (Test-Path -LiteralPath $versionsRoot)) { Write-Info 'INFO 版本库为空'; exit 0 }
    $all = @(Get-ChildItem -LiteralPath $versionsRoot -Directory | Sort-Object LastWriteTime -Descending)
    if ($all.Count -le $Keep) { Write-Info "INFO 仅 $($all.Count) 个版本，未超过 -Keep $Keep"; exit 0 }
    $drop = $all | Select-Object -Skip $Keep
    foreach ($d in $drop) {
      if (-not $Force) { Write-Info "DRYRUN would delete: $($d.Name)（加 -Force 执行）"; continue }
      Remove-Item -LiteralPath $d.FullName -Recurse -Force
      Write-Ok "deleted $($d.Name)"
    }
  }
}
exit 0
