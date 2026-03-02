#!/usr/bin/env bash
# =============================================================================
# VPS 初始化脚本
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────
# 颜色输出
# ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${GREEN}══ $* ${RESET}"; }
pause()   { echo -e "${YELLOW}[!] $* ${RESET}"; read -rp "    确认后按 Enter 继续..."; }

# ──────────────────────────────────────────────
# 权限检查
# ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请以 root 用户运行本脚本：sudo bash $0"

# ──────────────────────────────────────────────
# 交互式参数收集
# ──────────────────────────────────────────────
echo -e "${BOLD}"
echo "============================================="
echo "       VPS 初始化脚本 - 参数配置"
echo "============================================="
echo -e "${RESET}"

# 新用户名
while true; do
  read -rp "$(echo -e "${BOLD}新建普通用户名：${RESET}")" NEW_USER
  [[ -n "$NEW_USER" ]] && break
  warn "用户名不能为空"
done

# SSH 端口：支持随机生成高位端口
echo -e "${BOLD}SSH 端口（留空自动随机生成 10000-65535 高位端口）：${RESET}"
read -rp "> " SSH_PORT_INPUT
if [[ -z "$SSH_PORT_INPUT" ]]; then
  SSH_PORT=$(( RANDOM % 55536 + 10000 ))
  info "已随机生成 SSH 端口：${BOLD}$SSH_PORT${RESET}"
else
  while true; do
    if [[ "$SSH_PORT_INPUT" =~ ^[0-9]+$ ]] && (( SSH_PORT_INPUT >= 1 && SSH_PORT_INPUT <= 65535 )); then
      SSH_PORT="$SSH_PORT_INPUT"
      break
    fi
    warn "请输入有效端口号（1-65535）"
    read -rp "> " SSH_PORT_INPUT
  done
fi

# SSH 公钥
echo -e "${BOLD}粘贴你的 SSH 公钥内容（ssh-ed25519 / ssh-rsa ...）：${RESET}"
echo -e "${YELLOW}（提示：在本地执行 cat ~/.ssh/id_ed25519.pub 获取）${RESET}"
while true; do
  read -rp "> " SSH_PUBKEY
  [[ "$SSH_PUBKEY" == ssh-* ]] && break
  warn "公钥内容应以 ssh- 开头，请重新粘贴"
done

# Fail2ban 白名单 IP
read -rp "$(echo -e "${BOLD}Fail2ban 白名单 IP（你本地出口 IP，可留空）：${RESET}")" F2B_IGNOREIP
F2B_IGNOREIP="${F2B_IGNOREIP:-}"

# 可选模块
echo ""
read -rp "$(echo -e "${BOLD}是否安装 Docker？[y/N]：${RESET}")" INSTALL_DOCKER
INSTALL_DOCKER="${INSTALL_DOCKER,,}"

read -rp "$(echo -e "${BOLD}是否启用自动安全更新（unattended-upgrades）？[y/N]：${RESET}")" INSTALL_UNATTENDED
INSTALL_UNATTENDED="${INSTALL_UNATTENDED,,}"

read -rp "$(echo -e "${BOLD}是否开启内核安全加固参数？[y/N]：${RESET}")" HARDEN_KERNEL
HARDEN_KERNEL="${HARDEN_KERNEL,,}"

# 汇总确认
echo -e "\n${BOLD}============================================="
echo "  配置汇总，请确认："
echo "=============================================${RESET}"
echo "  新用户名       : $NEW_USER"
echo -e "  SSH 端口       : ${BOLD}${YELLOW}$SSH_PORT${RESET}  ← 请记住此端口"
echo "  SSH 公钥       : ${SSH_PUBKEY:0:40}..."
echo "  Fail2ban 白名单: ${F2B_IGNOREIP:-（无）}"
echo "  安装 Docker    : $INSTALL_DOCKER"
echo "  自动安全更新   : $INSTALL_UNATTENDED"
echo "  内核安全加固   : $HARDEN_KERNEL"
echo "============================================="
pause "以上配置正确，开始执行"

# ──────────────────────────────────────────────
# sysctl 辅助函数（全局可用）
# ──────────────────────────────────────────────
SYSCTL_CONF="/etc/sysctl.conf"
_sysctl_set() {
  local key="$1" val="$2"
  if grep -qE "^#?\s*${key}\s*=" "$SYSCTL_CONF"; then
    sed -i "s|^#\?\s*${key}\s*=.*|${key} = ${val}|" "$SYSCTL_CONF"
  else
    echo "${key} = ${val}" >> "$SYSCTL_CONF"
  fi
}

# ──────────────────────────────────────────────
# Step 1：更新系统 & 安装基础工具
# ──────────────────────────────────────────────
step "1 / 11  更新系统 & 安装基础工具"
apt update -y
apt upgrade -y
apt install -y curl wget git ufw htop vim fail2ban ntpdate rclone
success "系统更新 & 基础工具安装完成"

# ──────────────────────────────────────────────
# Step 2：NTP 时间同步
# ──────────────────────────────────────────────
step "2 / 11  配置 NTP 时间同步"

ntpdate pool.ntp.org && success "时间同步成功：$(date)" || warn "ntpdate 同步失败，请检查网络"

# 写入 root crontab（幂等：先删除旧条目再追加）
CRON_MARK="# init_vps: ntp sync"
(crontab -l 2>/dev/null | grep -v "$CRON_MARK"; \
  echo "0 0 * * * /usr/sbin/ntpdate pool.ntp.org > /dev/null 2>&1 $CRON_MARK") | crontab -
success "已添加每日 00:00 NTP 同步 cron 任务"

# ──────────────────────────────────────────────
# Step 3：文件描述符限制
# ──────────────────────────────────────────────
step "3 / 11  调整文件描述符限制"
LIMITS_CONF="/etc/security/limits.conf"
LIMITS_MARK="# init_vps: fd limits"

# 幂等：先删除旧行再追加
sed -i "/${LIMITS_MARK}/d" "$LIMITS_CONF"
cat >> "$LIMITS_CONF" <<EOF
* soft nofile 65535  ${LIMITS_MARK}
* hard nofile 65535  ${LIMITS_MARK}
root soft nofile 65535  ${LIMITS_MARK}
root hard nofile 65535  ${LIMITS_MARK}
EOF

_sysctl_set "fs.file-max" "2097152"
success "文件描述符限制已设置为 65535（重新登录后生效）"

# ──────────────────────────────────────────────
# Step 4：新建普通用户
# ──────────────────────────────────────────────
step "4 / 11  新建普通用户：$NEW_USER"
if id "$NEW_USER" &>/dev/null; then
  info "用户 $NEW_USER 已存在，跳过创建"
else
  adduser --gecos "" "$NEW_USER"
fi
usermod -aG sudo "$NEW_USER"
success "用户 $NEW_USER 已加入 sudo 组"

# ──────────────────────────────────────────────
# Step 5：配置 SSH 公钥
# ──────────────────────────────────────────────
step "5 / 11  配置 SSH 公钥"
USER_HOME="/home/$NEW_USER"
SSH_DIR="$USER_HOME/.ssh"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

AUTH_KEYS="$SSH_DIR/authorized_keys"
if grep -qF "$SSH_PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
  info "公钥已存在，跳过写入"
else
  echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
  success "公钥已写入 $AUTH_KEYS"
fi

chmod 600 "$AUTH_KEYS"
chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"

# ──────────────────────────────────────────────
# Step 6：修改 sshd_config
# ──────────────────────────────────────────────
step "6 / 11  配置 SSH（端口 / 加固 / 现代算法）"
SSHD_CONFIG="/etc/ssh/sshd_config"

# 备份（幂等：只备份一次）
[[ ! -f "${SSHD_CONFIG}.bak" ]] && cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak" \
  && info "已备份原始配置到 ${SSHD_CONFIG}.bak"

_sshd_set() {
  local key="$1" val="$2"
  if grep -qE "^#?\s*${key}\s" "$SSHD_CONFIG"; then
    sed -i "s|^#\?\s*${key}\s.*|${key} ${val}|" "$SSHD_CONFIG"
  else
    echo "${key} ${val}" >> "$SSHD_CONFIG"
  fi
}

# 基础安全
_sshd_set "Port"                   "$SSH_PORT"
_sshd_set "PermitRootLogin"        "no"
_sshd_set "PasswordAuthentication" "no"
_sshd_set "PubkeyAuthentication"   "yes"

# 限制登录用户白名单
_sshd_set "AllowUsers"             "$NEW_USER"

# 空闲超时（5分钟无响应 × 2次 = 10分钟自动断开）
_sshd_set "ClientAliveInterval"    "300"
_sshd_set "ClientAliveCountMax"    "2"

# 禁用不安全算法（幂等：先删除旧块再追加）
sed -i '/^# --- init_vps ssh algorithms start ---/,/^# --- init_vps ssh algorithms end ---/d' "$SSHD_CONFIG"

cat >> "$SSHD_CONFIG" <<'EOF'

# --- init_vps ssh algorithms start ---
# 密钥交换：只允许现代算法
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256
# 对称加密：只允许 AES-GCM 和 ChaCha20
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
# 消息认证：只允许 SHA-2 系列
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
# 主机密钥类型：优先 ed25519
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
# --- init_vps ssh algorithms end ---
EOF

# Ubuntu 24.04 兼容处理
if systemctl list-units --type=socket 2>/dev/null | grep -q "ssh.socket"; then
  systemctl daemon-reload
  systemctl restart ssh.socket
  info "已通过 ssh.socket 重启 SSH"
else
  systemctl restart ssh
  info "已通过 sshd 服务重启 SSH"
fi

success "SSH 配置完成"

warn "=========================================================="
warn " 重要：请立刻开一个新终端，测试能否以新端口 SSH 登录："
warn "   ssh -p ${SSH_PORT} ${NEW_USER}@<服务器IP>"
warn " 确认登录成功后，再回到此窗口按 Enter 继续。"
warn " 未确认前请勿关闭此窗口！"
warn "=========================================================="
pause "确认已可以用新端口和新用户成功登录"

# ──────────────────────────────────────────────
# Step 7：UFW 防火墙
# ──────────────────────────────────────────────
step "7 / 11  配置 UFW 防火墙"
ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp

ufw --force enable
success "UFW 已启用"
ufw status

# ──────────────────────────────────────────────
# Step 8：配置 Fail2ban
# ──────────────────────────────────────────────
step "8 / 11  配置 Fail2ban"
JAIL_LOCAL="/etc/fail2ban/jail.local"

[[ ! -f "$JAIL_LOCAL" ]] && cp /etc/fail2ban/jail.conf "$JAIL_LOCAL"

sed -i '/^# --- init_vps sshd block start ---/,/^# --- init_vps sshd block end ---/d' "$JAIL_LOCAL"

IGNOREIP_LINE=""
[[ -n "$F2B_IGNOREIP" ]] && IGNOREIP_LINE="ignoreip = 127.0.0.1/8 ::1 ${F2B_IGNOREIP}"

cat >> "$JAIL_LOCAL" <<EOF

# --- init_vps sshd block start ---
[sshd]
enabled   = true
port      = $SSH_PORT
maxretry  = 3
bantime   = 100d
banaction = ufw
${IGNOREIP_LINE}
# --- init_vps sshd block end ---
EOF

systemctl enable fail2ban
systemctl restart fail2ban
success "Fail2ban 配置完成"
fail2ban-client status sshd || warn "fail2ban 状态查询失败，请稍后手动检查"

# ──────────────────────────────────────────────
# Step 9：禁用 root 密码登录
# ──────────────────────────────────────────────
step "9 / 11  禁用 root 密码登录"
passwd -l root
success "root 密码已锁定"

# ──────────────────────────────────────────────
# Step 10：Docker（可选）
# ──────────────────────────────────────────────
if [[ "$INSTALL_DOCKER" == "y" ]]; then
  step "10 / 11  安装 Docker"

  if command -v docker &>/dev/null; then
    info "Docker 已安装，跳过"
  else
    curl -fsSL https://get.docker.com | sh
  fi

  usermod -aG docker "$NEW_USER"
  systemctl enable docker
  systemctl start docker

  # Docker daemon.json 加固
  # 幂等：已存在则跳过，避免覆盖用户自定义配置
  DOCKER_DAEMON="/etc/docker/daemon.json"
  if [[ ! -f "$DOCKER_DAEMON" ]]; then
    mkdir -p /etc/docker
    cat > "$DOCKER_DAEMON" <<'EOF'
{
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    systemctl restart docker
    success "Docker daemon.json 已写入（禁止容器提权 + 全局日志限制）"
  else
    info "daemon.json 已存在，跳过写入（请手动确认配置）"
  fi

  success "Docker 安装完成，$NEW_USER 已加入 docker 组（重新登录后生效）"

  # Docker Compose v2 检查
  if docker compose version &>/dev/null; then
    success "Docker Compose v2 已内置：$(docker compose version)"
  else
    apt install -y docker-compose-plugin
    success "Docker Compose v2 已安装"
  fi
else
  step "10 / 11  跳过 Docker 安装"
fi

# ──────────────────────────────────────────────
# Step 11：内核参数（BBR + 可选安全加固）
# ──────────────────────────────────────────────
step "11 / 11  内核参数配置"

# BBR（始终开启）
info "开启 BBR 拥塞控制..."
_sysctl_set "net.core.default_qdisc"          "fq"
_sysctl_set "net.ipv4.tcp_congestion_control" "bbr"

# 可选安全加固
if [[ "$HARDEN_KERNEL" == "y" ]]; then
  _sysctl_set "net.ipv4.tcp_syncookies"         "1"
  _sysctl_set "net.ipv4.conf.all.rp_filter"     "1"
  _sysctl_set "net.ipv4.conf.default.rp_filter" "1"
  info "内核安全参数已写入"
fi

sysctl -p

# 验证 BBR
BBR_CHECK=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [[ "$BBR_CHECK" == "bbr" ]]; then
  success "BBR 已成功开启"
else
  warn "BBR 验证失败，当前算法：${BBR_CHECK}，内核版本可能不支持（需 4.9+）"
fi

if [[ "$INSTALL_UNATTENDED" == "y" ]]; then
  apt install -y unattended-upgrades
  dpkg-reconfigure -plow unattended-upgrades
  success "自动安全更新已启用"
fi

# ──────────────────────────────────────────────
# 完成摘要
# ──────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}"
echo "╔════════════════════════════════════════════╗"
echo "║           🎉  初始化完成！                 ║"
echo "╚════════════════════════════════════════════╝"
echo -e "${RESET}"
echo "  用户             : $NEW_USER"
echo -e "  SSH 端口         : ${BOLD}${YELLOW}$SSH_PORT${RESET}  ← 请妥善保存！"
echo "  UFW 状态         : $(ufw status | head -1)"
echo "  Fail2ban         : $(systemctl is-active fail2ban)"
echo "  BBR              : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  rclone           : $(rclone --version 2>/dev/null | head -1 || echo '未安装')"
[[ "$INSTALL_DOCKER" == "y" ]] && \
  echo "  Docker           : $(docker --version 2>/dev/null || echo '请重新登录后验证')"
echo "  NTP cron         : 每日 00:00 同步 pool.ntp.org"
echo ""
echo -e "${YELLOW}后续建议：${RESET}"
echo "  1. 重新以 $NEW_USER 登录，验证所有功能正常"
echo "  2. 文件描述符限制（65535）重新登录后生效"
[[ "$INSTALL_DOCKER" == "y" ]] && \
  echo "  3. Docker 组权限重新登录后生效，测试：docker run hello-world"
echo "  4. 配置 rclone 云存储备份：rclone config"
echo ""