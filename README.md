# OpenWrt sing-box eBPF

面向 OpenWrt / iStoreOS 的 reF1nd sing-box 管理脚本，提供 SSH 菜单、procd 服务、本机 eBPF、LAN IPv4 TProxy、认证 HTTP/SOCKS5 入口及自定义目的路由。

**公开仓库：** [fsyllkn/openwrt-singbox-ebpf](https://github.com/fsyllkn/openwrt-singbox-ebpf)，默认分支 `main`。默认在线安装和压缩包源码更新使用本仓库，无需 GitHub Token，也不要求安装 Git；已有 Git 工作树沿用其配置的远程与分支，见“在线更新”。

本仓库包含通用配置和完整的本地 Provider 样例。**新装可以先启动服务、查看面板和示例节点，再逐项填写自己的上游。** 新装使用分文件配置：用户维护 Provider、入站、出站及路由例外，项目维护 DNS 和基础分流策略。样例没有真实订阅、可用代理节点或内置账号；服务运行中不代表已经具备代理上网能力。已有单文件配置继续可用，不会被自动拆分。

## 1. 支持范围

| 项目 | 支持与要求 |
| --- | --- |
| 系统 | OpenWrt / iStoreOS、procd、`opkg` 或 `apk` |
| 自动下载核心 | Linux `x86_64/amd64`、`aarch64/arm64`，OpenWrt 使用 musl 版本 |
| 本机透明代理 | reF1nd eBPF local；cgroup 数据平面需要固件实际支持 cgroup v2 / BPF |
| LAN 网关 | nftables TProxy，接管选定 LAN 接口和源网段的 IPv4 TCP/UDP；需 `ip-full`、nft 及固件 TProxy 能力 |
| 显式代理 | HTTP/SOCKS5 mixed 入站，可配置 LAN 地址和认证 |
| 网络拓扑 | 单网口旁路由或独立 LAN/WAN；不要求接口名为 `br-lan`，不假定掩码为 `/24` |

脚本不会自动更换接管模式来绕过固件限制。MIPS、32 位 ARM 等没有本项目已配置的安装包时会提前报错。LAN IPv4 TProxy 不等于已经接管客户端 IPv6；真实转发、DNS 和客户端行为仍需在设备上验证。

## 2. 获取源码并打开菜单

### 已经克隆或解压了仓库

在你实际下载、克隆或解压得到的仓库目录执行：

```sh
sh ./quick-install.sh
```

脚本直接使用自己所在的完整源码目录，注册 `sb` 并打开菜单。仓库放在哪个目录，就从哪个目录使用；不会自动复制到另一个预设位置。也可以在其他工作目录通过 `sh '/实际的源码目录/quick-install.sh'` 启动。

如果旧版引导脚本在普通目录下误报 `Source directory must not contain control characters or line breaks.`，请在实际源码目录更新引导脚本后重试：

```sh
cd '/实际的源码目录' &&
bootstrap_tmp=$(mktemp ./quick-install.sh.XXXXXX) &&
wget -O "$bootstrap_tmp" https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh &&
sh -n "$bootstrap_tmp" &&
mv -f "$bootstrap_tmp" ./quick-install.sh &&
sh ./quick-install.sh
```

这是旧校验依赖 BusyBox 可选 `tr` 字符类别支持造成的误判；新版使用 shell 自身的路径校验，无需移动仓库或安装 GNU 工具。以上命令仅替换引导脚本并打开菜单。也可在电脑上下载新版 `quick-install.sh`，上传覆盖源码目录中的同名文件，再执行 `sh ./quick-install.sh`。

### 尚未下载源码：在线引导

先在 OpenWrt SSH 中进入希望保存项目的持久目录，再执行下面的命令。`/tmp/sb-openwrt.sh` 只是临时引导脚本；没有现成仓库时，源码会准备在**当前工作目录的 `openwrt-singbox-ebpf` 子目录**。当前工作目录已经是完整仓库时，则原地使用：

```sh
wget -O /tmp/sb-openwrt.sh https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh &&
sh /tmp/sb-openwrt.sh
```

已有 curl 时也可使用：

```sh
curl -fL https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh -o /tmp/sb-openwrt.sh &&
sh /tmp/sb-openwrt.sh
```

引导脚本仅准备源码和注册 `sb` 快捷命令，随后打开菜单。进入 **5 安装与更新 → 1 安装/修复核心服务** 才安装依赖、核心及服务。**首次安装不立即启动服务，但会启用开机启动；修复已有安装可能更新核心并重启正在运行的服务。** 重复打开 `sb` 不会自动联网更新。

源码位置按实际调用方式确定：

| 调用方式 | 使用的源码目录 |
| --- | --- |
| 设置了 `SB_INSTALL_SOURCE_DIR` | 使用显式指定的绝对路径作为目标 |
| 使用 `--source DIRECTORY`，未指定目标 | 原地使用该源码目录 |
| 运行完整仓库中的 `quick-install.sh` | 使用脚本所在的真实仓库目录 |
| 运行单独下载的引导脚本，当前目录是完整仓库 | 使用当前仓库目录 |
| 运行单独的引导脚本，当前目录没有仓库 | 在当前目录下准备 `openwrt-singbox-ebpf` 子目录 |

路径支持中文和空格；在命令中引用路径时请加引号。`SB_INSTALL_SOURCE_DIR` 可用于明确选择另一个目标位置，已有源码通常不需要设置它。`--archive` 和 `--update` 沿用同一套位置选择规则，不另行选择固定目录。

源码目录用于下载和更新项目；服务目录由 `SH_SINGBOX_HOME` 或 UCI 的 `sing-box.main.service_dir` 确定，默认是 `/opt/sing-box`。两者应使用不同目录；安装器会在改动软件包和服务之前拒绝原地自复制。安装完成后的配置初始化、核心更新使用服务目录 `scripts/` 中的配套工具。菜单和其他工具各自解析本次运行所需的脚本位置，避免继承另一个源码目录的旧路径；源码归档中的 Bash 脚本只需可读，不要求预先添加执行权限。

### 通过本地或局域网 HTTP 代理

首次下载脚本也必须经过代理时：

```sh
download_proxy='http://127.0.0.1:7890'
curl -fL --proxy "$download_proxy" --noproxy '' \
  https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh -o /tmp/sb-openwrt.sh &&
SB_DOWNLOAD_MODE=http SB_HTTP_PROXY="$download_proxy" sh /tmp/sb-openwrt.sh
```

将地址改为当前设备可达的 HTTP 代理。上面的变量只用于本次命令及其子菜单；长期设置使用 **安装与更新 → 设置下载代理**。

HTTPS 资源经过 HTTP 代理需要客户端支持 CONNECT。脚本优先使用 curl，也支持 GNU Wget；OpenWrt 的 BusyBox wget / uclient-fetch 不作为该模式的替代客户端。缺少 curl 时，先通过可用的软件源安装 curl，或使用下一种 GitHub 下载代理/离线方式准备项目。脚本不会因 HTTP 代理失败而回退直连。

### 通过公开 GitHub 下载代理

以下前缀仅为格式示例，可替换成你信任且可用的服务：

```sh
github_proxy='https://ghfast.top'
wget -O /tmp/sb-openwrt.sh "$github_proxy/https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh" &&
SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY="$github_proxy" sh /tmp/sb-openwrt.sh
```

已下载脚本时，可直接传参数；以下三条任选一条，不要依次全部执行：

```sh
sh /tmp/sb-openwrt.sh --http-proxy http://127.0.0.1:7890
sh /tmp/sb-openwrt.sh --github-proxy https://ghfast.top/
sh /tmp/sb-openwrt.sh --direct
```

一次选择一种下载方式。GitHub 下载前缀用于公开的 GitHub 源码和资源，代理服务能够看到这些资源请求；使用可信服务。订阅、运行流量和本地控制 API 不使用此下载前缀。

### 离线准备源码

在能下载的电脑上准备本仓库 `main` 分支的 ZIP 或 TAR.GZ，以及单独的 `quick-install.sh`。将两者上传到设备，把引导脚本保存为 `/tmp/sb-openwrt.sh`；例如 ZIP 上传为 `/tmp/openwrt-singbox-ebpf-main.zip`。进入希望保存源码的持久目录后执行：

```sh
sh /tmp/sb-openwrt.sh --archive /tmp/openwrt-singbox-ebpf-main.zip
```

ZIP 需要 unzip，TAR.GZ 可直接使用 tar。也可从已经解压的源码目录直接运行 `sh ./quick-install.sh`，或通过单独的引导脚本指定现成源码；未设置另一个目标目录时会原地使用：

```sh
sh /tmp/sb-openwrt.sh --source '/实际的源码目录'
```

这一步只离线准备源码并打开菜单。**完整安装仍需要取得软件包、核心、WebUI 和规则集；上传源码压缩包不等于准备了全部离线安装资源。** 离线准备源码和已有安装的 `--scripts-only` 部署不要求下载代理可用。

## 3. 统一下载代理设置

运行 `sb`，选择 **安装与更新 → 设置下载代理**。可选择默认下载、HTTP 代理、GitHub 下载代理前缀。输入 URL 不回显；保存到 UCI，配置文件权限为 `0600`。设置后，本菜单后续操作使用新设置。

也可使用配置工具。下列是独立操作，按需要选择一项执行；路径以默认运行目录为例，自定义目录请相应替换：

| 操作 | 命令 |
| --- | --- |
| 查看设置 | `sh /opt/sing-box/scripts/configure-download.sh show` |
| 使用默认下载 | `sh /opt/sing-box/scripts/configure-download.sh set direct` |
| 使用 HTTP 代理 | `sh /opt/sing-box/scripts/configure-download.sh set http http://127.0.0.1:7890` |
| 使用 GitHub 下载前缀 | `sh /opt/sing-box/scripts/configure-download.sh set github https://ghfast.top/` |
| 清除持久设置 | `sh /opt/sing-box/scripts/configure-download.sh clear` |

安装前工具位于源码的 `scripts/configure-download.sh`。含认证信息的代理优先通过菜单输入，或使用 `set http --stdin`，避免 URL 进入命令历史。状态显示会遮蔽认证信息。

| 选择 | 适用范围 |
| --- | --- |
| 默认 `direct` | 不添加项目代理，保留标准系统 `http_proxy` / `https_proxy` 等环境设置 |
| HTTP `http` | 项目下载；包管理器及 Git 更新仅在对应子进程中接收代理环境，不写入 sing-box 的代理流量配置 |
| GitHub `github` | 为 `github.com`、`raw.githubusercontent.com`、`codeload.github.com` 的公开下载 URL 添加指定前缀 |

GitHub 前缀不用于系统软件源、其他网站、本地 Clash API 或订阅地址。`api.github.com` 发布元数据仍走默认网络；固定默认核心不需要这项 API 查询，更新其他版本时需要 API 可达或选择 HTTP 代理。Git 工作树的 `git pull` 使用默认网络或 HTTP 代理；GitHub 下载前缀用于无 Git 的压缩包更新。

优先级：命令行参数设置的本次环境覆盖 > `SB_DOWNLOAD_MODE` / `SB_HTTP_PROXY` / `SB_GITHUB_PROXY` > UCI > 默认方式。单独设置一个代理 URL 环境变量可推断对应模式；同时设置两个 URL 时应明确指定模式。

UCI 项为 `sing-box.download.mode`、`sing-box.download.http_proxy`、`sing-box.download.github_proxy`。共享下载工具覆盖源码压缩包、核心压缩包、WebUI 和规则集，不再自动尝试隐藏的第三方下载代理。核心仍按对应版本验证 SHA256；下载失败保留已有完整文件并返回错误。curl 使用总时限；wget 可用 `timeout` 时有总时限，否则使用客户端请求超时。

三份通用配置为内置远程规则集设置了 `initial_path: "geo/<tag>.srs"`。核心没有有效缓存时，首次启动可使用安装器已通过所选代理下载的文件，避免预下载完成后仍必须同步直连 GitHub。核心缓存优先于这份启动备用文件。已有单文件配置不会自动添加 `initial_path`；分文件模式的固定 DNS/路由策略随项目模板更新，经配置生成和校验后写入运行 JSON。

核心后台刷新规则集和订阅时，不读取此 UCI 下载设置：Provider 的下载出站可在 `providers.json` 中用 `http_client.detour` 设置；内置远程规则集的 `download_detour` 属于固定路由策略，分文件模式不能通过 `routing.json` 或 `settings.json` 覆盖。需要自定义这些规则集的后台下载出站时，应先切回单文件模式，再修改实际运行配置；不要直接编辑分文件模式的生成 JSON。

## 4. 第一次配置与启动

### 先确认服务与面板可以启动

选择 **5 安装与更新 → 1 安装/修复核心服务**。全新安装（既无运行 JSON，也无配置分片）时，安装器会准备用户配置分文件、生成完整运行 JSON，并初始化两份非空的本地 Provider，不需要先填写订阅 URL。首次安装不会立即启动服务；在固件支持相应 eBPF 能力、安装资源齐全后，可以执行：

```sh
sbctl config &&
sbctl preflight &&
sbctl start &&
sbctl status
```

Clash API 默认只监听本机 `127.0.0.1:9090`。在电脑上用实际 OpenWrt 地址建立 SSH 转发，然后访问 `http://127.0.0.1:19090/ui/`：

```sh
ssh -L 19090:127.0.0.1:9090 root@OPENWRT_IP
```

面板中能看到 `xboard/SAMPLE-XBOARD-REPLACE-ME`、`local/SAMPLE-LOCAL-REPLACE-ME` 等节点。它们只用于确认 Provider 和 selector 已加载，未提供真实代理；默认关闭示例节点的自动健康检查。保持客户端原有网关/DNS，填写真实节点并验证后再接入 LAN 客户端。

默认模板已开启本机 eBPF。占位上游尚不可用时，**OpenWrt 本机命中 `proxy` / `ai` 的请求也会失败**；只想确认面板能打开时，试运行后可执行 `sbctl stop`，填好真实上游再启动。安装会启用开机启动，若暂时不希望设备重启后加载未完成的配置，可执行 `/etc/init.d/sing-box disable`，配置完成后再用 `/etc/init.d/sing-box enable` 恢复。

### 样例文件与本地引用

| 仓库中的公开样例 | 新建配置时生成的运行文件 | 用途 |
| --- | --- | --- |
| `examples/xboard.sample.json` | `<运行目录>/providers/xboard.json` | 示例订阅节点文件，默认以 local Provider 加载 |
| `examples/local.sample.json` | `<运行目录>/providers/local.json` | 手工节点或 X-Tunnel 导出文件的本地引用示例 |
| `examples/http-provider.sample.json` | 不自动启用 | 填写真实 URL 后，将同名 `xboard` Provider 切换成 remote |

配置中的 `providers/xboard.json`、`providers/local.json` 是相对于 **sing-box 运行目录** 的路径，默认在 `/opt/sing-box` 下；它们不相对于 JSON 所在的 `config/` 目录。安装后的 `.sample.json` 也会保留，便于查阅格式。`provider.template.json` 提供同样可被核心解析的非空本地节点样例。

`config/config.json` 与 `config/config.template.json` 是相同的公开起始配置，包含：

- 两个 `type: "local"` Provider，引用安装器准备好的本地文件，不请求虚拟订阅地址。
- `configure-your-proxy` 是待配置的 `127.0.0.1:1080` SOCKS 出站，请替换成实际节点，或确认该地址已经有可信 SOCKS 服务。
- `proxy` 同时列出本地 Provider 的节点，并保留静态 `configure-your-proxy` 默认项；`ai` 初始跟随 `proxy`，没有隐式 `direct` 兜底。
- mixed 和 Clash API 初始仅监听回环地址；LAN 入口通过菜单按实际设备设置。
- 新模板不预置设备专属 UID。

### 再填写真实节点或订阅

手工节点/X-Tunnel：编辑运行目录中的 `providers/local.json`，或在 `config/config.d/providers.json` 中把 `local` Provider 的 `path` 改成实际导出路径。文件需至少包含一个核心支持的代理节点。**配置与隐私 → 编辑配置** 可以选择要编辑的配置部分；已有单文件模式仍编辑完整 JSON。重新加载本地 Provider 或重启后，在面板的 `proxy` 组选择真实的 `local/<节点标签>`。

HTTP 订阅：参考 [HTTP 片段](examples/http-provider.sample.json)，将 `example.invalid` URL 换成自己的真实地址，再替换 `config/config.d/providers.json` 里同名的 `xboard` local Provider，保留另一个 `local` Provider；单文件模式在完整 JSON 中修改。这个片段不是完整配置，不能直接作为 `sbctl import-config` 的输入。默认示例使用 `User-Agent: clash.meta`，省略 `http_client.detour`，通过核心默认拨号器下载；如果订阅必须经过代理，再把 `detour` 设为已配置且可用的代理出站标签。不要指向尚未配置的占位节点，也不要将它设为没有拨号选项的 `direct` 出站。

切换成 remote 后，现有的新鲜 `xboard.json` 缓存可能暂时仍显示示例节点；在面板 Provider 页面手动更新 `xboard`，待真实节点出现后再选择。`path` 是可被订阅刷新覆盖的缓存，自己的手工节点应放在独立的 `local.json` 中。不要为了开启订阅而同时保留两个同名 Provider。

固定核心启动时先建立 selector 静态成员，再加载 Provider。保留静态默认项，在面板选择动态 Provider 节点并由缓存保存；不要把 `xboard/<节点标签>` 直接填入初始 `outbounds` 或 `default`，以免产生启动期找不到节点的错误。字段与合并方法见 [Provider 说明](providers/README.md)。

配置真实上游后，在 **3 LAN透明网关设置** 中设置需要的 HTTP/SOCKS5 入口或 LAN 透明网关，随后预检、重启并在客户端验证。这些工具在分文件模式下会把修改写回 `inbounds.json`，后续生成配置时保留。安装或更新不会用公开起始配置或样例替换用户的节点、订阅缓存和自定义配置部分。

使用 X-Tunnel 时，先让其核心以专用的非 root 账号运行，再进入 **6 诊断与维护 → 2 对齐 X-Tunnel eBPF 进程 UID**。工具读取实际进程 UID，不要求固定数值；若进程仍含 root UID，或 real/effective/saved/fs UID 不一致，会要求先调整运行账号，不会自动排除 UID 0。

## 5. 保留 LAN 入站与远端内网访问

完整示例见 [examples/lan-private-routing.json](examples/lan-private-routing.json) 和 [填写说明](examples/README.md)。示例包含带认证的 LAN mixed 入站及“指定目的 IP/CIDR → 指定节点”路由，所有地址、账号均为文档占位内容。

### 更换设备或 LAN 地址时检查哪些设置

先执行 `sbctl config`，查看实际配置路径、全部监听地址和已保存的网关接口/源网段。菜单的 **配置 LAN HTTP/SOCKS5 代理** 和 **关闭 LAN HTTP/SOCKS5 入口** 只管理 `tag: "lan-mixed"`；自定义的 `lan-explicit-proxy` 等其他入站会保留。若它们仍监听旧 LAN 地址，应在 `inbounds.json`（单文件模式则是完整配置）中逐项修改相应 `listen`，再执行 `sbctl preflight && sbctl restart`。

透明网关的接口和客户端源网段通过 **3 LAN透明网关设置 → 1 设置 LAN 透明网关** 单独设置。设置后还需预检和重启，再用 **2 查看网关状态** 或 `sbctl gateway status` 确认规则已激活；主菜单中的 `configured` 只表示已保存设置。修改网关设置不会自动改写其他入站的监听地址，也不要把远端私网目的路由改成新的本地 LAN 网段。

### 特色路由通过独立文件和菜单管理

特色路由保存在 `/opt/sing-box/config/config.d/routing.json`；使用自定义运行配置路径时，以 `sbctl config` 显示的伴随目录为准。进入一级菜单 **2 特色路由**，可以查看、新增、修改、删除规则、调整优先级，以及查看可选出站分组。

新增时填写目的 IP/网段、可选的客户端源 IP/网段和端口，再从实际 `outbounds.json` 中的分组选择目标。至少填写源或目的 IP 范围之一。单个 IPv4 会保存为 `/32`，不依赖本机 LAN 网段。`remote-office`、`remote-home` 是用户自定义的分组 `tag`，工具按名称引用它们，没有预置的办公室、家庭地址或固定分组名称。

例如，下面是追加到现有 `outbounds` 数组中的一个分组对象，其中 `office-node` 须是已经配置的静态节点，`local` 须是已定义的 Provider：

```json
{
  "type": "selector",
  "tag": "remote-office",
  "outbounds": ["office-node"],
  "default": "office-node",
  "providers": ["local"]
}
```

分组建立后会出现在特色路由的目标列表里。规则只记录 `outbound: "remote-office"`，由核心使用该分组当前选择的节点。`providers: ["local"]` 让这个组也能在面板选择 `local` 中的真实节点；分组不会自动继承 `proxy` 的 Provider 成员。只用静态节点时可省略 `providers`，使用其他订阅时填写其实际 Provider 标签；仍需保留静态初始成员和默认项。

换节点时可以调整分组；重命名或删除仍被引用的分组时，必须同步修改路由，否则预检会拒绝启动。特色路由菜单和 `--group` 只选择 `selector`、`urltest` 或 `loadbalance` 分组。完整 LAN 示例里的 `remote-office` 是 SOCKS 静态节点，可由原生 JSON 规则直接引用；若要通过菜单管理，应在同一次 `outbounds` 编辑中将该节点改名为 `office-node`，并建立上述 `remote-office` 分组，避免保存时出现缺失引用。

保存规则时先组装并预检，通过后更新源文件和完整运行 JSON。需要让运行中的服务采用这些规则时，选择特色路由中的 **校验并重启应用**；启动、重启或重载服务时也会自动读取最新源文件。编辑期间如果规则或分组发生变化，旧提交会被拒绝，以免序号变化后误改另一条规则。

也可以通过 SSH 管理。下列新增示例要求 `remote-office` 分组已经存在：

```sh
sbctl routes groups &&
sbctl routes add --destination 10.77.50.10 --group remote-office --port 14432 &&
sbctl routes list
```

新增规则默认追加到末尾。需要修改时，先查看 `list` 中的实际编号，再单独执行 `sbctl routes edit N --group remote-home`，将 `N` 替换为要修改的编号，并确认 `remote-home` 分组已存在；不要把 `1` 当作刚新增规则的固定编号。确认规则无误后应用：

```sh
sbctl preflight && sbctl restart
```

规则序号从 1 开始；`sbctl routes move FROM TO` 调整顺序，`sbctl routes remove N` 删除指定规则，完整参数见 `sbctl routes help`。这些命令仅修改独立路由源文件，保留其他用户规则的条件和顺序，并通过配置生成器更新运行 JSON。旧单文件模式需要先在 **配置与隐私 → 配置分文件模式 / 迁移** 中显式无损拆分；管理工具不会自动替换旧 DNS 或路由策略。

### 地址与规则的作用

三类地址用途不同：

| 设置 | 含义 |
| --- | --- |
| `inbounds[].listen` | 当前 OpenWrt 实际拥有的监听地址 |
| `runtime/gateway.json` 的 `interface` / `source_cidr` | 从哪个接口接管哪些 LAN 客户端 |
| `route.rules[].ip_cidr` + `outbound` | 把哪些目的地址交给指定节点访问 |

例如，希望访问 `10.77.50.10` 和 `10.88.60.0/24` 内的目标时经过能到达远端私网的 `remote-office` 出站，先在 `outbounds.json` 定义该静态节点或分组，再添加下面的规则。**这是 `routing.json` 的结构示例；已有规则时只向 `rules` 数组追加其中的规则对象，不要覆盖整个文件或数组。** 此规则未限定端口；只匹配 `14432` 时需再添加 `"port": [14432]`。

```json
{
  "route": {
    "rules": [
      {
        "ip_cidr": ["10.77.50.10/32", "10.88.60.0/24"],
        "action": "route",
        "outbound": "remote-office"
      }
    ]
  }
}
```

生成器把这些例外放在固定的 DNS 劫持、嗅探、STUN/DTLS 防护规则之后，通用私网直连和地区分流之前；因此远端内网目标不会先被通用私网规则直连。可用 `source_ip_cidr` 限定某些 LAN 客户端，也可与目的网段同时使用。分文件模式要求例外有明确的 IP/CIDR 或进程条件，并指向已定义的静态出站标签。

修改本地 LAN 时，不要把这些远端目的规则一起改成新 LAN 网段。网关、UID 和代理配置工具保留自定义入站选项、其他用户及明确目的路由。需要自定义域名分流、私有 DNS 或调整固定规则顺序时，可使用单文件模式；本版不会替这些高级规则猜测应该使用哪一个 DNS。

进入网关的私网 TCP/UDP 由 sing-box 路由决定出口，不再因目的地址属于 LAN 前缀而一律提前放行。路由器自身地址和保留地址仍作本地处理。若客户端直接通过同网段 ARP 访问目标，流量可能根本不经过 OpenWrt，此时需设置具体路由或使用显式 HTTP/SOCKS5 代理。远端节点必须能够访问目标服务。

## 6. 分文件配置、固定策略与配置保护

### 日常编辑哪些文件

默认运行目录为 `/opt/sing-box`。**配置与隐私 → 编辑配置** 按部分编辑，先把草稿组装成完整配置并预检，通过后才提交源文件和运行 JSON；失败时保留原配置，并打印被拒绝草稿的保存位置。保存不自动重启。常用 IP/网段规则可直接使用 **特色路由** 菜单管理。

| 用户配置文件 | 内容与格式 |
| --- | --- |
| `config/config.d/providers.json` | `{"providers":[...]}`：订阅 URL、缓存路径、本地 Provider 引用 |
| `config/config.d/inbounds.json` | `{"inbounds":[...]}`：eBPF、LAN 监听 IP/端口、认证用户等 |
| `config/config.d/outbounds.json` | `{"outbounds":[...]}`：静态节点和 `proxy`、`ai` 等分组 |
| `config/config.d/routing.json` | `{"route":{"rules":[...]}}`：指定源/目的 IP、网段或进程的路由例外，默认空数组 |
| `config/config.d/settings.json` | 日志、面板、缓存等其余顶层设置；不允许写入 `dns`、`route` 或上述三个数组 |

对应的五份公开样例位于 [examples](examples/README.md)。`config.d/providers.json` 是 **Provider 定义**；`providers/xboard.json` 和 `providers/local.json` 是它们加载的 **节点数据**，两层文件不能互换。核心的相对路径仍以运行目录为基准。

项目从 `config/config.template.json` 提取固定 `dns`、`route`，与用户源文件组装为 `config/config.json`。服务仍只读取这一份完整 JSON，不使用 `sing-box -C` 的目录合并，也不运行 `sing-box merge`。`layout.json` 记录格式版本及生成状态，由工具管理。

`proxy`、`ai` 和 `direct` 是固定策略引用的保留标签。可以自定义代理节点和分组成员，但需要保留有效的静态成员、默认项以及 Provider 引用；生成器检查重复标签、缺失引用、循环依赖，并拒绝 `proxy`/`ai` 的选择链混入 `direct` 或 `Compatible` 兜底。实际节点是否能够连通仍需用户验证。

### 固定策略的作用与边界

固定模板负责 DNS 劫持规则、加密上游、DNS 分流、AI 独立 DNS、AAAA 空答复、STUN/DTLS 拒绝，以及基础业务分流。AI DNS 请求使用 `ai`，相应 AI 业务也使用 `ai`；常规代理 DNS 和代理业务使用 `proxy`。因此更换这些组内的节点时，关联策略不用再分别修改。

这表示 **DNS 请求和相应业务关联到同一出站组**，不保证两者最终公网 IP、地区或 ASN 相同：公共递归 DNS 有自己的出口，分组也可能包含其他选择或测速组。规则集、直连规则和用户添加的 IP/进程例外并非一一对应的域名 DNS 策略。远端私网 IP 可以按例外走指定节点，但远端私有域名还需要配置可达的内网 DNS；这类定制使用单文件模式。

防护只覆盖经过本机/网关且被接管的流量。LAN 网关目前接管 IPv4，不能据此宣称客户端 IPv6、应用自带 DoH 或未经过网关的连接已经全部受控。AAAA 空答复和 STUN/DTLS 拒绝也会影响部分应用，应在实际设备与客户端上验证。

### 现有单文件配置如何迁移

更新脚本后，已有 JSON 仍是单文件模式。**配置与隐私 → 配置分文件模式 / 迁移** 可选择无损拆分，等价命令为：

```sh
sbctl split-config &&
sbctl config &&
sbctl preflight &&
sbctl restart
```

迁移会比较现有 DNS、固定路由内容及规则顺序，仅在能完整保留配置含义时拆分；允许提取位于约定位置的 IP/进程例外。如果现有 DNS 或规则顺序不同，会明确拒绝，原配置与运行服务保持不变。不要为了通过迁移而直接用模板覆盖个人配置。

生成后的完整 JSON 不作为日常编辑入口。直接改动它会触发保护，避免下一次生成时丢失手工修改。需要导入完整 JSON 时使用 `sbctl import-config FILE`，分文件模式会执行相同的兼容性检查。需要保留自由定制时，使用 **配置与隐私 → 配置分文件模式 / 迁移** 或 `sbctl single-config`，可保留有效完整 JSON、归档源目录并返回单文件模式；不自动重启。

`single-config` 保留的是当时已有的完整运行 JSON，不会先应用尚未生成的源文件编辑。希望把这些编辑带入单文件配置时，先成功执行 `sbctl preflight`，再切换。

通过 SSH 编辑源文件后，运行 `sbctl preflight` 组装并检查，再重启。也可以先在目录外编辑草稿，使用下面的命令校验后提交，避免把无效草稿写进当前源文件：

```sh
sbctl config-part outbounds /tmp/my-outbounds.json &&
sbctl config-part routing /tmp/my-routing.json &&
sbctl restart
```

这两个文件也必须带上表格所列的顶层包装，不能只写数组。直接编辑源文件后如果预检失败，旧运行 JSON 保留，重启会在停止旧进程之前取消；恢复草稿后再预检。停止服务和清理网关不依赖源文件校验，配置错误时仍能关闭接管。

### 路径和个人数据保护

| 路径/设置 | 作用 |
| --- | --- |
| `/opt/sing-box` | 默认运行目录 |
| `/opt/sing-box/config/config.json` | 默认实际运行配置；分文件模式下为生成结果 |
| `/opt/sing-box/config/config.d` | 分文件模式的用户配置源；自定义 `live.json` 对应相邻的 `live.d` |
| `/opt/sing-box/config/config.template.json` | 项目维护的固定 DNS/路由策略来源 |
| `/opt/sing-box/providers` | 设备上的个人 Provider 和下载缓存 |
| `/opt/sing-box/runtime/source-dir` | 最近部署时记录的源码目录 |
| `/opt/sing-box/runtime/gateway.json` | 此设备的 LAN 接口与客户端源网段 |
| `sing-box.main.service_dir` / `config_file` | UCI 中持久设置的运行目录与配置路径 |
| `SH_SINGBOX_HOME` / `SH_SINGBOX_CONFIG` | 显式命令环境覆盖，路径必须为绝对路径 |
| `SB_INSTALL_SOURCE_DIR` | 显式选择源码目标，与服务运行目录设置独立 |

以 `sbctl config` 输出的路径和模式为准。源码配置与运行配置可以是不同文件；更新源码不会自动导入用户配置。要导入自己编辑的完整配置：

```sh
sbctl import-config /path/to/your-config.json &&
sbctl preflight &&
sbctl restart
```

导入先核心校验、备份，再替换；不自动重启。分文件模式还检查固定策略兼容性，并对重组结果执行设备预检。预检每次核对实际 IPv4 监听地址及上游 UID，不把语法缓存当成端口绑定成功。配置编辑工具保留配置符号链接。

个人订阅、节点密码和下载后的 Provider 应保存在设备上的个人运行文件中。仓库将虚拟 `.sample.json` 放在 `examples/`，`providers/` 仅跟踪通用模板和说明；真实 `xboard.json`、`local.json`、默认配置分片目录及其备份被 Git 忽略。更新只补缺失的样例，不替换已有 Provider；只有真正新建运行配置时才初始化缺失的运行 Provider 文件，已有分片但生成 JSON 丢失时不会重新填入样例。不要把私人数据写回公开 `.sample.json` 或起始配置后提交，Git 忽略规则不会保护已经跟踪的文件。

## 7. 在线更新

### SSH 菜单

安装器会记录本次使用的真实源码目录。安装后的 `sb` 优先使用显式 `SB_INSTALL_SOURCE_DIR`、当前源码菜单所在目录，或当前工作目录中的完整仓库，再使用安装时保存的源码记录；不会搜索预设的绝对目录。源码移动或重新下载后，可进入新的仓库目录执行 `sh ./quick-install.sh`，重新注册快捷命令；下一次完整安装或 `--scripts-only` 部署会刷新源码记录。

找不到有效源码时，安装/源码更新会给出实际目录的指定方法，服务管理仍可使用。若显式指定了无效的 `SB_INSTALL_SOURCE_DIR`，会要求修正该路径，不会悄悄更新其他旧仓库。

运行 `sb` → **5 安装与更新 → 2 更新公开仓库源码**：

- **通过引导脚本/压缩包准备的源码目录：** 在离线文件路径处直接回车，按当前代理设置下载公开仓库 `main` 分支；也可填写已上传的 ZIP/TAR.GZ。
- **Git 工作树：** 检查无未提交变更且当前分支为 `main` 或 `openwrt` 后，从当前配置的远程执行 `git pull --ff-only`。此模式不提示压缩包路径，也不会自动换成公开仓库；GitHub 下载前缀不能代理 `git pull`，请使用默认网络或 HTTP 代理。

源码更新完成后，记下输出的 `源码更新完成：...` 目录，退出当前菜单。将下面的 `/实际的源码目录` 替换为该绝对路径，再部署配套脚本。**此步骤用于已经完成安装的设备；首次安装中断请按下一节恢复。**

```sh
cd '/实际的源码目录' &&
bash ./install.sh --scripts-only &&
sbctl config &&
sbctl preflight &&
sbctl restart
```

这里始终使用实际源码目录，不要求目录名称或上级路径固定。`&&` 确保进入目录、部署或预检失败时不会继续执行后续步骤。`--scripts-only` 本身会先检查并备份，再更新脚本、菜单、procd 文件及配套模板；保留用户分片、运行 JSON、Provider、核心和网关设置，不联网、不生成配置、不自动重启。上面最后一条命令才重启服务。部署后重新运行 `sb`，以加载新菜单。

分文件模式下，新模板中的 DNS/基础路由策略在下一次预检或启动时组装，通过校验后才写入生成 JSON；单文件模式不会自动改变 DNS/路由。

### 安装在配置初始化阶段中断后的恢复

旧版从源码菜单安装时，可能出现 `Missing configuration-parts tool: .../scripts/config-parts.sh`：菜单传入了源码目录的工具路径，安装器又把没有执行位误判为文件缺失。新版安装器使用实际服务目录中的可读工具，并交给 Bash 执行。

如果已经遇到这个错误，先通过 **安装与更新 → 更新公开仓库源码** 更新，退出旧菜单。将下面的占位路径替换为更新完成后显示的实际源码目录，再执行：

```sh
cd '/实际的源码目录' &&
bash ./install.sh &&
sbctl config
```

这会补齐此前可能尚未完成的 CLI 和 procd 注册；`--scripts-only` 要求这些安装内容已经存在，不能代替本次完整修复。中断前生成的完整 JSON、Provider 和用户配置会保留；重跑安装不会擅自迁移已有单文件配置。如果 `sbctl config` 显示为单文件模式，可执行 `sbctl split-config`，或进入 **配置与隐私 → 配置分文件模式 / 迁移 → 将兼容的单文件配置无损拆分**。迁移校验通过后才生成分片；不兼容的自定义 DNS 或规则顺序会保留原配置并提示原因。

### 一次完成源码与脚本更新

适用于非 Git 源码目录和已经完成的服务安装。先退出旧菜单，并将占位路径替换为实际源码目录：

```sh
cd '/实际的源码目录' &&
sh ./quick-install.sh --update --no-menu &&
bash ./install.sh --scripts-only
```

这组命令不重启服务；完成后重新打开 `sb`，需要应用时执行 `sbctl preflight && sbctl restart`。需要本次临时代理时，为引导命令添加 `--http-proxy URL` 或 `--github-proxy PREFIX`。Git 工作树不会被压缩包覆盖；使用菜单的干净工作树检查和 `git pull --ff-only` 流程。

从仍采用旧目录逻辑的版本首次升级时，先按第 2 节下载新版引导脚本到 `/tmp/sb-openwrt.sh`。在实际的非 Git 源码目录执行下面的命令，可由新版引导器完成原地更新和脚本部署：

```sh
sh /tmp/sb-openwrt.sh --update --no-menu &&
bash ./install.sh --scripts-only
```

**5 安装与更新 → 5 更新 reF1nd 内核** 单独更新核心，默认使用项目固定版本（当前为 `v1.15.0-alpha.11-reF1nd`），不是自动追踪 GitHub latest。明确要用其他发行版本时，可执行 `sbctl update-core RELEASE_TAG`，把 `RELEASE_TAG` 替换为目标版本；指定版本也必须能取得并通过对应校验值验证。

核心更新先下载并验证校验值，用候选核心检查现有配置后才替换；正在运行时重启失败会恢复旧二进制并尝试恢复服务。分文件模式先检查当前源文件与生成 JSON 是否一致；存在尚未应用的编辑、新模板策略或生成 JSON 缺失时，请先用当前核心执行 `sbctl preflight`，确认配置后再更新核心。候选核心验证期间也会检查源文件是否变化，避免校验一份配置却运行另一份。

### 旧版提示 `cksum: command not found`

这是旧脚本对 OpenWrt 可选工具的错误依赖。OpenWrt 默认启用 `sha256sum`，但未启用 `cksum` 和 `stat`。旧版在已有单文件配置时使用 `cksum` 检查更新前后配置是否变化，因此首次安装可能成功，随后更新却失败。新版统一使用 SHA-256，支持独立 `sha256sum` 和 `busybox sha256sum`；配置校验缓存也已移除这一依赖，无需额外安装 `cksum`。

先更新源码，再将修复部署到实际服务目录。**只更新源码、随后直接运行旧的 `sbctl update-core`，仍会调用服务目录中的旧脚本。** 已完成安装的设备按本节“一次完成源码与脚本更新”执行，成功后重试 `sbctl update-core`。如果完整安装就在核心下载/更新阶段中断，更新源码后执行 `bash ./install.sh`，或重新进入 **5 安装与更新 → 1 安装/修复核心服务**，补齐后续服务注册；此时不能用 `--scripts-only` 代替完整安装。现有运行 JSON、配置分片和 Provider 会保留。

`Configuration preparation failed; current core and service are unchanged` 表示更新在替换核心和重启服务前中止。不要为了绕过该提示删除个人配置；SHA-256 检查仍会拦截更新期间发生的配置修改。

### 旧版提示需要 `timeout`，却显示“新核心拒绝配置”

如果 `core-update-check.log` 中是 `A timeout utility is required ...`，检查还没有执行到核心。旧版把外部 `timeout` 当成更新前提，BusyBox 的 applet 列表探测也可能失败，却把这些执行环境问题统一显示为 `New core rejects the existing configuration`。这个组合提示不能说明 JSON 配置有错。

新版核心更新和 `sbctl` 配置检查使用同一个内置限时执行器，依靠安装器已有的 Bash 和基础 `sleep`，无需单独安装 `timeout`，也不依赖 BusyBox 的 `--list` 输出。检查默认最多运行 90 秒，超时后终止检查进程；不响应终止信号的进程最多再给 2 秒后强制结束。正常退出、超时、执行失败和中断会分别报告，详情仍保存在原检查日志中。配置检查失败时不会替换核心或重启现有服务。

按本节的源码及脚本更新流程部署修复；如果安装曾中断，更新源码后重跑 `bash ./install.sh`。安装器支持空白运行目录，也支持首次安装时已经放好配置的目录。日志中的 `Checking existing configuration` 只表示当时运行路径下已经有配置文件，不要求先完成过服务安装，更不需要删除该文件来绕过检查。

## 8. 常用菜单和诊断

| 一级菜单 | 二级功能 |
| --- | --- |
| 1 服务管理 | 状态、启动、重启、停止、日志、配置校验 |
| 2 特色路由 | 查看、新增、修改、删除、调整顺序、查看分组、校验并重启应用 |
| 3 LAN透明网关设置 | 透明网关设置/状态/关闭、HTTP/SOCKS5 入口设置/关闭 |
| 4 配置与隐私 | 编辑配置、分文件模式迁移、旧格式迁移、隐私策略、泄漏检查 |
| 5 安装与更新 | 安装修复、公开源码更新、下载代理、规则集更新、核心更新 |
| 6 诊断与维护 | X-Tunnel 对接检查、UID 对齐、eBPF/路由诊断、卸载保留配置 |
| 0 | 退出主菜单；在二级菜单中返回上一级 |

执行操作后保留在当前分类，不用每次重新进入。确认提示统一显示 `[Y/n]`：**直接回车、输入 `y` 或 `yes` 都表示执行，`n` 表示取消**；输入中断或 EOF 会取消，不当作回车。停止、重启、删除和卸载保留配置等操作仍会先显示实际影响，再接受这一确认。

菜单选择、LAN 参数和特色路由表单支持退格修改输入，兼容 SSH 终端常见的 `Ctrl+H`（BS）和 `DEL` 两种 Backspace 编码。代理 URL、密码等隐藏输入也支持退格，输入内容仍不回显。

首次安装的固件如果同时缺少 Bash 和 `stty`，菜单会提示使用兼容输入：键入时不回显，退格会修正最终输入，按回车提交；`Ctrl+C` 取消，`Ctrl+D` 后再按回车也会取消。安装流程装好 Bash 后，重新进入菜单即可自动使用正常的可编辑输入，无需手动修改 SSH 终端设置。

严格隐私模板使用 AI 独立 DNS、AAAA 空答复和 STUN/DTLS 拒绝策略。视频会议、语音和 WebRTC 功能可能受影响；这也不能控制没有经过网关的客户端流量。DNS 使用同一代理出站不等于解析服务位于该节点本机。需要节点所在内网 DNS 时，另行配置实际可达的解析服务。

Clash API 默认 `127.0.0.1:9090`。可用 SSH 端口转发访问 WebUI；若向 LAN 开放 API，应配置自己的 secret 并限制来源。下载代理设置不改变 API 监听或认证。

```sh
sbctl config
sbctl check-xtunnel
sbctl gateway status
sbctl ebpf-status
logread -e sing-box
```

网关使用独立 nft 表 `singbox_one_arm`、fwmark `0x1536`、路由表 `53136` 和优先级 `15360`。这些是需要保持一致的内部资源标识；工具检查资源归属与冲突，不清空其他防火墙或策略路由。OpenWrt DNS guard 保留 netifd/dnsmasq 管理的 DNS 和 `/etc/resolv.conf`。

## 9. 验证与发布内容

GitHub Actions 覆盖 shell 语法、分级菜单导航、回车确认、模拟终端退格与隐藏输入、运行路径、配置保留、UID、网关、核心更新回滚、安装卸载、下载代理及独立引导流程；分文件与特色路由测试覆盖无损迁移、分组引用、增删改及排序、事务回滚、缓存失效、并发编辑和停止保护。在 CI Linux 上解析并加载/移除实际生成的 nft 规则，公开配置还有结构化脱敏检查。

引导路径测试还会编译关闭 `FEATURE_TR_CLASSES` / `FEATURE_TR_EQUIV` 的 BusyBox，使用其真实 ash 和工具验证普通目录、中文/空格目录、控制字符拒绝与启动器清理，避免只在 GNU 工具环境下通过测试。

同一 BusyBox 构建启用 `SHA256SUM`，明确关闭 `CKSUM` 和 `STAT`。核心更新和配置缓存测试使用不含 `cksum` 的独立命令目录，验证独立 SHA-256 工具及真实 BusyBox applet 两种方式，并检查同大小/同修改时间的配置编辑、摘要失败或无效输出不会绕过更新保护或误用缓存。

限时检查还覆盖没有 `timeout` 命令或 applet 的环境，验证真实退出码、超时、中断和子进程回收。安装集成测试在隔离目录实际执行完整安装器、更新器、配置组合工具和控制器，分别从空白运行目录和预存配置开始，检查配置保留及 CLI/procd 注册；网络、包管理和测试核心由夹具代替，测试不会安装软件包或改动宿主服务。

除了对完整 JSON 执行真实核心 `check`，CI 还使用同一固定核心验证分文件初始化、节点编辑、私网路由和丢失输出重建。另一个只有 loopback 的独立 network namespace 会真正启动核心：验证本地样例加载、selector 节点选择、HTTP 片段从本地模拟订阅获取节点及缓存重启。Provider 启动测试保留公开配置的 Provider/selector 结构，移除了与其无关的 eBPF、远程规则集和 WebUI 下载，不向虚拟订阅地址发请求。

下载代理和服务边界测试使用隔离的模拟工具，不修改测试主机的真实路由。CI 的 nft 验证和核心配置校验不等同于对某台 OpenWrt 的 BPF、客户端 DNS、IPv6或端到端转发验收。

公开发布采用独立源码快照，不带入原私有仓库提交历史。运行配置、订阅缓存、备份和设备凭据不属于发布内容。
