# 桌宠启动脚本：双击 start-pet.bat，或运行 powershell -File start-pet.ps1
# 逻辑：已在运行 → 提示退出；有 opencode 会话加载了插件 → 让该实例召唤（联动会话状态）；否则独立模式启动
$ErrorActionPreference = 'SilentlyContinue'
$here = $PSScriptRoot
$port = 12030

function Test-PetWindowVisible {
    if (-not ('PetLauncher.Win' -as [type])) {
        Add-Type -Namespace PetLauncher -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
'@
    }
    $script:petFound = $false
    $cb = [PetLauncher.Win+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$l)
        if ([PetLauncher.Win]::IsWindowVisible($h)) {
            $ownerPid = 0
            [void][PetLauncher.Win]::GetWindowThreadProcessId($h, [ref]$ownerPid)
            $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq 'powershell') {
                $cls = New-Object System.Text.StringBuilder 512
                [void][PetLauncher.Win]::GetClassName($h, $cls, 512)
                if ($cls.ToString().StartsWith('HwndWrapper[DefaultDomain;Pipeline Execution Thread;')) { $script:petFound = $true }
            }
        }
        return $true
    }
    [void][PetLauncher.Win]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:petFound
}

# 只与本项目固定端口通信，不扫描或复用 Copilot 桌宠及其他实例。
$serviceUrl = "http://127.0.0.1:$port/"
$ourServiceRunning = $false
try {
    $state = Invoke-RestMethod ($serviceUrl + 'api/state') -TimeoutSec 2
    if ($state.service -eq 'opencode-desktop-pet') {
        if ($state.running) {
            Write-Host 'OpenCode 桌宠已经在运行（端口 12030）。' -ForegroundColor Yellow
            exit 0
        }
        $ourServiceRunning = $true
    } else {
        Write-Host '端口 12030 已被其他服务占用；为避免与其他桌宠冲突，本次不启动。' -ForegroundColor Red
        exit 2
    }
} catch {}

# 桌面上有其他来源的桌宠（残留或其他 AI 代理的副本）时：不再拦截召唤，直接给个提示
if (Test-PetWindowVisible) {
    Write-Host '提示：桌面上已有一个桌宠窗口（可能是其他来源），将同时启动本插件的桌宠。' -ForegroundColor DarkYellow
}

$win = Join-Path $here 'pet-window.ps1'
if (-not (Test-Path $win)) {
    Write-Host "找不到 pet-window.ps1（期望位置：$win）" -ForegroundColor Red
    exit 1
}
if (-not $ourServiceRunning) {
    Write-Host 'OpenCode 桌宠服务（127.0.0.1:12030）尚未启动；将以独立模式显示桌宠。重启 OpenCode 后可获得会话联动。' -ForegroundColor DarkYellow
    Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $win
    exit 0
}

$r = Invoke-RestMethod ($serviceUrl + 'api/pet/show') -Method Post -TimeoutSec 5
if ($r.ok) { Write-Host '已召唤 OpenCode 桌宠。' -ForegroundColor Green; exit 0 }
Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $win, '-StateUrl', $serviceUrl
Write-Host '桌宠窗口已启动；服务地址为 http://127.0.0.1:12030/。' -ForegroundColor Green
exit 0
