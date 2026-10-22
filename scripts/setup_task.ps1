<#
.SYNOPSIS
    注册「开机自动把本机 WorkBuddy 令牌同步到 GitHub Secret」的计划任务。

.DESCRIPTION
    登录时自动跑一次 refresh_token.py，把本机令牌同步到 GitHub Secret；
    另外在桌面生成一个「同步 WorkBuddy 令牌」快捷方式——手动打开 / 重启
    WorkBuddy 客户端之后点一下它即可（客户端启动会轮换令牌，旧的那个立即失效）。

    两种入口共用一个文件 scripts\run_refresh.cmd：
      不带参数  = 手动（控制台，先问账号，结束停窗）——桌面快捷方式用；
      --auto    = 静默（无窗口无提问，账号取 -Account）——登录启动降级方案用，
                  这段由本脚本追加，-Uninstall 时摘掉。

    需要先安装 GitHub CLI 并登录：winget install --id GitHub.cli && gh auth login

    多账号：同一个仓库托管多个 WorkBuddy 账号时，用 -Account 指定本机
    对应哪个账号（令牌会写进 WB_ACCESS_TOKEN_<ID>）。**不传 -Account 时脚本
    会直接问你**（回车沿用本机上次的账号，没有历史则回车表示单账号模式）；
    不传 -Repo 时也会先尝试从 git remote 推断，推不出来再问你。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup_task.ps1

    不带参数运行：依次询问仓库与账号 id，其余用默认值。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup_task.ps1 -Repo 用户名/仓库名 -RunNow

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup_task.ps1 -Repo 用户名/仓库名 -Account WORK

    适合脚本化调用：全参数给出时不会出现任何提问。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup_task.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    # 你的仓库，形如 用户名/workbuddy_auto_checkin（仅 -Uninstall 时可省略）
    [string]$Repo = "",

    # 多账号：本机对应哪个账号（令牌写入 WB_ACCESS_TOKEN_<ID>）；留空写 WB_ACCESS_TOKEN
    [string]$Account = "",

    # 0（默认）= 只在登录时跑一次；> 0 = 额外按分钟轮询
    #
    # WorkBuddy 客户端每次启动都会轮换 accessToken，旧令牌立即失效。
    # 所以「登录时跑一次」只覆盖开机场景；之后手动重启客户端，需要点一下
    # 桌面的「同步 WorkBuddy 令牌」快捷方式（本脚本会生成）。
    # 不想手动点，就给个 5，让它每 5 分钟自己也查一次。
    [double]$IntervalMinutes = 0,

    # 没有历史推送记录时的兜底：令牌剩余不足这么多天就不推送
    [double]$MinDays = 3,

    # 登录后等待客户端刷新凭据的最长秒数
    [double]$WaitSeconds = 120,

    # 移除计划任务
    [switch]$Uninstall,

    # 注册完成后立刻跑一次，便于当场验证
    [switch]$RunNow,

    # 不生成桌面「同步 WorkBuddy 令牌」快捷方式
    [switch]$NoShortcut,

    # 完全不做任何提问：缺 -Repo / -Account 时直接用参数值（空即单账号模式）
    # 供计划任务、批处理、CI 等无人值守的调用使用
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# 只有真正的交互式控制台才提问；被批处理 / 计划任务 / CI 调用时直接走参数，
# 否则 Read-Host 会一直等输入，把静默调用卡死。
# -NonInteractive（或环境变量 WB_NO_PROMPT=1）可强制关掉提问。
$canPrompt = (-not $NonInteractive) -and (-not $env:WB_NO_PROMPT) -and
             (-not [Console]::IsInputRedirected) -and [Environment]::UserInteractive

# 已在用的账号 id（从本机已有的登录启动项里读），作为提问时的默认值
$knownAccounts = @()
foreach ($vbs in (Get-ChildItem -LiteralPath ([Environment]::GetFolderPath("Startup")) `
            -Filter "WorkBuddyTokenRefresh-*.vbs" -ErrorAction SilentlyContinue)) {
    $knownAccounts += ($vbs.BaseName -replace '^WorkBuddyTokenRefresh-', '')
}

# ---- 账号 id：没在命令行给就问一次，回车沿用上次 / 单账号模式 ----
if (-not $Account -and -not $Uninstall -and $canPrompt) {
    Write-Host ""
    Write-Host "本机账号 id 会拼成 Secret 名 WB_ACCESS_TOKEN_<ID>，" -ForegroundColor Cyan
    Write-Host "必须和仓库变量 WB_ACCOUNTS 里的 id 一致（可留空表示单账号）。" -ForegroundColor Cyan
    if ($knownAccounts.Count -ge 1) {
        Write-Host ("本机已有账号：{0}" -f ($knownAccounts -join ", ")) -ForegroundColor DarkGray
    }
    $defaultAccount = if ($knownAccounts.Count -ge 1) { $knownAccounts[0] } else { "" }
    while ($true) {
        if ($defaultAccount) {
            $typed = Read-Host ("本机账号 id [回车沿用 {0}]" -f $defaultAccount)
        } else {
            $typed = Read-Host "本机账号 id [回车 = 单账号模式，写 WB_ACCESS_TOKEN]"
        }
        if ($null -eq $typed) { $typed = "" }
        $typed = $typed.Trim()
        if (-not $typed) { $typed = $defaultAccount }
        if (-not $typed) { break }                       # 单账号模式，合法
        if ($typed -match '^[A-Za-z0-9_]{1,32}$') { $Account = $typed; break }
        Write-Host "  只能用字母、数字、下划线，1~32 位，请重新输入。" -ForegroundColor Yellow
    }
    Write-Host ""
}

# 账号 id 会拼进 Secret 名，先归一化再用于任务名、日志名、启动项名
$Account = ($Account -as [string])
if ($null -eq $Account) { $Account = "" }
$Account = $Account.Trim().ToUpper()
if ($Account -and $Account -notmatch '^[A-Z0-9_]{1,32}$') {
    Write-Host "[x] -Account 只允许字母、数字、下划线，1~32 位（例如 WORK）" -ForegroundColor Red
    exit 1
}

$suffix = ""
$secretName = "WB_ACCESS_TOKEN"
if ($Account) {
    $suffix = "-" + $Account
    $secretName = "WB_ACCESS_TOKEN_" + $Account
}

$TaskName = "WorkBuddyTokenRefresh" + $suffix
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $scriptDir
$pyScript = Join-Path $root "refresh_token.py"
$logDir = Join-Path $env:LOCALAPPDATA "workbuddy_auto_checkin"
$logFile = Join-Path $logDir ("refresh" + $suffix + ".log")
$startupDir = [Environment]::GetFolderPath("Startup")
$startupVbs = Join-Path $startupDir ("WorkBuddyTokenRefresh" + $suffix + ".vbs")
# 统一入口：手动同步与登录启动共用这一个 .cmd（自动段落由 Install-StartupLauncher 追加）
$cmdFile = Join-Path $scriptDir "run_refresh.cmd"

function New-AutoBlock {
    <#
        生成统一入口 run_refresh.cmd 里 "--auto" 段落（登录启动 / 静默用）。

        为什么单独抽出来：手动模式（桌面快捷方式）与自动模式现在共用一个文件，
        而自动段落只在「计划任务注册失败、降级到启动文件夹」时才需要。
        没有自动段落时 .cmd 仍可当手动入口用，所以这里宁可失败也不写坏文件。

        必须只含 ASCII：中文路径写进 .cmd 会被编码成 '?'。
    #>
    param(
        [string]$Launcher,
        [string]$Prefix,
        [string]$Repo,
        [string]$Account,
        [double]$MinDays,
        [double]$WaitSeconds,
        [double]$IntervalMinutes,
        [string]$Suffix
    )

    $logExpr = '%LOCALAPPDATA%\workbuddy_auto_checkin\refresh' + $Suffix + '.log'
    $stopExpr = '%LOCALAPPDATA%\workbuddy_auto_checkin\refresh' + $Suffix + '.stop'

    $call = '"' + $Launcher + '"'
    if ($Prefix) { $call += " " + $Prefix }
    $call += ' "%~dp0..\refresh_token.py" --gh-repo ' + $Repo
    if ($Account) { $call += ' --account ' + $Account }
    $call += ' --min-days ' + $MinDays + ' --wait ' + $WaitSeconds + ' --log "' + $logExpr + '"'

    $lines = @(
        'rem ---- auto mode: logon / background, never prompts (started by the logon .vbs) ----'
        ':auto'
        'set "ACCOUNT=' + $Account + '"'
        'set "LOG=%LOCALAPPDATA%\workbuddy_auto_checkin\refresh' + $Suffix + '.log"'
    )
    if ($IntervalMinutes -gt 0) {
        $lines += 'set "STOP=' + $stopExpr + '"'
        $lines += ':loop'
        $lines += 'if exist "%STOP%" exit /b 0'
    }
    $lines += $call
    if ($IntervalMinutes -gt 0) {
        # ping 当 sleep 用：timeout 在没有控制台时可能直接失败
        $ticks = [int]([math]::Round($IntervalMinutes * 60)) + 1
        $lines += ('ping -n ' + $ticks + ' 127.0.0.1 >nul')
        $lines += 'goto loop'
    }
    $lines += 'exit /b 0'
    return (($lines -join "`r`n") + "`r`n")
}

function Install-StartupLauncher {
    <#
        降级方案：写进「启动」文件夹。
        不需要管理员权限，也不需要任务计划服务；代价是没有真正的定时器，
        所以让 .cmd 自己循环（跑一次 → 等 N 分钟 → 再跑），效果与计划任务等价。

        启动项现在指向统一入口 <CmdPath> --auto：cmd 里不能提问（无控制台），
        账号来自安装时的 -Account，所以自动段落里 --account 是写死的。
    #>
    param(
        [string]$Launcher,          # 裸命令名，如 pyw / pythonw
        [string]$Prefix,            # 传给启动器的前缀参数（pyw 需要 -3）
        [string]$Repo,
        [string]$Account,
        [double]$MinDays,
        [double]$WaitSeconds,
        [double]$IntervalMinutes,
        [string]$Suffix,
        [string]$CmdPath
    )

    if (-not $startupDir -or -not (Test-Path -LiteralPath $startupDir)) {
        Write-Host "[x] 找不到「启动」文件夹，无法降级。" -ForegroundColor Red
        return $null
    }
    if (-not (Test-Path -LiteralPath $CmdPath)) {
        Write-Host "[x] 找不到统一入口 $CmdPath，无法挂自动段落。" -ForegroundColor Red
        return $null
    }

    # 已有自动段落先摘掉，保证多次运行不会叠加出第二份 :auto / :loop
    $autoBlock = New-AutoBlock -Launcher $Launcher -Prefix $Prefix -Repo $Repo -Account $Account `
        -MinDays $MinDays -WaitSeconds $WaitSeconds -IntervalMinutes $IntervalMinutes -Suffix $Suffix
    $existing = [IO.File]::ReadAllText($CmdPath)
    $existing = [regex]::Replace($existing, "(?s)\r?\nrem ---- auto mode.*\z", "`r`n")
    [IO.File]::WriteAllText($CmdPath, $existing.TrimEnd() + "`r`n`r`n" + $autoBlock, [Text.Encoding]::ASCII)

    $vbsContent = @(
        "' Generated by setup_task.ps1 - sync WorkBuddy token on logon"
        "Set sh = CreateObject(`"WScript.Shell`")"
        "sh.Run `"`"`"$CmdPath`"`" --auto`", 0, False"
    ) -join "`r`n"
    # 路径含中文时 ASCII 会写成 '?'，此时改用 UTF-16LE（WSH 支持带 BOM 的 Unicode 脚本）
    $cmdIsAscii = ($CmdPath -notmatch '[^\x00-\x7F]')
    $vbsEncoding = if ($cmdIsAscii) { [Text.Encoding]::ASCII } else { [Text.Encoding]::Unicode }
    [IO.File]::WriteAllText($startupVbs, $vbsContent, $vbsEncoding)

    Write-Host "[OK] 已改用登录启动方式（无需管理员权限）" -ForegroundColor Green
    Write-Host "     启动脚本：$startupVbs"
    Write-Host "     实际命令：$CmdPath"
    if ($IntervalMinutes -gt 0) {
        Write-Host ("     同步方式：登录时一次 + 每 {0} 分钟轮询" -f $IntervalMinutes)
    } else {
        Write-Host "     同步方式：仅登录时跑一次（重启客户端后请点桌面快捷方式）"
    }
    return $startupVbs
}

if ($Uninstall) {
    $removed = $false
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[OK] 已移除计划任务：$TaskName" -ForegroundColor Green
        $removed = $true
    }
    if (Test-Path -LiteralPath $startupVbs) {
        # 降级模式的 .cmd 在循环里跑，先落一个停止标记，否则它下次睡醒还会继续
        $stopFlag = Join-Path $logDir ("refresh" + $suffix + ".stop")
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        [IO.File]::WriteAllText($stopFlag, "stopped`r`n", [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $startupVbs -Force
        Write-Host "[OK] 已移除登录启动项：$startupVbs" -ForegroundColor Green
        Write-Host "     已写入停止标记：$stopFlag（循环进程会在下一轮退出）"
        $removed = $true
    }
    if (-not $removed) { Write-Host "[--] 没找到已注册的计划任务或启动项：$TaskName" }
    # 桌面快捷方式：新版是通用的「同步 WorkBuddy 令牌」，旧版按账号后缀命名。
    # 本机若还有别的账号在用，通用那份要留着。
    # 注意：统一入口 run_refresh.cmd 同时服务桌面快捷方式与启动项，不能整文件删除，
    # 这里只摘掉它里面的自动段落，手动模式段落保留（删了快捷方式就指向空气）。
    $desktop = [Environment]::GetFolderPath("Desktop")
    $stillUsed = @(Get-ChildItem -LiteralPath $startupDir -Filter "WorkBuddyTokenRefresh-*.vbs" -ErrorAction SilentlyContinue).Count -gt 0
    $targets = @(Join-Path $desktop ("同步 WorkBuddy 令牌" + $(if ($Account) { "（" + $Account + "）" } else { "" }) + ".lnk"))
    if (-not $stillUsed) {
        $targets += (Join-Path $desktop "同步 WorkBuddy 令牌.lnk")
        $targets += (Join-Path $scriptDir "sync_now.cmd")
    }
    $targets += (Join-Path $scriptDir ("sync_now" + $suffix + ".cmd"))
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            Remove-Item -LiteralPath $t -Force
            Write-Host "[OK] 已移除：$t" -ForegroundColor Green
        }
    }
    if (-not $stillUsed) {
        $entryCmd = Join-Path $scriptDir "run_refresh.cmd"
        if (Test-Path -LiteralPath $entryCmd) {
            $body = [IO.File]::ReadAllText($entryCmd)
            if ($body -match "(?s)\r?\nrem ---- auto mode") {
                $body = [regex]::Replace($body, "(?s)\r?\nrem ---- auto mode.*\z", "`r`n")
                [IO.File]::WriteAllText($entryCmd, $body.TrimEnd() + "`r`n", [Text.Encoding]::ASCII)
                Write-Host "[OK] 已摘掉统一入口里的自动段落：$entryCmd（手动模式保留）" -ForegroundColor Green
            }
        }
    }
    # 多账号时其它账号各自的启动项不会被这条命令带走，提示一下免得以为清干净了
    $others = @()
    foreach ($f in (Get-ChildItem -LiteralPath $startupDir -Filter "WorkBuddyTokenRefresh-*.vbs" -ErrorAction SilentlyContinue)) {
        $others += ("  " + $f.Name + "  →  powershell -File scripts\setup_task.ps1 -Uninstall -Account " +
            ($f.BaseName -replace '^WorkBuddyTokenRefresh-', ''))
    }
    if ($others.Count -gt 0) {
        Write-Host "[提示] 本机还有其它账号的登录启动项，如需一并移除：" -ForegroundColor Yellow
        $others | ForEach-Object { Write-Host $_ }
    }
    return
}

# 仓库：没给就试着从 git remote 推出来，推不出来再问
if (-not $Repo -and $canPrompt) {
    $guess = ""
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $url = (git -C (Split-Path -Parent $scriptDir) remote get-url origin 2>$null)
        if ($url -and $url -match 'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$') {
            $guess = $Matches[1] + "/" + $Matches[2]
        }
    }
    while ($true) {
        if ($guess) {
            $typed = Read-Host ("GitHub 仓库 [回车 = {0}]" -f $guess)
        } else {
            $typed = Read-Host "GitHub 仓库（形如 用户名/仓库名）"
        }
        if ($null -eq $typed) { $typed = "" }
        $typed = $typed.Trim()
        if (-not $typed) { $typed = $guess }
        if ($typed -match '^[^/\s]+/[^/\s]+$' -and -not $typed.Contains("github.com")) {
            $Repo = $typed
            break
        }
        Write-Host "  格式应为 用户名/仓库名，不要带 https:// 或 .git，请重新输入。" -ForegroundColor Yellow
    }
    Write-Host ""
}

# 同一台机器再次运行时，如果既有登录项又没说清是哪个账号，提示一下别弄错
if ($canPrompt -and $knownAccounts.Count -gt 1 -and $knownAccounts -notcontains $Account) {
    Write-Host ("[提示] 本机已有这些账号的登录项：{0}" -f ($knownAccounts -join ", ")) -ForegroundColor Yellow
    Write-Host ("       本次按 '{0}' 注册，会新增一套启动项与桌面快捷方式。" -f $(if ($Account) { $Account } else { "单账号模式" })) -ForegroundColor Yellow
    Write-Host ""
}

if (-not $Repo) {
    Write-Host "[x] 必须用 -Repo 指定你的仓库，例如：-Repo 用户名/workbuddy_auto_checkin" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $pyScript)) {
    Write-Host "[x] 找不到 $pyScript（本脚本应放在项目的 scripts 目录下）" -ForegroundColor Red
    exit 1
}

# gh 缺失时自动任务没有意义：脚本只能打印 token，无法写入 Secret
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Write-Host "[x] 未找到 GitHub CLI（gh），无法自动写入 Secret。" -ForegroundColor Red
    Write-Host "    1) 安装：winget install --id GitHub.cli"
    Write-Host "    2) 登录：gh auth login   （选 GitHub.com -> HTTPS -> 浏览器授权）"
    Write-Host "    3) 重跑本脚本"
    exit 1
}

# 静默运行必须用 pythonw：python.exe 会弹出黑窗口，且没有 stdout
# 记两份：完整路径给计划任务（Unicode 安全），裸命令名给降级 .cmd（ASCII 安全）
$launcherPath = $null
$launcherName = $null
$prefix = @()
$pyw = Get-Command pyw.exe -ErrorAction SilentlyContinue
if ($pyw) {
    $launcherPath = $pyw.Source
    $launcherName = "pyw"
    $prefix = @("-3")
} else {
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($py) {
        $candidate = Join-Path (Split-Path -Parent $py.Source) "pythonw.exe"
        if (Test-Path -LiteralPath $candidate) {
            $launcherPath = $candidate
            $launcherName = "pythonw"
        }
    }
    if (-not $launcherPath) {
        $pw = Get-Command pythonw.exe -ErrorAction SilentlyContinue
        if ($pw) {
            $launcherPath = $pw.Source
            $launcherName = "pythonw"
        }
    }
}
if (-not $launcherPath) {
    Write-Host "[x] 未找到 pythonw.exe / pyw.exe，无法静默运行。" -ForegroundColor Red
    Write-Host "    安装 Python 3 后再试（安装时勾选 py launcher）。"
    exit 1
}

$waitSecondsUsed = $WaitSeconds
# 轮询模式下不需要长时间等待：下一轮自然会看到新令牌
if ($IntervalMinutes -gt 0 -and $waitSecondsUsed -gt 30) { $waitSecondsUsed = 30 }

$arguments = @()
$arguments += $prefix
$arguments += "`"$pyScript`""
$arguments += @("--gh-repo", $Repo)
if ($Account) { $arguments += @("--account", $Account) }
$arguments += @("--min-days", $MinDays, "--wait", $waitSecondsUsed, "--log", "`"$logFile`"")
$argumentLine = ($arguments | ForEach-Object { $_.ToString() }) -join " "

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
# 上次 -Uninstall 留下的停止标记会让降级模式的循环直接退出，这里先清掉
$stopFlag = Join-Path $logDir ("refresh" + $suffix + ".stop")
if (Test-Path -LiteralPath $stopFlag) { Remove-Item -LiteralPath $stopFlag -Force }

$action = New-ScheduledTaskAction -Execute $launcherPath -Argument $argumentLine -WorkingDirectory $root

$triggers = @()
$logon = New-ScheduledTaskTrigger -AtLogOn
$logon.Delay = "PT1M"     # 登录后客户端要一点时间把凭据刷新完
$triggers += $logon
if ($IntervalMinutes -gt 0) {
    # 客户端重启会轮换令牌，只靠登录触发必然失效，所以给个可选的重复触发
    $triggers += New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($IntervalMinutes) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
}

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Settings $settings -Force -ErrorAction Stop `
        -Description "把本机 WorkBuddy 令牌同步到 GitHub Secret $secretName（令牌轮换后自动重推）" | Out-Null

    Write-Host "[OK] 已注册计划任务：$TaskName" -ForegroundColor Green
    Write-Host "     Secret：$secretName$(if ($Account) { "（账号 $Account）" })"
    Write-Host "     启动器：$launcherPath"
    Write-Host "     参数  ：$argumentLine"
    if ($IntervalMinutes -gt 0) {
        Write-Host ("     触发  ：登录后 1 分钟 + 每 {0} 分钟一次" -f $IntervalMinutes)
    } else {
        Write-Host "     触发  ：仅登录后 1 分钟"
    }
    Write-Host "     日志  ：$logFile"
    # 计划任务已接管登录同步；之前降级时留下的 vbs / 停止标记要清掉，
    # 否则登录会双跑，更糟的是旧版 vbs 指向的 .cmd 可能已被删除（WSH 开机报错）
    foreach ($staleVbs in @($startupVbs)) {
        if (Test-Path -LiteralPath $staleVbs) {
            Remove-Item -LiteralPath $staleVbs -Force
            Write-Host "[--] 已清理降级启动项（计划任务已接管）：$staleVbs"
        }
    }
    if (Test-Path -LiteralPath $stopFlag) { Remove-Item -LiteralPath $stopFlag -Force }
} catch {
    # 常见于未提升权限的普通账户：计划任务服务拒绝写入。
    # 但如果同名计划任务其实已经存在（以前注册成功过），它仍在接管登录同步，
    # 此时再写降级 vbs 只会造成登录双跑——直接沿用现有任务即可。
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "[!] 重新注册计划任务失败：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    但同名计划任务已存在（状态 $($existingTask.State)），登录同步由它继续承担，" -ForegroundColor Yellow
        Write-Host "    不写降级启动项。要更新任务参数请以管理员身份重跑本脚本。" -ForegroundColor Yellow
    } else {
        Write-Host "[!] 注册计划任务失败：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    改为写入「启动」文件夹（登录时运行，不需要管理员权限）`n"
        if (-not (Install-StartupLauncher -Launcher $launcherName -Prefix ($prefix -join " ") `
                    -Repo $Repo -Account $Account -MinDays $MinDays -WaitSeconds $waitSecondsUsed `
                    -IntervalMinutes $IntervalMinutes -Suffix $suffix -CmdPath $cmdFile)) {
            Write-Host "    如要使用计划任务，请以管理员身份打开 PowerShell 后重跑本脚本。" -ForegroundColor Red
            exit 1
        }
        Write-Host "     Secret：$secretName$(if ($Account) { "（账号 $Account）" })"
        Write-Host "     日志  ：$logFile"
        Write-Host "     说明  ：登录启动靠 .cmd 兜住，注销/重启后才会重新开始。" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------- 桌面快捷方式（手动同步用）
# 场景：登录脚本只在开机时跑一次；你中途关掉再打开 WorkBuddy，客户端会轮换
# 令牌，这一枚才是有效的。点一下这个快捷方式就能把新令牌推上去。
if (-not $NoShortcut) {
    # 统一入口：run_refresh.cmd。同一个文件两种模式——
    #   不带参数 = 手动模式，控制台、先问账号（回车沿用上次，- 表示单账号）；
    #   带 --auto = 静默模式，账号来自本脚本的 -Account，由登录项调用。
    # 这样仓库里只有一个 .cmd，换账号也不用重新生成。
    $syncCmd = Join-Path $scriptDir "run_refresh.cmd"
    # 旧版按账号后缀生成的 .cmd、以及上一个版本的独立 sync_now.cmd 一并清掉
    foreach ($stale in (Get-ChildItem -LiteralPath $scriptDir -Filter "sync_now*.cmd" -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $stale.FullName -Force
        Write-Host "[--] 已清理旧脚本：$($stale.Name)"
    }
    # 用控制台版 python：双击后能看到提问与「已写入 / 跳过」的结论，不是黑窗一闪而过
    $console = $null
    foreach ($n in @("py", "python")) {
        if (Get-Command $n -ErrorAction SilentlyContinue) { $console = $n; break }
    }
    if ($console) {
        $consolePrefix = if ($console -eq "py") { "-3 " } else { "" }
        # run_refresh.cmd 是 git 跟踪的源码文件，且可能比本脚本内置模板更新
        # （8e7497a 加过 RC 捕获与退出码提示，模板没有）。只在文件缺失时才用
        # 模板生成（适配「不 via git、只拷代码」的场景）；已存在则绝不重写，
        # 否则会把仓库里更新的版本降级回模板（2026-10-22 实测踩过）。
        # :auto 段的追加 / 摘除由 Install-StartupLauncher 和 -Uninstall 负责。
        if (Test-Path -LiteralPath $syncCmd) {
            Write-Host "[--] run_refresh.cmd 已存在，保留仓库版本（不用内置模板覆盖）"
        } else {
        $syncLines = @(
            '@echo off'
            'setlocal'
            'rem Single entry point for the WorkBuddy token sync. Two modes:'
            'rem   no argument  = manual (console): ask the account, push, pause before closing'
            'rem   --auto       = background (logon .vbs): account from setup_task.ps1 -Account'
            'rem The "--auto" block is appended by setup_task.ps1 and stripped on -Uninstall.'
            'rem This file must stay ASCII: it is written with ASCII encoding, non-ASCII -> "?".'
            'if /i "%~1"=="--auto" goto auto'
            ''
            'title WorkBuddy token sync'
            'rem last_account.txt is a one-line mirror written by refresh_token.py:'
            'rem   LINJJ           = the account used last time (shown in the prompt below)'
            'rem   -               = last run was single-account mode'
            'rem   (file missing)  = never synced on this machine'
            'set "LASTACC="'
            'if exist "%LOCALAPPDATA%\workbuddy_auto_checkin\last_account.txt" for /f "usebackq delims=" %%L in ("%LOCALAPPDATA%\workbuddy_auto_checkin\last_account.txt") do set "LASTACC=%%L"'
            'if "%LASTACC%"=="-" set "LASTACC="'
            'if defined LASTACC goto asklast'
            ''
            'set /p "ACCOUNT=Account id [no last account yet, Enter = single-account mode]: "'
            'goto afterask'
            ''
            ':asklast'
            'set /p "ACCOUNT=Account id [Enter = %LASTACC%, - = single-account mode]: "'
            ''
            ':afterask'
            'if defined ACCOUNT goto typed'
            'goto runask'
            ''
            ':typed'
            'rem strip quotes so the id cannot break out of the argument'
            'set "ACCOUNT=%ACCOUNT:"=%"'
            'if "%ACCOUNT%"=="-" set "ACCOUNT="'
            'if not defined ACCOUNT goto runask'
            'rem Client rotates the token on every start; old one dies instantly'
            '"' + $console + '" ' + $consolePrefix + '"%~dp0..\refresh_token.py" --gh-repo ' + $Repo +
                ' --account "%ACCOUNT%" --min-days 3 --wait 60 --log "%LOCALAPPDATA%\workbuddy_auto_checkin\refresh-%ACCOUNT%.log"'
            'set "LOGPATH=%LOCALAPPDATA%\workbuddy_auto_checkin\refresh-%ACCOUNT%.log"'
            'goto done'
            ''
            ':runask'
            '"' + $console + '" ' + $consolePrefix + '"%~dp0..\refresh_token.py" --gh-repo ' + $Repo +
                ' --ask-account --min-days 3 --wait 60 --log "%LOCALAPPDATA%\workbuddy_auto_checkin\refresh.log"'
            'set "LOGPATH=%LOCALAPPDATA%\workbuddy_auto_checkin\refresh.log"'
            ''
            ':done'
            'echo.'
            'echo ---- done. log: %LOGPATH%'
            'ping -n 9 127.0.0.1 >nul'
            'exit /b 0'
        )
        # 这段只在文件缺失时执行（见上方注释）；模板里没有 :auto 段。
        [IO.File]::WriteAllText($syncCmd, (($syncLines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
        }

        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnkPath = Join-Path $desktop "同步 WorkBuddy 令牌.lnk"
        # 旧版「同步 WorkBuddy 令牌（ID）.lnk」清掉，只留一个通用入口
        foreach ($stale in (Get-ChildItem -LiteralPath $desktop -Filter "同步 WorkBuddy 令牌（*.lnk" -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $stale.FullName -Force
        }
        try {
            $wsh = New-Object -ComObject WScript.Shell
            $lnk = $wsh.CreateShortcut($lnkPath)
            $lnk.TargetPath = $env:COMSPEC
            $lnk.Arguments = '/c ""' + $syncCmd + '""'
            $lnk.WorkingDirectory = $root
            $lnk.Description = "打开 WorkBuddy 之后点一下：按提示选择账号，把新令牌同步到 GitHub Secret"
            $wb = Get-Process -Name WorkBuddy -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($wb -and $wb.Path) { $lnk.IconLocation = $wb.Path + ",0" }
            $lnk.Save()
            Write-Host "`n[OK] 桌面快捷方式：$lnkPath" -ForegroundColor Green
            Write-Host "     双击后会先问「本机账号 id」（回车沿用上次），随后自动同步" -ForegroundColor DarkGray
        } catch {
            Write-Host ("`n[!] 创建快捷方式失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
            Write-Host "     可以直接双击：$syncCmd"
        }
    } else {
        Write-Host "`n[!] 没找到控制台版 python（py/python），跳过桌面快捷方式" -ForegroundColor Yellow
    }
}

# ---------------------------------------------- 启动项自检（防「改方案后残留」）
# 本次开机报错 80070002 的根源就是：方案改成统一入口后，旧版 vbs 还指着
# 已被删除的 per-account .cmd，没有任何机制去发现它坏了。这里兜底扫一遍：
# 每个 WorkBuddyTokenRefresh*.vbs 的 sh.Run 目标都必须真实存在，否则删掉并明说。
foreach ($vbs in (Get-ChildItem -LiteralPath $startupDir -Filter "WorkBuddyTokenRefresh*.vbs" -ErrorAction SilentlyContinue)) {
    $text = [IO.File]::ReadAllText($vbs.FullName)
    $m = [regex]::Match($text, 'sh\.Run\s+"""([^"]*)')
    if (-not $m.Success) { continue }
    $target = [regex]::Match($m.Groups[1].Value, '^[^"]+').Value
    if ($target -and -not (Test-Path -LiteralPath $target)) {
        Remove-Item -LiteralPath $vbs.FullName -Force
        Write-Host "[--] 已清理失效启动项（目标不存在：$target）：$($vbs.Name)" -ForegroundColor Yellow
    }
}

if ($RunNow) {
    Write-Host "`n立即试跑一次…"
    $registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    try {
        if ($registered) {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        } else {
            # 降级模式不能直接跑 .cmd（它可能带循环），单独起一个进程跑一次
            Start-Process -FilePath $launcherPath -ArgumentList $argumentLine -WindowStyle Hidden
        }
    } catch {
        Write-Host "[!] 触发失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 10
    if (Test-Path -LiteralPath $logFile) {
        Write-Host "----- 日志末尾 -----"
        Get-Content -LiteralPath $logFile -Tail 12 -Encoding UTF8
        Write-Host "--------------------"
    } else {
        Write-Host "[!] 还没生成日志，稍后手动查看：$logFile"
    }
}
