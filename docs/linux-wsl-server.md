# 在 Linux / Windows WSL 上运行 Acro Runtime 服务端

Acro 的服务端 `@acro/runtime` 是独立的 Node.js 进程,除 macOS 外也可作为登录用户的
systemd 服务常驻在 Linux 服务器或 Windows WSL 上,长期稳定接受客户端连接。

macOS 服务端用桌面 App(内置 runtime)或 `scripts/install-launchagents.sh`;本文只讲
Linux / WSL。终端字节流、Git、文件与生产操作仍由终端里的 Agent 按项目规则处理,Acro 不解释。

## 一键部署:`acro ssh`

从客户端一条命令搞定「SSH 进目标机 → 装依赖 → 启动 runtime → 取回配对码」,免去下面的手动步骤:

```bash
acro ssh <[user@]host | ssh 别名>            # 装好并打印配对码,你自己配对
acro ssh <target> --pair                     # 顺手完成配对(用配对码里的服务器地址,适合同网段)
acro ssh <target> --pair --endpoint host:8790  # 指定客户端可达的入口(公网 / FRP)后配对
```

- 复用系统 `ssh`(带 `-t` 分配终端),读你的 `~/.ssh/config`、密钥与 agent;认证方式(密钥 / 密码 / passphrase)与平时 `ssh` 一致,需要密码的 `sudo` 也能正常提示。不自研 SSH。
- 幂等:首次会自动装 Node 24、编译工具、拉仓库、`pnpm install`、装并启动 systemd 服务;已装过则 `git pull` 后 **`restart` 加载新代码**。已配对的主机重跑只更新、不再生成配对码。
- 前提:目标机是 Debian / Ubuntu / WSL、当前用户能 `sudo`(交互式跑会提示密码;非交互 / 脚本化跑需 `NOPASSWD`)、能访问仓库(私有仓库需目标机具备 git 访问;或用 `--repo <url>` / `--branch <ref>` 覆盖)。
- 传输不变:配对完成后仍是客户端到服务器 `8790` 的 WebSocket + E2EE;`acro ssh` 只做「装 + 返回配置」,不建隧道。服务器在 NAT 后面时,`--endpoint` 传你的公网 / FRP 入口。

不满足上述前提(非 Debian 系、无 sudo、离线等)时,走下面的手动步骤。

## 能力差异

Linux / WSL 服务端与 macOS 的差别:

| 能力 | Linux / WSL |
|---|---|
| 持久终端、断线重连 | ✅ 原样可用 |
| 文件浏览、内容搜索、Git 状态 / diff | ✅ 原样可用 |
| 监听端口面板 | ✅ 走 `ss`(见前置依赖) |
| 设备配对、多主机连接 | ✅ 原样可用 |
| 浏览器表面 | ⚠️ 装了 Chromium 才可用 |
| iOS 模拟器 | ❌ macOS 专有 |
| Computer Use | ❌ macOS 专有 |

## 前置依赖(目标机一次性)

Ubuntu / Debian 为例:

```bash
# Node.js ≥ 23.6(默认剥离类型,直接运行 .ts,与 macOS 部署一致)
node -v

# pnpm
corepack enable

# node-pty 现编工具链(无 Linux 预编译,须在目标机编译)
sudo apt install -y build-essential python3 git

# 端口面板用 ss(iproute2,通常已自带);实时 cwd 读 /proc,无需 lsof
which ss

# 可选:更快的内容搜索(缺则自动回退 grep,只是慢些、不尊重 .gitignore)
sudo apt install -y ripgrep

# 可选:浏览器表面
npx playwright install --with-deps chromium
```

> Node 低于 23.6 会无法直接加载 `.ts`,请升级 Node。不要在服务单元的 `ExecStart` 里加
> `--experimental-strip-types`——runtime 派生 terminal daemon 时不透传 argv,daemon 收不到会
> 起不来、终端全线失败。只有升级 Node 或 `NODE_OPTIONS` 能同时覆盖 runtime 与 daemon。

## 部署

```bash
git clone https://github.com/leaperone/acro.git
cd acro
pnpm install                       # 现编 node-pty
bash scripts/install-systemd.sh    # 生成 ~/.config/systemd/user/acro-runtime.service

loginctl enable-linger "$USER"     # 无登录会话也保持运行,headless 服务器必需
systemctl --user daemon-reload
systemctl --user enable --now acro-runtime.service
```

runtime 监听 `8790`(`ACRO_PORT` 可改),绑全部接口。状态与配对码落在 `~/.acro`。

## 首次配对

```bash
journalctl --user -u acro-runtime.service -f   # 看启动日志
cat ~/.acro/bootstrap-offer.txt                # 首次启动生成的配对码 acro://pair?c=…
```

把配对码带外传给客户端:桌面端侧边栏「连接服务器」粘贴,或移动端扫码。配对采用访问授权模型,
token 只在 E2EE 信道内认证,服务端只存哈希,授权可随时撤销。

## 远程连接与入口

- **同网段**:配对码自动写入服务器的 LAN 直连地址,客户端就近直连。
- **跨网 / 公网**:Acro 不自研 NAT 穿透。用你自己的 FRP 或反向代理把 `host:port` 暴露出去,
  再把这个入口追加进配对——客户端 `acro endpoints add <host:port>`,或服务端 `device.share`
  的 `extraEndpoints`。所有连接走应用层 E2EE(X25519 + ChaCha20-Poly1305),可安全经过明文公网代理。
- 一台服务器对客户端 = 一个 token + 多个入口,局域网优先、失败自动回退公网,从任何入口连上都是同一设备身份、同一批会话。

## 升级

```bash
cd acro && git pull
pnpm install                                   # 依赖有变才需要
systemctl --user restart acro-runtime.service
```

terminal daemon 是 runtime 派生的独立 detached 进程(单元用 `KillMode=process`),`restart`
只重启 runtime 主进程,**正在跑的终端会话保住,客户端自动重连**。仅当 `git pull` 改到了 daemon
自身代码、需要加载新 daemon 时,才在会话收尾后重启 daemon(设置里的「重启终端服务」= `daemon.restart`)
——那会丢所有会话。

## Windows WSL 特别说明

- **启用 systemd**:`/etc/wsl.conf` 加

  ```ini
  [boot]
  systemd=true
  ```

  然后在 Windows 侧 `wsl --shutdown` 重启 WSL。较新版本 WSL 默认已开。

- **网络**:WSL2 是 NAT 网络,Windows 主机以外的设备连不到 WSL 的内网 IP。三选一:
  - 客户端就跑在同一台 Windows 上,走 `localhost` 转发;
  - 用 FRP / 公网代理(同「跨网」);
  - Windows 侧 `netsh interface portproxy` 把 Windows 端口转发到 WSL 的 `8790`。

## 排查

| 现象 | 排查 |
|---|---|
| 终端创建失败 / `pty.spawn` 报错 | 确认 `$SHELL` 或 `/bin/bash` 存在;确认 `pnpm install` 时 node-pty 编译无 gyp 报错(装了 `build-essential python3`) |
| 端口面板空白 | 确认 `ss` 存在(`iproute2`);非 root 只看得到本用户的 socket,与 macOS 的 lsof 同限制 |
| 客户端连不上 | 确认配对码里的入口可达;跨网需自己配公网入口(见上) |
| 浏览器表面打不开 | `npx playwright install --with-deps chromium`;确认 `chrome-linux/chrome` 或系统 `chromium` 存在 |
| 看完整日志 | `journalctl --user -u acro-runtime.service -e` |
