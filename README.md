# VPS 一键工具箱

新机器到手，一条命令搞定初始化、安全加固和存储守护。

## 一键使用

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/snnae998/vps-toolbox/main/vps-toolbox.sh)
```

## 菜单

```
=================================
  VPS 一键工具箱
=================================
1. 一键初始化你的VPS
2. 一键加固你的VPS
3. 存储守护（每周自动清理）
4. 单、多线程测速
5. TcpQuality
0. 退出
=================================
```

## 1. 一键初始化你的VPS

进子菜单，可单跑某一项，也可全部运行：

| 序号 | 功能 | 说明 |
|---|---|---|
| 1 | 装基础工具 | 安装 curl、wget、unzip |
| 2 | IPv4优先 | 修改 `/etc/gai.conf`，优先使用 IPv4 |
| 3 | IPv6检查修复 | 检查 IPv6 是否正常，坏了自动禁用 |
| 4 | 时间同步修复 | 检查 NTP 同步，未同步自动安装并开启 |
| 5 | 开启BBR | 检查 TCP 拥塞控制，未开启自动启用 BBR |
| 6 | 改时区 | 设置时区为 Asia/Shanghai |
| 7 | 系统更新 | `apt update && apt upgrade -y` |
| 8 | 全部运行 | 依次执行 1–7 |

## 2. 一键加固你的VPS

调用 [key.sh](https://github.com/snnae998/key.sh)，提供交互菜单：

- SSH 密钥登录管理
- 密码登录开关
- Fail2Ban 防护
- SSH 端口修改

## 3. 存储守护

部署每周定时清理（每周一 06:06），自动清理：

- apt 缓存与无用包（`autoremove` / `clean` / `autoclean`）
- systemd 日志（只保留 100M / 7 天）
- 无用的 Docker 镜像与容器日志

防止磁盘被日志和缓存撑爆。

## 4. 单、多线程测速

调用 [TaierSpeedtest](https://github.com/MiaM1ku/taierspeedtest)，单线程与多线程下载测速。

## 5. TcpQuality

调用 [TcpQuality](https://github.com/ibsgss/TcpQuality)，测试 TCP 线路质量（回程路由、丢包、延迟）。

## 6. NodeQuality

调用 [NodeQuality](https://run.NodeQuality.com)，节点综合质量测试（IP 质量、硬件、网络、回程路由、端口）。

## 适用系统

- Debian / Ubuntu（apt）
- 需要 root 权限运行

## 致谢

- 存储守护清理脚本源自 [vps99.sh](https://github.com/snnae998/vps99.sh)
- SSH 加固脚本：[key.sh](https://github.com/snnae998/key.sh)
