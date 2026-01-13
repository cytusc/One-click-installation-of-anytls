# One-click Installation of anytls

🚀 一个简单快速的 anytls 服务一键部署脚本，适用于 Linux 服务器。

## 快速安装

执行以下命令即可完成安装：

```bash
curl -sL https://raw.githubusercontent.com/cytusc/One-click-installation-of-anytls/main/install_anytls.sh -o anytls.sh && chmod +x anytls.sh && ./anytls.sh
```

## 功能特性

- ✔️ **全自动安装配置**：无需手动输入，自动生成安全密码与随机端口（10000-65535）
- ✔️ **自动更新**：安装时自动获取 GitHub 最新版本
- ✔️ **智能节点命名**：自动检测国家与运营商，生成易读的节点名称
- ✔️ **智能防冲突**：自动检测端口占用，确保服务顺利启动
- ✔️ 支持 systemd 服务管理
- ✔️ 包含服务状态监控
- ✔️ 支持 Ubuntu/Debian
- 使用此脚本ip被封责任自负

## 说明

本项目 Fork 来自 [https://github.com/kirito201711/One-click-installation-of-anytls](https://github.com/kirito201711/One-click-installation-of-anytls)
