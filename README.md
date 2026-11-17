# infra-tools

Установка Xray (Trojan + REALITY) на Ubuntu/Debian с systemd, интернетом и публичным IPv4.
Скрипт сам устанавливает Xray и зависимости. Команды ниже выполняются на сервере;
если вошёл как root, убери `sudo`.

## Установка

```bash
sudo apt-get update && sudo apt-get install -y git util-linux
git clone https://github.com/Sitleman/infra-tools.git
cd infra-tools
sudo bash create_vpn_server.sh Client1
```

`git` нужен для скачивания, `util-linux` — для команды `flock`, требуемой до запуска установки.
Открой входящий TCP 443 в firewall сервера и панели хостинга.
Если UFW уже включён: `sudo ufw allow 443/tcp`.

Импортируй выведенную ссылку или QR-код в клиент с поддержкой Trojan + REALITY.
Для всего устройства включи VPN/TUN. Ссылка и QR-код дают доступ к серверу — не публикуй их.

## Добавление пользователя

```bash
sudo bash add_vpn_user.sh ivan
```

Имя должно быть уникальным: 1–64 латинских букв, цифр, `_` или `-`.
Скрипт выдаст новую ссылку и QR-код; перезапуск Xray кратковременно прервёт соединения.

## Настройки

По умолчанию: порт `443`, SNI `www.samsung.com`, IPv4 определяется через `api.ipify.org`.
Другие значения можно передать при установке:

```bash
sudo env VPN_SERVER_ADDRESS=vpn.example.com VPN_PORT=8443 VPN_SNI=www.samsung.com bash create_vpn_server.sh Client1
```

Для своего порта открой соответствующий TCP-порт. SNI должен поддерживать TLS 1.3 и быть доступен с сервера.
Если задавал `VPN_SERVER_ADDRESS`, передавай его и при добавлении пользователей:
`sudo env VPN_SERVER_ADDRESS=vpn.example.com bash add_vpn_user.sh ivan`. IPv6 не поддерживается.

Существующий непустой конфиг `/usr/local/etc/xray/config.json` установщик не перезаписывает.
Уже установленный Xray автоматически не обновляется. Логи: `sudo journalctl -u xray -n 50 --no-pager`.
