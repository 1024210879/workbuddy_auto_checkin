#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""refresh_token.py —— 在你自己的电脑上运行，把 WorkBuddy 登录态导出成 GitHub Secret。

云端 runner 没有本机登录态，也无法解密 Electron safeStorage 保护的凭据；
因此 token 必须由本机脚本导出，再写入仓库 Secret（绝不进仓库、绝不进日志）。

用法：
    python refresh_token.py                       # 打印 token + 手动配置指引
    python refresh_token.py --gh-repo OWNER/REPO  # 有 gh CLI 时直接写入 Secret
                                                  # 没有 gh 则打印 token + 手动配置指引

多账号（同一个仓库托管多个 WorkBuddy 账号）：
    python refresh_token.py --gh-repo OWNER/REPO --account WORK
    写入 WB_ACCESS_TOKEN_WORK。不带 --account 时仍写 WB_ACCESS_TOKEN（单账号 / 主号）。

手动同步（打开 WorkBuddy 之后跑一次，见桌面「同步 WorkBuddy 令牌」快捷方式）：
    python refresh_token.py --gh-repo OWNER/REPO --ask-account --wait 60
    客户端每次启动都会轮换 accessToken、旧令牌立即失效，所以「手动打开客户端」
    之后必须重跑一次本脚本；--wait 会让它在客户端还没写完凭据时多等一会儿。
    --ask-account 会当场问你要同步哪个账号（回车沿用上次用的），
    省得把某台机器的 id 写死在 .cmd 里。

    可选参数：
      --account ID   把令牌写入 WB_ACCESS_TOKEN_ID（多账号时用来区分）。
                     只允许 A-Z 0-9 _，会统一转成大写。
      --ask-account  没有 --account 时交互式询问账号 id（无控制台则用上次的值）。
      --min-days N   仅在没有历史推送记录时生效：令牌剩余不足 N 天就拒绝推送
                     （默认 3）。有记录时按「谁更新用谁」比较，不看剩余天数。
      --wait SEC     打开客户端后立刻运行时，最多等 SEC 秒直到凭据换新。
      --check        只检查新鲜度，不做任何写入。
      --force        忽略新鲜度判断，强制推送。
      --log PATH     输出追加到日志文件（供静默运行使用，日志中绝不含 token）。

    退出码：0 成功/无需推送；3 令牌不新鲜已跳过；4 令牌已过期；1 其他错误。

（打包成 refresh_token.exe 后用法相同，双击运行等价于无参数形式）

安全约定：
  - 明文 token 只出现在本进程内存与最终那一次目标位置；
  - 命令行参数、环境变量、日志均不含明文 token；
  - 不写临时 token 文件（状态文件只记录过期时间戳与 12 位指纹，不含 token）。
"""

import base64
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

AUTH_TIMEOUT = 30.0
INPUT_LIMIT = 65536
OUTPUT_LIMIT = 65536
TOKEN_RE = re.compile(r"[A-Za-z0-9._~+/-]+=*")

DEFAULT_MIN_DAYS = 3.0        # 无推送记录时，剩余不足这么多天就不再推送
POLL_INTERVAL = 5.0           # --wait 期间轮询凭据文件的间隔
FRESH_WINDOW = 120.0          # 凭据文件在这个秒数内被写过，才认为客户端正在刷新，值得等待
DEFAULT_SECRET = "WB_ACCESS_TOKEN"   # 单账号 / 主号用的 Secret 名
ACCOUNT_RE = re.compile(r"[A-Z0-9_]{1,32}")
EXIT_OK = 0
EXIT_ERROR = 1
EXIT_STALE = 3                # 令牌不新鲜，主动跳过（不是错误，不改写 Secret）
EXIT_EXPIRED = 4              # 令牌已过期


# 固定代码只出现在 argv；加密信封走 stdin，构建材料不出本进程。
# 仅支持 sym-v1 / field / suite 1。
AUTH_HELPER_JS = r"""
'use strict';
const crypto = require('crypto');
const inputLimit = 65536;
const failure = reason => { throw {reason}; };
const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
function base64(value, length) {
  if (typeof value !== 'string' || value.length > inputLimit) failure('INVALID_FORMAT');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.toString('base64') !== value || (length !== undefined && bytes.length !== length))
    failure('INVALID_FORMAT');
  return bytes;
}
function utf8(bytes) {
  const text = bytes.toString('utf8');
  if (!Buffer.from(text, 'utf8').equals(bytes)) failure('INVALID_FORMAT');
  return text;
}
function decode(value) {
  if (!object(value) || Object.keys(value).sort().join(',') !== '$wbEncrypted,envelope' || value.$wbEncrypted !== 1)
    failure('UNSUPPORTED_ENVELOPE');
  let envelope;
  try { envelope = JSON.parse(utf8(base64(value.envelope))); }
  catch (e) { failure(e.reason || 'INVALID_FORMAT'); }
  if (!object(envelope) || !Number.isInteger(envelope.suite)) failure('INVALID_FORMAT');
  if (envelope.suite !== 1) failure('UNSUPPORTED_ENVELOPE');
  if (Object.keys(envelope).sort().join(',') !== 'authTag,ciphertext,keyId,nonce,suite' ||
      typeof envelope.keyId !== 'string' || !/^[0-9a-f]{16}$/.test(envelope.keyId)) failure('INVALID_FORMAT');
  return {keyId: envelope.keyId, nonce: base64(envelope.nonce, 12),
    tag: base64(envelope.authTag, 16), ciphertext: base64(envelope.ciphertext)};
}
function nativeStorage() {
  try {
    const storage = process._linkedBinding('electron_browser_workbuddy_storage');
    if (typeof storage.loggerGet !== 'function') failure('RUNTIME_UNAVAILABLE');
    return storage;
  } catch (_) { failure('RUNTIME_UNAVAILABLE'); }
}
function decrypt(envelope) {
  let payload;
  try { payload = JSON.parse(nativeStorage().loggerGet()); }
  catch (_) { failure('RUNTIME_UNAVAILABLE'); }
  let key;
  let plaintext;
  try {
    if (!object(payload) || payload.version !== 1) failure('RUNTIME_UNAVAILABLE');
    let secret;
    try { secret = base64(payload.atRestSecretKey, 32); }
    catch (_) { failure('RUNTIME_UNAVAILABLE'); }
    const empty = secret.every(b => b === 0);
    secret.fill(0);
    if (empty) failure('RUNTIME_UNAVAILABLE');
    key = crypto.createHash('sha256').update(payload.atRestSecretKey, 'utf8').digest();
    payload = null;
    if (crypto.createHash('sha256').update(key).digest('hex').slice(0, 16) !== envelope.keyId)
      failure('KEY_MISMATCH');
    const lp = s => {
      const bytes = Buffer.from(s, 'utf8');
      const length = Buffer.alloc(4); length.writeUInt32BE(bytes.length);
      return Buffer.concat([length, bytes]);
    };
    const aad = Buffer.concat([Buffer.from('WB-AAD\0', 'ascii'), Buffer.from([1]),
      lp('WBEV1'), lp('sym-v1'), Buffer.from([0, 0, 0, 1]), lp(envelope.keyId), Buffer.from([2, 0, 0])]);
    try {
      const cipher = crypto.createDecipheriv('aes-256-gcm', key, envelope.nonce, {authTagLength: 16});
      cipher.setAAD(aad); cipher.setAuthTag(envelope.tag);
      plaintext = Buffer.concat([cipher.update(envelope.ciphertext), cipher.final()]);
    } catch (_) { failure('DECRYPT_FAILED'); }
    const token = utf8(plaintext);
    if (!token.length || token.length > 32768 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(token))
      failure('INVALID_FORMAT');
    return token;
  } finally {
    if (key) key.fill(0);
    if (plaintext) plaintext.fill(0);
  }
}
let chunks = [], size = 0;
function reply(value) {
  process.stdout.write(JSON.stringify({version: 1, ...value}), () => process.exit(value.ok ? 0 : 1));
}
process.stdin.on('data', chunk => {
  size += chunk.length;
  if (size > inputLimit) reply({ok: false, reason: 'INVALID_FORMAT'});
  else chunks.push(chunk);
});
process.stdin.on('error', () => reply({ok: false, reason: 'HELPER_PROTOCOL'}));
process.stdin.on('end', () => {
  try {
    const request = JSON.parse(utf8(Buffer.concat(chunks))); chunks = [];
    if (!object(request) || request.version !== 1) failure('HELPER_PROTOCOL');
    if (request.operation === 'probe') {
      nativeStorage();
      if (!crypto.getCiphers().includes('aes-256-gcm')) failure('RUNTIME_UNAVAILABLE');
      reply({ok: true, electron: process.versions.electron || 'unknown'});
    } else if (request.operation === 'decrypt') {
      reply({ok: true, accessToken: decrypt(decode(request.value))});
    } else failure('HELPER_PROTOCOL');
  } catch (e) {
    const reasons = ['INVALID_FORMAT','UNSUPPORTED_ENVELOPE','RUNTIME_UNAVAILABLE',
      'KEY_MISMATCH','DECRYPT_FAILED','HELPER_PROTOCOL'];
    reply({ok: false, reason: reasons.includes(e.reason) ? e.reason : 'HELPER_PROTOCOL'});
  }
});
"""


def find_auth_file():
    """按平台探测凭据文件；WORKBUDDY_AUTH_FILE 可覆盖。"""
    override = os.environ.get("WORKBUDDY_AUTH_FILE")
    if override:
        return override if os.path.exists(override) else None
    home = os.path.expanduser("~")
    local = os.environ.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local")
    candidates = [
        os.path.join(local, "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"),
        os.path.join(local, "workbuddy-desktop.info"),
        os.path.join(home, "Library", "Application Support", "workbuddy-desktop.info"),
        os.path.join(home, ".config", "workbuddy-desktop.info"),
        os.path.join(home, ".workbuddy", "auth", "workbuddy-desktop.info"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return None


def find_runtime():
    """定位 WorkBuddy 可执行文件：环境变量 → 常见安装目录 → 注册表。"""
    override = os.environ.get("WORKBUDDY_EXE")
    if override:
        if os.path.isfile(override):
            return os.path.abspath(override)
        raise SystemExit("WORKBUDDY_EXE 指向的文件不存在")
    home = os.path.expanduser("~")
    local = os.environ.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local")
    candidates = [os.path.join(local, "Programs", "WorkBuddy", "WorkBuddy.exe")]
    for name in ("ProgramFiles", "ProgramFiles(x86)"):
        if os.environ.get(name):
            candidates.append(os.path.join(os.environ[name], "WorkBuddy", "WorkBuddy.exe"))
    for path in candidates:
        if os.path.isfile(path):
            return os.path.abspath(path)
    if sys.platform == "win32":
        found = _registry_runtime()
        if found:
            return found
    # 兜底：常见非默认安装位置（含本机实测的 D:\WorkBuddy）
    for root in ("C:/", "D:/", "E:/"):
        p = os.path.join(root, "WorkBuddy", "WorkBuddy.exe")
        if os.path.isfile(p):
            return os.path.abspath(p)
    raise SystemExit("未找到 WorkBuddy 客户端，请设置 WORKBUDDY_EXE 环境变量")


def _registry_runtime():
    """只读取注册表字符串值，绝不解释卸载命令。"""
    try:
        import winreg
    except ImportError:
        return None
    subkey = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        for view in (winreg.KEY_WOW64_64KEY, winreg.KEY_WOW64_32KEY):
            try:
                with winreg.OpenKey(hive, subkey, 0, winreg.KEY_READ | view) as root:
                    for i in range(winreg.QueryInfoKey(root)[0]):
                        try:
                            with winreg.OpenKey(root, winreg.EnumKey(root, i)) as entry:
                                name, _ = winreg.QueryValueEx(entry, "DisplayName")
                                if not isinstance(name, str) or "workbuddy" not in name.lower():
                                    continue
                                icon, _ = winreg.QueryValueEx(entry, "DisplayIcon")
                                if isinstance(icon, str):
                                    path = icon.split(",")[0].strip().strip('"')
                                    if os.path.isfile(path):
                                        return os.path.abspath(path)
                        except OSError:
                            continue
            except OSError:
                continue
    return None


def run_helper(exe, request):
    """所有管道与超时都有界；异常中绝不含捕获的数据。"""
    data = json.dumps(dict(request, version=1), ensure_ascii=True).encode("ascii")
    env = {k: v for k, v in os.environ.items()
           if not k.upper().startswith(("NODE_", "ELECTRON_", "WORKBUDDY_"))}
    env["ELECTRON_RUN_AS_NODE"] = "1"
    proc = subprocess.Popen(
        [exe, "-e", AUTH_HELPER_JS],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=env, shell=False,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    try:
        out, err = proc.communicate(data, timeout=AUTH_TIMEOUT)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise SystemExit("解密助手超时")
    if len(out) > OUTPUT_LIMIT:
        raise SystemExit("解密助手输出超限")
    try:
        reply = json.loads(out.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise SystemExit("解密助手返回无效结果")
    if reply.get("ok") is not True:
        raise SystemExit("解密失败：" + str(reply.get("reason", "UNKNOWN")))
    return reply


def load_session(path):
    """读取凭据文件。

    开机时段客户端可能正在写这个文件，Windows 下会短暂报拒绝访问；
    也可能是读到写了一半的 JSON。两种情况都靠短退避重试解决，
    避免计划任务在「刚好撞上客户端写入」时直接崩掉。
    """
    last = None
    for attempt in range(6):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (PermissionError, ValueError) as e:
            last = e
            time.sleep(0.4 * (attempt + 1))
    raise SystemExit("读取凭据文件失败（客户端可能正占用）：%s" % last)


def normalize_repo(value):
    """接受 OWNER/REPO 或 .git 后缀形式，统一成 OWNER/REPO 供 gh 与 URL 使用。"""
    repo = value.strip().rstrip("/")
    if repo.endswith(".git"):
        repo = repo[: -len(".git")]
    if repo.count("/") != 1 or not all(repo.split("/")):
        raise SystemExit("仓库格式应为 OWNER/REPO（例如 FXmonkey/workbuddy_auto），收到：%s" % value)
    return repo


def normalize_account(value):
    """账号 id 会拼进 Secret 名，只允许字母数字下划线，统一转大写。"""
    account = value.strip().upper()
    if not ACCOUNT_RE.fullmatch(account):
        raise SystemExit(
            "账号 id 只允许字母、数字、下划线，1~32 位（会拼成 WB_ACCESS_TOKEN_<ID>），收到：%s" % value)
    return account


def secret_name(account):
    """账号 → Secret 名。不给账号时沿用单账号时期的 WB_ACCESS_TOKEN。"""
    return DEFAULT_SECRET if not account else DEFAULT_SECRET + "_" + account


class _Tee:
    """把 stdout/stderr 同时写向日志文件与原控制台（有控制台时）。"""

    def __init__(self, file, console=None):
        self.file = file
        self.console = console

    def write(self, text):
        for s in (self.file, self.console):
            if s is None:
                continue
            try:
                s.write(text)
                s.flush()
            except (OSError, ValueError):
                continue
        return len(text)

    def flush(self):
        for s in (self.file, self.console):
            if s is not None:
                try:
                    s.flush()
                except (OSError, ValueError):
                    pass

    def isatty(self):
        return False


def _data_dir():
    local = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), ".workbuddy_auto_checkin")
    return os.path.join(local, "workbuddy_auto_checkin")


def install_log(path):
    """把输出接到日志文件，返回 (日志路径|None, 是否已接管)。

    静默运行（pythonw / 计划任务）时 sys.stdout 为 None，此时 print 会抛
    AttributeError，必须在这里兜住；接管后也保证日志里不会出现明文 token。
    """
    console_out, console_err = sys.stdout, sys.stderr
    if path is None:
        if console_out is not None:
            return None, False
        path = os.path.join(_data_dir(), "refresh.log")   # 无控制台又没指定日志
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        handle = open(path, "a", encoding="utf-8")
    except OSError as e:
        raise SystemExit("无法写日志文件：%s" % e)
    handle.write("\n===== %s =====\n" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    handle.flush()
    sys.stdout = _Tee(handle, console_out)
    sys.stderr = _Tee(handle, console_err)
    return path, True


def parse_args(argv):
    opts = {"gh_repo": None, "min_days": DEFAULT_MIN_DAYS, "check": False,
            "force": False, "log": None, "wait": 0.0, "account": "",
            "ask_account": False}
    numeric = {"--min-days": "min_days", "--wait": "wait"}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--gh-repo", "--log", "--account") or arg in numeric:
            if i + 1 >= len(argv):
                raise SystemExit("参数 %s 缺少取值" % arg)
            value = argv[i + 1]
            i += 2
            if arg == "--gh-repo":
                opts["gh_repo"] = normalize_repo(value)
            elif arg == "--log":
                opts["log"] = value
            elif arg == "--account":
                opts["account"] = normalize_account(value)
            else:
                try:
                    num = float(value)
                except ValueError:
                    raise SystemExit("参数 %s 需要数字，收到：%s" % (arg, value))
                if num < 0:
                    raise SystemExit("参数 %s 不能为负数" % arg)
                opts[numeric[arg]] = num
            continue
        if arg == "--check":
            opts["check"] = True
        elif arg == "--force":
            opts["force"] = True
        elif arg == "--ask-account":
            opts["ask_account"] = True
        else:
            raise SystemExit(
                "未知参数：%s（可用：--gh-repo --account --ask-account --min-days --wait --check --force --log）" % arg)
        i += 1
    return opts


def token_expiry(session):
    """从凭据里取 accessToken 的过期时刻（秒）。取不到返回 None。"""
    value = dig_session(session, "auth", "expiresAt")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value / 1000.0 if value > 1e11 else float(value)   # 客户端写的是毫秒


def dig_session(obj, *keys):
    for k in keys:
        if isinstance(obj, dict) and k in obj:
            obj = obj[k]
        else:
            return None
    return obj


def fmt_time(ts):
    """把秒级时间戳格式化成人看的时间；非法值返回空串。"""
    if isinstance(ts, bool) or not isinstance(ts, (int, float)):
        return ""
    try:
        return datetime.datetime.fromtimestamp(float(ts)).strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return ""


def read_state():
    try:
        with open(os.path.join(_data_dir(), "state.json"), "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def pushed_expiry(secret):
    """该 Secret 上次推送的令牌过期时刻；没有记录返回 None。

    多账号时按 Secret 名分开记，否则两个账号会互相把对方判成「已推送」。
    """
    state = read_state()
    pushed = state.get("pushed")
    if isinstance(pushed, dict):
        entry = pushed.get(secret)
        if isinstance(entry, dict):
            entry = entry.get("expires_at")
        if isinstance(entry, (int, float)) and not isinstance(entry, bool):
            return float(entry)
        return None
    # 兼容单账号时期的旧格式：全局只有一条记录
    legacy = state.get("pushed_expires_at")
    if secret == DEFAULT_SECRET and isinstance(legacy, (int, float)) and not isinstance(legacy, bool):
        return float(legacy)
    return None


def known_accounts():
    """本机已同步过的账号 id（从 state.json 的 Secret 名反推）。"""
    pushed = read_state().get("pushed")
    found = set()
    if isinstance(pushed, dict):
        for name in pushed:
            if name == DEFAULT_SECRET:
                continue
            if name.startswith(DEFAULT_SECRET + "_"):
                found.add(name[len(DEFAULT_SECRET) + 1:])
    return sorted(found)


def ask_account():
    """交互式询问本机账号 id（供桌面「同步 WorkBuddy 令牌」快捷方式使用）。

    回车沿用上次用的账号；输入 - 或直接回车且无历史 = 单账号模式。
    没有控制台（pythonw 静默运行 / stdin 被重定向）时不做提问，返回上次的值。
    """
    state = read_state()
    last = state.get("last_account")
    last = last.strip().upper() if isinstance(last, str) and ACCOUNT_RE.fullmatch(last.strip().upper()) else ""
    known = known_accounts()
    default = last or (known[0] if len(known) == 1 else "")

    print("账号 id 决定写哪个 Secret：WB_ACCESS_TOKEN_<ID>；留空 = 单账号模式（WB_ACCESS_TOKEN）")
    if known:
        print("本机同步过的账号：%s" % "、".join(known))
    elif not default:
        print("本机还没有同步记录，可以填仓库变量 WB_ACCOUNTS 里给这台机器用的那个 id")

    # 没有真正的控制台（计划任务 / 重定向 / pythonw）就别提问：否则会死等输入
    if not (getattr(sys.stdin, "isatty", None) and sys.stdin.isatty()):
        print("[提示] 当前没有可交互的控制台，按默认账号继续：%s" % (default or "单账号模式"))
        return default

    while True:
        if default:
            tip = "本机账号 id [回车沿用上次的 %s，输入 - 表示单账号模式]：" % default
        else:
            tip = "本机账号 id [本机没有记录，回车 = 单账号模式]："
        try:
            raw = input(tip)
        except (EOFError, OSError, RuntimeError):
            print("")
            print("[提示] 没有可用的控制台输入，按默认值继续：%s" % (default or "单账号模式"))
            return default
        raw = (raw or "").strip()
        if raw in ("-", "/", "0"):
            return ""
        if not raw:
            return default
        candidate = raw.upper()
        if ACCOUNT_RE.fullmatch(candidate):
            return candidate
        print("  只能用字母、数字、下划线，1~32 位，请重新输入。")


def mirror_last_account(account):
    """把「上次用的账号」镜像成一行纯文本，供 .cmd 在提问前直接显示。

    .cmd 是 ASCII 写的，也读不了 JSON（cmd 的 for /f 会把逗号、冒号当分隔符），
    所以这里额外落一个 last_account.txt：内容就是账号 id，或 "-" 表示上次是
    单账号模式。只是一个只读镜像，真相仍然是 state.json 的 last_account。
    """
    try:
        os.makedirs(_data_dir(), exist_ok=True)
        path = os.path.join(_data_dir(), "last_account.txt")
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write((account or "-") + "\n")
        os.replace(tmp, path)
    except OSError:
        pass


def remember_account(account):
    """记下本次用的账号，下次提问时作为默认值（只存 id，不存令牌）。"""
    mirror_last_account(account)
    state = read_state()
    if state.get("last_account") == account:
        return
    if account:
        state["last_account"] = account
    else:
        state.pop("last_account", None)
    try:
        os.makedirs(_data_dir(), exist_ok=True)
        with open(os.path.join(_data_dir(), "state.json"), "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=1)
    except OSError:
        pass


def write_state(secret, expires_at, fingerprint=""):
    """只记录「已推送令牌的过期时刻 + 指纹」，不含任何凭据内容。"""
    state = read_state()
    pushed = state.get("pushed")
    if not isinstance(pushed, dict):
        pushed = {}
    entry = {"expires_at": expires_at,
             "pushed_at": datetime.datetime.now().isoformat(timespec="seconds")}
    if fingerprint:
        entry["fp"] = fingerprint
    pushed[secret] = entry
    state["pushed"] = pushed
    state.pop("pushed_expires_at", None)     # 旧格式字段，迁移后不再需要
    state.pop("pushed_at", None)
    try:
        os.makedirs(_data_dir(), exist_ok=True)
        with open(os.path.join(_data_dir(), "state.json"), "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=1)
    except OSError:
        pass


def wait_for_refresh(path, session, seconds, secret):
    """等客户端把令牌换掉——打开 WorkBuddy 后立刻运行本脚本时用。

    客户端启动时会先写旧凭据再刷新，这一刻读文件可能拿到即将作废的那枚。
    但多数时候并没有「正在启动」这回事，白等几十秒很难受，所以先用文件 mtime
    判断：凭据最近两分钟内被写过，才值得等（客户端刚起来）；
    否则直接返回，让后面的闸门判断要不要推送。
    """
    recorded = pushed_expiry(secret)
    before = token_expiry(session)
    base = recorded if recorded is not None else before
    if base is None:
        return session
    if before is not None and before > base + 1:
        return session                      # 已经是新的，不用等
    try:
        age = time.time() - os.stat(path).st_mtime
    except OSError:
        age = None
    if age is None or age > FRESH_WINDOW:
        return session                      # 凭据没刚被写过，不是在启动过程中
    print("凭据刚被写入，等待客户端刷新（最多 %d 秒）…" % int(seconds))
    deadline = time.time() + seconds
    while time.time() < deadline:
        time.sleep(POLL_INTERVAL)
        try:
            fresh = load_session(path)
        except (OSError, ValueError):
            continue
        after = token_expiry(fresh)
        if after is not None and after > base + 1:
            print("检测到客户端已刷新凭据")
            return fresh
    print("等待超时，凭据没有变化")
    return session


def main():
    opts = parse_args(sys.argv[1:])
    if opts["ask_account"] and not opts["account"]:
        opts["account"] = ask_account()
    if opts["account"]:
        remember_account(opts["account"])
    secret = secret_name(opts["account"])
    log_path, _ = install_log(opts["log"])
    if log_path:
        print("日志：%s" % log_path)
    print("目标 Secret：%s%s" % (secret, "（账号 %s）" % opts["account"] if opts["account"] else ""))

    auth_file = find_auth_file()
    if not auth_file:
        raise SystemExit("未找到凭据文件，请设置 WORKBUDDY_AUTH_FILE")
    print("凭据文件：%s" % auth_file)

    session = load_session(auth_file)
    if opts["wait"] > 0:
        session = wait_for_refresh(auth_file, session, opts["wait"], secret)

    # ---- 新鲜度闸门：宁可不写，也不能把坏令牌覆盖进 Secret ----
    # 关键背景：客户端每次启动都会轮换 accessToken，旧令牌立即失效。
    # 所以判断依据不是「还剩几天」，而是「本机这枚是否比 Secret 里的更新」。
    expires_at = token_expiry(session)
    recorded = pushed_expiry(secret)
    when = fmt_time(expires_at)
    if expires_at is None:
        print("[检查] 凭据未提供过期时间，无法判断新鲜度，按原样继续")
    else:
        left = expires_at - time.time()
        if left <= 0:
            print("[过期] 令牌已于 %s 过期（本机超过约 28 天未启动 WorkBuddy 会如此）" % when)
            if not opts["force"]:
                print("       本次不写入 Secret —— 用过期令牌覆盖，只会让定时任务立刻 401。")
                print("       处理：启动 WorkBuddy 客户端（它会自动刷新凭据），再运行本脚本。")
                return EXIT_EXPIRED
            print("       已指定 --force，仍然继续")
        elif recorded is not None and expires_at > recorded + 1:
            print("[更新] 客户端已轮换令牌：本机 %s 到期，Secret 里是 %s 到期"
                  % (when, fmt_time(recorded)))
            print("       旧令牌在轮换后立即失效，必须重推，否则 Actions 一定 401。")
        elif recorded is not None:
            if not opts["force"]:
                print("[跳过] 本机令牌 %s 到期，不比 Secret 里的（%s）更新，无需重复写入"
                      % (when, fmt_time(recorded)))
                return EXIT_OK
            print("       已指定 --force，仍然继续（本机令牌并不比 Secret 里新）")
        elif left < opts["min_days"] * 86400:
            # 没有推送记录时无法比较新旧，只能保守一点：快过期的不要覆盖上去
            print("[不新鲜] 令牌剩余 %.1f 天（%s 到期），低于阈值 %.0f 天"
                  % (left / 86400.0, when, opts["min_days"]))
            if not opts["force"]:
                print("       本次不写入 Secret（没有历史推送记录，不敢确定谁更新）。")
                print("       启动 WorkBuddy 客户端即可自动续期，之后本脚本会重试。")
                return EXIT_STALE
            print("       已指定 --force，仍然继续")
        else:
            print("[检查] 令牌剩余 %.1f 天（%s 到期），首次推送" % (left / 86400.0, when))

    if opts["check"]:
        print("[检查] --check 模式，不做任何写入")
        return EXIT_OK

    # 纯打印模式（无 --gh-repo 或没有 gh）必须能把 token 打出来，
    # 否则想手工复制一次都会被判断逻辑挡掉
    will_push = bool(opts["gh_repo"]) and shutil.which("gh") is not None

    token = dig_session(session, "auth", "accessToken")
    if not token:
        raise SystemExit("凭据文件缺少 accessToken，请先在 WorkBuddy 登录")
    if not isinstance(token, str):
        exe = find_runtime()
        sys.stderr.write("凭据为加密信封，正在通过本机客户端解密…\n")
        token = run_helper(exe, {"operation": "decrypt", "value": token})["accessToken"]

    if not (isinstance(token, str) and TOKEN_RE.fullmatch(token)):
        raise SystemExit("token 格式异常")

    fingerprint = hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]

    # 有 gh 且指定了仓库 → 自动写入；否则统一走「指引 + 起止标记 + token」，
    # 保证无论是终端跑 .py 还是双击 exe，输出结构一致、都能照着做
    if opts["gh_repo"] and shutil.which("gh") is not None:
        # 明文 token 只作为 stdin 传给 gh，不出现在命令行与进程列表中
        proc = subprocess.run(
            ["gh", "secret", "set", secret, "--repo", opts["gh_repo"], "--body", "-"],
            input=token.encode("utf-8"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise SystemExit("写入 GitHub Secret 失败：" + proc.stderr.decode("utf-8", "replace"))
        write_state(secret, expires_at, fingerprint)
        print("已写入 GitHub Secret %s（仓库 %s，令牌指纹 %s）" % (secret, opts["gh_repo"], fingerprint))
        return EXIT_OK

    if opts["gh_repo"]:
        print("\n[提示] 未检测到 GitHub CLI（gh），无法自动写入 Secret。")
        print("       安装：winget install --id GitHub.cli ；然后 gh auth login")

    # 日志模式下绝不落明文 token
    if log_path:
        print("\n[安全] 日志模式不输出明文 token。需要复制 token 时，请在终端直接运行。")
        print("[安全提醒] token 等同登录态，请勿粘贴到聊天、日志或任何第三方站点。",
              file=sys.stderr)
        return EXIT_ERROR

    print("\n请手动配置：")
    print("  1) 复制下方两个标记之间的 token")
    if opts["gh_repo"]:
        print("  2) 打开 https://github.com/%s/settings/secrets/actions/new" % opts["gh_repo"])
        print("  3) Name 填 %s，Secret 粘贴 token，保存" % secret)
        print("如需自动写入，安装 gh CLI（https://cli.github.com/）后执行 gh auth login")
    else:
        print("  2) GitHub Actions 版：你仓库的 Settings → Secrets and variables → Actions，"
             "新建 %s 并粘贴" % secret)
        print("     WPS 金山文档版：「签到自动化」表的 B1 单元格粘贴")
    print("\n----- 以下为 token -----")
    print(token)
    print("----- 以上为 token -----")
    print("\n[安全提醒] token 等同登录态，请勿粘贴到聊天、日志或任何第三方站点。", file=sys.stderr)
    return EXIT_OK


def _pause_if_frozen():
    """打包成 exe 被双击运行时，结束前停一下，让用户来得及复制输出。

    计划任务/重定向场景没有交互终端，此时必须直接返回，否则会一直挂着。
    """
    if not getattr(sys, "frozen", False):
        return
    try:
        if sys.stdin is None or not sys.stdin.isatty():
            return
        input("\n按回车键退出…")
    except (EOFError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        _pause_if_frozen()