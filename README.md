# OpenWrt sing-box eBPF

面向 OpenWrt / iStoreOS 的 reF1nd sing-box 管理脚本，提供 SSH 菜单、procd 服务、本机 eBPF、LAN IPv4 TProxy、认证 HTTP/SOCKS5 入口及自定义目的路由。

**公开仓库：** [fsyllkn/openwrt-singbox-ebpf](https://github.com/fsyllkn/openwrt-singbox-ebpf)，默认分支 `main`。在线安装、源码更新均使用本仓库，无需 GitHub Token，也不要求安装 Git。

本仓库包含通用配置和完整的本地 Provider 样例。**新装可以先启动服务、查看面板和示例节点，再逐项填写自己的上游。** 样例没有真实订阅、可用代理节点或内置账号；服务运行中不代表已经具备代理上网能力。安装器不会覆盖设备已有的运行配置。

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

## 2. 在线准备源码并打开菜单

### 默认下载

在 OpenWrt SSH 中执行：

```sh
wget -O /tmp/sb-openwrt.sh https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh
sh /tmp/sb-openwrt.sh
```

已有 curl 时也可使用：

```sh
curl -fL https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh -o /tmp/sb-openwrt.sh
sh /tmp/sb-openwrt.sh
```

引导脚本仅准备源码和注册 `sb` 快捷命令，随后打开菜单。菜单 **1** 才安装依赖、核心及服务；安装本身不启动透明代理。重复打开 `sb` 不会自动联网更新。

源码默认放在 `/overlay/openwrt-singbox-ebpf`，没有 `/overlay` 时使用 `/root/openwrt-singbox-ebpf`。可用绝对路径环境变量 `SB_INSTALL_SOURCE_DIR` 指定其他目录，支持普通空格。

### 通过本地或局域网 HTTP 代理

首次下载脚本也必须经过代理时：

```sh
download_proxy='http://127.0.0.1:7890'
http_proxy="$download_proxy" https_proxy="$download_proxy" \
  curl -fL https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh -o /tmp/sb-openwrt.sh
SB_DOWNLOAD_MODE=http SB_HTTP_PROXY="$download_proxy" sh /tmp/sb-openwrt.sh
```

将地址改为当前设备可达的 HTTP 代理。上面的变量只用于本次命令及其子菜单；长期设置使用菜单 **24**。

HTTPS 资源经过 HTTP 代理需要客户端支持 CONNECT。脚本优先使用 curl，也支持 GNU Wget；OpenWrt 的 BusyBox wget / uclient-fetch 不作为该模式的替代客户端。缺少 curl 时，先通过可用的软件源安装 curl，或使用下一种 GitHub 下载代理/离线方式准备项目。脚本不会因 HTTP 代理失败而回退直连。

### 通过公开 GitHub 下载代理

以下前缀仅为格式示例，可替换成你信任且可用的服务：

```sh
github_proxy='https://ghfast.top'
wget -O /tmp/sb-openwrt.sh "$github_proxy/https://raw.githubusercontent.com/fsyllkn/openwrt-singbox-ebpf/main/quick-install.sh"
SB_DOWNLOAD_MODE=github SB_GITHUB_PROXY="$github_proxy" sh /tmp/sb-openwrt.sh
```

已下载脚本时，可直接传参数：

```sh
sh /tmp/sb-openwrt.sh --http-proxy http://127.0.0.1:7890
sh /tmp/sb-openwrt.sh --github-proxy https://ghfast.top/
sh /tmp/sb-openwrt.sh --direct
```

一次选择一种下载方式。GitHub 下载前缀用于公开的 GitHub 源码和资源，代理服务能够看到这些资源请求；使用可信服务。订阅、运行流量和本地控制 API 不使用此下载前缀。

### 离线安装源码

上传本仓库 `main` 分支的 ZIP 或 TAR.GZ 后执行：

```sh
sh /tmp/sb-openwrt.sh --archive /tmp/openwrt-singbox-ebpf-main.zip
```

ZIP 需要 unzip，TAR.GZ 可直接使用 tar。也可从已上传的源码目录准备：

```sh
sh /path/to/source/quick-install.sh --source /path/to/source
```

离线准备和 `--scripts-only` 不要求下载代理可用。

## 3. 统一下载代理设置

运行 `sb`，选择 **24 设置安装/更新下载代理**。可选择默认下载、HTTP 代理、GitHub 下载代理前缀。输入 URL 不回显；保存到 UCI，配置文件权限为 `0600`。设置后，本菜单后续操作使用新设置。

也可使用配置工具：

```sh
sh /opt/sing-box/scripts/configure-download.sh show
sh /opt/sing-box/scripts/configure-download.sh set direct
sh /opt/sing-box/scripts/configure-download.sh set http http://127.0.0.1:7890
sh /opt/sing-box/scripts/configure-download.sh set github https://ghfast.top/
sh /opt/sing-box/scripts/configure-download.sh clear
```

安装前工具位于源码的 `scripts/configure-download.sh`。含认证信息的代理优先通过菜单输入，或使用 `set http --stdin`，避免 URL 进入命令历史。状态显示会遮蔽认证信息。

| 选择 | 适用范围 |
| --- | --- |
| 默认 `direct` | 不添加项目代理，保留标准系统 `http_proxy` / `https_proxy` 等环境设置 |
| HTTP `http` | 项目下载；包管理器及 Git 更新仅在对应子进程中接收代理环境，不写入 sing-box 的代理流量配置 |
| GitHub `github` | 为 `github.com`、`raw.githubusercontent.com`、`codeload.github.com` 的公开下载 URL 添加指定前缀 |

GitHub 前缀不用于系统软件源、其他网站、本地 Clash API 或订阅地址。`api.github.com` 发布元数据仍走默认网络；固定默认核心不需要这项 API 查询，更新其他版本时需要 API 可达或选择 HTTP 代理。Git 工作树的 `git pull` 使用默认网络或 HTTP 代理；GitHub 下载前缀用于无 Git 的压缩包更新。

优先级：命令行参数设置的本次环境覆盖 > `SB_DOWNLOAD_MODE` / `SB_HTTP_PROXY` / `SB_GITHUB_PROXY` > UCI > 默认方式。单独设置一个代理 URL 环境变量可推断对应模式；同时设置两个 URL 时应明确指定模式。

UCI 项为 `sing-box.download.mode`、`sing-box.download.http_proxy`、`sing-box.download.github_proxy`。共享下载工具覆盖源码压缩包、核心压缩包、WebUI 和规则集，不再自动尝试隐藏的第三方下载代理。核心仍按对应版本验证 SHA256；下载失败保留已有完整文件并返回错误。curl 使用总时限；wget 可用 `timeout` 时有总时限，否则使用客户端请求超时。

三份通用配置为内置远程规则集设置了 `initial_path: "geo/<tag>.srs"`。核心没有有效缓存时，首次启动可使用安装器已通过所选代理下载的文件，避免预下载完成后仍必须同步直连 GitHub。核心缓存优先于这份启动备用文件；核心后续远程规则集/订阅的后台刷新仍由运行 JSON 的 `download_detour` 等设置决定，不读取此 UCI 下载设置。需要让后台刷新经过运行中的代理时，请按实际出站配置对应 detour。已有设备配置不会被安装器自动改写。

## 4. 第一次配置与启动

### 先确认服务与面板可以启动

菜单 **1** 安装/修复核心服务。没有现有运行配置时，安装器会同时准备完整 JSON 和两份非空的本地 Provider，不需要先填写订阅 URL。安装仍不自动启动服务；在固件支持相应 eBPF 能力、安装资源齐全后，可以执行：

```sh
sbctl config
sbctl preflight && sbctl start
sbctl status
```

Clash API 默认只监听本机 `127.0.0.1:9090`。在电脑上用实际 OpenWrt 地址建立 SSH 转发，然后访问 `http://127.0.0.1:19090/ui/`：

```sh
ssh -L 19090:127.0.0.1:9090 root@OPENWRT_IP
```

面板中能看到 `xboard/SAMPLE-XBOARD-REPLACE-ME`、`local/SAMPLE-LOCAL-REPLACE-ME` 等节点。它们只用于确认 Provider 和 selector 已加载，未提供真实代理；默认关闭示例节点的自动健康检查。保持客户端原有网关/DNS，填写真实节点并验证后再接入 LAN 客户端。

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

手工节点/X-Tunnel：编辑运行目录中的 `providers/local.json`，或把 `local` Provider 的 `path` 改成实际导出路径。文件需至少包含一个核心支持的代理节点。保存后，在面板的 `proxy` 组选择真实的 `local/<节点标签>`。

HTTP 订阅：参考 [HTTP 片段](examples/http-provider.sample.json)，将 `example.invalid` URL 换成自己的真实地址，再替换实际配置里同名的 `xboard` local Provider，保留另一个 `local` Provider。这个片段不是完整配置，不能直接作为 `sbctl import-config` 的输入。默认示例使用 `User-Agent: clash.meta`，省略 `http_client.detour`，通过核心默认拨号器下载；如果订阅必须经过代理，再把 `detour` 设为已配置且可用的代理出站标签。不要指向尚未配置的占位节点，也不要将它设为没有拨号选项的 `direct` 出站。

切换成 remote 后，现有的新鲜 `xboard.json` 缓存可能暂时仍显示示例节点；在面板 Provider 页面手动更新 `xboard`，待真实节点出现后再选择。`path` 是可被订阅刷新覆盖的缓存，自己的手工节点应放在独立的 `local.json` 中。不要为了开启订阅而同时保留两个同名 Provider。

固定核心启动时先建立 selector 静态成员，再加载 Provider。保留静态默认项，在面板选择动态 Provider 节点并由缓存保存；不要把 `xboard/<节点标签>` 直接填入初始 `outbounds` 或 `default`，以免产生启动期找不到节点的错误。字段与合并方法见 [Provider 说明](providers/README.md)。

配置真实上游后，菜单 **16** 设置需要的 LAN 显式入口，菜单 **13** 设置需要的 LAN 透明网关；使用 X-Tunnel 时先启动其核心，再用菜单 **21** 对齐实际专用 UID 排除。最后预检、重启并在客户端验证。安装或更新不会把公开起始配置覆盖到已有运行 JSON，也不会用样例替换已有节点或订阅缓存。

## 5. 保留 LAN 入站与远端内网访问

完整示例见 [examples/lan-private-routing.json](examples/lan-private-routing.json) 和 [填写说明](examples/README.md)。示例包含带认证的 LAN mixed 入站及“指定目的 IP/CIDR → 指定节点”路由，所有地址、账号均为文档占位内容。

三类地址用途不同：

| 设置 | 含义 |
| --- | --- |
| `inbounds[].listen` | 当前 OpenWrt 实际拥有的监听地址 |
| `runtime/gateway.json` 的 `interface` / `source_cidr` | 从哪个接口接管哪些 LAN 客户端 |
| `route.rules[].ip_cidr` + `outbound` | 把哪些目的地址交给指定节点访问 |

例如，希望访问 `10.77.50.10:14432` 时经过能到达远端私网的 `remote-office` 节点，相关目的规则应在通用私网直连之前：

```json
[
  { "ip_cidr": ["10.77.50.10/32", "10.88.60.0/24"], "outbound": "remote-office" },
  { "ip_is_private": true, "outbound": "direct" }
]
```

修改本地 LAN 时，不要把这些远端目的规则一起改成新 LAN 网段。网关、UID 和代理配置工具保留自定义入站选项、其他用户及明确目的路由；严格隐私合并也保留自定义规则的相对顺序。

进入网关的私网 TCP/UDP 由 sing-box 路由决定出口，不再因目的地址属于 LAN 前缀而一律提前放行。路由器自身地址和保留地址仍作本地处理。若客户端直接通过同网段 ARP 访问目标，流量可能根本不经过 OpenWrt，此时需设置具体路由或使用显式 HTTP/SOCKS5 代理。远端节点必须能够访问目标服务。

## 6. 文件路径与配置保护

| 路径/设置 | 作用 |
| --- | --- |
| `/opt/sing-box` | 默认运行目录 |
| `/opt/sing-box/config/config.json` | 默认实际运行配置 |
| `/opt/sing-box/providers` | 设备上的个人 Provider 和下载缓存 |
| `/opt/sing-box/runtime/source-dir` | 最近部署时记录的源码目录 |
| `/opt/sing-box/runtime/gateway.json` | 此设备的 LAN 接口与客户端源网段 |
| `sing-box.main.service_dir` / `config_file` | UCI 中持久设置的运行目录与配置路径 |
| `SH_SINGBOX_HOME` / `SH_SINGBOX_CONFIG` | 显式命令环境覆盖，路径必须为绝对路径 |

以 `sbctl config` 输出为准。源码配置与运行配置可以是不同文件；更新源码不会自动导入用户配置。要导入自己编辑的完整配置：

```sh
sbctl import-config /path/to/your-config.json
sbctl preflight
sbctl restart
```

导入先内核校验、备份，再替换；不自动重启。预检每次核对实际 IPv4 监听地址及上游 UID，不把语法缓存当成端口绑定成功。配置编辑工具保留配置符号链接。

个人订阅、节点密码和下载后的 Provider 只存放在设备的运行目录。仓库将虚拟 `.sample.json` 放在 `examples/`，`providers/` 仅跟踪通用模板和说明；真实 `xboard.json`、`local.json` 及其他缓存被 Git 忽略。更新只补缺失的样例，不替换已有 Provider；只有新建运行 JSON 时才初始化缺失的运行 Provider 文件。不要把私人数据写回公开 `.sample.json` 或起始配置后提交，Git 忽略规则不会保护已经跟踪的文件。

## 7. 在线更新

### SSH 菜单

运行 `sb` → **2 更新公开仓库源码** → 离线文件路径处直接回车，即按当前代理设置下载公开 `main` 分支。也可填写已上传的 ZIP/TAR.GZ。

更新源码后，在实际源码目录部署配套脚本：

```sh
cd /overlay/openwrt-singbox-ebpf
bash install.sh --scripts-only
sbctl config
sbctl preflight
sbctl restart
```

目录不同请替换 `cd` 路径。`--scripts-only` 会先检查并备份，再更新脚本、菜单、procd 文件及配套模板；保留运行 JSON、Provider、核心和网关设置，不联网、不自动重启。

### 一次完成源码与脚本更新

```sh
cd /overlay/openwrt-singbox-ebpf
SB_INSTALL_SOURCE_DIR="$PWD" sh ./quick-install.sh --update --no-menu &&
bash ./install.sh --scripts-only
```

需要本次临时代理时，为引导命令添加 `--http-proxy URL` 或 `--github-proxy PREFIX`。Git 工作树不会被压缩包覆盖；使用菜单的干净工作树检查和 `git pull --ff-only` 流程。

菜单 **12** 单独更新核心：先下载并验证版本校验值，用候选核心检查现有配置后才替换；正在运行时重启失败会恢复旧二进制并尝试恢复服务。

## 8. 常用菜单和诊断

| 选项 | 功能 |
| --- | --- |
| 1 / 2 | 安装修复 / 更新公开源码 |
| 3 / 4 / 5 / 6 / 7 / 8 | 重启 / 日志 / 启动 / 停止 / 状态 / 配置校验 |
| 9 / 10 | 编辑运行配置 / 迁移旧版 DNS、block、shared 设置 |
| 11 / 12 | 更新规则集 / 核心 |
| 13 / 14 / 15 | 设置 / 查看 / 关闭 LAN 透明网关 |
| 16 / 17 | 配置 / 关闭 LAN HTTP/SOCKS5 入口 |
| 18 / 19 | 应用严格隐私策略 / 主机与配置诊断 |
| 20 / 21 / 22 | 检查 X-Tunnel Provider / 对齐实际 UID / eBPF 与路由诊断 |
| 23 / 24 | 卸载服务保留配置 / 下载代理设置 |

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

GitHub Actions 覆盖 shell 语法、菜单、运行路径、配置保留、UID、网关、核心更新回滚、安装卸载、下载代理及独立引导流程；在 CI Linux 上解析并加载/移除实际生成的 nft 规则。公开配置还有结构化脱敏检查。

除了对完整 JSON 执行真实核心 `check`，CI 还在只有 loopback 的独立 network namespace 内真正启动核心：验证本地样例加载、selector 节点选择、HTTP 片段从本地模拟订阅获取节点及缓存重启。该测试保留公开配置的 Provider/selector 结构，移除了与其无关的 eBPF、远程规则集和 WebUI 下载，不向虚拟订阅地址发请求。

下载代理和服务边界测试使用隔离的模拟工具，不修改测试主机的真实路由。CI 的 nft 验证和核心配置校验不等同于对某台 OpenWrt 的 BPF、客户端 DNS、IPv6或端到端转发验收。

公开发布采用独立源码快照，不带入原私有仓库提交历史。运行配置、订阅缓存、备份和设备凭据不属于发布内容。
