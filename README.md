# Buddy 加油站每日自动化（GitHub Actions）

每天一次自动完成 **签到** 与 **派猫猫旅行**，结果推送到飞书。云端 runner 执行，不依赖任何常开设备。

## 为什么需要刷新脚本

云端 runner 没有你的本机登录态，也无法解密 Electron `safeStorage` 保护的凭据——所以 token **不能**在云端现取。做法是：

1. 在你自己的电脑上运行 `refresh_token.py`：读本机登录态 → 调本机客户端运行时解密 → 导出 token；
2. 把它写进仓库 Secret `WB_ACCESS_TOKEN`；
3. Actions 只从 Secret 读取。

明文 token 不进仓库、不进日志、不落临时文件。

## 一次性配置

### 1. 建仓库并加入这两个文件

```
wb_auto.py
refresh_token.py
.github/workflows/daily.yml
```

### 2. 配置 Secret

```bash
# token（由本机脚本直接写入，不经过命令行明文）
python refresh_token.py --gh-repo OWNER/REPO

# 飞书机器人 webhook
gh secret set FEISHU_WEBHOOK --repo OWNER/REPO --body "https://open.feishu.cn/open-apis/bot/v2/hook/xxxxx"
```

也可以手动：本地运行 `python refresh_token.py` 打印 token，再粘进仓库 Settings → Secrets → `WB_ACCESS_TOKEN`。

### 3. 手动触发一次验证

Actions 页签 → 该 workflow → **Run workflow**。

## 本机刷新 token 的时机

token 由客户端签发、有效期约 28 天。出现「认证被拒」时，在本机重跑一次 `refresh_token.py` 即可。

## 行为约定

| 场景 | 行为 |
| --- | --- |
| 今天未签到 | 调领取接口领积分 |
| 今天已签到 | 读状态接口直接汇报，不再重复领取（幂等） |
| 猫猫已到家 | 先领这趟的旅行积分 |
| 猫猫在途中 | 只汇报位置与预计到家时间，不派出新的 |
| 猫猫空闲且今日名额未用完 | 派一趟新的 |
| 今日名额已用完 | 不再派出（读 `daily_limit_reached`，不硬撞接口） |
| 猫猫失败 | 不影响签到结论，猫猫状态单独汇报 |
| 整体成败 | **只看签到**：签到成功即成功 |

## 接口（以实际请求为准，从客户端 `app.asar` 中核对）

```text
POST {endpoint}/v2/billing/meter/checkin-activity-status   查今日签到状态
POST {endpoint}/v2/billing/meter/daily-checkin            领取签到积分

GET  {endpoint}/v2/activity/growth/buddy/travel/status    查猫猫旅行状态
POST {endpoint}/v2/activity/growth/buddy/travel/claim     领已到家的旅行积分
GET  {endpoint}/v2/activity/growth/buddy/travel/config    取可派目的地
POST {endpoint}/v2/activity/growth/buddy/travel/depart    派出新一趟
```

`endpoint` 默认 `https://copilot.tencent.com`，可用 Secret/变量 `WB_ENDPOINT` 覆盖。

所有返回统一是 `{code, msg, data}` 信封，业务字段在 `data` 里，脚本用 `unwrap()` 统一解包。

## 安全说明

- `refresh_token.py` 里的解密助手只含固定代码；加密信封通过 stdin 传入；解密密钥仅存在于客户端子进程内存，用后清零；
- 明文 token 只出现在子进程返回值与最终写入目标，命令行、argv、环境变量、日志均不含明文；
- `wb_auto.py` 打印的所有返回体都过 `masked()` 脱敏，长字符串只留首尾若干字符；
- 写操作只在网络异常时有限重试，靠服务端幂等避免重复提交。

## 常见问题

**飞书没收到卡片** — 检查 `FEISHU_WEBHOOK` 是否配置；脚本会在日志里打印飞书返回的 `code`。

**job 红了但飞书显示签到成功** — 这是刻意的：只有签到未达成才整体判失败，猫猫问题只体现为 warning 与卡片里的猫猫行。