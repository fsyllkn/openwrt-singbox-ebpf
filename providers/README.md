# 本地 Provider 与订阅示例

本目录只提交说明和 `provider.template.json`；两份安装样例的公开源码位于 `examples/`。所有样例都没有真实订阅、节点、账号或访问令牌。样例中包含非空的 SOCKS 节点，供内核完成本地 Provider 的加载；它们不提供代理上网服务。

## 公开样例与设备运行文件

| 公开源码文件 | 新安装时创建的运行文件 | 样例节点 |
| --- | --- | --- |
| [examples/xboard.sample.json](../examples/xboard.sample.json) | `providers/xboard.json` | `SAMPLE-XBOARD-REPLACE-ME`，指向 `127.0.0.1:9` |
| [examples/local.sample.json](../examples/local.sample.json) | `providers/local.json` | `SAMPLE-LOCAL-REPLACE-ME`，指向 `127.0.0.1:10` |
| `providers/provider.template.json` | 不自动启用；供另存为个人 Provider 使用 | 与 `examples/local.sample.json` 相同 |

运行文件位于设备的服务目录，默认是 `/opt/sing-box/providers/`。安装器会把 `examples/` 中的两份公开样例部署为运行目录内的 `providers/xboard.sample.json`、`providers/local.sample.json`，再为新安装创建缺少的 `providers/xboard.json`、`providers/local.json`。样例文件与实际节点文件名称分开，已有运行文件和符号链接会保留；更新脚本不会用样例覆盖个人 Provider。

## 默认本地 Provider

三份完整配置都按以下方式引用运行文件：

```json
"providers": [
  {
    "type": "local",
    "tag": "xboard",
    "path": "providers/xboard.json",
    "health_check": { "enabled": false }
  },
  {
    "type": "local",
    "tag": "local",
    "path": "providers/local.json",
    "health_check": { "enabled": false }
  }
]
```

分片模式把以上 Provider 定义保存到配置旁的 `config.d/providers.json`，格式样例见 [config-providers.sample.json](../examples/config-providers.sample.json)。这里的定义文件与节点内容文件用途不同：定义中写 `type`、`tag`、`path` 或订阅 URL；`providers/xboard.json`、`providers/local.json` 中写实际节点的 `outbounds` 数组。默认 `config.d/outbounds.json` 中的 `proxy` 选择器引用这些 Provider。

路径相对于服务运行目录，不是相对于配置 JSON 所在目录。通过本项目的 `sbctl` 或服务管理器运行时，两者会使用同一服务目录。把完整示例导入旧安装前，也需要准备相应的运行文件。

本地 Provider 文件必须存在且含至少一个内核支持的节点；`{"outbounds": []}` 会导致启动时报告 `no servers found`。样例关闭了节点健康检查，不会自动探测占位节点。服务能否启动还取决于设备的 BPF 支持、监听端口和规则集等条件，JSON 语法通过不等于设备运行成功。

`proxy` 已引用 `xboard` 和 `local` 两个 Provider，同时保留静态出站 `configure-your-proxy` 作为初始选择。这个静态出站指向 `127.0.0.1:1080`，也需要配置真实上游。`ai` 默认跟随 `proxy`，两者都没有 `direct` 兜底；需要代理的流量在上游不可用时会失败。

固定内核会给 Provider 节点加标签前缀，例如 `xboard/SAMPLE-XBOARD-REPLACE-ME`。把个人真实节点写入设备上的运行文件后，在控制面板中选择对应的 `xboard/<节点标签>` 或 `local/<节点标签>`；选择结果可由核心缓存恢复。保留静态初始出站，避免在 Provider 加载前把 `default` 指向尚未加入选择器的动态节点。若直接配置了静态真实出站，则可以把 `default` 改为该静态出站标签。

自建 `remote-office`、`remote-home` 等分组时，每个组都需要自己的 `providers` 引用，例如 `"providers": ["local"]`；它不会自动继承 `proxy` 的成员。添加 Provider 引用后，仍需保留已定义的静态初始成员与默认项，再从该组的面板列表选择真实 Provider 节点。仅使用静态节点的分组可以省略 `providers`。

## HTTP 订阅单独启用

见 [HTTP 订阅片段](../examples/http-provider.sample.json)。这是合并到完整配置中的片段，不是独立运行配置，也不会被默认配置自动加载。

先将虚构 URL 换成自己的实际订阅，再用该片段替换 `providers.json` 分片（或旧版完整配置）中 `tag: "xboard"` 的本地 Provider；保留 `local` 以及其他个人 Provider。同一标签只能有一条定义，不能把同标签的本地与远程 Provider 一起追加。

远程 Provider 的 `path: "providers/xboard.json"` 是可写入的下载缓存，成功更新后内容会被订阅替换。首次启动如果没有有效缓存，核心会同步请求 URL，失败可能阻止启动。已有缓存也可能因过期或 URL 变化触发请求；`update_interval: "24h"` 和 `health_check.enabled: false` 都不表示禁用订阅刷新。

示例在 `http_client.headers` 中设置 `User-Agent: clash.meta`，省略 `detour`，通过核心默认拨号器直连下载订阅。这不改变业务流量的代理路由。需要经代理下载时，才把 `http_client.detour` 设置为已配置且实际可用的出站标签；不能依赖尚未配置的占位代理，也不要填指向空 `direct` 出站的标签，否则实际请求会报错。

## 保存个人配置

只编辑设备上的运行文件，不要把真实节点写回 `examples/*.sample.json` 或 `providers/provider.template.json`。仓库的 `providers/` 仅允许跟踪模板和本说明，`providers/xboard.json`、`providers/local.json`、部署后的 `.sample.json` 及其他缓存均被忽略；提交前仍要检查暂存区，因为忽略规则不会删除已经跟踪的文件。
