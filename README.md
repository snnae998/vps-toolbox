# VPS 一键工具箱

新机器到手，一条命令搞定初始化、安全加固、存储守护和送中检测。

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
6. NodeQuality
7. 一键Snell
8. X-UI
9. 一键检测送中
10. CF隧道升级
0. 退出
=================================
```

## 1. 一键初始化你的VPS

进子菜单，可单跑某一项，也可全部运行：

| 序号 | 功能 | 说明 |
|---|---|---|
| 1 | 改主机名 | 输入新主机名，写入 `/etc/hostname` 并立即生效（留空跳过） |
| 2 | 装基础工具 | 安装 curl、wget、unzip |
| 3 | IPv4优先 | 修改 `/etc/gai.conf`，优先使用 IPv4 |
| 4 | IPv6检查修复 | 检查 IPv6 是否正常，坏了自动禁用 |
| 5 | 时间同步修复 | 检查 NTP 同步，未同步自动安装并开启 |
| 6 | 开启BBR | 检查 TCP 拥塞控制，未开启自动启用 BBR |
| 7 | 改时区 | 设置时区为 Asia/Shanghai |
| 8 | 设置DNS | 设为 1.1.1.1 / 8.8.8.8，自动适配 dhcpcd、systemd-resolved 或直改 resolv.conf，重启不丢失 |
| 9 | 系统更新 | 非交互 `apt upgrade`，配置文件一律保留本地版本，全程不弹窗 |
| 10 | 全部运行 | 依次执行 1–9 |

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

## 7. 一键Snell

下载并运行 Snell 一键安装脚本（`https://git.io/Snell.sh`），在 VPS 上部署 Snell 代理服务。

## 8. X-UI

调用 [X-UI](https://github.com/FranzKafkaYu/x-ui) 安装脚本，部署 Xray 可视化管理面板。

## 9. 一键检测送中

调用本仓库的 [songzhong.sh](songzhong.sh)，检测 YouTube 对本机出口 IP 的地区判定（与 xykt IPQuality 同一口径：抓 YouTube Premium 页面查 `www.google.cn` 信号）。IPv4 / IPv6 分开检测并显示各自出口 IP，约 3 秒出结果；页面打不开时会明确提示无法判定，不会误报未送中。

也可单独运行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/snnae998/vps-toolbox/main/songzhong.sh)
```

## 10. CF隧道升级

调用本仓库的 [cloudflared-upgrade.sh](cloudflared-upgrade.sh)，把 cloudflared 平滑升级到最新版（当前 2026.11.2），覆盖 Docker / Compose / Systemd / OpenRC / 纯二进制五种部署。先起临时进程接管隧道再替换，升级过程不断连；新版带 GitHub digest 校验、失败自动回滚、检测到多种部署时拒绝猜测。

也可单独运行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/snnae998/vps-toolbox/main/cloudflared-upgrade.sh)
```

常用参数：`--mode docker|systemd` 指定部署方式，`--service <服务名>` / `--container <容器名>` 指定目标，`--skip-version-check` 强制重装。

## 适用系统

- Debian / Ubuntu（apt）
- 需要 root 权限运行

## 致谢

- 存储守护清理脚本源自 [vps99.sh](https://github.com/snnae998/vps99.sh)
- SSH 加固脚本：[key.sh](https://github.com/snnae998/key.sh)
- 单、多线程测速：[TaierSpeedtest](https://github.com/MiaM1ku/taierspeedtest)
- TCP 线路质量测试：[TcpQuality](https://github.com/ibsgss/TcpQuality)
- 节点综合质量测试：[NodeQuality](https://github.com/LloydAsp/NodeQuality)
- Snell 一键安装：[Snell.sh](https://git.io/Snell.sh)
- Xray 可视化面板：[X-UI](https://github.com/FranzKafkaYu/x-ui)
- 送中检测：本仓库 songzhong.sh（判定口径同 [xykt IPQuality](https://github.com/xykt/IPQuality)）
