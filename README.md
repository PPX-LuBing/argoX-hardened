# argoX-hardened

一个用于在 VPS 上部署 **Argo Tunnel + Xray** 的硬化版本脚本项目。  
本仓库主脚本为：`argox.sh`。

---

## 一键调用方式（curl + bash）

本项目推荐直接这样调用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PPX-LuBing/argoX-hardened/main/argox.sh)
```

> 说明：
> - 这是“远程拉取脚本并立即执行”的方式。
> - 请先自行审阅脚本内容后再执行，确保符合你的安全策略。

---

## 项目特性

- 支持 Argo Tunnel（Try / Token / Json / API 模式）
- 支持 Xray 多协议入站（含 Reality）
- 可生成常见客户端订阅信息
- 支持 systemd / openrc（Alpine）服务管理
- 提供交互式菜单与命令行参数两种使用方式

---

## 系统要求

- Linux（Debian / Ubuntu / CentOS / Alpine / Arch）
- Root 权限
- 可联网环境（用于下载依赖与组件）

---

## 常用命令参数

```bash
-a   开/关 Argo 服务
-x   开/关 Xray 服务
-t   更换 Argo 隧道类型
-d   更换优选域名/CDN
-u   卸载
-n   输出节点/订阅信息
-v   检查并升级版本
-b   显示外部工具禁用提示
-p   指定内部起始端口
-f   读取 KV 文件进行非交互安装
-k   快速安装（英文）
-l   快速安装（中文）
```

示例：

```bash
# 查看节点信息
argox -n

# 更换 Argo 隧道类型
argox -t

# 非交互安装（使用 kv 配置文件）
bash argox.sh -f ./install.kv
```

---

## 安全提示

1. 远程执行命令前请先审计脚本。
2. 生产环境建议固定版本而非长期跟踪 `main`。
3. 涉及 Token/API 凭据时请做好最小权限控制。

---

## 仓库地址

- GitHub: https://github.com/PPX-LuBing/argoX-hardened
