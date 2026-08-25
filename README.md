# dsh-lan-access

> DeepSeek Harness (dsh) 局域网访问插件 — 让手机浏览器在**家庭可信内网**完整操控 DSH Web GUI
> LAN-access plugin for DeepSeek Harness — full control of the DSH Web GUI from a phone browser on your **trusted home network**.

[中文](#中文) | [English](#english)

---

## 中文

### 这是什么

> **兼容性**：本插件通过 DSH 官方插件机制（bundle patch 层 + `webServer.tapIndex`）工作，
> 适用于 **DSH web profile**（实测版本：harness v0.18.x / `@deepseek-ai/*` 0.1.1-rc.2）。
> 已在本机 `dsh web` 完整验证：webserver 绑定 `0.0.0.0`、`/api` 信任篱笆放行局域网、
> 页面注入 shim 均生效。

`dsh-lan-access` 是一个 **dsh 插件（bundle 层）**，解决两个官方限制，实现手机端与电脑端一致的完整操控能力（发指令、审批权限弹窗、查看编译日志）：

1. **绕过 host 绑定限制**：官方 `dsh web` 出于安全原因在 CLI 硬编码拒绝
   `--host 0.0.0.0`（见 `dsh-web-app/lib/startup.js`）。本插件在官方支持的**组合
   （composition）层**把 `webserver` 行的 `host` 覆盖为 `0.0.0.0`，让服务器监听所有网卡；
   `--port` 参数仍生效。
2. **修复安全上下文导致的网页接口报错**：手机浏览器经 `http://<局域网IP>:3080` 访问时处于
   **非安全上下文**，`crypto.randomUUID()` 是 `undefined`，而 DSH 客户端 `mintRpcId()`
   直接调用它（见 [deepseek-harness discussion #4209](https://github.com/deepseek-ai/deepseek-harness/discussions/4209)），
   导致整个 RPC 层崩溃。本插件向每个 `index.html` 注入 shim，用 `crypto.getRandomValues()`
   兜底实现 UUID v4（原生存在时不覆盖）。
3. **信任篱笆自动放行**：绑到 `0.0.0.0` 后，dsh 自带 `web-runtime` 会自动把本机所有非内网
   IPv4 加入 `/api` browser-trust 篱笆的 `trustedHosts`，手机请求无需额外 `--trusted-host`。

### 安装

方式 A — 从 git 托管仓库安装（推荐，官方 `dsh plugin` 机制，需 pnpm）：

```bash
# GitHub 托管（本仓库）
dsh plugin --profile web add github:ZnFr60/dsh-lan-access#main
# Gitee 托管（镜像）
dsh plugin --profile web add git+https://gitee.com/mnrf/dsh-lan-access.git
```

方式 B — 本地 link 安装（开发/内网）：

```bash
git clone https://gitee.com/mnrf/dsh-lan-access.git
dsh plugin --profile web add link:/绝对/路径/dsh-lan-access
```

方式 C — npm 包安装（发布到 npm 后）：

```bash
dsh plugin --profile web add dsh-lan-access
```

> 需要 pnpm：`corepack enable` 或参考 [pnpm 安装](https://pnpm.io/installation)。

安装完成后**重启 dsh web**：

```bash
dsh web --no-open
```

### 使用方法（Usage）

**适用对象**：本插件是 **web profile 专用**插件，请务必安装到 `--profile web`。
（它需要 web profile 里的 `webserver` 行，若装进无 web 层的通用 profile 会提示
`entry "webserver" not found`，属预期警告，并非装错。）

**前置条件**
- 已安装 DSH 并可用 `dsh web`；
- 已安装 [pnpm](https://pnpm.io/installation)（`dsh plugin` 依赖，`corepack enable` 即可）。

**完整安装步骤**

```bash
# 1) 安装插件到 web profile（git 托管 / npm / 本地 link 三选一）
dsh plugin --profile web add github:ZnFr60/dsh-lan-access#main   # GitHub
# 或: dsh plugin --profile web add git+https://gitee.com/mnrf/dsh-lan-access.git  # Gitee
# 或: dsh plugin --profile web add dsh-lan-access                                 # npm(发布后)
# 或(本地开发): dsh plugin --profile web add link:/绝对/路径/dsh-lan-access

# 2) 重启 web 使插件生效
dsh web --no-open
```

**验证生效**

```bash
# ① 组合配置：webserver.host 应为 0.0.0.0，且出现 lan-access 行
dsh --profile web --dump-config

# ② 页面 HTML 应含 randomUUID shim（说明安全上下文修复已注入）
curl -s http://127.0.0.1:3080/ | grep -o "randomUUID"

# ③ 手机访问（局域网 IP 换成你的）：
#     http://<你的局域网IPv4>:3080
#     应能完整操作：发指令、审批权限弹窗、查看编译日志，与电脑端一致
```

**卸载**

```bash
dsh plugin --profile web remove dsh-lan-access
# 然后重启 dsh web 即恢复默认回环访问
```

### 手机访问地址

- 服务器本机：`http://127.0.0.1:3080`
- 局域网：`http://<局域网IPv4>:3080`（手机与电脑连同一路由器/交换机、同网段）

### 卸载

```bash
dsh plugin --profile web remove dsh-lan-access
# 然后重启 dsh web
```

### 原理（如何兼容 DeepSeek Harness）

`dsh` 用 profile + bundle patch 层组合应用。`package.json` 声明
`dsh.bundle.patch: "./cordis.patch.yml"`，`dsh plugin add` 会把它识别为 **profile 层**
并自动并入 `dsh.profile.bundles`。`cordis.patch.yml`：

```yaml
- id: webserver
  config:
    host: '0.0.0.0'
    port: !!js ctx.webStartup.port ?? 3080
- insert:
    - id: lan-access
      name: 'dsh-lan-access'
```

`lib/index.js` 用 `webServer.tapIndex()` 向每个 index.html 注入 shim（在 app 模块
执行前运行，见 `index.html` 的 `<head>` 与 `type="module"` 延迟执行特性）。

### 文件结构

```
dsh-lan-access/
├── package.json          # 声明 dsh.bundle.patch，dsh 插件清单
├── cordis.patch.yml      # bundle patch：覆盖 webserver host + 挂载 lan-access 行
├── lib/
│   ├── index.js          # 插件主体：注入 randomUUID shim、打印 LAN URL
│   └── index.d.ts        # 类型声明
├── LICENSE               # MIT
└── README.md
```

### 安全注意事项

- 仅监听 `0.0.0.0`；**不要**配置任何端口转发、隧道或公网绑定。
- 建议配合防火墙只放行局域网网段（示例，Windows 以管理员执行）：
  ```powershell
  netsh advfirewall firewall add rule name="dsh-lan-3080" dir=in action=allow protocol=TCP localport=3080 remoteip=LocalSubnet
  ```
- `/api` 信任篱笆仍会拒绝非受信 Host（DNS 重绑定防护保持有效）。

---

## English

### What it does

> **Compatibility**: works through the official DSH plugin mechanism (bundle patch
> layer + `webServer.tapIndex`) for the **DSH web profile** (verified on harness
> v0.18.x / `@deepseek-ai/*` 0.1.1-rc.2): webserver binds `0.0.0.0`, the `/api` trust
> fence accepts LAN hosts, and the page ships the shim.

`dsh-lan-access` is a **dsh bundle plugin** that unlocks two official limits so a
phone browser on your trusted home network can fully operate the DSH Web GUI
(send commands, approve permission prompts, read build logs) exactly like the desktop:

1. **Bypass the host-bind guard**: the official `dsh web` CLI hard-rejects
   `--host 0.0.0.0` for safety. This plugin overrides the `webserver` row's `host`
   to `0.0.0.0` at the **supported composition layer**; `--port` still works.
2. **Fix the secure-context crash**: on plain HTTP (`http://<lan-ip>:3080`) the
   browser is a non-secure context where `crypto.randomUUID()` is `undefined`.
   DSH's `mintRpcId()` calls it directly ([discussion #4209](https://github.com/deepseek-ai/deepseek-harness/discussions/4209)),
   breaking the whole RPC layer. This plugin injects a shim into every `index.html`
   that polyfills UUID v4 from `crypto.getRandomValues()` (native is left untouched).
3. **Trust fence auto-allow**: binding `0.0.0.0` makes dsh's own `web-runtime` add all
   local IPv4 literals to the `/api` browser-trust `trustedHosts`, so no extra
   `--trusted-host` is needed.

### Install

> **Target**: a **web-profile** plugin — install into `--profile web`. It needs the
> `webserver` row that only the web profile (via `dsh-web-app`) provides; installing
> into a generic profile prints `entry "webserver" not found`, which is expected.

Requires [pnpm](https://pnpm.io/installation). From this repo (official `dsh plugin` mechanism):

```bash
# GitHub-hosted (this repo)
dsh plugin --profile web add github:ZnFr60/dsh-lan-access#main
# Gitee-hosted (mirror)
dsh plugin --profile web add git+https://gitee.com/mnrf/dsh-lan-access.git
# npm (after publishing)
# dsh plugin --profile web add dsh-lan-access
# local link (dev)
# dsh plugin --profile web add link:/abs/path/dsh-lan-access
```

Restart the web server after installing:

```bash
dsh web --no-open
```

### Usage / Verify

```bash
# 1) composition: webserver.host should be 0.0.0.0 and a lan-access row present
dsh --profile web --dump-config

# 2) index.html should contain the randomUUID shim
curl -s http://127.0.0.1:3080/ | grep -o "randomUUID"

# 3) open from your phone: http://<your-lan-ipv4>:3080
#    full control: send commands, approve permission prompts, read build logs
```

### Phone URL

- Local server: `http://127.0.0.1:3080`
- LAN: `http://<your-lan-ipv4>:3080` (phone and computer on the same LAN/subnet)

### Uninstall

```bash
dsh plugin --profile web remove dsh-lan-access
```

### Security

- Binds `0.0.0.0` only; **no** port forwarding / tunnel / public exposure.
- Consider a firewall rule scoped to the local subnet (example above).
- The `/api` trust fence still rejects untrusted Hosts (DNS-rebinding protection stays on).

## License

[MIT](LICENSE)
