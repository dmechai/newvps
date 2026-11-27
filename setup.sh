#!/usr/bin/env bash
# New Ubuntu/Debian VPS bootstrap.
# Run once with root privileges after your first login.
set -euo pipefail

SSH_PORT="22"
TIMEZONE=""
ALLOW_HTTP="yes"

usage() {
    cat <<'EOF'
Usage: bash setup.sh [--timezone ZONE] [--no-http]
       bash setup.sh --restore-root

  --restore-root    Restore root SSH/SFTP without changing existing accounts
  --timezone ZONE   Set the system time zone (default: keep the current one)
  --no-http         Do not open ports 80 and 443

Run on a new Ubuntu/Debian VPS using SSH port 22. Normal setup prompts
for a hostname and fail2ban allowlist and preserves SSH authentication.
Use --restore-root separately if you need root SSH password access.
EOF
}

valid_ignore_ip() {
    local value="$1"
    [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] && return 0
    [[ "${value}" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] && return 0
    return 1
}

valid_hostname() {
    local value="$1"
    [[ "${#value}" -le 64 ]] || return 1
    [[ "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

restore_root() (
    local config=/etc/ssh/sshd_config backup stage service= sshd_bin effective reply
    local changed=0 reload_attempted=0 client_ip client_port server_ip server_port unit setting
    [[ -t 0 ]] || { echo '恢复模式需要交互式终端。' >&2; return 1; }
    if [[ -z ${SSH_CONNECTION:-} ]]; then
        echo '请从现有 SSH 连接运行恢复模式，以便核对实际来源地址和端口。' >&2
        return 1
    fi
    read -r client_ip client_port server_ip server_port <<< "$SSH_CONNECTION"
    if [[ "$server_port" != "$SSH_PORT" || -z "$client_ip" || -z "$server_ip" ]]; then
        echo '当前连接不是 SSH 22 端口；未改动配置。请先确认 22 端口和云防火墙。' >&2
        return 1
    fi
    if [[ $(LC_ALL=C passwd -S root | awk '{print $2}') != P ]]; then
        echo 'root 没有可用密码。请先通过云控制台确认或设置 root 密码，再重试。' >&2
        return 1
    fi
    sshd_bin=$(command -v sshd || true)
    [[ -n "$sshd_bin" && -f "$config" && ! -L "$config" ]] || {
        echo '未找到标准 OpenSSH 配置，未做改动。' >&2; return 1;
    }
    for unit in ssh.service sshd.service; do
        if systemctl is-active --quiet "$unit"; then
            service="$unit"
            break
        fi
    done
    [[ -n "$service" ]] || { echo '未找到运行中的 SSH 服务。' >&2; return 1; }
    if ! command -v ss >/dev/null || [[ -z $(ss -H -ltn 'sport = :22') ]]; then
        echo '未能确认本机正在监听 TCP 22，未做改动。' >&2
        return 1
    fi
    "$sshd_bin" -t -f "$config"

    umask 077
    backup=$(mktemp -d /etc/ssh/newvps-restore.XXXXXXXX)
    cp -a -- "$config" "$backup/sshd_config"
    stage=$(mktemp /etc/ssh/.newvps-restore.XXXXXXXX)
    rollback() {
        local status=$?
        trap - EXIT
        if (( changed )); then
            if cp -a -- "$backup/sshd_config" "$stage" && mv -fT -- "$stage" "$config" &&
                { (( ! reload_attempted )) || systemctl reload "$service"; }; then
                echo '已恢复原 SSH 配置。' >&2
            else
                echo "自动回滚失败，请保持当前终端打开；备份：$backup/sshd_config" >&2
                status=1
            fi
        fi
        rm -f -- "$stage"
        exit "$status"
    }
    trap rollback EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    cp -a -- "$config" "$stage"
    # These global settings must precede cloud-init and old bootstrap includes.
    {
        if ! grep -Eq '^# (newvps|newconfig) restore-root$' "$config"; then
            printf '%s\n' '# newvps restore-root' 'PermitRootLogin yes' 'PasswordAuthentication yes' 'PermitEmptyPasswords no'
        fi
        cat "$config"
    } > "$stage"
    "$sshd_bin" -t -f "$stage"
    effective=$("$sshd_bin" -T -f "$stage" -C "user=root,host=$client_ip,addr=$client_ip,laddr=$server_ip,lport=$SSH_PORT")
    for setting in 'permitrootlogin yes' 'passwordauthentication yes' 'permitemptypasswords no' "port $SSH_PORT"; do
        if ! grep -Fxq "$setting" <<< "$effective"; then
            echo "SSH 生效配置未通过检查：$setting。未做改动。" >&2
            return 1
        fi
    done

    changed=1
    mv -fT -- "$stage" "$config"
    reload_attempted=1
    systemctl reload "$service"
    if [[ -z $(ss -H -ltn 'sport = :22') ]]; then
        echo '重载后未检测到 TCP 22 监听，将回滚。' >&2
        return 1
    fi
    echo '请保留当前会话，另开窗口用 root 密码测试 SSH 和 SFTP（端口 22）。'
    echo '    ssh -p 22 -o PubkeyAuthentication=no -o PreferredAuthentications=password root@服务器IP'
    echo '    sftp -P 22 -o PubkeyAuthentication=no -o PreferredAuthentications=password root@服务器IP'
    if ! read -r -t 300 -p '两项均成功后输入 yes；否则将回滚: ' reply || [[ "$reply" != yes ]]; then
        return 1
    fi
    changed=0
    echo "已保留 root SSH 配置。原配置备份：$backup/sshd_config"
)

if [[ "${1:-}" == --restore-root ]]; then
    if [[ $# -ne 1 || "$EUID" -ne 0 ]]; then
        echo '请以管理员权限单独运行：sudo --preserve-env=SSH_CONNECTION bash setup.sh --restore-root' >&2
        exit 1
    fi
    restore_root
    exit
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timezone)
            TIMEZONE="${2:?missing timezone}"
            shift 2
            ;;
        --no-http)
            ALLOW_HTTP="no"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this as root: sudo bash setup.sh" >&2
    exit 1
fi

if [[ -n "${SSH_CONNECTION:-}" && "${SSH_CONNECTION##* }" != "${SSH_PORT}" ]]; then
    echo "当前 SSH 连接不使用 ${SSH_PORT} 端口。为避免断开访问，不修改防火墙，停止执行。" >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script only supports apt-based systems (Debian/Ubuntu)." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

CURRENT_HOSTNAME="$(hostname)"
echo
echo "当前主机名: ${CURRENT_HOSTNAME}"
while true; do
    read -r -p "新主机名（直接回车保持 ${CURRENT_HOSTNAME}）: " NEW_HOSTNAME
    if [[ -z "${NEW_HOSTNAME}" ]]; then
        break
    fi
    if valid_hostname "${NEW_HOSTNAME}"; then
        break
    fi
    echo "格式无效。使用字母、数字、短横线，可以用点分隔，例如 vps.example.com。"
done

if [[ -n "${NEW_HOSTNAME}" && "${NEW_HOSTNAME}" != "${CURRENT_HOSTNAME}" ]]; then
    echo "==> Setting hostname to ${NEW_HOSTNAME}"
    hostnamectl set-hostname "${NEW_HOSTNAME}"
    SHORT_HOSTNAME="${NEW_HOSTNAME%%.*}"
    HOSTS_LINE="127.0.1.1\t${NEW_HOSTNAME}"
    if [[ "${SHORT_HOSTNAME}" != "${NEW_HOSTNAME}" ]]; then
        HOSTS_LINE="${HOSTS_LINE} ${SHORT_HOSTNAME}"
    fi
    if [[ -f /etc/hosts ]] && grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i "s/^127\\.0\\.1\\.1[[:space:]].*/${HOSTS_LINE}/" /etc/hosts
    else
        printf '%b\n' "${HOSTS_LINE}" >> /etc/hosts
    fi
    if [[ -d /etc/cloud ]]; then
        install -d -m 0755 /etc/cloud/cloud.cfg.d
        printf '%s\n' 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
    fi
fi

echo "==> Updating packages"
apt-get update
apt-get upgrade -y
apt-get install -y ufw fail2ban unattended-upgrades ca-certificates curl sudo

if [[ -n "${TIMEZONE}" ]]; then
    echo "==> Setting timezone to ${TIMEZONE}"
    timedatectl set-timezone "${TIMEZONE}"
fi

echo
echo "fail2ban 白名单。这里的地址永远不会被封。"
echo "一行一个，可以是 IP 或 CIDR。直接回车结束。"
echo "127.0.0.1/8 和 ::1 会自动加入。"
echo "请填写 VPS 实际看到的 SSH 来源 IP。"
IGNORE_IPS=("127.0.0.1/8" "::1")
while true; do
    read -r -p "白名单 IP（回车结束）: " IGNORE_IP
    if [[ -z "${IGNORE_IP}" ]]; then
        break
    fi
    if ! valid_ignore_ip "${IGNORE_IP}"; then
        echo "格式无效，请重新输入。"
        continue
    fi
    IGNORE_IPS+=("${IGNORE_IP}")
done

echo "==> Configuring firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'ssh'
if [[ "${ALLOW_HTTP}" == "yes" ]]; then
    ufw allow 80/tcp comment 'http'
    ufw allow 443/tcp comment 'https'
fi
ufw --force enable
ufw status verbose

echo "==> Configuring fail2ban for sshd"
install -d -m 0755 /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
ignoreip = ${IGNORE_IPS[*]}
EOF
systemctl enable fail2ban
systemctl restart fail2ban

echo "==> Enabling unattended security upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades || true

echo
echo "Done."
echo "主机名: $(hostname)"
echo "SSH 及云厂商控制台的登录方式保持原样。"
echo "关闭当前会话前，请另开窗口测试原有 SSH 和 SFTP 登录。"
echo
ufw status verbose
fail2ban-client status sshd || true
