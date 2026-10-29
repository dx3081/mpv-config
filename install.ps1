<#
.SYNOPSIS
  把这个仓库的 mpv 配置装到某个 mpv 的 portable_config 里。

.DESCRIPTION
  默认：把 mpv.conf / input.conf / scripts / script-opts / fonts 复制到 C:\app\mpv\portable_config。
  已有的 portable_config 会先整个备份成 portable_config.bak-日期-时间（除非 -NoBackup）。

  用法（在仓库目录里，右键“用 PowerShell 运行”或在终端执行）：
    .\install.ps1                                   # 装到 C:\app\mpv\portable_config
    .\install.ps1 -Target D:\tools\mpv\portable_config   # 笔记本上 mpv 在别的地方
    .\install.ps1 -Link                             # 不复制，把 portable_config 做成指向本仓库的链接（git pull 就生效）

  第一次运行如果被拦（“禁止运行脚本”）：
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
param(
  [string]$Target = "C:\app\mpv\portable_config",
  [switch]$Link,
  [switch]$NoBackup
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$MpvDir = Split-Path -Parent $Target
$MpvExe = Join-Path $MpvDir "mpv.exe"

if (-not (Test-Path $MpvExe)) {
  Write-Warning "没在 $MpvDir 里找到 mpv.exe。Target 应该是 mpv.exe 旁边的 portable_config 目录。继续安装，但请确认路径。"
}

# 1. 备份
if ((Test-Path $Target) -and -not $NoBackup) {
  $stamp = Get-Date -Format "yyyy-MM-dd-HHmm"
  $bak = "$Target.bak-$stamp"
  $item = Get-Item $Target
  if ($item.LinkType) {
    Write-Host "已有的 $Target 是链接（指向 $($item.Target)），直接移除，不备份内容。"
    (Get-Item $Target).Delete()
  } else {
    Write-Host "备份旧配置 -> $bak"
    Move-Item $Target $bak
  }
}

# 2. 安装
if ($Link) {
  if (Test-Path $Target) { throw "$Target 还在，先手动移走。" }
  New-Item -ItemType Junction -Path $Target -Target $Repo | Out-Null
  Write-Host "已把 $Target 链接到 $Repo（以后在仓库里 git pull 就生效）。"
} else {
  New-Item -ItemType Directory -Force -Path $Target | Out-Null
  foreach ($f in @("mpv.conf", "input.conf")) {
    Copy-Item (Join-Path $Repo $f) (Join-Path $Target $f) -Force
  }
  foreach ($d in @("scripts", "script-opts", "fonts")) {
    $src = Join-Path $Repo $d
    if (Test-Path $src) {
      $dst = Join-Path $Target $d
      if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
      Copy-Item $src $dst -Recurse -Force
    }
  }
  # 旧备份里的着色器缓存拿回来，省第一次启动的编译时间
  if ($bak -and (Test-Path (Join-Path $bak "cache"))) {
    Copy-Item (Join-Path $bak "cache") (Join-Path $Target "cache") -Recurse -Force
  }
  Write-Host "已复制到 $Target"
}

# 3. 预热一次着色器缓存（无窗口、不出声），让第一次真正打开视频也快
if (Test-Path $MpvExe) {
  Write-Host "预热着色器缓存..."
  & $MpvExe --config-dir="$Target" --force-window=immediate --idle=once --frames=0 --ao=null --really-quiet "av://lavfi:color=c=black:s=1280x720:d=0.1" 2>$null
}

Write-Host ""
Write-Host "装好了。把视频格式关联到 mpv 的方法见 CURRENT.md 的“文件关联”一节。"
