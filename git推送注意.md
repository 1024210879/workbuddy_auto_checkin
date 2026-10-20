# git 推送注意（本机代理坑）

## 现象

`git push` / `git fetch` 直连 GitHub 时反复失败，报错二选一：

```
fatal: unable to access 'https://github.com/...': Failed to connect to github.com port 443 after 21xxx ms: Couldn't connect to server
fatal: unable to access 'https://github.com/...': Recv failure: Connection was reset
```

但同一时刻 `gh api user` 能正常返回——gh 能通、git 不能通。

## 根因

两层因素叠加：

1. **DNS 污染**：本机把 `github.com` 解析到 `20.205.243.166`，这个 IP 的 443 端口实际不可达
   （`Test-NetConnection github.com -Port 443` 为 False）。真实可达的 IP 是
   `140.82.112.x` ~ `140.82.116.x`、`20.27.177.113` 等。
2. **git 不走系统代理**：系统开着 IE 代理 `127.0.0.1:58309`（注册表
   `HKCU:\...\Internet Settings` 里 `ProxyEnable=1`），但 git 默认只读环境变量
   `HTTP(S)_PROXY` 或自己的 `http.proxy` 配置，**不会**自动继承 IE 代理；
   WinHTTP 层面是直连（`netsh winhttp show proxy` 显示 Direct access）。
   gh 内部对代理的处理与 git 不同，所以同一个网络下 gh 通、git 不通。

## 解决办法

### 临时（每次 push 前，只影响当条命令的进程）

PowerShell：

```powershell
$env:HTTPS_PROXY='http://127.0.0.1:58309'; $env:HTTP_PROXY='http://127.0.0.1:58309'
git push origin main
```

bash（Git Bash / WSL）：

```bash
HTTPS_PROXY=http://127.0.0.1:58309 HTTP_PROXY=http://127.0.0.1:58309 git push origin main
```

### 永久（推荐，只对 github.com 生效，不污染其它 git 主机）

```powershell
git config --global http.https://github.com.proxy http://127.0.0.1:58309
```

撤销：

```powershell
git config --global --unset http.https://github.com.proxy
```

### 注意

- 代理端口 `58309` 来自本机 IE 代理设置（`Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'` 的 `ProxyServer`）。代理工具换端口后这里要同步改。
- 如果代理软件没开，配了永久代理后 push 反而会失败（connection refused），报错会变成 `Failed to connect to 127.0.0.1 port 58309`——这是代理层的问题，不是 GitHub 的问题。
- 不要用「改 hosts 固定 IP」的方式绕 DNS 污染：GitHub 的 IP 会变，写死很快失效，而且 git 走 IP 直连还会遇到 SNI/证书校验问题（实测 `https://140.82.112.3/...` 直接被代理层重置）。
- SSH（`git@github.com`）在 22 端口可达，但本机没有配置 SSH key（`ssh -T git@github.com` 返回 Permission denied），所以 SSH 路线当前不可用，除非先 `gh ssh-key add` 上传公钥。

## 排查顺序备忘

1. `gh api user` —— 通，说明是 git 层的代理/DNS 问题，不是账号或网络整体问题。
2. `Test-NetConnection github.com -Port 443` —— False 则确认 DNS 污染/直连被封。
3. `Get-ItemProperty 'HKCU:\...\Internet Settings'` 拿到当前代理端口。
4. 带 `HTTPS_PROXY` 环境变量重试 push。

## 历史

2026-10-20 首次踩坑：推送 `30eba71`（统一入口 run_refresh.cmd）时，git 直连反复失败，
用 IE 代理 `127.0.0.1:58309` 后一次成功。当时还遇到 non-fast-forward 拒绝，
用 `git rebase origin/main` 解掉（远端历史被 rewrite 过，本地只有一个实质新提交需要重放）。
