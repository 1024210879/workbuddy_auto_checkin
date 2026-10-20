# 移植到另一台电脑

本文针对的场景：**两台电脑并行使用**，新机器登录**另一个 WorkBuddy 账号**，
使用**另一个 GitHub 账号 / 新仓库**。两台机器互不干扰，各自维护自己那份签到数据。

---

## 0. 先搞清楚哪些能复制、哪些必须在新机器重建

| 类别 | 具体东西 | 处理方式 |
| --- | --- | --- |
| 能直接复制 | 源码、`.github/workflows/`、`scripts/setup_task.ps1`、`README.md` | 走 `git clone`，不要手工拷文件夹 |
| **必须新机器重新生成** | `%APPDATA%\...\Startup\WorkBuddyTokenRefresh.vbs`、`scripts\run_refresh.cmd` | 里面写死了旧机的绝对路径，复制过去等于指向不存在的文件。必须跑一次 `setup_task.ps1` |
| **必须新机器重新生成** | `%LOCALAPPDATA%\workbuddy_auto_checkin\state.json`、`refresh.log` | 去重状态和日志，属于本机状态。`state.json` 尤其不要拷——它按 `expiresAt` 去重且不区分仓库，拷过去可能让新机误判「已推送过」而跳过写入 |
| **绝对不能复制** | `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info` | 这是旧机、旧账号的登录态。新机必须自己登录客户端生成 |
| **不能复制** | `%APPDATA%\GitHub CLI\hosts.yml` | gh 的登录凭据，新机自己 `gh auth login` |
| **不能复制** | `.git`、`__pycache__`、`build/`、`dist/` | 版本库与构建产物，新机重新 clone / 重新生成 |

> 一句话：**只搬代码，不搬状态。** 凭据、去重状态、启动项、gh 登录，全部在新机器上重做。

---

## 1. 旧机器上先做（一次性）

当前改动**还没有提交**，`git clone` 只会拿到旧代码（没有过期闸门、没有 `scripts/`）。
所以顺序必须是「先提交推送，再在新机器拉」。

```bash
cd D:/Software/GithubRepository/workbuddy_auto_checkin
git status                     # 确认只有预期内的改动
git add -A
git commit -m "feat: 令牌自动续期（过期闸门 / 去重 / 静默日志 / 登录启动）"
git push origin main
```

推送后在本机确认一下：

```bash
git ls-tree --name-only origin/main | grep scripts    # 应能看到 scripts
gh secret list --repo 1024210879/workbuddy_auto_checkin
```

> 旧机器的登录启动项**保留不动**，它继续服务旧仓库。

---

## 2. 新机器装三样东西

| 依赖 | 用途 | 装法 |
| --- | --- | --- |
| WorkBuddy 桌面客户端 | 签发并自动刷新 token（脚本只是「搬运工」，不能没有它） | 官网下载安装，用**新账号**登录 |
| Python 3 | 跑 `refresh_token.py` | 安装时**勾选 `py launcher`**，否则找不到 `pyw.exe` |
| GitHub CLI（gh） | 写仓库 Secret | `winget install --id GitHub.cli` 然后 `gh auth login` |

`gh auth login` 全程用**新 GitHub 账号**授权（GitHub.com → HTTPS → 浏览器）。

装完自查：

```bash
py -3 -V
gh auth status
```

---

## 3. 把代码弄到新机器

旧仓库是 **public**，所以有三种方式，推荐 B。

### A. Fork（最省事，但有坑）

```bash
gh repo fork 1024210879/workbuddy_auto_checkin --clone --default-branch-only
```

坑：**fork 出来的仓库 Actions 默认是关闭的**，必须手动去网页
`Settings → Actions → General → 允许所有 action` 或首页点
「I understand my workflows, go ahead and enable them」，否则 cron 永远不跑。
另外 fork 会留在原仓库的 network 里，后续想转成独立仓库比较别扭。

### B. 新建仓库 + push（推荐）

```bash
git clone https://github.com/1024210879/workbuddy_auto_checkin.git
cd workbuddy_auto_checkin
git remote remove origin
gh repo create <新账号>/workbuddy_auto_checkin --public --source=. --remote=origin --push
```

这样得到的是一个**完全独立的新仓库**：Actions 默认开启、可以是 private、没有 fork 网络的牵连。
把 `<新账号>` 换成新 GitHub 用户名；想要私有就改 `--private`。

### C. 下载 ZIP

最笨但可行：网页 `Code → Download ZIP`，解压后 `git init` + 推上去。
不推荐，会丢提交历史，以后也没法 `git pull` 同步上游修复。

---

## 4. 配两条 Secret

新仓库是空的，两条都要重新配。

### 4.1 `WB_ACCESS_TOKEN` —— 由脚本自动写入

前提：**新机器的客户端已经登录过新账号**，凭据文件才会存在且是新鲜的。

```bash
# 第一步：只检查，不写入。验证「找到凭据 / 能定位客户端 / 能解密 / 剩余天数」
py -3 refresh_token.py --check

# 第二步：确认无误后写入新仓库
py -3 refresh_token.py --gh-repo <新账号>/workbuddy_auto_checkin
```

`--check` 通过后再写，是刻意的顺序：解密依赖客户端私有 binding，
**换机器 / 换客户端版本时这一环最容易断**，先验证比写进去发现是废 token 好。

正常情况下**不需要** `--force`。它只在三种情况用：

- `state.json` 说「已推送过」但你换了仓库（去重不区分仓库，会误跳过）；
- 令牌剩余不足 3 天，你仍想推（闸门默认 exit 3）；
- 你明确知道令牌已在别处轮换过。

### 4.2 `FEISHU_WEBHOOK` —— 手动配

```bash
gh secret set FEISHU_WEBHOOK --repo <新账号>/workbuddy_auto_checkin --body "https://open.feishu.cn/open-apis/bot/v2/hook/xxxx"
```

要不要新建机器人：

- **可以复用旧 webhook**。webhook 只是一个 URL，新仓库往里推完全合法，卡片就发到原来那个群。两个账号的卡片会混在一起。
- **更推荐新建**：新账号本来就该有自己的通知群，新建一个群 → 添加「自定义机器人」→ 拿新 webhook。两个账号各发各的群，一眼能分清。

---

## 5. 注册自动续期（新机器上跑）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup_task.ps1 -Repo <新账号>/workbuddy_auto_checkin -RunNow
```

行为：注册计划任务「登录后 1 分钟跑一次」（**权限不足时自动降级**为写入「启动」文件夹的 vbs，效果一样），
并在桌面生成「同步 WorkBuddy 令牌」快捷方式。`-RunNow` 会立刻跑一次并回显日志尾部。

> **注意**：WorkBuddy 客户端每次启动都会轮换 `accessToken`，旧令牌立即作废。
> 登录那次只覆盖开机场景；**中途关掉又打开客户端后，点一下桌面快捷方式**即可（约 3 秒）。
> 快捷方式内部是 `refresh_token.py --wait 60`：凭据文件刚被写过才等待，否则秒退。

> 新机器上如果路径/用户名含中文也没关系：`.cmd` 只用 `%~dp0` 与 `%LOCALAPPDATA%` 运行时展开。

**中文路径：已处理。** 生成的 `.cmd` 只用 `%~dp0`（脚本自身位置）和 `%LOCALAPPDATA%`，
由 cmd 运行时展开，项目路径和用户名带中文都不会变成 `?`；`.vbs` 在路径非 ASCII 时自动改用
UTF-16LE 写入（WSH 支持带 BOM 的 Unicode 脚本）。旧版脚本曾把完整路径按 ASCII 写进 `.cmd`，
如果你在新机器上用的是旧脚本，重新跑一次本脚本即可覆盖。

---

## 6. 验证清单

按顺序打勾，每一步都能定位到具体断点：

1. **Secret 在不在** —— `gh secret list --repo <新账号>/workbuddy_auto_checkin`，两条都有、时间是刚才
2. **云端能不能跑** —— `gh workflow run daily.yml --repo <新账号>/workbuddy_auto_checkin`，然后 `gh run watch`
3. **签到是否真成功** —— 看 Run 的 Step Summary，或直接看飞书卡片有没有到
4. **本机自动续期是否生效** —— 清掉去重状态后重跑一次启动项，`%LOCALAPPDATA%\workbuddy_auto_checkin\refresh.log` 应出现新记录
5. **下次登录是否自动跑** —— 重启一次电脑，等 1～2 分钟，再看日志时间戳
6. **确认不是「假成功」** —— 日志里出现「该令牌此前已推送过」是正常的（说明客户端这次没刷新新值，Secret 里那枚仍有效）；出现 exit 3 / exit 4 才是真问题

---

## 7. 两台并行时的注意事项

**如果两台机器要写同一个仓库**（多账号模式，见 README「多账号」一节），差异只有三处：

- 新机器导出令牌时加 `--account <ID>`，令牌会写进 `WB_ACCESS_TOKEN_<ID>`，不碰主号的 `WB_ACCESS_TOKEN`
- 仓库里要加一个变量 `WB_ACCOUNTS` 声明账号清单（Variables 页签，不是 Secrets）
- 注册自动续期时同样带 `-Account <ID>`，任务名、日志名、启动项名都会带上账号后缀，同机也不会互相覆盖

这样两台机器各写各的 Secret，**不会互相覆盖**。如果你反其道行之——把新机也指向旧账号、又不加 `--account`——两台就会轮流覆盖同一个 Secret，虽然功能上还能用（谁最后写谁生效），但排查问题会很混乱。

其它通用注意点：

- 两套 cron 各跑各的，签到数据也是两份（不同 WorkBuddy 账号），**不会重复领奖**
- 同一仓库多账号时，矩阵会按账号数成倍消耗 Actions 额度（公开仓库不计时，私有仓库每月 2000 分钟，仍然够用）
- 已知限制：cron 是 UTC，且 GitHub 高负载时会延迟甚至丢弃整次运行，这就是 `daily.yml` 里配三个时段互为备份的原因，迁移时**别改 cron**。

---

## 8. 出问题时先看哪里

| 现象 | 先看 | 常见原因 |
| --- | --- | --- |
| Actions 完全不跑 | 仓库 Actions 是否启用 | fork 后没点启用 |
| 跑了但 401 | Secret 时间戳与 `state.json` 的 `expires_at` | **客户端重启过、令牌已轮换**（最常见）；或新机 `--check` 没过就写了 |
| 本机脚本报找不到凭据 | 客户端是否登录过 | 新机还没启动客户端 / 换了账号没登录 |
| 客户端定位失败 | `WORKBUDDY_EXE` 环境变量 | 装在非标准目录，注册表也没记录 |
| 解密报错 | 客户端版本 | 私有 binding 与版本绑定，升级客户端后重测 `--check` |
| 开机没自动跑 | `%APPDATA%\...\Startup` 下有没有 vbs | 降级失败 / 被安全软件清理 / 上次 `-Uninstall` 留了 `refresh.stop` |
