# sk5

一键搭建 SOCKS5 代理，带交互菜单：**安装 / 修改 / 卸载 / 限速 / 白名单**。

后端是 [gost v2](https://github.com/ginuerzh/gost) 2.12.0 —— 单个静态 Go 二进制，不依赖 PAM、不建系统账号，凭据只存在 600 权限的 JSON 里。

## 安装

```bash
bash <(curl -fsSL -H 'Accept: application/vnd.github.raw' \
  'https://api.github.com/repos/Assute/socks5/contents/gost.sh?ref=main')
```

> 用 GitHub API 而不是 `raw.githubusercontent.com`：后者走 Fastly 缓存，刚发布时可能长期返回旧内容。需要固定版本时用 `https://cdn.jsdelivr.net/gh/Assute/socks5@<commit>/gost.sh`。

安装完命令是 **`sk5`**。如果机器上有本脚本旧版装的 `/usr/local/sbin/socks5`，会被自动转成指向 `sk5` 的软链，避免新旧两份副本并存（别人的文件不动）。

## 菜单

```
1) 安装 SOCKS5
2) 修改配置（端口 / 认证）
3) 卸载
4) 设置限速
w) 白名单（只放行指定域名）
------------------------------
5) 查看状态   6) 查看连接信息   7) 重启
8) 实时日志   9) 自检 (doctor)
u) 升级脚本   0) 退出
```

菜单顶部实时显示：脚本版本、服务运行状态、端口、当前限速、白名单状态。

## 命令行

```bash
sk5 install --port 8443 --user u1 --pass 'p@ss:w/rd#1'
sk5 install --no-auth                      # 无认证（仅内网）
sk5 install --allow '.example.com,1.2.3.4' # 装完即启用白名单
sk5 modify | uninstall | limit | status | info | restart | logs | stats
sk5 allow                                  # 白名单管理
sk5 upgrade                                # 升级脚本
sk5 doctor                                 # 自检
sk5 version
sk5 help
```

## 设计上修掉的几个坑

1. **失效的下载源**：`ghproxy.com` / `mirror.ghproxy.com` 已停用，改用 GitHub 直连 + `ghfast.top` + `gh-proxy.com`，并校验官方 `checksums.txt` 的 sha256，不匹配直接拒绝安装。
2. **密码泄露**：凭据不写进 systemd 命令行，只放 `/etc/gost/gost.json`（600）。`systemctl cat gost` 看不到密码。
3. **变量残留**：每次安装都重置凭据状态，不会把上一次的用户名密码带进新配置。
4. **端口占用**：动手前先检查。占用的若是 dante 版残留，交互模式会直接问你要不要停掉它；非交互模式明确中止且不改动任何文件。
5. **HTB 丢包**：`tc` 的 `burst` / `cburst` 显式给 32k。不写时内核按速率推算，低速率下可能小于一个 MTU，结果不是限速而是全丢包 —— 症状是「连上后几十秒就超时」。
6. **service 不重启**：`Restart=always` 而不是 `on-failure`。被外部 SIGKILL 时退出码可能仍为 0，`on-failure` 不会拉起来。
7. **命令永不更新**：早期版本只在首次安装时写命令文件，之后改仓库无用，副本停在旧版。现在有 `sk5 upgrade`。

## 升级脚本

```bash
sk5 upgrade
```

- 以**磁盘上** `/usr/local/sbin/sk5` 的版本为基准比对（拿运行进程的版本比会永远判「已最新」）
- 先走 GitHub API，失败回退 raw；两者都校验 shebang 与 `SCRIPT_VERSION`，不合格拒绝替换
- 逐段数值比较版本，`1.10 > 1.9` 不会被字符串比较判错
- 只在远端确实更新时才覆盖，旧副本留成 `.bak`；远端更旧不降级，下载失败不动磁盘

菜单按 `u` 同效。`sk5 version` 会同时打印**运行版本**与**已装命令的版本**，不一致时提示升级。

## 目标白名单

只放行你指定的域名/IP，其余目标一律拒绝。菜单按 `w`，或命令行 `sk5 allow`。

```
1) 查看规则   2) 添加   3) 删除
4) 清空（放行全部目标）   5) 重新应用
6) 从日志收集被拒的域名（补规则用）
```

规则写在 `/etc/socks5-gost/allow.txt`：

```
.example.com       # 匹配 example.com 及其一级子域（www.example.com）
*.example.com      # 同上，脚本会自动改写成 .example.com
1.2.3.4            # 单个 IP
10.0.0.0/8         # 网段
```

**改完 10 秒内自动生效**（`reload 10s`），不用重启。

### 三个实测出来的坑

| 写法 | 实际行为 |
|---|---|
| `bypass=~.example.com`（内联） | ✅ 白名单 |
| `bypass=~<文件路径>` | ❌ **`~` 被忽略**，变成黑名单 |
| 文件里写 `reverse true` | ✅ 白名单（唯一正确的文件写法） |

所以 `allow.txt` 里的 `reload 10s` / `reverse true` 两行是开关，不能删。`doctor` 会检查 `reverse` 在不在，缺了会标红。

### 匹配深度

gost 只匹配**主域 + 一级子域**：

| 目标 | `.example.com` |
|---|---|
| `example.com` | ✅ |
| `www.example.com` | ✅ |
| `a.b.example.com` | ❌ 不支持二级 |

裸域名 `example.com` 是**精确匹配**，`www.example.com` 不放行，所以要覆盖子域必须写点开头的 `.example.com`。`*.x` 与 `.x` 深度相同但 `*.` 不匹配主域本身，脚本统一归一成 `.x`。

### 补规则：资源被拒时

站点样式丢失、接口 404 这类问题，常见原因是静态资源挂在另一个域名上（CDN / 对象存储 / 第三方库），没列进白名单就被拒。

菜单 `w → 6` 会从日志里回收被拒的域名：

```
最近 2 hours ago 被拒绝的域名（已排除纯 IP）
   1) cdn.jsdelivr.net
   2) fonts.googleapis.com
把上面 2 个域名加入白名单？[y/N]:
```

已被现有规则覆盖的会自动跳过。

> `curl` 返回 `(97)` 只代表代理层失败，**无法区分**「被白名单拒绝」与「目标域名解析不了」—— 两者都是 97。要确认得看日志里的 `Bypass` 行（`w → 6` 就是在解析它）。

## 自检

```bash
sk5 doctor
```

```
[脚本]
  运行位置: /usr/local/sbin/sk5
  运行版本: v1.8
  语法自检: OK
  已装命令: /usr/local/sbin/sk5（v1.8）

[程序与服务]
  gost:     gost v2.12.0
  服务:     OK 运行中
  启动于:   ... （已运行 358 秒）
  重启次数: 0

[配置]        gost.json 权限、unit 的 Type/Restart、凭据是否在命令行里
[端口与可达性] 监听状态、绑定地址、本机探测、公网探测
[目标白名单]  规则清单、reverse 是否在
[滥用风险]    认证状态、当前连接数、近 10 分钟客户端 IP 数
[防火墙]      ufw / firewalld / iptables 放行情况
```

两个关键读法：

- **`启动于` 很短 + `重启次数` 一直涨** → 进程在反复退出（被外部杀 / OOM）
- **服务运行中但 `公网探测` FAIL，而 `本机探测` OK** → 云安全组没放行，跟代理无关

## 限速

gost 本身不限制带宽，用 Linux `tc` 的 HTB 队列在网卡层整形。

**关键设计：只匹配 SOCKS 端口，不整形整块网卡。** 直接对网卡限速会连 SSH 一起限。

| 方向 | 匹配条件 | 含义 |
|---|---|---|
| 出方向 | 报文源端口 == SOCKS 端口 | 下载（服务器 → 客户端） |
| 入方向 | 报文目标端口 == SOCKS 端口 | 上传（客户端 → 服务器） |

入方向的包用 `ifb` 虚拟网卡中转后再整形（ingress 挂不了 HTB）。父类给 10 Gbit、默认类不限速，只有命中端口的那一类受限，所以同机的其他流量不受影响。

限速菜单里可选：双向限速 / 只限下载 / 只限上传 / 查看 tc 实况 / 清除。

单位写法：`10` = 10 Mbps，`800K` = 800 Kbps，`0` = 不限。

设置落在 `/etc/socks5-gost/limit.conf`，由 `gost-shaping.service` 开机自动恢复（调用自包含的 `/usr/local/sbin/gost-shaping`，不依赖管理脚本放在哪）。

排查限速是否在丢包：

```bash
IFC=$(ip -4 route show default | awk '{print $5; exit}')
tc -s class show dev "$IFC"    # 看 1:10 那行的 dropped
```

`dropped` 持续增长 = 队列在丢包，把速率调大或检查 `burst`。

## 文件位置

| 路径 | 作用 |
|---|---|
| `/usr/local/bin/gost` | gost 二进制 |
| `/etc/gost/gost.json` | 服务配置（含凭据，权限 600） |
| `/etc/systemd/system/gost.service` | 服务单元 |
| `/usr/local/sbin/sk5` | 管理命令 |
| `/etc/socks5-gost/install.conf` | 安装信息（含密码，权限 600） |
| `/etc/socks5-gost/limit.conf` | 限速配置 |
| `/etc/socks5-gost/allow.txt` | 目标白名单 |
| `/etc/socks5-gost/usage.log` | 操作历史 |
| `/usr/local/sbin/gost-shaping` | 限速应用脚本（systemd 调用） |
| `/etc/systemd/system/gost-shaping.service` | 限速开机恢复 |

连接日志由 journald 管理，没有单独落文件。

## 用户名和密码

用户名和密码都可以随意设，**中英文、空格、符号都行**：

- **用户名**：1–64 位，非空
- **密码**：1–128 位；留空自动生成 16 位随机串

只挡三样：空值、超长、控制字符（换行 / 制表符 —— 会破坏配置文件的 `KEY=VALUE` 格式）。

gost 的凭据放在 URL 里（`socks5://user:pass@:port`），所以脚本会先做百分号编码再写入，`@ : / # ? %` 都不会破坏结构：

```json
{"ServeNodes":["socks5://%E5%BC%A0%E4%B8%89:%E5%AF%86%E7%A0%81%20abc@:8443"]}
```

**客户端用原始明文**，不用管编码。因为密码可能有特殊字符，客户端命令一律用 `--proxy-user` 传凭据，不走 `user:pass@host` 的 URL 形式：

```bash
curl --socks5-hostname 服务器IP:8443 --proxy-user '张三:密码 abc' https://api.ipify.org
```

## 客户端

浏览器填 SOCKS5 主机 + 端口，**务必勾选「代理解析域名」/「远程 DNS」**，否则 DNS 泄漏，且白名单也管不住域名解析。

返回服务器的出口 IP 即成功。

> 启用白名单后，客户端自带的「节点测速 / 延迟测试」通常会失败 —— 它测的是厂商固定的测试地址，不在你的列表里。这不代表节点有问题。

## 排查

```bash
systemctl status gost                # 服务状态
journalctl -u gost -n 50             # 最近日志
journalctl -u gost -f                # 实时
sk5 doctor                           # 一次列清
```

gost 日志格式：`<->` 表示连接建立，`>-<` 表示关闭，`: Bypass <域名>` 表示被白名单拒绝。

```
[socks5] 1.1.1.1:52733 -> socks5://:3030 -> example.com:443
[socks5] 1.1.1.1:52733 <-> example.com:443      ← 建立
[socks5] 1.1.1.1:52733 >-< example.com:443      ← 关闭
[socks5] 1.1.1.1:52733 - 1.1.1.1:3030 : Bypass other.com:443   ← 被白名单拒
```

### 端口被占用

```
[ERROR] 端口 3030 已被占用：
  LISTEN 0 511 0.0.0.0:3030 ... users:(("danted",pid=3577890,fd=9))
```

如果占用者是旧版 dante，交互安装会问你要不要停掉；手工处理：

```bash
systemctl disable --now danted socks5-shaping 2>/dev/null
pkill -9 -x danted
ss -ltnp | grep -w 3030        # 必须没有输出
systemctl reset-failed gost
sk5 restart
```

`pkill -9` 不能省 —— `systemctl stop` 经常杀不干净 dante 派生的子进程，残留会一直占着端口。

### 服务起不来

```bash
sk5 doctor                    # 先看这一段
systemctl cat gost | grep -E 'Type=|Restart=|ExecStart'
# 期望：Type=simple，Restart=always，ExecStart 里是 -C 配置文件而不是明文密码
```

## 安全

- **默认启用用户名密码认证**。无认证代理一旦公网可达，通常几分钟内就被扫描器收录，流量算在你头上。
- **不要用弱密码**。公网端口每天都有爆破，`123456` 这种几分钟就进。
- **白名单是最有效的一道限制**：只放行你真正要用的目标，别人拿到凭据也当不了通用出口。
- **只对固定 IP 开放**更彻底：

```bash
iptables -I INPUT -p tcp --dport 8443 -s 你的IP -j ACCEPT
iptables -A INPUT -p tcp --dport 8443 -j DROP
```

- 云主机还要在控制台的安全组里放行入方向 TCP 端口。

### 一个必须说清的局限

**SOCKS5 是明文协议，不能对抗链路审查。** 客户端发出的 `CONNECT 域名` 和 TLS 的 SNI 都是明文，中间设备能直接看到你在访问什么。用它访问被针对性阻断的站点时，可能触发对该服务器 IP:端口 的封锁 —— 表现为「一开始能用，访问某个站点后就整个连不上了」。

白名单解决的是「别人拿你的代理当通用梯子」，不解决这个问题。需要访问被审查的目标，要换加密且抗识别的协议（如 VLESS + Reality、Hysteria2、Trojan），或临时用 `ssh -D` 这类全程加密的通道。
