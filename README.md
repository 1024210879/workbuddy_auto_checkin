# workbuddy_auto

WorkBuddy「Buddy 加油站」的每日自动化：**签到领积分**、**派猫猫旅行并领回礼物**，结果推送到飞书。

跑在 GitHub Actions 上，按 cron 每天执行一次，不需要任何常开设备。

## 特性

- **云端定时** — 免费 runner + `schedule` 触发，本机关机照常执行
- **一次做两件事** — 签到与成长中心旅行在同一次运行里完成
- **幂等** — 先查状态再决定是否领取；已签不重领，已派不重派
- **结论解耦** — 猫猫模块任何异常都不影响签到结论；整体成败只看签到
- **零明文入库** — 仓库不含任何凭据；token 由本机脚本导出后写入 GitHub Secret

## 工作原理

```text
本机（一次性）                      GitHub                           外部
┌──────────────────┐    gh secret   ┌────────────────────┐
│ refresh_token.py │ ─────────────► │ Secret:            │
│  读登录态 → 解密 │                │  WB_ACCESS_TOKEN   │
└──────────────────┘                │  FEISHU_WEBHOOK    │
                                    └─────────┬──────────┘
                                              │ 每天 cron
                                    ┌─────────▼──────────┐        ┌──────────────┐
                                    │ Actions: wb_auto.py│ ─────► │ copilot.     │
                                    │  签到 / 领奖 / 派出│ ◄───── │ tencent.com  │
                                    └─────────┬──────────┘        └──────────────┘
                                              │ webhook
                                    ┌─────────▼──────────┐
                                    │ 飞书群机器人卡片    │
                                    └────────────────────┘
```

### 为什么 token 必须在本机导出

桌面端把会话写在 `workbuddy-desktop.info` 里，其中 `accessToken` 是 Electron `safeStorage` 保护的
`$wbEncrypted` 信封（AES-256-GCM，密钥由客户端运行时持有）。云端 runner 既没有这份文件，也没有解开它所需的
运行时，因此**无法在云端现取 token**。

`refresh_token.py` 的做法是：读出加密信封 → 以 `ELECTRON_RUN_AS_NODE=1` 起一个 WorkBuddy 子进程 →
把信封通过 stdin 递进去，由客户端自己的运行时解密 → 从 stdout 取回明文 token。解密材料全程不落盘。

## 快速开始

前置：本机装有 WorkBuddy 桌面端并已登录；Python 3.8+；一个飞书自定义机器人 webhook。

```bash
git clone https://github.com/FXmonkey/workbuddy_auto.git
cd workbuddy_auto
```

注入两个 Secret：

```bash
# 有 gh CLI：token 经 stdin 直接写入，不经过命令行明文
python refresh_token.py --gh-repo FXmonkey/workbuddy_auto

# 没有 gh CLI：脚本会打印 token 与手动配置指引，按提示到仓库 Settings → Secrets 添加
# 名称固定为 WB_ACCESS_TOKEN

gh secret set FEISHU_WEBHOOK --repo FXmonkey/workbuddy_auto \
  --body "https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxxxx"
```

手动触发验证：

```bash
gh workflow run daily.yml --repo FXmonkey/workbuddy_auto
```

或在仓库 **Actions → Buddy 加油站每日自动化 → Run workflow**。

## 配置项

### Actions 侧（`wb_auto.py`）

| 变量 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `WB_ACCESS_TOKEN` | 是 | — | 访问令牌。缺失则直接退出（exit 2） |
| `FEISHU_WEBHOOK` | 建议 | — | 飞书自定义机器人地址。缺失则不推送，仅打印日志 |
| `WB_ENDPOINT` | 否 | `https://copilot.tencent.com` | 接口地址 |
| `WB_RESULT_FILE` | 否 | — | 写入 Markdown 汇总表，供 Actions 的 step summary 使用 |

### 本机侧（`refresh_token.py`）

| 变量 | 说明 |
| --- | --- |
| `WORKBUDDY_AUTH_FILE` | 覆盖凭据文件路径。用于非默认安装或凭据位置变动 |
| `WORKBUDDY_EXE` | 覆盖客户端可执行文件路径。自动探测失败时使用 |

凭据文件按 `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info` 探测；
客户端按 `WORKBUDDY_EXE` → `%LOCALAPPDATA%\Programs\WorkBuddy\WorkBuddy.exe` → 常见盘根目录 → 注册表
`DisplayIcon` 的顺序探测。

## 行为矩阵

| 情况 | 行为 | `result` |
| --- | --- | --- |
| 今天未签到 | 调用领取接口 | `CLAIMED` |
| 今天已签到 | 不重复领取，读状态汇报 | `ALREADY` |
| 活动未开启 | 直接汇报，不做写操作 | `INACTIVE` |
| 猫猫已到家 | 先领这趟的旅行积分，再判断派出 | `DEPARTED` / `LIMIT_REACHED` |
| 猫猫在途中 | 汇报位置与预计到家时间，不派出 | `IN_TRIP` |
| 猫猫空闲且名额未用完 | 派出一趟 | `DEPARTED` |
| 今日名额已用完 | 读服务端 `daily_limit_reached`，不派出 | `LIMIT_REACHED` |
| 认证被拒（401/403） | 提示重新运行 `refresh_token.py` | `AUTH` |
| 网络不可达 | 有限重试后汇报，不误报成功 | `NETWORK` |
| 猫猫模块异常 | 捕获后单独汇报，不影响签到 | `ERROR` |
| 旅行状态取值未知 | 原样汇报，不做写操作 | `UNKNOWN_STATE` |
| 领取返回无法识别 | 汇报原始返回，不臆断成功 | `UNKNOWN` |

派出名额的判断读服务端下发的 `daily_limit_reached`，而不是硬撞 `depart` 接口等它报错。

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 签到成功 |
| `1` | 签到未达成（猫猫失败不在此列） |
| `2` | 缺少 `WB_ACCESS_TOKEN` |

workflow 中脚本以 `exit 0` 收尾，只对未完成项发 `::warning::`，因此一次运行显示绿色不代表签到一定成功——
**以日志、step summary 与飞书卡片为准**。

## 接口

均从客户端 `app.asar` 中核对并经线上实测，非网络流传版本。所有响应统一是 `{code, msg, data}` 信封，
业务字段在 `data` 内，脚本用 `unwrap()` 统一解包。

```text
POST /v2/billing/meter/checkin-activity-status   查询今日签到状态
POST /v2/billing/meter/daily-checkin             领取签到积分（已签返回 code 10001）

GET  /v2/activity/growth/buddy/travel/status     查询旅行状态
POST /v2/activity/growth/buddy/travel/claim      领取已到家的旅行积分
GET  /v2/activity/growth/buddy/travel/config     获取可派目的地
POST /v2/activity/growth/buddy/travel/depart     派出一趟
```

时间戳字段（`arrive_at` / `depart_at` / `server_now`）为**秒级**，与毫秒混用会算出错误的剩余时间。

## 项目结构

```text
wb_auto.py                    云端执行主体：签到、领奖、派出、推送
refresh_token.py              本机一次性操作：导出 token / 写入 Secret
.github/workflows/daily.yml   cron 定义与执行步骤
```

## 安全设计

- 仓库内不含任何凭据；token 只存在于 GitHub Secret 与运行时内存
- 解密助手只含固定代码，加密信封走 stdin，不经过 argv；密钥用后清零，不写临时文件
- 明文 token 不进入命令行、环境变量或日志；`--gh-repo` 模式下经 stdin 交给 `gh`
- 所有响应打印前过 `masked()` 脱敏，长字符串仅保留首尾若干字符
- 写操作仅在网络异常时有限重试，依赖服务端幂等避免重复提交
- 建议仓库保持 Private

## 常见问题

**令牌过期** — token 由客户端签发，有效期约 28 天（`expiresIn` 2419200）。日志或飞书出现「认证被拒」时，本机重跑
`python refresh_token.py --gh-repo OWNER/REPO` 覆盖即可。

**Actions 页签看不到 workflow** — 确认 `.github/workflows/daily.yml` 已入库，且仓库的 Actions 功能未被禁用。

**飞书没收到卡片** — 日志中 `[飞书]` 行会打印服务端返回码。`19001` 表示 webhook 地址无效或复制不完整。

**偶发 302** — 高频轮询旅行状态时网关会短暂跳转，请求层已对 3xx 退避重试。按日频执行不会触发。

**非默认安装路径** — 用 `WORKBUDDY_EXE` 指定客户端，用 `WORKBUDDY_AUTH_FILE` 指定凭据文件。

## 已知限制

- 只覆盖签到与猫猫旅行；**不含**断登补签、连登兑换、盲盒、任务领取等成长中心其它玩法
- 依赖客户端私有接口，客户端升级可能改变接口或凭据格式，届时需更新脚本
- 仅支持 `sym-v1` / `suite 1` 格式的加密信封；其它格式会明确返回 `UNSUPPORTED_ENVELOPE` 而非发送无效请求
