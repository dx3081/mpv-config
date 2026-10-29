# mpv-config 现状页

目标：把 mpv 调成“QuickTime 式逐帧播放器”，和 Fast Viewer 一样快、按键一致，换电脑直接用。
仓库：https://github.com/dx3081/mpv-config　　装在：`C:\app\mpv\portable_config`
更新：2026-10-28（温哥华时间）

## 这一版做了什么
- 旧配置整份备份在 `C:\app\mpv\portable_config.bak-2026-10-28`（还有一份一模一样的 `portable_config.bak-2026-10-28-2233`，是安装脚本第二次跑时自动备的，可删）。
- `mpv.conf`：速度优先。砍掉 interpolation（插帧）、deband 4 次迭代、ewa_lanczossharp、error-diffusion（这项在 0.41 本来就报错）、hdr-compute-peak、display-resample；改 `profile=fast`、硬解 `hwdec=d3d11va` 直出、`hr-seek=yes`（拖到哪帧就是哪帧）；不加载用不到的内置脚本（ytdl、auto_profiles、select、positioning、commands）；比屏幕大的视频自动缩进屏幕。
- `input.conf`：左右方向键改成逐帧；原来的 5 秒跳转挪到 Shift+方向键；其余沿用旧配置（见下表）。
- 界面：uosc 5.13.0（底部进度条 + 悬停出现的控制条：上一帧 / 播放暂停 / 下一帧 / 倍速 / 全屏）+ thumbfast（进度条悬停缩略图）。改动的选项都写在 `script-opts\uosc.conf` 和 `script-opts\thumbfast.conf` 第一行。
- `install.ps1`：一键装到任意 mpv 的 portable_config，先备份旧的，再预热一次着色器缓存。

## 实测数字（台式机 i7-11700F / RX 9070 XT / Win10，2560x1364 h264 mp4，热启动，各跑 8 次）
| | 旧配置 | 新配置（含 uosc + thumbfast） |
|---|---|---|
| mpv 内部：启动到画出第一帧 | 560–610 ms | 300–530 ms，一般 400 ms 左右 |
| 加 mpv.exe 本身加载 | +约 100 ms | +约 100 ms |
| 双击到出画面（估算） | 约 0.7 秒 | 约 0.4–0.6 秒 |
| 逐帧（每帧） | — | 2–3 ms |
| 精确跳转（每次） | — | 约 8 ms，拖进度条画面实时跟 |
| 暂停闲置 CPU（两个 mpv 进程） | — | 0.0% |
| 播放时 CPU（硬解，整机） | — | 约 1% |
| 内存 | — | 主进程约 250 MB + 缩略图进程约 77 MB |

- **“0.3 秒出画面”没达到**，卡在三样驱动开销上：D3D11 建设备 80–180 ms（每次都不一样，AMD 驱动的事）、声卡 WASAPI 初始化约 75 ms、硬解初始化约 45 ms。这三样加起来就 200–300 ms，mpv 配置层面到头了，再往下得改 mpv 本身或换播放器内核。
- 试过没用、已去掉：`gpu-api=vulkan`（慢一倍）、`vo=gpu` 老渲染器（没差）、`force-window=immediate`（更慢）、`hwdec=d3d11va-copy`（慢 80 ms）、软解（慢 100 ms）、`d3d11-flip=no`（没差）、`ao=openal`（退出慢 1 秒多）、thumbfast `spawn_first=yes`（不拖慢，所以留着：打开文件就预启动缩略图进程，第一次悬停不用等）。
- 改配置后的第一次启动会慢（约 600 ms，编译着色器并缓存到 `portable_config\cache`），之后恢复。`install.ps1` 装完会自动预热一次。

## 按键表
| 按键 | 作用 |
|---|---|
| 右键 / Esc / q / 小键盘 - | 关闭（鼠标停在进度条上右键也能关，已测） |
| 左键单击 | 播放 / 暂停（点在进度条上 = 跳转） |
| 左键双击 / f | 全屏（已测） |
| ← → | 上一帧 / 下一帧（自动暂停，长按连发） |
| Shift+← → | 后退 / 快进 5 秒（原来 ← → 的功能） |
| Ctrl+← → 、小键盘 1 / 3 | 精退 / 精进 1 秒 |
| 滚轮上 / 下 | 上一帧 / 下一帧（鼠标在进度条上时 = 按 1 秒跳） |
| 小键盘 4 / 6 | 上一帧 / 下一帧 |
| 空格 / 小键盘 + / 小键盘 5 | 播放 / 暂停。暂停时进度条常亮，播放时自动隐藏（= 旧的分析 / 纯净模式，不用再单独切） |
| 鼠标中键 | 开 / 关底部那条常显细进度线 |
| 小键盘 7 / 9 / 8 | 减速 / 加速 / 回到 1 倍 |
| ↑ ↓ | 音量 |
| 回车 | 窗口最大化 |
| 鼠标侧键 | 后退 / 快进 5 秒 |
| i | 视频统计 |
| Ctrl+s | 截图到桌面 |
| m | uosc 菜单（音轨 / 字幕 / 章节） |

## 换电脑怎么装（MSI 笔记本）
1. 装便携版 mpv（和台式机一样的 mpv-winbuild 包，解压到比如 `C:\app\mpv`）。
2. 下载本仓库（GitHub 页面 Code → Download ZIP，解压），在解压目录里开 PowerShell：
   ```
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Target C:\app\mpv\portable_config
   ```
   mpv 装在别处就改 `-Target`。
3. 不需要装任何编译工具。uosc 和 thumbfast 都已经打包在仓库里，不用再下。

## 文件关联（Windows 要你自己点）
- .mp4 已经关联到 mpv。.mkv / .mov / .avi / .webm / .m4v / .ts 没有。
- 最省事：随便找一个 .mkv 文件 → 右键 → 打开方式 → 选择其他应用 → 勾“始终使用此应用” → 选 `C:\app\mpv\mpv.exe`。每种后缀做一次。
- 一次全关联：`C:\app\mpv\installer\mpv-install.bat` 右键“以管理员身份运行”，它会把所有常见视频格式注册给这个 mpv（装完后在“设置 → 应用 → 默认应用”里把视频播放器选 mpv）。

## 没验证 / 还悬着
- GitHub 仓库 `dx3081/mpv-config` 还没建成：用 API 建被这台电脑上 Claude 的权限拦了（公开、私有都拦）。要你在网页 https://github.com/new 建一个名叫 `mpv-config` 的空仓库（公开，别勾 README），建好说一声就推。
- 笔记本（RTX 3060 / Win11）上没跑过，数字待测；NVIDIA 的 D3D11 建设备时间可能和 AMD 不同。
- 冷启动（开机后第一次打开）没单独量，受硬盘缓存影响大。
- 4K / HEVC / 10bit 视频没测（硬解支持，但逐帧倒退在 HEVC 长 GOP 上会比 h264 慢）。
