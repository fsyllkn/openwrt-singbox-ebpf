# Provider 配置与缓存

本目录只提交空白的 `provider.template.json`，不包含订阅、账号、访问令牌或已下载节点。

安装后的个人 Provider 文件请放在安装目录的 `providers/` 中，例如 `/opt/sing-box/providers/local-nodes.json`。在实际运行配置中按内核支持的 Provider 格式填写该文件路径；HTTP 订阅地址只写入设备上的实际配置，不要写进公开仓库。

`provider.template.json` 的 `outbounds` 数组初始为空。添加自己的节点后，保存为设备上的独立文件，并在 selector 中选择有效节点；空模板不会提供可用代理。初始配置的 `providers` 为空，不会请求示例订阅地址。

仓库忽略本目录除模板与本说明外的文件，避免下载的订阅缓存意外进入提交。提交前仍应检查 Git 暂存区：忽略规则不会删除已经跟踪的文件。
