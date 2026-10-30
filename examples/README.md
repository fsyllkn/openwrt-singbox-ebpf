# 分片配置、局域网与订阅示例

本目录包含完整的 `lan-private-routing.json`、单独的 `http-provider.sample.json` 订阅片段，以及 `xboard.sample.json`、`local.sample.json` 两份本地 Provider 内容文件。完整配置使用本地 Provider，不会自动请求片段中的虚构订阅 URL。Provider 样例与运行文件的区别见 [Provider 说明](../providers/README.md)。

## 分片配置

新安装把可自定义内容保存在运行配置旁的分片目录中。默认完整运行配置为 `/opt/sing-box/config/config.json`，对应目录为 `/opt/sing-box/config/config.d/`；自定义配置路径以 `sbctl config` 显示的实际位置为准。完整 JSON 由工具生成，分片模式下应编辑源分片。

| 公开格式样例 | 设备上的源文件 | 可修改内容 |
| --- | --- | --- |
| `config-providers.sample.json` | `providers.json` | Provider 定义、订阅与本地节点文件引用 |
| `config-inbounds.sample.json` | `inbounds.json` | eBPF 设置、UID、LAN 监听地址、端口与认证 |
| `config-outbounds.sample.json` | `outbounds.json` | 节点和选择组；保留 `proxy`、`ai`、`direct` 标签约束 |
| `config-routing.sample.json` | `routing.json` | 有明确目的/源 IP、CIDR 或进程条件的路由例外，默认为空 |
| `config-settings.sample.json` | `settings.json` | 日志、控制 API、缓存、HTTP 客户端和其他非策略设置 |

这些文件是原生 JSON 片段，不是独立的完整运行配置。例如 `inbounds.json` 顶层只有 `{"inbounds": [...]}`，`routing.json` 顶层只有 `{"route": {"rules": [...]}}`。DNS、固定路由和规则集由安装目录的 `config/config.template.json` 维护；不要把 `dns`、`route` 或其他分片数组放进 `settings.json` 试图覆盖它们。

通过 `sb` 的 **配置与隐私 → 编辑配置** 编辑对应分片，再运行 `sbctl preflight` 和 `sbctl restart`。LAN、网关和 UID 工具会回写 `inbounds.json`，重新生成后设置仍然保留。隐私策略操作在此模式下刷新固定策略，不重写用户分片；`layout.json` 由工具维护。

已有单文件安装仍按原配置工作，可用 `sbctl split-config` 显式迁移。只有 DNS、固定路由和规则顺序兼容且能无损重组时才会切换；自定义解析器或复杂规则不兼容时，工具保留原配置。需要继续自定义 DNS 时可保留单文件模式；已启用分片的配置可用 `sbctl single-config` 显式切回。不要直接编辑生成 JSON 或通过删除分片目录绕过一致性检查。

### 指定私网目的地址经过指定出站

一级菜单 **特色路由** 可直接维护独立 `routing.json`，支持新增、修改、删除、调整顺序和查看当前出站分组。目标列表实时读取 `outbounds.json` 中的分组 `tag`，支持 `remote-office`、`remote-home` 或其他自定义名字。保存时校验引用；服务启动、重启或重载前自动组合，核心按该分组选择的实际节点转发。保存后可在特色路由菜单选择 **校验并重启应用**。

只读命令为 `sbctl routes list` 和 `sbctl routes groups`；例如 `sbctl routes add --destination 10.77.50.10 --group remote-office --port 14432` 会把单个 IPv4 转成 `/32`。`edit N` 修改指定规则，`remove N` 删除，`move FROM TO` 调整优先级；序号从 1 开始。菜单与命令只修改相应路由，不清空其他规则或重建出站节点。分组更名时要同步修改引用；无效引用可直接在路由管理中修复，不需要先启动坏配置。

在 `outbounds.json` 定义自己的静态 `remote-office` 出站，然后把以下内容写入设备上的 `routing.json`。地址均为虚构示例，需替换为实际目标：

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

规则按用户填写的次序插在固定 DNS 劫持、协议识别、STUN/DTLS 拒绝三条规则之后，在其他固定路由和通用私网直连规则之前。引用的出站必须存在，且远端出口实际能够访问目标网络；不要把动态 Provider 节点标签直接当作尚未加载的静态出站。需要从 Provider 中选择时，可以建立具有安全静态初始成员的命名选择组，再由面板选择真实节点。

目的 CIDR 规则只决定业务连接的出站，不会自动添加企业内网 DNS。需要自定义解析器或仅按域名匹配的 DNS/路由策略时，第一版分片模式无法无损表达，应保留单文件配置。

### DNS 与代理出口的边界

固定 AI 域名规则使 AI DNS 和业务连接都引用 `ai`，普通代理 DNS 引用 `proxy`。这表示配置使用相同的出站组，不保证每次查询、缓存命中和后续连接使用完全相同的节点、出口 IP 或 ASN。公共 DoH 经过代理传输，也不等于解析服务位于代理节点本机；自定义私网例外不会改变其解析器。

当前策略仍有明确的私网、国内和管理进程直连规则。AAAA 空答复、STUN/DTLS 拒绝也不代表接管所有客户端 IPv6、应用自带加密 DNS 或未经过网关的流量；应在实际设备和客户端验证需要的行为。

## 局域网认证代理与远端私网路由

`lan-private-routing.json` 是在公开基础配置上扩展的完整示例，保留 DNS、AI 与 WebRTC 严格策略，并演示两项独立功能：

- 让 `lan-mixed` 绑定设备实际拥有的局域网 IPv4，并要求用户名、密码。
- 把指定目的 IP 或 CIDR 交给 `remote-office` 节点，从该节点的出口访问远端私网；其他私网目的地址仍可按后面的通用规则直连。

## 使用前必须修改

| 示例字段 | 示例值的含义 | 应填内容 |
| --- | --- | --- |
| `lan-mixed.listen` | `192.0.2.10` 是文档示例地址 | 本机实际持有的 LAN IPv4 |
| `lan-mixed.users` | `REPLACE_WITH_...` 是占位符 | 自己的用户名和足够长的随机密码 |
| `configure-your-proxy` | `127.0.0.1:1080` 是待配置 SOCKS 出站 | 用自己的实际代理节点替换，或确认此处已有可信 SOCKS 服务 |
| `remote-office` | `192.0.2.20:1080` 是文档示例节点 | 能访问目标远端私网的实际出站节点 |
| 私网目的地址 | `10.77.50.10/32`、`10.88.60.0/24` 是虚构网络 | 希望强制经过该节点的实际目的 IP/CIDR |
| 本地 Provider | `providers/xboard.json` 与 `providers/local.json` 是相对运行目录的路径 | 确保文件存在且节点数组非空；个人节点只写设备上的运行文件 |

本示例仅含占位节点和账号字段，没有可用订阅或真实节点。请先替换占位内容。公开的本地 Provider 样例只有 `examples/xboard.sample.json`、`examples/local.sample.json` 两份；安装后会部署到运行目录的 `providers/`，并为新安装创建缺少的 `xboard.json`、`local.json`。样例 SOCKS 节点指向回环端口 `9`、`10`，配置关闭了节点健康检查。它们让本地 Provider 有合法的非空内容，不提供代理上网服务。

`proxy` 已引用 `xboard`、`local`，初始仍选择静态 `configure-your-proxy`。使用自己的 Provider 节点时，在控制面板中选择带有 `xboard/` 或 `local/` 前缀的实际节点。基础 `proxy` 与 `ai` 选择器均没有 `direct` 兜底，待配置节点不可用时不会用直连冒充代理成功。

## 路由顺序

示例先保留 DNS 劫持、协议识别和 STUN/DTLS 拒绝规则，再放置指定目的 IP/CIDR → `remote-office` 的规则，随后才是其他域名与通用私网直连规则。修改时保持指定目的地址规则在通用 `private` / `ip_is_private` 直连规则之前，否则目的私网流量可能先命中直连。

`remote-office` 是实际出站标签，需与对应节点的 `tag` 一致。节点可以采用内核支持的其他协议，也可以指向本机 X-Tunnel 客户端提供的 SOCKS 端口；关键是该节点的远端出口确实能够到达目标私网。JSON 路由不会为远端服务器自动创建内网连接。

## 校验与应用

把编辑后的文件保存到设备上的个人路径，然后运行：

```sh
sbctl import-config /path/to/your-config.json
sbctl config
sbctl preflight
sbctl restart
```

导入会校验并备份现有配置，不自动重启。单文件模式的内核校验不等于实际监听检查；分片模式还要求固定策略兼容，并对重组结果执行预检后回写源文件。请先修改文档地址：分片导入、后续预检或启动会拒绝未分配给本机的监听地址。

透明 LAN 网关的接口和源网段需要单独通过 `sb` 菜单设置。修改 `mixed.listen` 不会自动改变网关源网段，也不等于已经接管 LAN 客户端的 IPv6 或 DNS。

## HTTP 订阅片段

`http-provider.sample.json` 仅演示顶层 `providers` 字段中的一项，不能直接交给 `sbctl import-config` 当作完整配置运行。

1. 将 `https://example.invalid/subscription/REPLACE_WITH_YOUR_SUBSCRIPTION` 换成自己的实际订阅 URL。
2. 在设备上的 `providers.json` 分片或旧版完整配置中，用片段的远程 Provider 替换原有 `tag: "xboard"` 的本地 Provider，保留其他 Provider。
3. 检查 `path` 和订阅下载路径，再校验、重启，并在控制面板中选择实际节点。

片段在 `http_client.headers` 中设置 `User-Agent: clash.meta`，省略 `detour`，使用核心默认拨号器直连下载订阅；它仅影响订阅请求。需要通过代理下载时，再填已配置且实际可用的出站标签，不能依赖尚未配置的占位代理，也不要填指向空 `direct` 出站的标签。

`providers/xboard.json` 会作为可写的订阅缓存，更新时会被替换。无有效缓存时，错误的 URL 会导致初次订阅加载失败；24 小时更新间隔和关闭节点健康检查都不会禁用订阅下载。不要把未替换的虚构 URL 合并进要启动的配置。
