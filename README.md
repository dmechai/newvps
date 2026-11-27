<h1 align="center">newvps</h1>
<p align="center">Ubuntu / Debian 新 VPS 的交互式初始化脚本。</p>
<p align="center"><img alt="运行环境 Bash" src="https://img.shields.io/badge/运行环境-Bash-4EAA25?style=flat-square"></p>
<p align="center"><a href="#功能">功能</a> · <a href="#第一次使用">快速开始</a> · <a href="#已跑过旧版恢复-root-登录">恢复 root 登录</a></p>

## 功能

| 项目 | 默认行为 |
| --- | --- |
| 系统更新 | 更新已安装软件包，启用自动安全更新 |
| 主机名 | 询问新名称，直接回车保留当前设置。改名时更新 `/etc/hosts`，并配置 cloud-init 保留新名字 |
| 时区 | 保留服务器当前时区，可用 `--timezone` 指定 |
| 防火墙 | 启用 UFW，默认拒绝入站、允许出站，添加 TCP 22、80、443 放行规则并保留已有规则 |
| fail2ban | 监控 SSH，同一来源在 10 分钟内失败 5 次会被封禁 1 小时。运行时可逐行添加可信 IP 或 CIDR，回车结束。默认包含 `127.0.0.1/8` 和 `::1` |
| 登录方式 | 普通初始化保留已有账户、密码和 SSH 认证设置，云控制台登录方式保持原样 |

## 第一次使用

适合使用 systemd、通过 TCP 22 提供 SSH 的新 Ubuntu 或 Debian VPS。需要 root 或 `sudo` 权限。在服务器上下载脚本并先检查内容。

```bash
curl -fsSLo setup.sh https://raw.githubusercontent.com/dmechai/newvps/main/setup.sh && less setup.sh
```

检查后运行。已经是 root 时可省略 `sudo --preserve-env=SSH_CONNECTION`。

```bash
sudo --preserve-env=SSH_CONNECTION bash setup.sh
```

初始化结束后，保留当前会话。从另一个窗口验证原有 SSH 登录，平时用 SFTP 的话也测试一次 SFTP。

## 常用选项

```bash
sudo --preserve-env=SSH_CONNECTION bash setup.sh --no-http
sudo --preserve-env=SSH_CONNECTION bash setup.sh --timezone Etc/UTC
bash setup.sh --help
```

`--no-http` 跳过添加 80 和 443 的放行规则，已有规则会保留。若需要添加 fail2ban 白名单，请填 VPS 实际看到的 SSH 来源地址。共享或动态地址不适合作为长期白名单。

## 已跑过旧版：恢复 root 登录

`--restore-root` 是单独的恢复模式，用于需要恢复 root 密码 SSH 和 SFTP 的服务器。启用后，root 密码一旦泄露就会暴露整台机器。fail2ban 只能减少重复猜密码。建议在恢复前用云防火墙限制 TCP 22 的来源，并确认云控制台可用。

从原有管理员账号通过 TCP 22 登录并确认已知 root 密码。在服务器上执行以下命令。

```bash
sudo --preserve-env=SSH_CONNECTION bash setup.sh --restore-root
```

如果登录时自动进入 root shell，且该 shell 没有保留 `SSH_CONNECTION`，可从本机用现有管理员账号重新连接。将示例中的 `admin` 和 `vps.example.com` 替换为自己的账号和地址。

```bash
ssh -t admin@vps.example.com 'sudo --preserve-env=SSH_CONNECTION bash'
```

恢复模式会备份 SSH 配置，验证本机监听 TCP 22，然后设置 `PermitRootLogin yes`、`PasswordAuthentication yes` 和 `PermitEmptyPasswords no`。旧账号保留为备用入口。出现提示后，用新窗口测试 SSH 和 SFTP。

```bash
ssh -p 22 -o PubkeyAuthentication=no -o PreferredAuthentications=password root@vps.example.com
sftp -P 22 -o PubkeyAuthentication=no -o PreferredAuthentications=password root@vps.example.com
```

两项都成功后，在原窗口输入 `yes`。超时（5 分钟）、中断或未确认时，脚本会尝试恢复原 SSH 配置。
