# desktop-pet 桌面悬浮窗（WPF 透明置顶窗，类 Codex 桌宠）
# 由 index.mjs（opencode 插件）拉起：powershell -STA -File pet-window.ps1 -ExtDir <dir> -StateUrl <url>
# 也可直接双击/手动运行（不带参数）：ExtDir 默认脚本所在目录，StateUrl 为空则独立模式——
# 独立模式同样联动会话状态：检测 opencode 是否运行，并读取 opencode.db-wal 的近期写入判断 working/idle
param(
    [string]$ExtDir = $PSScriptRoot,
    [string]$StateUrl = "",
    [string]$DataDir = ""
)

if (-not $DataDir) {
    $appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $env:USERPROFILE "AppData\Roaming" }
    $DataDir = Join-Path $appData "opencode-desktop-pet"
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# 找到 opencode 桌面窗口并返回对话区附近的屏幕坐标；不依赖固定进程名。
if (-not ("PetTargetWindow" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class PetTargetWindow
{
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    public static int[] FindComposePoint()
    {
        IntPtr best = IntPtr.Zero;
        long bestArea = 0;
        EnumProc callback = delegate(IntPtr hWnd, IntPtr unused)
        {
            if (!IsWindowVisible(hWnd) || IsIconic(hWnd)) return true;
            var title = new StringBuilder(1024);
            GetWindowTextW(hWnd, title, title.Capacity);
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            string process = "";
            try { using (var p = Process.GetProcessById((int)pid)) process = p.ProcessName.ToLowerInvariant(); }
            catch { return true; }
            string caption = title.ToString().ToLowerInvariant();
            bool knownProcess = process == "opencode" || process == "opencode-desktop" || process == "opencode app";
            bool excluded = process == "powershell" || process == "pwsh" || process == "cmd" || process == "windowsterminal" || process == "code" || process == "chrome" || process == "msedge";
            if (!knownProcess && (excluded || !caption.Contains("opencode"))) return true;
            RECT r;
            if (!GetWindowRect(hWnd, out r) || r.Right <= r.Left || r.Bottom <= r.Top) return true;
            long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
            if (area > bestArea) { best = hWnd; bestArea = area; }
            return true;
        };
        EnumWindows(callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        if (best == IntPtr.Zero) return null;
        RECT target;
        if (!GetWindowRect(best, out target)) return null;
        return new int[] { (target.Left + target.Right) / 2, target.Bottom - Math.Min(100, (target.Bottom - target.Top) / 10) };
    }
}
"@
}

# 聊天用 HTTP 桥：POST 在后台线程完成，结果塞进线程安全队列，
# 由 UI 线程的 DispatcherTimer 取出来渲染（避免从线程池回调里直接碰 WPF 控件）
if (-not ("PetChatBridge" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Text;

public static class PetChatBridge
{
    public static void PostJson(string url, string json, ConcurrentQueue<string> queue, int timeoutMs)
    {
        try
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "POST";
            req.ContentType = "application/json; charset=utf-8";
            req.Timeout = timeoutMs;
            req.ReadWriteTimeout = timeoutMs;
            var bytes = Encoding.UTF8.GetBytes(json == null ? "" : json);
            req.ContentLength = bytes.Length;
            req.BeginGetRequestStream(ar =>
            {
                try
                {
                    using (var stream = req.EndGetRequestStream(ar)) { stream.Write(bytes, 0, bytes.Length); }
                    req.BeginGetResponse(ar2 =>
                    {
                        try
                        {
                            using (var resp = req.EndGetResponse(ar2))
                            using (var reader = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                            {
                                queue.Enqueue("BODY:" + reader.ReadToEnd());
                            }
                        }
                        catch (WebException wex)
                        {
                            // 非 2xx 也带着 JSON 正文回来，交给 PowerShell 判断 ok / error
                            try
                            {
                                if (wex.Response != null)
                                {
                                    using (var reader = new StreamReader(wex.Response.GetResponseStream(), Encoding.UTF8))
                                    {
                                        queue.Enqueue("BODY:" + reader.ReadToEnd());
                                        return;
                                    }
                                }
                            }
                            catch { }
                            queue.Enqueue("ERR:" + wex.Message);
                        }
                        catch (Exception ex) { queue.Enqueue("ERR:" + ex.Message); }
                    }, null);
                }
                catch (Exception ex) { queue.Enqueue("ERR:" + ex.Message); }
            }, null);
        }
        catch (Exception ex) { queue.Enqueue("ERR:" + ex.Message); }
    }
}
"@
}

$script:configPath = Join-Path $DataDir "pet.json"
$legacyConfigPath = Join-Path $ExtDir "pet.json"
$legacyPetsPath = Join-Path $ExtDir "pets"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
if (-not (Test-Path $script:configPath) -and (Test-Path $legacyConfigPath)) {
    Copy-Item $legacyConfigPath $script:configPath -ErrorAction SilentlyContinue
}
if (-not (Test-Path (Join-Path $DataDir ".legacy-data-migrated"))) {
    Get-ChildItem $ExtDir -File | Where-Object { $_.Extension -in '.png', '.gif', '.webp' } | ForEach-Object {
        $target = Join-Path $DataDir $_.Name
        if (-not (Test-Path $target)) { Copy-Item $_.FullName $target }
    }
    if (Test-Path $legacyPetsPath) {
        $targetPetsPath = Join-Path $DataDir "pets"
        New-Item -ItemType Directory -Path $targetPetsPath -Force | Out-Null
        Get-ChildItem $legacyPetsPath -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($legacyPetsPath.Length).TrimStart('\\', '/')
            $target = Join-Path $targetPetsPath $relative
            if (-not (Test-Path $target)) {
                $targetDir = Split-Path -Parent $target
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                Copy-Item $_.FullName $target
            }
        }
    }
    Set-Content -Path (Join-Path $DataDir ".legacy-data-migrated") -Value "" -NoNewline
}

function Read-PetConfig {
    try {
        $raw = Get-Content -Raw -Encoding UTF8 $script:configPath
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

$script:cfg = Read-PetConfig
if ($null -eq $script:cfg) { exit 1 }

$script:fw = [int]$script:cfg.frameWidth
$script:fh = [int]$script:cfg.frameHeight
$script:scale = if ($script:cfg.scale) { [double]$script:cfg.scale } else { 4.0 }
$script:fps = if ($script:cfg.fps) { [double]$script:cfg.fps } else { 8 }
$script:spriteW = $script:fw * $script:scale
$script:spriteH = $script:fh * $script:scale
$script:bubbleH = 64
$script:spriteBaseTop = $script:bubbleH

# ---- 轮询间隔（pet.json 的 pollIntervalMs，clamp 100..5000，默认 250） ----
function Get-PollIntervalMs {
    $ms = 250
    try {
        if ($null -ne $script:cfg.pollIntervalMs) { $ms = [int]$script:cfg.pollIntervalMs }
    } catch {}
    if ($ms -lt 100) { $ms = 100 }      # 下限：再快没有意义，只会空转
    if ($ms -gt 5000) { $ms = 5000 }    # 上限：配置写错也不至于把服务打爆
    return $ms
}
$script:pollMs = Get-PollIntervalMs

# 实际生效间隔 = 配置间隔 与「连接中断」退避值 的较大者（断连期间自动降频）
function Update-PollInterval {
    $ms = $script:pollMs
    if (-not $script:pollOk -and $script:backoffMs -gt $ms) { $ms = $script:backoffMs }
    if ($ms -lt 100) { $ms = 100 }
    $pollTimer.Interval = [TimeSpan]::FromMilliseconds($ms)
}

function Load-Bitmap([string]$file) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = New-Object System.Uri($file)
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $bmp.Freeze()
    return $bmp
}

$script:spritePath = Join-Path $DataDir ([string]$script:cfg.sprite)
if (-not (Test-Path $script:spritePath)) { $script:spritePath = Join-Path $ExtDir ([string]$script:cfg.sprite) }
if (-not (Test-Path $script:spritePath)) { exit 1 }
$script:bitmap = Load-Bitmap $script:spritePath

$winW = $script:spriteW + 24
$winH = $script:spriteH + $script:bubbleH + 16
$shadowW = [int]($script:spriteW * 0.6)
$shadowL = [int](12 + $script:spriteW * 0.2)
$shadowT = $script:bubbleH + $script:spriteH - 8
$bubbleW = $winW - 8
$badgeL = $winW - 32

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenCodeDesktopPetWindow"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False"
        Width="$winW" Height="$winH">
  <Canvas x:Name="Root">
    <Border x:Name="Bubble" Canvas.Left="4" Canvas.Top="0" Width="$bubbleW"
            Background="White" CornerRadius="10" Padding="8,5"
            BorderBrush="#33000000" BorderThickness="1" Visibility="Collapsed">
      <TextBlock x:Name="BubbleText" TextWrapping="Wrap" TextAlignment="Center"
                 FontSize="13" Foreground="#1F2328"/>
    </Border>
    <Ellipse x:Name="Shadow" Width="$shadowW" Height="10"
             Canvas.Left="$shadowL" Canvas.Top="$shadowT"
             Fill="Black" Opacity="0.18">
      <Ellipse.Effect><BlurEffect Radius="4"/></Ellipse.Effect>
    </Ellipse>
    <Image x:Name="Sprite" Width="$spriteW" Height="$spriteH"
           Canvas.Left="12" Canvas.Top="$($script:spriteBaseTop)"
           RenderOptions.BitmapScalingMode="NearestNeighbor"
           RenderTransformOrigin="0.5,0.5"/>
    <TextBlock x:Name="Badge" Text="&#x1F6E0;" FontSize="16"
               Canvas.Left="$badgeL" Canvas.Top="$($script:spriteBaseTop + 2)"
               Visibility="Collapsed"/>
  </Canvas>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$sprite = $window.FindName("Sprite")
$shadow = $window.FindName("Shadow")
$bubble = $window.FindName("Bubble")
$bubbleText = $window.FindName("BubbleText")
$badge = $window.FindName("Badge")

# ---- 状态 ----
$script:mode = "idle"          # idle | walk | sleep
$script:dir = 1
$script:frame = 0
$script:hopY = 0.0
$script:hopV = 0.0
$script:overrideAnim = $null
$script:activity = "idle"
$script:workPhase = $null          # working 细分：thinking（思考中）| tool（跑工具）
$script:lastMsg = $null
$script:bubbleUntil = [DateTime]::MinValue
$script:lastInteraction = Get-Date
$script:nextDecision = (Get-Date).AddSeconds(3)
$script:failCount = 0
$script:pollCount = 0
# 「连接中断」保活态：连续失败不再关窗自杀，只降频重试 + 气泡提示一次
$script:pollOk = $true
$script:backoffMs = 250            # 断连退避：250 → 500 → 1000 → 2000 → 5000（封顶）
$script:disconnNotified = $false   # 同一段断连只提示一次
$script:configWriteTime = (Get-Item $script:configPath).LastWriteTime
$script:autoWander = $true
try { $script:autoWander = [bool]$script:cfg.behavior.autoWander } catch {}
$script:lookAtMouse = $false
try { $script:lookAtMouse = [bool]$script:cfg.behavior.lookAtMouse } catch {}
$script:lookAtOpenCode = $false
try { $script:lookAtOpenCode = [bool]$script:cfg.behavior.lookAtOpenCode } catch {}
$script:targetPoint = $null
$script:targetPointAt = [DateTime]::MinValue
$script:dragging = $false          # 拖着桌宠走 → drag 动画
$script:pokeUntil = [DateTime]::MinValue   # 戳一下 → poke 动画（短时）
$script:downPos = New-Object System.Drawing.Point(0, 0)

# ---- 聊天窗（懒创建；关掉后下次再点「聊天…」重新建） ----
$script:chatWin = $null
$script:chatLog = $null
$script:chatInput = $null
$script:chatStatus = $null
$script:chatScroll = $null
$script:chatTimer = $null
$script:chatQueue = $null
$script:chatOpen = $false
$script:chatBusy = $false

# ---- 独立模式联动：检测 opencode 运行 + 读取 opencode.db-wal 活跃度 ----
# 与 index.mjs 的 anySessionActive / ACTIVE_WINDOW_MS 同口径：
# ~/.local/share/opencode/opencode.db-wal 最近 6 秒内有写入即视为「有会话在干活」
$script:opencodeDataDir = Join-Path $env:USERPROFILE ".local\share\opencode"
$script:activeWindowMs = 6000
$script:opencodeProcNames = @("opencode", "OpenCode")

function Test-OpenCodeRunning {
    foreach ($name in $script:opencodeProcNames) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true }
    }
    # 数据目录存在也算 opencode 在本机用过的证据
    return (Test-Path $script:opencodeDataDir)
}

function Test-OpenCodeSessionActive {
    if (-not (Test-Path $script:opencodeDataDir)) { return $false }
    $now = Get-Date
    try {
        $item = Get-Item (Join-Path $script:opencodeDataDir "opencode.db-wal") -ErrorAction Stop
        if (($now - $item.LastWriteTime).TotalMilliseconds -lt $script:activeWindowMs) { return $true }
    } catch {}
    return $false
}

# 独立模式轮询：opencode 未运行 → idle；运行且 db-wal 近期有写入 → working
function Update-StandaloneActivity {
    $sessionActive = (Test-OpenCodeRunning) -and (Test-OpenCodeSessionActive)
    if ($sessionActive) {
        $script:activity = "working"
        $badge.Visibility = "Visible"
        if ($script:mode -eq "sleep") { $script:mode = "idle"; $script:lastInteraction = Get-Date }
        if ($script:mode -eq "walk") { $script:mode = "idle" }
    } else {
        $script:activity = "idle"
        $badge.Visibility = "Collapsed"
    }
}

$wa = [System.Windows.SystemParameters]::WorkArea
$window.Left = $wa.Right - $window.Width - 60
$window.Top = $wa.Bottom - $window.Height - 12

function Get-AnimDef([string]$name) {
    if ($null -eq $script:cfg.animations) { return $null }
    $prop = $script:cfg.animations.PSObject.Properties[$name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# 特殊动画别名：pet.json 里写哪个名字都认（顺序即优先级），和 state.mjs 的 ANIM_ALIASES 一致
$script:animAliases = @{
    thinking = @("thinking", "think", "reasoning")
    tool     = @("work", "typing", "busy")
    drag     = @("drag", "grab", "lift")
    poke     = @("poke", "tap", "hit")
    chat     = @("chat", "talk", "talking")
    look     = @("look", "stare", "watch")
    sleep    = @("sleep", "rest")
    walk     = @("walk")
    review   = @("review", "done", "inspect")
    aborted  = @("aborted", "stop", "cancel", "interrupted")
    error    = @("error", "failed", "crash")
}

function Get-AnimAlias([string]$kind) {
    $names = $script:animAliases[$kind]
    if (-not $names) { return $null }
    foreach ($n in $names) {
        if ($null -ne (Get-AnimDef $n)) { return $n }
    }
    return $null
}

function Resolve-AnimName {
    if ($script:overrideAnim -and (Get-AnimDef $script:overrideAnim)) { return $script:overrideAnim }
    if ($script:dragging) {
        $n = Get-AnimAlias "drag"; if ($n) { return $n }
    }
    if ((Get-Date) -lt $script:pokeUntil) {
        $n = Get-AnimAlias "poke"; if ($n) { return $n }
    }
    if ($script:activity -eq "working") {
        # 思考中（模型在想）和干活（跑工具）分开演；拿不到阶段时按老行为演 work
        if ($script:workPhase -eq "thinking") {
            $n = Get-AnimAlias "thinking"; if ($n) { return $n }
        }
        $n = Get-AnimAlias "tool"; if ($n) { return $n }
    }
    if ($script:chatBusy -or $script:chatOpen) {
        $n = Get-AnimAlias "chat"; if ($n) { return $n }
    }
    if ($script:lookAtMouse -or $script:lookAtOpenCode) {
        $n = Get-AnimAlias "look"; if ($n) { return $n }
    }
    if ($script:mode -eq "sleep") {
        $n = Get-AnimAlias "sleep"; if ($n) { return $n }
    }
    if ($script:mode -eq "walk") {
        $n = Get-AnimAlias "walk"; if ($n) { return $n }
    }
    $d = [string]$script:cfg.defaultAnimation
    if (Get-AnimDef $d) { return $d }
    return "idle"
}

# 光标相对桌宠中心的方向（看着鼠标时用来选行）
function Get-LookTarget {
    if ($script:lookAtOpenCode) {
        try {
            if (((Get-Date) - $script:targetPointAt).TotalMilliseconds -ge 250) {
                $script:targetPoint = [PetTargetWindow]::FindComposePoint()
                $script:targetPointAt = Get-Date
            }
            $point = $script:targetPoint
            if ($point) {
                return @{ dx = $point[0] - ($window.Left + $window.Width / 2.0); dy = $point[1] - ($window.Top + $window.Height / 2.0) }
            }
            return @{ dx = 100.0 * $script:dir; dy = 0.0 }
        } catch {}
    }
    $cur = [System.Windows.Forms.Cursor]::Position
    return @{
        dx = $cur.X - ($window.Left + $window.Width / 2.0)
        dy = $cur.Y - ($window.Top + $window.Height / 2.0)
    }
}

# 配置热更新后重新应用几何（帧尺寸/缩放变化时窗口与元素都要跟着变）
function Update-Geometry {
    $script:fw = [int]$script:cfg.frameWidth
    $script:fh = [int]$script:cfg.frameHeight
    $script:scale = if ($script:cfg.scale) { [double]$script:cfg.scale } else { 4.0 }
    $script:fps = if ($script:cfg.fps) { [double]$script:cfg.fps } else { 8 }
    $script:spriteW = $script:fw * $script:scale
    $script:spriteH = $script:fh * $script:scale
    $winW = $script:spriteW + 24
    $winH = $script:spriteH + $script:bubbleH + 16
    $window.Width = $winW
    $window.Height = $winH
    $sprite.Width = $script:spriteW
    $sprite.Height = $script:spriteH
    $bubble.Width = $winW - 8
    $shadow.Width = [int]($script:spriteW * 0.6)
    [System.Windows.Controls.Canvas]::SetLeft($shadow, 12 + $script:spriteW * 0.2)
    [System.Windows.Controls.Canvas]::SetTop($shadow, $script:bubbleH + $script:spriteH - 8)
    [System.Windows.Controls.Canvas]::SetLeft($badge, $winW - 32)
    $animTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(30, 1000.0 / (Get-TimerFps)))
    $script:frame = 0
    $script:frameAt = $null
}

function Show-Bubble([string]$text, [int]$ms) {
    $bubbleText.Text = $text
    $bubble.Visibility = "Visible"
    $script:bubbleUntil = (Get-Date).AddMilliseconds($ms)
}

function Poke {
    $phrases = $null
    try { $phrases = $script:cfg.speech.phrases } catch {}
    if ($phrases -and $phrases.Count -gt 0) {
        Show-Bubble ([string]($phrases | Get-Random)) 1800
    }
}

# 动画帧率：动画自带 fps 优先，否则用全局 fps
function Get-AnimFps($anim) {
    if ($null -ne $anim -and $null -ne $anim.fps -and [double]$anim.fps -gt 0) { return [double]$anim.fps }
    return $script:fps
}

# 定时器频率取全局与所有动画中的最高值，保证最快的动画不被限速
function Get-TimerFps {
    $max = [double]$script:fps
    try {
        foreach ($p in $script:cfg.animations.PSObject.Properties) {
            if ($null -ne $p.Value.fps -and [double]$p.Value.fps -gt $max) { $max = [double]$p.Value.fps }
        }
    } catch {}
    return $max
}

function Update-SpriteFrame {
    $animName = Resolve-AnimName
    $anim = Get-AnimDef $animName
    $row = 0; $frames = 1
    if ($null -ne $anim) {
        $row = [int]$anim.row
        $frames = [int]$anim.frames
        if ($frames -lt 1) { $frames = 1 }
    }
    # 每个动画可单独设 fps：按该动画自己的帧率推进帧，定时器按所有动画里最高的帧率跑
    if ($animName -ne $script:frameAnim -or $null -eq $script:frameAt) {
        $script:frameAnim = $animName; $script:frameAt = Get-Date; $script:frame = 0
    }
    $animFps = Get-AnimFps $anim
    if (((Get-Date) - $script:frameAt).TotalSeconds -ge (1.0 / $animFps)) {
        $script:frame = ($script:frame + 1) % $frames
        $script:frameAt = Get-Date
    }
    $flip = $script:dir
    if (($script:lookAtMouse -or $script:lookAtOpenCode) -and $animName -eq "look" -and $null -ne $anim) {
        # 看鼠标或 opencode 对话区：按目标方向选行；缺专用方向行时复用 row / 水平镜像
        $t = Get-LookTarget
        if ([Math]::Abs($t.dx) -ge [Math]::Abs($t.dy)) {
            if ($t.dx -lt 0) {
                if ($null -ne $anim.leftRow) { $row = [int]$anim.leftRow; $flip = 1 } else { $flip = -1 }
            } else {
                $row = [int]$anim.row; $flip = 1
            }
        } elseif ($t.dy -lt 0) {
            if ($null -ne $anim.upRow) { $row = [int]$anim.upRow }
            else { $row = [int]$anim.row }
            $flip = 1
        } else {
            if ($null -ne $anim.downRow) { $row = [int]$anim.downRow }
            else { $row = [int]$anim.row }
            $flip = 1
        }
    } elseif ($script:dir -lt 0 -and $null -ne $anim.leftRow) {
        $row = [int]$anim.leftRow   # 贴图自带左行帧（方向已烘焙），无需镜像
        $flip = 1
    }
    $rect = New-Object System.Windows.Int32Rect(($script:frame * $script:fw), ($row * $script:fh), $script:fw, $script:fh)
    $sprite.Source = New-Object System.Windows.Media.Imaging.CroppedBitmap($script:bitmap, $rect)
    # 单帧贴图没有可播放的帧动画；给静态待机姿态轻微呼吸起伏，避免看起来像窗口卡住。
    $breath = 1.0
    if ($frames -le 1 -and $animName -ne "walk") {
        $phase = [DateTime]::Now.TimeOfDay.TotalSeconds * 2.4
        $breath = 0.985 + (0.015 * [Math]::Sin($phase))
    }
    $sprite.RenderTransform = New-Object System.Windows.Media.ScaleTransform($flip, $breath)
}

function Decide {
    $min = 3.0; $max = 8.0
    try {
        $range = $script:cfg.behavior.wanderIntervalSec
        if ($range -and $range.Count -ge 2) { $min = [double]$range[0]; $max = [double]$range[1] }
    } catch {}
    $span = [int](($max - $min) * 10)
    if ($span -lt 1) { $span = 10 }
    $script:nextDecision = (Get-Date).AddSeconds($min + (Get-Random -Minimum 0 -Maximum $span) / 10.0)

    # 看着鼠标：专心盯光标，不走动也不睡
    if ($script:lookAtMouse -or $script:lookAtOpenCode) { $script:mode = "idle"; return }

    if (-not $script:autoWander) { $script:mode = "idle"; return }
    if ($script:activity -eq "working" -and (Get-AnimDef "work")) {
        if ($script:mode -ne "sleep") { $script:mode = "idle" }   # agent 工作中：坐下敲电脑，不乱跑
        return
    }

    $sleepAfter = 45.0
    try { if ($script:cfg.behavior.sleepAfterIdleSec) { $sleepAfter = [double]$script:cfg.behavior.sleepAfterIdleSec } } catch {}
    $idleSec = ((Get-Date) - $script:lastInteraction).TotalSeconds
    if ($sleepAfter -gt 0 -and $idleSec -gt $sleepAfter -and (Get-AnimDef "sleep")) {
        $script:mode = "sleep"
        return
    }
    if ($script:mode -eq "sleep") { return }

    if ((Get-Random -Minimum 0 -Maximum 100) -lt 55 -and (Get-AnimDef "walk")) {
        $script:mode = "walk"
        $script:dir = (Get-Random -Minimum 0 -Maximum 2) * 2 - 1
    } else {
        $script:mode = "idle"
    }
}

# ---- 动画/行为定时器 ----
$script:lastTick = Get-Date
$animTimer = New-Object System.Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(30, 1000.0 / (Get-TimerFps)))
$animTimer.Add_Tick({
    $now = Get-Date
    $dt = ($now - $script:lastTick).TotalSeconds
    $script:lastTick = $now
    if ($dt -gt 0.1) { $dt = 0.1 }

    Update-SpriteFrame

    if (-not $script:overrideAnim -and $now -ge $script:nextDecision) { Decide }

    if ($script:mode -eq "walk") {
        $speed = 40.0
        try { if ($script:cfg.behavior.walkSpeedPxPerSec) { $speed = [double]$script:cfg.behavior.walkSpeedPxPerSec } } catch {}
        $waNow = [System.Windows.SystemParameters]::WorkArea
        $newLeft = $window.Left + $script:dir * $speed * $dt
        if ($newLeft -le $waNow.Left) { $newLeft = $waNow.Left; $script:dir = 1 }
        if ($newLeft -ge ($waNow.Right - $window.Width)) { $newLeft = $waNow.Right - $window.Width; $script:dir = -1 }
        $window.Left = $newLeft
    }

    if ($script:hopV -ne 0 -or $script:hopY -ne 0) {
        $script:hopY -= $script:hopV * $dt
        $script:hopV -= 900.0 * $dt
        if ($script:hopY -ge 0) { $script:hopY = 0; $script:hopV = 0 }
        [System.Windows.Controls.Canvas]::SetTop($sprite, $script:spriteBaseTop + $script:hopY)
        [System.Windows.Controls.Canvas]::SetTop($shadow, $shadowT - $script:hopY * 0.15)
    }

    if ($script:bubbleUntil -ne [DateTime]::MinValue -and $now -gt $script:bubbleUntil) {
        $script:bubbleUntil = [DateTime]::MinValue
        $bubble.Visibility = "Collapsed"
    }
})

# ---- 指令轮询（agent 动作 / 配置热更新 / 保活） ----
$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds($script:pollMs)
$pollTimer.Add_Tick({
    $script:pollCount += 1

    if ($script:pollCount % 4 -eq 1) {
        try {
            $wt = (Get-Item $script:configPath).LastWriteTime
            if ($wt -ne $script:configWriteTime) {
                $script:configWriteTime = $wt
                $newCfg = Read-PetConfig
                if ($null -ne $newCfg) {
                    $geomChanged = ([int]$newCfg.frameWidth -ne $script:fw) -or ([int]$newCfg.frameHeight -ne $script:fh)
                    $newScale = if ($newCfg.scale) { [double]$newCfg.scale } else { 4.0 }
                    if ($newScale -ne $script:scale) { $geomChanged = $true }
                    $newFps = if ($newCfg.fps) { [double]$newCfg.fps } else { 8 }
                    if ($newFps -ne $script:fps) { $geomChanged = $true }
                    $newSprite = Join-Path $DataDir ([string]$newCfg.sprite)
                    if (-not (Test-Path $newSprite)) { $newSprite = Join-Path $ExtDir ([string]$newCfg.sprite) }
                    if ($newSprite -ne $script:spritePath -and (Test-Path $newSprite)) {
                        $script:spritePath = $newSprite
                        $script:bitmap = Load-Bitmap $newSprite
                    }
                    $oldTimerFps = Get-TimerFps
                    $script:cfg = $newCfg
                    if ((Get-TimerFps) -ne $oldTimerFps) { $geomChanged = $true }
                    if ($geomChanged) { Update-Geometry }
                    try { $script:autoWander = [bool]$script:cfg.behavior.autoWander } catch {}
                    try { $script:lookAtMouse = [bool]$script:cfg.behavior.lookAtMouse } catch {}
                    try { $script:lookAtOpenCode = [bool]$script:cfg.behavior.lookAtOpenCode } catch {}
                    # 配置热重载：pollIntervalMs 变化时同步 DispatcherTimer 间隔
                    $newPollMs = Get-PollIntervalMs
                    if ($newPollMs -ne $script:pollMs) {
                        $script:pollMs = $newPollMs
                        Update-PollInterval
                    }
                }
            }
        } catch {}
    }

    if ($StateUrl -eq "") {
        # 独立模式：不连插件服务、进程常驻；约 1 秒一次本地检测 opencode 与会话活跃度，联动 working/idle
        if ($script:pollCount % 4 -eq 2) { Update-StandaloneActivity }
        return
    }
    try {
        $s = Invoke-RestMethod -Uri ($StateUrl + "api/state") -Method Get -TimeoutSec 2
        $script:failCount = 0
        if (-not $script:pollOk) {
            # 服务恢复：回到正常态，退避与「只提示一次」标记一起复位
            $script:pollOk = $true
            $script:backoffMs = 250
            $script:disconnNotified = $false
            Update-PollInterval
        }
        if ($s.animation) { $script:overrideAnim = [string]$s.animation } else { $script:overrideAnim = $null }
        if ($s.message) {
            $msg = [string]$s.message
            if ($msg -ne $script:lastMsg) { $script:lastMsg = $msg; Show-Bubble $msg 4500 }
        } else {
            $script:lastMsg = $null
        }
        if ($s.activity -eq "working") {
            $script:activity = "working"
            $badge.Visibility = "Visible"
            if ($s.workPhase) { $script:workPhase = [string]$s.workPhase } else { $script:workPhase = $null }
            if ($script:mode -eq "sleep") { $script:mode = "idle"; $script:lastInteraction = Get-Date }
            if ($script:mode -eq "walk") { $script:mode = "idle" }
        } else {
            $script:activity = "idle"
            $script:workPhase = $null
            $badge.Visibility = "Collapsed"
        }
        # 看着鼠标：以服务端状态为准（右键菜单 / agent 工具 / 面板都能改）
        if ($null -ne $s.lookAtMouse) { $script:lookAtMouse = [bool]$s.lookAtMouse }
        if ($null -ne $s.lookAtOpenCode) { $script:lookAtOpenCode = [bool]$s.lookAtOpenCode }
    } catch {
        # 连接中断：绝不关窗自杀（原 failCount>=10 的自动退出已删除），进程始终不退，只降频重试
        $script:failCount += 1
        if ($script:pollOk) {
            $script:pollOk = $false
            $script:backoffMs = 250
            if (-not $script:disconnNotified) {
                $script:disconnNotified = $true
                Show-Bubble "连接中断，正在等待桌宠服务恢复……" 4500
            }
        } else {
            # 指数退避：250 → 500 → 1000 → 2000 → 5000（封顶）
            $next = $script:backoffMs * 2
            if ($next -gt 5000) { $next = 5000 }
            $script:backoffMs = $next
        }
        Update-PollInterval
    }
})

# ---- 鼠标交互 ----
$window.Add_MouseLeftButtonDown({
    $script:lastInteraction = Get-Date
    if ($script:mode -eq "sleep") { $script:mode = "idle" }
    $script:downPos = [System.Windows.Forms.Cursor]::Position
    $script:dragging = $true
    try { $window.DragMove() } catch {}
    $script:dragging = $false
})

$window.Add_MouseLeftButtonUp({
    $up = [System.Windows.Forms.Cursor]::Position
    $dist = [Math]::Abs($up.X - $script:downPos.X) + [Math]::Abs($up.Y - $script:downPos.Y)
    if ($dist -lt 6) {
        Poke
        $script:pokeUntil = (Get-Date).AddMilliseconds(1200)   # 戳一下：短时播 poke 动画
    }
    $script:lastInteraction = Get-Date
    $waNow = [System.Windows.SystemParameters]::WorkArea
    if ($window.Left -lt $waNow.Left) { $window.Left = $waNow.Left }
    if ($window.Left -gt ($waNow.Right - $window.Width)) { $window.Left = $waNow.Right - $window.Width }
    if ($window.Top -lt $waNow.Top) { $window.Top = $waNow.Top }
    if ($window.Top -gt ($waNow.Bottom - $window.Height)) { $window.Top = $waNow.Bottom - $window.Height }
})

# ---- 右键菜单 ----
# 设置面板 = 扩展 HTTP 服务上的 pet.html（桌宠库：切换 / 导入 / 保存）
# 扩展拉起本窗时会传 -StateUrl；独立模式则从心跳注册表里找在跑的扩展实例
# 注意：注册表清理只在扩展的 readRegistry 路径上做；独立模式打开设置时往往没有扩展在跑，
# 所以这里必须自己做新鲜度校验（与 extension.mjs 的 REG_STALE_MS 同口径），过期/死进程的心跳文件顺手删除
function Get-PanelUrl {
    if ($StateUrl -ne "") { return $StateUrl }
    $candidate = "http://127.0.0.1:12030/"
    try {
        $s = Invoke-RestMethod -Uri ($candidate + "api/state") -TimeoutSec 1
        if ($s.service -eq "opencode-desktop-pet") { return $candidate }
    } catch {}
    return ""
}

# ---- 聊天窗：和桌宠（= 当前 opencode 会话）聊天 ----
function Get-OfflineReply {
    $list = $null
    try { $list = $script:cfg.chat.offlineReplies } catch {}
    if ($list -and $list.Count -gt 0) { return [string]($list | Get-Random) }
    return "我现在连不上大脑（opencode 会话），先陪我待会儿吧。"
}

function Add-ChatBubble([string]$text, [string]$who) {
    if (-not $script:chatLog) { return }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.TextWrapping = "Wrap"
    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $border.Padding = New-Object System.Windows.Thickness(8, 5, 8, 5)
    $border.Margin = New-Object System.Windows.Thickness(4, 2, 4, 2)
    $border.MaxWidth = 290
    if ($who -eq "me") {
        $border.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x2D, 0x7D, 0xD2))
        $tb.Foreground = [System.Windows.Media.Brushes]::White
        $border.HorizontalAlignment = "Right"
    } else {
        $border.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0xE9, 0xEB, 0xEF))
        $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0x1F, 0x23, 0x28))
        $border.HorizontalAlignment = "Left"
    }
    $border.Child = $tb
    $script:chatLog.Children.Add($border) | Out-Null
    try { $script:chatScroll.ScrollToEnd() } catch {}
}

# 后台线程 POST 的结果在 UI 线程这里落地
function Receive-ChatResult([string]$payload) {
    $script:chatBusy = $false
    if ($script:chatStatus) { $script:chatStatus.Text = "" }
    if ($payload.StartsWith("ERR:")) {
        Add-ChatBubble ("连不上大脑：" + $payload.Substring(4)) "pet"
        return
    }
    $body = $payload
    if ($body.StartsWith("BODY:")) { $body = $body.Substring(5) }
    $obj = $null
    try { $obj = $body | ConvertFrom-Json } catch {}
    if ($null -ne $obj -and $obj.ok -and $obj.reply) { Add-ChatBubble ([string]$obj.reply) "pet" }
    elseif ($null -ne $obj -and $obj.reply) { Add-ChatBubble ([string]$obj.reply) "pet" }
    elseif ($null -ne $obj -and $obj.error) { Add-ChatBubble ([string]$obj.error) "pet" }
    else { Add-ChatBubble (Get-OfflineReply) "pet" }
}

function Send-ChatMessage {
    $text = ""
    if ($script:chatInput) { $text = ([string]$script:chatInput.Text).Trim() }
    if (-not $text) { return }
    $script:chatInput.Text = ""
    Add-ChatBubble $text "me"

    $max = 2000
    try { if ($script:cfg.chat.maxChars) { $max = [int]$script:cfg.chat.maxChars } } catch {}
    if ($text.Length -gt $max) {
        Add-ChatBubble ("消息太长啦，最多 " + $max + " 个字。") "pet"
        return
    }
    if ($script:chatBusy) {
        Add-ChatBubble "我还在想上一条呢，等一下下～" "pet"
        return
    }

    $url = Get-PanelUrl
    if ($url -eq "") {
        # 没有运行中的扩展实例（独立模式）→ 用配置里的兜底台词，别让聊天框变成死胡同
        Add-ChatBubble (Get-OfflineReply) "pet"
        return
    }

    $timeout = 60000
    try { if ($script:cfg.chat.timeoutMs) { $timeout = [int]$script:cfg.chat.timeoutMs } } catch {}
    $json = @{ text = $text } | ConvertTo-Json -Compress
    try {
        $script:chatBusy = $true
        if ($script:chatStatus) { $script:chatStatus.Text = "思考中…" }
        [PetChatBridge]::PostJson($url + "api/chat", $json, $script:chatQueue, ($timeout + 5000))
    } catch {
        $script:chatBusy = $false
        if ($script:chatStatus) { $script:chatStatus.Text = "" }
        Add-ChatBubble (Get-OfflineReply) "pet"
    }
}

function Show-ChatWindow {
    if ($script:chatWin) {
        try { $script:chatWin.Activate() | Out-Null } catch {}
        return
    }

    $chatXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="聊天" Width="360" Height="420" Topmost="True" ShowInTaskbar="False"
        WindowStartupLocation="Manual" Background="#FFF6F7F9">
  <Grid Margin="8">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <ScrollViewer x:Name="ChatScroll" Grid.Row="0" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="ChatLog"/>
    </ScrollViewer>
    <TextBlock x:Name="ChatStatus" Grid.Row="1" Margin="4,4,4,0" FontSize="11" Foreground="#6B7280"/>
    <Grid Grid.Row="2" Margin="0,6,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="ChatInput" Grid.Column="0" MinHeight="26" VerticalContentAlignment="Center"/>
      <Button x:Name="ChatSend" Grid.Column="1" Content="发送" Margin="6,0,0,0" Padding="14,3"/>
    </Grid>
  </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader([xml]$chatXaml)
    $script:chatWin = [Windows.Markup.XamlReader]::Load($reader)
    $script:chatLog = $script:chatWin.FindName("ChatLog")
    $script:chatInput = $script:chatWin.FindName("ChatInput")
    $script:chatStatus = $script:chatWin.FindName("ChatStatus")
    $script:chatScroll = $script:chatWin.FindName("ChatScroll")
    $sendBtn = $script:chatWin.FindName("ChatSend")

    # 贴在桌宠窗旁边（屏幕不够就退回屏幕内）
    $wa2 = [System.Windows.SystemParameters]::WorkArea
    $left = $window.Left - $script:chatWin.Width - 8
    if ($left -lt $wa2.Left) { $left = $window.Left + $window.Width + 8 }
    if ($left + $script:chatWin.Width -gt $wa2.Right) { $left = $wa2.Right - $script:chatWin.Width }
    $top = $window.Top - $script:chatWin.Height + $window.Height
    if ($top -lt $wa2.Top) { $top = $wa2.Top }
    if ($top + $script:chatWin.Height -gt $wa2.Bottom) { $top = $wa2.Bottom - $script:chatWin.Height }
    $script:chatWin.Left = $left
    $script:chatWin.Top = $top

    $sendBtn.Add_Click({ Send-ChatMessage })
    $script:chatInput.Add_KeyDown({
        if ($_.Key -eq [System.Windows.Input.Key]::Enter) {
            Send-ChatMessage
            $_.Handled = $true
        }
    })

    $script:chatQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:chatTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:chatTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:chatTimer.Add_Tick({
        $item = $null
        while ($script:chatQueue -and $script:chatQueue.TryDequeue([ref]$item)) {
            Receive-ChatResult ([string]$item)
            $item = $null
        }
    })
    $script:chatTimer.Start()

    $script:chatWin.Add_Closed({
        $script:chatOpen = $false
        if ($script:chatTimer) { $script:chatTimer.Stop() }
        $script:chatWin = $null
        $script:chatLog = $null
        $script:chatInput = $null
        $script:chatStatus = $null
        $script:chatScroll = $null
        $script:chatTimer = $null
        $script:chatQueue = $null
        $script:chatBusy = $false
    })

    $script:chatOpen = $true
    Add-ChatBubble ("我是「" + [string]$script:cfg.name + "」，想聊什么？") "pet"
    $script:chatWin.Show()
    $script:chatInput.Focus() | Out-Null
}

$menu = New-Object System.Windows.Controls.ContextMenu

$itemSettings = New-Object System.Windows.Controls.MenuItem
$itemSettings.Header = "打开设置"
$itemSettings.Add_Click({
    $url = Get-PanelUrl
    if ($url -ne "") { Start-Process $url }
    else { Show-Bubble "没有运行中的桌宠服务，先打开 opencode 或运行 start-pet.bat" 4500 }
})
$menu.Items.Add($itemSettings) | Out-Null

$itemChat = New-Object System.Windows.Controls.MenuItem
$itemChat.Header = "聊天…"
$itemChat.Add_Click({ Show-ChatWindow })
$menu.Items.Add($itemChat) | Out-Null

$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

$itemWander = New-Object System.Windows.Controls.MenuItem
$itemWander.Header = "自动走动 开/关"
$itemWander.Add_Click({ $script:autoWander = -not $script:autoWander })
$menu.Items.Add($itemWander) | Out-Null

# 看着鼠标：有扩展实例时以服务端状态为准（面板/agent 工具也改得动），独立模式则本地切换
$itemLook = New-Object System.Windows.Controls.MenuItem
$itemLook.Header = "看着鼠标 开/关"
$itemLook.Add_Click({
    $want = -not $script:lookAtMouse
    $url = Get-PanelUrl
    if ($url -ne "") {
        try {
            $body = '{"enabled":' + $want.ToString().ToLower() + '}'
            $r = Invoke-RestMethod -Uri ($url + "api/look_at_mouse") -Method Post -ContentType "application/json" -Body $body -TimeoutSec 3
            if ($null -ne $r.lookAtMouse) { $want = [bool]$r.lookAtMouse }
        } catch {}
    }
    $script:lookAtMouse = $want
    $script:lastInteraction = Get-Date
    if ($want) { Show-Bubble "盯着鼠标看～" 1800 }
})
$menu.Items.Add($itemLook) | Out-Null

# 看向 opencode 的对话区；桌面端窗口标题或进程名含 opencode 即可识别
$itemLookOpenCode = New-Object System.Windows.Controls.MenuItem
$itemLookOpenCode.Header = "看向 opencode 对话区 开/关"
$itemLookOpenCode.Add_Click({
    $want = -not $script:lookAtOpenCode
    $url = Get-PanelUrl
    if ($url -ne "") {
        try {
            $body = '{"enabled":' + $want.ToString().ToLower() + '}'
            $r = Invoke-RestMethod -Uri ($url + "api/look_at_opencode") -Method Post -ContentType "application/json" -Body $body -TimeoutSec 3
            if ($null -ne $r.lookAtOpenCode) { $want = [bool]$r.lookAtOpenCode }
        } catch {}
    }
    $script:lookAtOpenCode = $want
    $script:lastInteraction = Get-Date
    if ($want) { Show-Bubble "看向 opencode 对话区～" 1800 }
})
$menu.Items.Add($itemLookOpenCode) | Out-Null

# 动画子菜单：每次展开重建，配置热更新后立刻能看到新动画
$script:itemAnim = New-Object System.Windows.Controls.MenuItem
$script:itemAnim.Header = "动画"
$script:itemAnim.Add_Opened({
    $script:itemAnim.Items.Clear()
    $auto = New-Object System.Windows.Controls.MenuItem
    $auto.Header = "自动"
    $auto.IsCheckable = $true
    $auto.IsChecked = ($null -eq $script:overrideAnim)
    $auto.Add_Click({ $script:overrideAnim = $null })
    $script:itemAnim.Items.Add($auto) | Out-Null
    if ($script:cfg.animations) {
        foreach ($p in $script:cfg.animations.PSObject.Properties) {
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = $p.Name
            $mi.IsCheckable = $true
            $mi.IsChecked = ($script:overrideAnim -eq $p.Name)
            $name = $p.Name
            $mi.Add_Click({ $script:overrideAnim = $name }.GetNewClosure())
            $script:itemAnim.Items.Add($mi) | Out-Null
        }
    }
})
$menu.Items.Add($script:itemAnim) | Out-Null

$itemSleep = New-Object System.Windows.Controls.MenuItem
$itemSleep.Header = "睡觉 / 醒来"
$itemSleep.Add_Click({
    if ($script:mode -eq "sleep") { $script:mode = "idle"; $script:lastInteraction = Get-Date }
    else { $script:mode = "sleep" }
})
$menu.Items.Add($itemSleep) | Out-Null

$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

$itemExit = New-Object System.Windows.Controls.MenuItem
$itemExit.Header = "退出"
$itemExit.Add_Click({ $window.Close() })
$menu.Items.Add($itemExit) | Out-Null

$window.ContextMenu = $menu

$animTimer.Start()
$pollTimer.Start()
$window.ShowDialog() | Out-Null
