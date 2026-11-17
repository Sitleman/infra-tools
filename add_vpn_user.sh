#!/bin/bash
set -euo pipefail
umask 077

if [[ ${1:-} == --help ]]; then
    echo 'Использование: sudo bash add_vpn_user.sh имя_пользователя'
    echo 'VPN_SERVER_ADDRESS задаёт публичный IPv4-адрес или домен сервера.'
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo 'Запусти скрипт от root.' >&2; exit 1; }
[[ $(uname -s) == Linux && -d /run/systemd/system ]] || {
    echo 'Нужен Linux-сервер с systemd.' >&2; exit 1;
}
NAME=${1:-}
[[ $# -eq 1 && $NAME =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || {
    echo 'Укажи одно имя: 1–64 латинских буквы, цифры, _ или -.' >&2; exit 1;
}
for dependency in jq curl qrencode flock; do command -v "$dependency" >/dev/null; done

CONFIG=/usr/local/etc/xray/config.json
XRAY=/usr/local/bin/xray
exec 9>/run/lock/xray-vpn.lock
flock -x 9
[[ -f $CONFIG && -x $XRAY ]] || {
    echo 'Сначала запусти create_vpn_server.sh.' >&2; exit 1;
}
SERVICE_COMMAND=$(systemctl show xray --property=ExecStart --value)
[[ $SERVICE_COMMAND == *"$XRAY"* && $SERVICE_COMMAND == *"-config $CONFIG "* ]] || {
    echo "Сервис xray должен запускать $XRAY run -config $CONFIG." >&2; exit 1;
}

INDEX=$(jq -er '
    [.inbounds | to_entries[] | select(
        .value.protocol == "trojan" and .value.streamSettings.security == "reality"
    ) | .key] |
    if length == 1 then .[0] else error("Нужен ровно один Trojan + REALITY inbound") end
' "$CONFIG")
CLIENTS=$(jq -er --argjson i "$INDEX" '
    .inbounds[$i].settings |
    if has("clients") then "clients" elif has("users") then "users"
    else error("Не найден список пользователей") end
' "$CONFIG")
jq -e --argjson i "$INDEX" --arg key "$CLIENTS" --arg name "$NAME" '
    .inbounds[$i].settings[$key] |
    if type != "array" then error("Список пользователей должен быть массивом")
    else all(.[]; .email != $name) end
' "$CONFIG" >/dev/null || {
    echo 'Имя уже занято или список пользователей повреждён.' >&2; exit 1;
}
NETWORK=$(jq -r --argjson i "$INDEX" '.inbounds[$i].streamSettings.network // "tcp"' "$CONFIG")
[[ $NETWORK == tcp || $NETWORK == raw ]] || {
    echo 'Поддерживается транспорт TCP/RAW.' >&2; exit 1;
}
ADDRESS=${VPN_SERVER_ADDRESS:-$(curl -4fsS --retry 3 --connect-timeout 10 --max-time 30 https://api.ipify.org)}
[[ $ADDRESS =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || {
    echo 'VPN_SERVER_ADDRESS должен быть IPv4-адресом или доменным именем.' >&2; exit 1;
}
PORT=$(jq -er --argjson i "$INDEX" '.inbounds[$i].port' "$CONFIG")
SNI=$(jq -er --argjson i "$INDEX" '.inbounds[$i].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
SHORT_ID=$(jq -er --argjson i "$INDEX" '.inbounds[$i].streamSettings.realitySettings.shortIds[0]' "$CONFIG")
PRIVATE_KEY=$(jq -er --argjson i "$INDEX" '.inbounds[$i].streamSettings.realitySettings.privateKey' "$CONFIG")
PASSWORD=$("$XRAY" uuid)
KEY_PAIR=$("$XRAY" x25519 -i "$PRIVATE_KEY")
PUBLIC_KEY=$(printf '%s\n' "$KEY_PAIR" | awk -F': *' 'tolower($1) ~ /public|^password/ {print $2}')
[[ -n $PASSWORD && -n $PUBLIC_KEY ]] || { echo 'Не удалось получить пароль или ключ Xray.' >&2; exit 1; }
LINK="trojan://${PASSWORD}@${ADDRESS}:${PORT}?security=reality&pbk=${PUBLIC_KEY}&sni=${SNI}&fp=chrome&type=tcp&sid=${SHORT_ID}#${NAME}"

WORK_DIR=$(mktemp -d)
TMP_DIR=
trap 'rm -rf -- "$WORK_DIR"; if [[ -n $TMP_DIR ]]; then rm -rf -- "$TMP_DIR"; fi' EXIT
TMP_DIR=$(mktemp -d "${CONFIG}.XXXXXX")
TMP=$TMP_DIR/config.json
qrencode -t ANSIUTF8 "$LINK" > "$WORK_DIR/qr.txt"
cp -p "$CONFIG" "$TMP"
jq --argjson i "$INDEX" --arg key "$CLIENTS" --arg name "$NAME" --arg password "$PASSWORD" '
    .inbounds[$i].settings[$key] += [{password: $password, email: $name}]
' "$CONFIG" > "$TMP"
"$XRAY" run -test -format json -config "$TMP"
cp -p "$CONFIG" "$WORK_DIR/config.json"
WAS_ACTIVE=0
if systemctl is-active --quiet xray; then WAS_ACTIVE=1; fi
mv -f "$TMP" "$CONFIG"

if ! (systemctl restart xray && sleep 1 && systemctl is-active --quiet xray); then
    cp -p "$WORK_DIR/config.json" "$TMP"
    mv -f "$TMP" "$CONFIG"
    if (( WAS_ACTIVE )); then systemctl restart xray || true; else systemctl stop xray || true; fi
    echo 'Xray не запустился; прежний конфиг восстановлен. Логи: journalctl -u xray -n 50 --no-pager' >&2
    exit 1
fi

printf '\nПользователь добавлен: %s\n%s\n\n' "$NAME" "$LINK"
cat "$WORK_DIR/qr.txt"
