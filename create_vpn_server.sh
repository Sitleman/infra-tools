#!/bin/bash
set -euo pipefail
umask 077

if [[ ${1:-} == --help ]]; then
    echo 'Использование: sudo bash create_vpn_server.sh [имя_первого_пользователя]'
    echo 'Настройки: VPN_SERVER_ADDRESS, VPN_PORT (443), VPN_SNI (www.samsung.com).'
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo 'Запусти скрипт от root.' >&2; exit 1; }
[[ $(uname -s) == Linux && -d /run/systemd/system ]] || {
    echo 'Нужен сервер Ubuntu/Debian с systemd.' >&2; exit 1;
}
command -v apt-get >/dev/null
command -v flock >/dev/null

CONFIG=/usr/local/etc/xray/config.json
XRAY=/usr/local/bin/xray
NAME=${1:-Client1}
PORT=${VPN_PORT:-443}
SNI=${VPN_SNI:-www.samsung.com}
[[ $# -le 1 && $NAME =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || {
    echo 'Укажи одно имя: 1–64 латинских буквы, цифры, _ или -.' >&2; exit 1;
}
if ! [[ $PORT =~ ^[1-9][0-9]{0,4}$ ]] || (( PORT > 65535 )); then
    echo 'VPN_PORT должен быть числом от 1 до 65535.' >&2
    exit 1
fi
[[ $SNI =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]] || {
    echo 'VPN_SNI должен быть доменным именем.' >&2; exit 1;
}

exec 9>/run/lock/xray-vpn.lock
flock -x 9
if [[ -f $CONFIG ]]; then
    EXISTING=$(tr -d '[:space:]' < "$CONFIG")
    [[ -z $EXISTING || $EXISTING == '{}' ]] || {
        echo 'Конфиг Xray уже существует. Добавляй пользователей через add_vpn_user.sh.' >&2
        exit 1
    }
fi

apt-get update
apt-get install -y ca-certificates curl unzip jq qrencode openssl util-linux
WORK_DIR=$(mktemp -d)
TMP_DIR=
trap 'rm -rf -- "$WORK_DIR"; if [[ -n $TMP_DIR ]]; then rm -rf -- "$TMP_DIR"; fi' EXIT

if [[ ! -x $XRAY ]]; then
    curl -fLsS --retry 3 --connect-timeout 10 --max-time 120 \
        https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh \
        -o "$WORK_DIR/install-release.sh"
    bash "$WORK_DIR/install-release.sh" install --manually-restart-later
fi

SERVICE_COMMAND=$(systemctl show xray --property=ExecStart --value)
[[ $SERVICE_COMMAND == *"$XRAY"* && $SERVICE_COMMAND == *"-config $CONFIG "* ]] || {
    echo "Сервис xray должен запускать $XRAY run -config $CONFIG." >&2; exit 1;
}
SERVICE_USER=$(systemctl show xray --property=User --value)
SERVICE_GROUP=$(id -gn "${SERVICE_USER:-root}")
ADDRESS=${VPN_SERVER_ADDRESS:-$(curl -4fsS --retry 3 --connect-timeout 10 --max-time 30 https://api.ipify.org)}
[[ $ADDRESS =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || {
    echo 'VPN_SERVER_ADDRESS должен быть IPv4-адресом или доменным именем.' >&2; exit 1;
}
PASSWORD=$("$XRAY" uuid)
KEY_PAIR=$("$XRAY" x25519)
PRIVATE_KEY=$(printf '%s\n' "$KEY_PAIR" | awk -F': *' 'tolower($1) ~ /private/ {print $2}')
PUBLIC_KEY=$(printf '%s\n' "$KEY_PAIR" | awk -F': *' 'tolower($1) ~ /public|^password/ {print $2}')
[[ -n $PRIVATE_KEY && -n $PUBLIC_KEY && -n $PASSWORD ]] || {
    echo 'Не удалось получить ключи или пароль из Xray.' >&2; exit 1;
}
SHORT_ID=$(openssl rand -hex 8)
LINK="trojan://${PASSWORD}@${ADDRESS}:${PORT}?security=reality&pbk=${PUBLIC_KEY}&sni=${SNI}&fp=chrome&type=tcp&sid=${SHORT_ID}#${NAME}"
qrencode -t ANSIUTF8 "$LINK" > "$WORK_DIR/qr.txt"

install -d -o root -g "$SERVICE_GROUP" -m 750 /usr/local/etc/xray
TMP_DIR=$(mktemp -d "${CONFIG}.XXXXXX")
TMP=$TMP_DIR/config.json
jq -n --arg password "$PASSWORD" --arg name "$NAME" --argjson port "$PORT" \
    --arg sni "$SNI" --arg privateKey "$PRIVATE_KEY" --arg shortId "$SHORT_ID" '
    {
        log: {loglevel: "warning"},
        inbounds: [{
            tag: "vpn-trojan", listen: "0.0.0.0", port: $port, protocol: "trojan",
            settings: {clients: [{password: $password, email: $name}]},
            streamSettings: {
                network: "tcp", security: "reality",
                realitySettings: {
                    show: false, dest: ($sni + ":443"), xver: 0,
                    serverNames: [$sni], privateKey: $privateKey, shortIds: [$shortId]
                }
            }
        }],
        outbounds: [{protocol: "freedom", tag: "direct"}]
    }' > "$TMP"
"$XRAY" run -test -format json -config "$TMP"
chmod 640 "$TMP"
chown "root:$SERVICE_GROUP" "$TMP"
if [[ -f $CONFIG ]]; then cp -p "$CONFIG" "$WORK_DIR/config.json"; fi
WAS_ACTIVE=0
if systemctl is-active --quiet xray; then WAS_ACTIVE=1; fi
systemctl enable xray
mv -f "$TMP" "$CONFIG"

if ! (systemctl restart xray && sleep 1 && systemctl is-active --quiet xray); then
    if [[ -f $WORK_DIR/config.json ]]; then
        cp -p "$WORK_DIR/config.json" "$TMP"
        mv -f "$TMP" "$CONFIG"
    else
        rm -f "$CONFIG"
    fi
    if (( WAS_ACTIVE )); then systemctl restart xray || true; else systemctl stop xray || true; fi
    echo 'Xray не запустился; прежний конфиг восстановлен. Логи: journalctl -u xray -n 50 --no-pager' >&2
    exit 1
fi

printf '\nСервер запущен. Разреши входящий TCP %s в firewall и панели хостинга.\n' "$PORT"
printf 'Пользователь: %s\n%s\n\n' "$NAME" "$LINK"
cat "$WORK_DIR/qr.txt"
