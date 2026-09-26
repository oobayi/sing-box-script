#!/bin/bash

set -euo pipefail

# ============================================================
# sing-box VLESS + Reality 管理脚本
# Debian 12
# ============================================================

CONFIG="/etc/sing-box/config.json"
CLIENT_INFO="/root/sing-box-client.txt"
SB_COMMAND="/usr/local/bin/sb"

# ============================================================
# 基础检查
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "无法识别系统"
    exit 1
fi

. /etc/os-release

if [ "${ID:-}" != "debian" ]; then
    echo "此脚本仅建议用于 Debian"
    exit 1
fi

echo
echo "========================================"
echo " sing-box VLESS + Reality"
echo " Debian 12"
echo "========================================"
echo

# ============================================================
# SNI 菜单
# ============================================================

select_sni() {

    echo
    echo "请选择 Reality SNI："
    echo
    echo "1) www.amazon.com"
    echo "2) www.ebay.com"
    echo "3) www.paypal.com"
    echo "4) aws.amazon.com"
    echo "5) www.cloudflare.com"
    echo "6) www.microsoft.com"
    echo "7) www.apple.com"
    echo "8) www.amd.com"
    echo "9) www.nvidia.com"
    echo "10) 自定义"
    echo

    read -rp "请选择 [1-10]（默认 1）: " choice

    case "${choice:-1}" in
        1) SNI="www.amazon.com" ;;
        2) SNI="www.ebay.com" ;;
        3) SNI="www.paypal.com" ;;
        4) SNI="aws.amazon.com" ;;
        5) SNI="www.cloudflare.com" ;;
        6) SNI="www.microsoft.com" ;;
        7) SNI="www.apple.com" ;;
        8) SNI="www.amd.com" ;;
        9) SNI="www.nvidia.com" ;;
        10)
            read -rp "请输入自定义 SNI: " SNI

            if [ -z "$SNI" ]; then
                echo "SNI 不能为空"
                exit 1
            fi
            ;;
        *)
            SNI="www.amazon.com"
            ;;
    esac

    echo
    echo "已选择：$SNI"
}

# ============================================================
# 选择端口
# ============================================================

select_port() {

    echo
    read -rp "请输入监听端口（默认 443）: " PORT
    PORT="${PORT:-443}"

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] ||
       [ "$PORT" -lt 1 ] ||
       [ "$PORT" -gt 65535 ]; then

        echo "端口无效"
        exit 1
    fi

    if ss -lnt 2>/dev/null |
       awk '{print $4}' |
       grep -qE ":${PORT}$"; then

        echo
        echo "端口 ${PORT} 已被占用："

        ss -lntp | grep ":${PORT}" || true

        exit 1
    fi
}

# ============================================================
# 安装依赖
# ============================================================

echo "[1/7] 安装基础依赖..."

apt-get update

apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    iproute2 \
    jq

# ============================================================
# 官方 sing-box APT
# ============================================================

echo
echo "[2/7] 配置 sing-box 官方仓库..."

mkdir -p /etc/apt/keyrings

curl -fsSL \
    https://sing-box.app/gpg.key \
    -o /etc/apt/keyrings/sagernet.asc

chmod a+r /etc/apt/keyrings/sagernet.asc

cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

apt-get update

apt-get install -y sing-box

echo
sing-box version

# ============================================================
# 用户选择
# ============================================================

echo
echo "[3/7] 设置 Reality..."

select_port
select_sni

# ============================================================
# 生成参数
# ============================================================

echo
echo "[4/7] 生成密钥..."

UUID="$(sing-box generate uuid)"

KEYPAIR="$(sing-box generate reality-keypair)"

PRIVATE_KEY="$(
    echo "$KEYPAIR" |
    awk '/PrivateKey:/ {print $2}'
)"

PUBLIC_KEY="$(
    echo "$KEYPAIR" |
    awk '/PublicKey:/ {print $2}'
)"

SHORT_ID="$(openssl rand -hex 4)"

if [ -z "$PRIVATE_KEY" ] ||
   [ -z "$PUBLIC_KEY" ]; then

    echo "Reality 密钥生成失败"
    exit 1
fi

# ============================================================
# 获取 IP
# ============================================================

SERVER_IP="$(
    curl -4 -fsS \
    --max-time 8 \
    https://api.ipify.org \
    || true
)"

if [ -z "$SERVER_IP" ]; then

    SERVER_IP="$(
        curl -4 -fsS \
        --max-time 8 \
        https://icanhazip.com |
        tr -d '\n' \
        || true
    )"
fi

if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
fi

# ============================================================
# 写配置
# ============================================================

echo
echo "[5/7] 创建配置..."

mkdir -p /etc/sing-box

if [ -f "$CONFIG" ]; then

    cp "$CONFIG" \
       "${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

fi

cat >"$CONFIG" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },

  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",

      "listen": "::",
      "listen_port": ${PORT},

      "users": [
        {
          "name": "default",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],

      "tls": {
        "enabled": true,
        "server_name": "${SNI}",

        "reality": {
          "enabled": true,

          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },

          "private_key": "${PRIVATE_KEY}",

          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],

  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

chmod 600 "$CONFIG"

# ============================================================
# 配置检查
# ============================================================

echo
echo "[6/7] 检查配置..."

sing-box check -c "$CONFIG"

# ============================================================
# 启动
# ============================================================

echo
echo "[7/7] 启动 sing-box..."

systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box

sleep 2

if ! systemctl is-active --quiet sing-box; then

    echo
    echo "sing-box 启动失败："
    echo

    journalctl \
        -u sing-box \
        --output cat \
        -n 50 \
        --no-pager

    exit 1
fi

# ============================================================
# 保存内部参数
# ============================================================

cat >/etc/sing-box/reality.env <<EOF
SERVER_IP=${SERVER_IP}
PORT=${PORT}
UUID=${UUID}
SNI=${SNI}
PUBLIC_KEY=${PUBLIC_KEY}
PRIVATE_KEY=${PRIVATE_KEY}
SHORT_ID=${SHORT_ID}
EOF

chmod 600 /etc/sing-box/reality.env

# ============================================================
# 安装 sb 管理命令
# ============================================================

cat >"$SB_COMMAND" <<'SBSCRIPT'
#!/bin/bash

set -u

CONFIG="/etc/sing-box/config.json"
ENV_FILE="/etc/sing-box/reality.env"
CLIENT_INFO="/root/sing-box-client.txt"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行 sb"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "找不到 Reality 配置信息"
    exit 1
fi

load_env() {
    source "$ENV_FILE"
}

save_env() {

cat >"$ENV_FILE" <<EOF
SERVER_IP=${SERVER_IP}
PORT=${PORT}
UUID=${UUID}
SNI=${SNI}
PUBLIC_KEY=${PUBLIC_KEY}
PRIVATE_KEY=${PRIVATE_KEY}
SHORT_ID=${SHORT_ID}
EOF

chmod 600 "$ENV_FILE"

}

create_url() {

    load_env

    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#sing-box-Reality"

}

save_client() {

    create_url

cat >"$CLIENT_INFO" <<EOF
VLESS + Reality

Server:
${SERVER_IP}

Port:
${PORT}

UUID:
${UUID}

Flow:
xtls-rprx-vision

Security:
reality

SNI:
${SNI}

Fingerprint:
chrome

Public Key:
${PUBLIC_KEY}

Short ID:
${SHORT_ID}

Network:
tcp

VLESS Link:

${VLESS_LINK}
EOF

chmod 600 "$CLIENT_INFO"

}

check_restart() {

    echo
    echo "检查配置..."

    if ! sing-box check -c "$CONFIG"; then
        echo
        echo "配置错误，没有重启 sing-box"
        return 1
    fi

    systemctl restart sing-box

    sleep 1

    if systemctl is-active --quiet sing-box; then
        echo
        echo "sing-box 已重新启动"
    else
        echo
        echo "sing-box 启动失败"
        journalctl -u sing-box --output cat -n 30 --no-pager
        return 1
    fi
}

show_info() {

    load_env

    echo
    echo "========================================"
    echo " VLESS + Reality"
    echo "========================================"
    echo
    echo "Server:      ${SERVER_IP}"
    echo "Port:        ${PORT}"
    echo "UUID:        ${UUID}"
    echo "SNI:         ${SNI}"
    echo "Public Key:  ${PUBLIC_KEY}"
    echo "Short ID:    ${SHORT_ID}"
    echo "Flow:        xtls-rprx-vision"
    echo "Network:     tcp"
    echo
}

show_url() {

    create_url

    echo
    echo "${VLESS_LINK}"
    echo
}

select_sni() {

    echo
    echo "请选择 Reality SNI："
    echo
    echo "1) www.amazon.com"
    echo "2) www.ebay.com"
    echo "3) www.paypal.com"
    echo "4) aws.amazon.com"
    echo "5) www.cloudflare.com"
    echo "6) www.microsoft.com"
    echo "7) www.apple.com"
    echo "8) www.amd.com"
    echo "9) www.nvidia.com"
    echo "10) 自定义"
    echo

    read -rp "请选择 [1-10]: " CHOICE

    case "$CHOICE" in

        1) NEW_SNI="www.amazon.com" ;;
        2) NEW_SNI="www.ebay.com" ;;
        3) NEW_SNI="www.paypal.com" ;;
        4) NEW_SNI="aws.amazon.com" ;;
        5) NEW_SNI="www.cloudflare.com" ;;
        6) NEW_SNI="www.microsoft.com" ;;
        7) NEW_SNI="www.apple.com" ;;
        8) NEW_SNI="www.amd.com" ;;
        9) NEW_SNI="www.nvidia.com" ;;

        10)

            read -rp "请输入 SNI: " NEW_SNI

            if [ -z "$NEW_SNI" ]; then
                echo "SNI 不能为空"
                return
            fi

            ;;

        *)

            echo "无效选择"
            return

            ;;
    esac

    load_env

    SNI="$NEW_SNI"

    jq \
        --arg sni "$SNI" \
        '
        .inbounds[0].tls.server_name = $sni |
        .inbounds[0].tls.reality.handshake.server = $sni
        ' \
        "$CONFIG" >"${CONFIG}.tmp"

    mv "${CONFIG}.tmp" "$CONFIG"

    chmod 600 "$CONFIG"

    save_env
    save_client

    check_restart

    echo
    echo "SNI 已修改为：${SNI}"
}

change_port() {

    load_env

    echo
    echo "当前端口：${PORT}"

    read -rp "请输入新端口: " NEW_PORT

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] ||
       [ "$NEW_PORT" -lt 1 ] ||
       [ "$NEW_PORT" -gt 65535 ]; then

        echo "端口无效"
        return
    fi

    if ss -lnt |
       awk '{print $4}' |
       grep -qE ":${NEW_PORT}$"; then

        echo "端口 ${NEW_PORT} 已被占用"
        return
    fi

    PORT="$NEW_PORT"

    jq \
        --argjson port "$PORT" \
        '.inbounds[0].listen_port = $port' \
        "$CONFIG" >"${CONFIG}.tmp"

    mv "${CONFIG}.tmp" "$CONFIG"

    chmod 600 "$CONFIG"

    save_env
    save_client

    check_restart

    echo
    echo "端口已修改为：${PORT}"
}

change_uuid() {

    load_env

    UUID="$(sing-box generate uuid)"

    jq \
        --arg uuid "$UUID" \
        '.inbounds[0].users[0].uuid = $uuid' \
        "$CONFIG" >"${CONFIG}.tmp"

    mv "${CONFIG}.tmp" "$CONFIG"

    chmod 600 "$CONFIG"

    save_env
    save_client

    check_restart

    echo
    echo "新的 UUID："
    echo "$UUID"
}

change_key() {

    load_env

    KEYPAIR="$(sing-box generate reality-keypair)"

    PRIVATE_KEY="$(
        echo "$KEYPAIR" |
        awk '/PrivateKey:/ {print $2}'
    )"

    PUBLIC_KEY="$(
        echo "$KEYPAIR" |
        awk '/PublicKey:/ {print $2}'
    )"

    SHORT_ID="$(openssl rand -hex 4)"

    jq \
        --arg key "$PRIVATE_KEY" \
        --arg sid "$SHORT_ID" \
        '
        .inbounds[0].tls.reality.private_key = $key |
        .inbounds[0].tls.reality.short_id = [$sid]
        ' \
        "$CONFIG" >"${CONFIG}.tmp"

    mv "${CONFIG}.tmp" "$CONFIG"

    chmod 600 "$CONFIG"

    save_env
    save_client

    check_restart

    echo
    echo "Reality Key 已重新生成"
    echo
    echo "Public Key:"
    echo "$PUBLIC_KEY"
    echo
    echo "Short ID:"
    echo "$SHORT_ID"
}

update_singbox() {

    echo
    echo "正在更新 sing-box..."
    echo

    apt-get update
    apt-get install --only-upgrade -y sing-box

    echo
    sing-box version

    check_restart
}

status_singbox() {

    systemctl status sing-box --no-pager

}

logs_singbox() {

    journalctl -u sing-box --output cat -f

}

restart_singbox() {

    systemctl restart sing-box

    echo
    echo "sing-box 已重启"

}

menu() {

while true
do

    clear

    load_env

    echo "========================================"
    echo " sing-box VLESS + Reality"
    echo "========================================"
    echo
    echo "当前 SNI：${SNI}"
    echo "当前端口：${PORT}"
    echo
    echo "1) 查看配置"
    echo "2) 查看分享链接"
    echo "3) 修改端口"
    echo "4) 修改 SNI"
    echo "5) 重新生成 UUID"
    echo "6) 重新生成 Reality Key"
    echo "7) 查看运行状态"
    echo "8) 查看实时日志"
    echo "9) 更新 sing-box"
    echo "10) 重启 sing-box"
    echo "0) 退出"
    echo

    read -rp "请选择: " ACTION

    case "$ACTION" in

        1)
            show_info
            read -rp "按 Enter 返回..."
            ;;

        2)
            show_url
            read -rp "按 Enter 返回..."
            ;;

        3)
            change_port
            read -rp "按 Enter 返回..."
            ;;

        4)
            select_sni
            read -rp "按 Enter 返回..."
            ;;

        5)
            change_uuid
            read -rp "按 Enter 返回..."
            ;;

        6)
            change_key
            read -rp "按 Enter 返回..."
            ;;

        7)
            status_singbox
            read -rp "按 Enter 返回..."
            ;;

        8)
            logs_singbox
            ;;

        9)
            update_singbox
            read -rp "按 Enter 返回..."
            ;;

        10)
            restart_singbox
            read -rp "按 Enter 返回..."
            ;;

        0)
            exit 0
            ;;

        *)
            echo "无效选择"
            sleep 1
            ;;
    esac

done

}

# 支持简单命令
case "${1:-}" in

    info)
        show_info
        ;;

    url)
        show_url
        ;;

    status)
        status_singbox
        ;;

    log)
        logs_singbox
        ;;

    restart)
        restart_singbox
        ;;

    update)
        update_singbox
        ;;

    *)
        menu
        ;;

esac
SBSCRIPT

chmod +x "$SB_COMMAND"

# ============================================================
# 保存客户端
# ============================================================

"$SB_COMMAND" url >/dev/null

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#sing-box-Reality"

cat >"$CLIENT_INFO" <<EOF
VLESS + Reality

Server:
${SERVER_IP}

Port:
${PORT}

UUID:
${UUID}

Flow:
xtls-rprx-vision

Security:
reality

SNI:
${SNI}

Fingerprint:
chrome

Public Key:
${PUBLIC_KEY}

Short ID:
${SHORT_ID}

Network:
tcp

VLESS Link:

${VLESS_LINK}
EOF

chmod 600 "$CLIENT_INFO"

# ============================================================
# 完成
# ============================================================

echo
echo
echo "========================================"
echo " 安装成功"
echo "========================================"
echo
echo "Server:      ${SERVER_IP}"
echo "Port:        ${PORT}"
echo "UUID:        ${UUID}"
echo "SNI:         ${SNI}"
echo "Public Key:  ${PUBLIC_KEY}"
echo "Short ID:    ${SHORT_ID}"
echo
echo "VLESS 分享链接："
echo
echo "${VLESS_LINK}"
echo
echo "========================================"
echo
echo "以后直接运行："
echo
echo "  sb"
echo
echo "即可进入管理菜单。"
echo
echo "快捷命令："
echo
echo "  sb info"
echo "  sb url"
echo "  sb status"
echo "  sb log"
echo "  sb restart"
echo "  sb update"
echo
