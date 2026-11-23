# socks5

一键搭建 SOCKS5 代理，带交互菜单：**安装 / 修改 / 卸载 / 限速**。

两个后端，按需选一个：

| 后端 | 脚本 | 特点 |
|---|---|---|
| **gost v2** | `gost.sh` | 单个静态二进制，不依赖 PAM、不建系统账号，凭据只存 600 权限的 JSON。**推荐** |
| dante | `install.sh` | 系统包管理安装，用户名认证走系统账号 / PAM，依赖多 |

两个脚本装的命令都叫 `socks5`，别同时用；切换前先卸载旧的。

## gost 版（推荐）

```bash
bash <(curl -fsSL -H 'Accept: application/vnd.github.raw' \
  'https://api.github.com/repos/Assute/socks5/contents/gost.sh?ref=main')
```

> 用 API 而不是 `raw.githubusercontent.com`：后者走 Fastly 缓存，刚发布时可能长期返回旧内容。需要固定版本时用 `https://cdn.jsdelivr.net/gh/Assute/socks5@<commit>/gost.sh`。

菜单：

```
1) 安装 SOCKS5
2) 修改配置（端口 / 认证）
3) 卸载
4) 设置限速
------------------------------
5) 查看状态   6) 查看连接信息   7) 重启
8) 实时日志   9) 自检           0) 退出
```

命令行：

```bash
socks5 install --port 8443 --user u1 --pass 'p@ss:w/rd#1'
socks5 modify | uninstall | limit | status | info | restart | logs
socks5 doctor        # 自检
socks5 version
```

这套脚本修掉了常见 gost 一键脚本的三个问题：

1. **失效的下载源**：`ghproxy.com` / `mirror.ghproxy.com` 已停用，改用 GitHub 直连 + `ghfast.top` + `gh-proxy.com`，并校验官方 `checksums.txt` 的 sha256，不匹配直接拒绝安装。
2. **密码泄露**：凭据不写进 systemd 命令行，只放 `/etc/gost/gost.json`（600）。`systemctl cat gost` 看不到密码。
3. **变量残留**：每次安装都重置凭据状态，不会把上一次的用户名密码带进新配置。

凭据含 `@ : / #` 时会自动百分号编码后再写进 gost 的 URL；客户端仍用原始明文密码。

## dante 版

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Assute/socks5/main/install.sh)
```

拿到菜单后选序号即可。装完会注册一个 `socks5` 命令，以后再管理直接敲：

```bash
socks5
```

## 菜单

```
1) 安装 SOCKS5 服务
2) 修改配置（端口 / 认证 / 重配）
3) 卸载 SOCKS5 服务
4) 设置限速
------------------------------
5) 查看状态
6) 查看连接信息
7) 重启服务
8) 实时日志
9) 操作统计
u) 升级脚本
0) 退出
```

菜单顶部实时显示：脚本版本、服务运行状态、端口、当前限速值。

## 升级

```bash
socks5 upgrade
```

拉取最新脚本，比对版本，确认后覆盖 `/usr/local/sbin/socks5`，旧版留一份 `.bak`。

**换脚本不等于换配置。** 新版可能改过 `danted.conf` 或 systemd 单元的生成逻辑，所以升级后会问你要不要重建一遍：

```
同时用新版本重建服务配置（danted.conf + systemd 单元）并重启？[Y/n]:
```

选是就会用新脚本重新生成配置、校验、重启。这一步是用**新脚本**执行的（`exec`），不是拿当前进程里的旧函数去写 —— 否则只会把旧格式再写一遍。

也可以单独重建，不升级：

```bash
socks5 refresh
```

改动过脚本或怀疑配置和版本对不上时，跑这个即可。

拉取走 GitHub API 而不是 `raw.githubusercontent.com`：后者走 Fastly 缓存，刚发布时通常还拿到旧内容。API 失败才退回 raw，并在版本倒退时明确告警。

查版本：

```bash
socks5 version
```

会同时打印**正在运行的版本**、**已安装命令的版本**、**安装记录里的版本**，三者不一致一眼可见。

## 自检

出问题时先跑这个，比逐个猜快得多：

```bash
socks5 doctor
```

```
[脚本]
  运行位置: /usr/local/sbin/socks5
  运行版本: v3.7
  语法自检: OK
  已装命令: /usr/local/sbin/socks5 (v3.7)
  安装记录: v3.7

[服务]
  danted:   OK 运行中
  unit:     Type=simple KillMode=mixed PIDFile=0
  单元格式: OK

[配置]
  /etc/danted.conf: 42 行
  配置校验: OK
  监听地址: 0.0.0.0 port = 3030
  出口网卡: eth0

[端口与限速]
  SOCKS 端口: 3030
  监听状态: OK
  限速: 下载 2mbit / 上传 2mbit
```

任何一项是 `FAIL` 或「旧格式」，下面该跑什么就清楚了。

> 版本号的一个坑：早期版本把脚本版本也存在 `install_info.conf` 里并用了 `SCRIPT_VERSION` 这个键名，`source` 该文件时会覆盖掉运行中的 `$SCRIPT_VERSION`，导致菜单、升级比较、refresh 全部报错版本号（代码是新的，显示是旧的）。v3.7 起记录键改名为 `MANAGER_VERSION`，且 `load_install_info` 会保护运行版本不被污染。

## 限速

dante 本身不支持限速，这里用 Linux `tc` 的 HTB 队列在网卡层整形。

**关键设计：只匹配 SOCKS 端口，不整形整块网卡。** 直接对网卡限速会连 SSH 一起限，几千块的带宽一开，自己先掉线。

| 方向 | 匹配条件 | 含义 |
|---|---|---|
| 出方向 | 报文源端口 == SOCKS 端口 | 下载（服务器 → 客户端） |
| 入方向 | 报文目标端口 == SOCKS 端口 | 上传（客户端 → 服务器） |

入方向的包用 `ifb` 虚拟网卡中转后再整形（ingress 挂不了 HTB）。父类给 10 Gbit、默认类不限速，只有命中端口的那一类受限，所以同机的其他流量不受影响。

限速菜单里可选：双向限速 / 只限下载 / 只限上传 / 查看 tc 实况 / 清除。

单位写法：`10` = 10 Mbps，`800K` = 800 Kbps，`0` = 不限。

设置结果落在 `/etc/socks5-manager/limit.conf`，并由 `socks5-shaping.service` 开机自动恢复（服务文件调用自包含的 `/usr/local/sbin/socks5-shaping`，不依赖管理脚本放在哪）。

## 命令行

```bash
socks5 install                          # 交互安装
socks5 install --port 1080 \
               --user Admin01 --pass 'p@ss:w/rd#1'   # 非交互安装
socks5 install --no-auth                 # 无认证（慎用）
socks5 modify                            # 改端口 / 改密码 / 换认证模式
socks5 limit                             # 限速菜单
socks5 status | info | restart | logs | stats
socks5 upgrade                           # 检查并升级脚本
socks5 refresh                           # 按安装记录重建配置并重启
socks5 version                           # 查版本（含已安装命令的版本）
socks5 doctor                            # 自检：脚本/服务/配置/限速一次列清
socks5 uninstall
```

## 文件位置

| 路径 | 作用 |
|---|---|
| `/etc/danted.conf` | Dante 配置，改动前自动备份为 `.bak.<时间戳>` |
| `/etc/systemd/system/danted.service` | 服务单元 |
| `/etc/socks5-manager/install_info.conf` | 安装信息（含密码，权限 600） |
| `/etc/socks5-manager/limit.conf` | 限速配置 |
| `/etc/socks5-manager/usage_stats.log` | 操作历史 |
| `/usr/local/sbin/socks5` | 管理命令 |
| `/usr/local/sbin/socks5-shaping` | 限速应用脚本（systemd 调用） |
| `/etc/logrotate.d/socks5-danted` | 日志轮转，保留 7 天 |
| `/var/log/danted.log` | 连接日志 |

## 用户名和密码

用户名和密码都可以随意设，脚本不限制字符集和复杂度：

- **用户名**：大写、数字开头、点、`@`、`#` 都行，最长 32 位。只挡三个会真正坏事的字符 —— 冒号（会破坏 `chpasswd` 的 `user:pass` 行格式）、空格、以及 `-` 开头。
- **密码**：1–64 位任意字符，包括 `@ : / # ? % 空格`。留空自动生成 16 位随机串。

唯一的外部限制来自系统：dante 的用户名认证走 PAM，**用户名必须对应一个真实的 Linux 账号**。`useradd` 默认会拒掉大写开头、数字开头的名字，脚本会自动加 `--badname` 重试；如果系统仍然拒绝，会打印 `useradd` 的原始报错。

密码写入时如果被 `pam_pwquality` 之类按复杂度挡下，脚本会绕开 PAM 直接写 SHA-512 哈希，所以 `123` 这种密码也能设成功。

因为密码可能有特殊字符，客户端命令一律用 `--proxy-user` 传凭据，不走 `user:pass@host` 的 URL 形式：

```bash
curl --socks5-hostname 服务器IP:1080 --proxy-user '用户名:密码' https://api.ipify.org
```

## 客户端

浏览器填 SOCKS5 主机 + 端口，**务必勾选「代理解析域名」/「远程 DNS」**，否则 DNS 泄漏。

curl 验证：

```bash
curl --socks5-hostname 服务器IP:1080 --proxy-user '用户名:密码' https://api.ipify.org
```

返回服务器的出口 IP 即成功。

## 排查

```bash
systemctl status danted            # 服务状态
journalctl -u danted -n 50         # 启动报错
tail -f /var/log/danted.log        # 连接日志
danted -V -f /etc/danted.conf      # 配置校验（大写 V；小写 v 只打印版本号）
tc -s class show dev eth0          # 限速是否命中（看 Sent 字节数）
iptables -S INPUT | grep 1080      # 防火墙规则
```

改完 `danted.conf` 记得 `systemctl restart danted`。

### 启动超时 / 起不来

dante 的几个行为容易踩：不给 `-D` 时它在前台运行、不 fork；pid 文件要 `-p` 显式指定才会生成。所以 unit 必须用 `Type=simple` 托管前台进程，写 `Type=forking` + `PIDFile=` 会卡满 90 秒然后被杀。脚本生成的 unit 已经是正确的，如果手工改过，对照检查：

```bash
systemctl cat danted | grep -E 'Type=|PIDFile|KillMode'
# 期望：Type=simple，没有 PIDFile，KillMode=mixed
```

danted 会派生一组子进程，残留下来会占着端口导致下次启动 `Address already in use`：

```bash
systemctl stop danted; systemctl reset-failed danted
pkill -9 -x danted
rm -f /run/danted.pid
ss -ltnp | grep 1080        # 确认端口已释放
socks5 restart
```

## 安全

无认证模式下，任何知道 `IP:端口` 的人都能拿它当出口，带宽和风险都是你的。建议：

- 默认用用户名密码认证（脚本默认选项）
- 只对固定 IP 开放：`iptables -A INPUT -p tcp --dport 1080 -s 你的IP -j ACCEPT`
- 或在 `danted.conf` 的 `client pass` 里把 `from: 0.0.0.0/0` 改成你的网段
