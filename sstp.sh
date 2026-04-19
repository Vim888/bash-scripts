#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.0.8"
CONFIG_FILE="/etc/sstp-manager.conf"
ACCEL_CONF="/etc/accel-ppp.conf"
CHAP_FILE="/etc/ppp/chap-secrets"
SYSCTL_FILE="/etc/sysctl.d/99-sstp-vpn.conf"
SERVICE_FILE="/etc/systemd/system/accel-ppp.service"
NAT_RULES_FILE="/etc/nftables-sstp.nft"
NAT_SERVICE_FILE="/etc/systemd/system/sstp-nat.service"
CERTBOT_HOOK_FILE="/etc/letsencrypt/renewal-hooks/deploy/restart-accel-ppp.sh"
ACCEL_SRC_DIR="/opt/accel-ppp-code"
ACCEL_BUILD_DIR="/opt/accel-ppp-code/build"
CLI_ADDR="127.0.0.1:2001"

VPN_HOST=""
LE_EMAIL=""
VPN_GW_IP=""
VPN_PREFIX=""
VPN_SUBNET=""
VPN_POOL_RANGE=""
WAN_IF=""
DNS1="1.1.1.1"
DNS2="8.8.8.8"
CLIENT_IP_RANGES="0.0.0.0/0"

msg() { printf '
[+] %s
' "$*"; }
warn() { printf '
[!] %s
' "$*" >&2; }
fail() { printf '
[ERROR] %s
' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-0} -eq 0 ]] || fail "Запускай скрипт от root"
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "debian" ]] || fail "Скрипт рассчитан на Debian"
    [[ "${VERSION_ID:-}" == "12" ]] || warn "Скрипт тестировался на Debian 12, у тебя ${PRETTY_NAME:-unknown}"
  else
    fail "Не удалось определить ОС"
  fi
}

detect_wan_if() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

is_valid_vpn_gw() {
  local ip="$1"
  is_valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ ^10\. ]] || return 1
  return 0
}

ensure_dir() { mkdir -p "$1"; }

client_ip_ranges_block() {
  local item
  for item in $CLIENT_IP_RANGES; do
    printf '%s
' "$item"
  done
}

save_config() {
  umask 077
  cat > "$CONFIG_FILE" <<CFG
VPN_HOST="$VPN_HOST"
LE_EMAIL="$LE_EMAIL"
VPN_GW_IP="$VPN_GW_IP"
VPN_PREFIX="$VPN_PREFIX"
VPN_SUBNET="$VPN_SUBNET"
VPN_POOL_RANGE="$VPN_POOL_RANGE"
WAN_IF="$WAN_IF"
DNS1="$DNS1"
DNS2="$DNS2"
CLIENT_IP_RANGES="$CLIENT_IP_RANGES"
CFG
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
}

prompt_nonempty() {
  local prompt="$1"
  local value=""
  while true; do
    read -r -p "$prompt" value
    [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
    warn "Значение не может быть пустым"
  done
}

prompt_first_run_values() {
  local default_wan
  default_wan="$(detect_wan_if || true)"

  msg "Первичная настройка SSTP VPN"
  printf 'Нужен домен, который указывает на этот сервер. Для certbot порт 80 должен быть доступен снаружи.

'

  VPN_HOST="$(prompt_nonempty 'VPN hostname/FQDN (пример: vpn.example.com): ')"
  read -r -p "Email для Let's Encrypt (можно оставить пустым): " LE_EMAIL

  while true; do
    read -r -p "VPN gateway IP в сети 10.x.x.x (пример: 10.20.30.1): " VPN_GW_IP
    if is_valid_vpn_gw "$VPN_GW_IP"; then
      break
    fi
    warn "Нужен корректный IPv4 в диапазоне 10.x.x.x"
  done

  VPN_PREFIX="${VPN_GW_IP%.*}"
  VPN_SUBNET="${VPN_PREFIX}.0/24"
  VPN_POOL_RANGE="${VPN_PREFIX}.10-250"

  read -r -p "Разрешённые внешние IP/сети клиентов [0.0.0.0/0]: " CLIENT_IP_RANGES
  CLIENT_IP_RANGES="${CLIENT_IP_RANGES:-0.0.0.0/0}"

  read -r -p "WAN interface [${default_wan:-eth0}]: " WAN_IF
  WAN_IF="${WAN_IF:-${default_wan:-eth0}}"

  read -r -p "DNS1 [1.1.1.1]: " DNS1
  DNS1="${DNS1:-1.1.1.1}"

  read -r -p "DNS2 [8.8.8.8]: " DNS2
  DNS2="${DNS2:-8.8.8.8}"

  save_config
}

install_packages() {
  msg "Устанавливаю пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y     ca-certificates     certbot     cmake     curl     gcc     g++     git     libpcre2-dev     libssl-dev     make     nftables     openssl     procps
}

build_accel_ppp() {
  msg "Скачиваю и собираю accel-ppp"
  if [[ -d "$ACCEL_SRC_DIR/.git" ]]; then
    git -C "$ACCEL_SRC_DIR" pull --ff-only
  else
    rm -rf "$ACCEL_SRC_DIR"
    git clone https://github.com/accel-ppp/accel-ppp.git "$ACCEL_SRC_DIR"
  fi

  rm -rf "$ACCEL_BUILD_DIR"
  mkdir -p "$ACCEL_BUILD_DIR"
  (
    cd "$ACCEL_BUILD_DIR"
    cmake -DBUILD_DRIVER=FALSE -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release ..
    make -j"$(nproc)"
    make install
  )
}

ensure_chap_file() {
  ensure_dir /etc/ppp
  touch "$CHAP_FILE"
  chmod 600 "$CHAP_FILE"
}

issue_certificate() {
  msg "Выпускаю сертификат Let's Encrypt для $VPN_HOST"

  if ss -ltn '( sport = :80 )' | tail -n +2 | grep -q .; then
    fail "Порт 80 уже занят. Освободи его на время certbot --standalone и запусти скрипт снова."
  fi

  if [[ -f "/etc/letsencrypt/live/$VPN_HOST/fullchain.pem" && -f "/etc/letsencrypt/live/$VPN_HOST/privkey.pem" ]]; then
    msg "Сертификат уже существует, пропускаю выпуск"
    return 0
  fi

  if [[ -n "$LE_EMAIL" ]]; then
    certbot certonly --standalone --non-interactive --agree-tos --email "$LE_EMAIL" -d "$VPN_HOST"
  else
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$VPN_HOST"
  fi
}

write_accel_config() {
  msg "Пишу /etc/accel-ppp.conf"
  cat > "$ACCEL_CONF" <<EOF_CONF
[modules]
log_syslog
ippool
chap-secrets
sstp
auth_mschap_v2
cli

[client-ip-range]
$(client_ip_ranges_block)

[common]
single-session=replace

[ppp]
verbose=1
min-mtu=1200
mtu=1400
mru=1400
ccp=1
mppe=require
ipv4=require
ipv6=deny

[sstp]
bind=0.0.0.0
port=443
verbose=1
accept=ssl
ssl-pemfile=/etc/letsencrypt/live/$VPN_HOST/fullchain.pem
ssl-keyfile=/etc/letsencrypt/live/$VPN_HOST/privkey.pem
host-name=$VPN_HOST
hello-interval=60
ifname=sstp%d
ppp-max-mtu=1452
http-error=allow
ip-pool=sstp_pool

[chap-secrets]
chap-secrets=$CHAP_FILE

[ip-pool]
gw-ip-address=$VPN_GW_IP
$VPN_POOL_RANGE,sstp_pool

[dns]
dns1=$DNS1
dns2=$DNS2

[cli]
tcp=$CLI_ADDR
verbose=0
sessions-columns=ifname,username,ip,type,state,uptime,calling-sid

[log]
syslog=accel-pppd,daemon
level=3
EOF_CONF
}

write_sysctl() {
  msg "Включаю IPv4 forwarding"
  cat > "$SYSCTL_FILE" <<'EOF_SYSCTL'
net.ipv4.ip_forward=1
EOF_SYSCTL
  sysctl --system >/dev/null
}

write_nat_rules() {
  msg "Настраиваю NAT через nftables"
  cat > "$NAT_RULES_FILE" <<EOF_NFT
add table ip sstp_nat
add chain ip sstp_nat postrouting { type nat hook postrouting priority srcnat ; policy accept ; }
add rule ip sstp_nat postrouting ip saddr $VPN_SUBNET oifname "$WAN_IF" masquerade
EOF_NFT

  cat > "$NAT_SERVICE_FILE" <<'EOF_NATSVC'
[Unit]
Description=SSTP NAT rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'nft delete table ip sstp_nat 2>/dev/null || true; nft -f /etc/nftables-sstp.nft'
ExecReload=/bin/sh -c 'nft delete table ip sstp_nat 2>/dev/null || true; nft -f /etc/nftables-sstp.nft'
ExecStop=/bin/sh -c 'nft delete table ip sstp_nat 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF_NATSVC
}

write_service_file() {
  msg "Создаю systemd unit для accel-ppp"
  cat > "$SERVICE_FILE" <<'EOF_SERVICE'
[Unit]
Description=Accel-PPP
After=network.target

[Service]
ExecStart=/usr/sbin/accel-pppd -d -p /var/run/accel-pppd.pid -c /etc/accel-ppp.conf
StandardOutput=null
ExecReload=/bin/kill -SIGUSR1 $MAINPID
PIDFile=/var/run/accel-pppd.pid
Type=forking
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
Alias=accel-ppp.service
EOF_SERVICE
}

write_certbot_hook() {
  msg "Создаю deploy-hook для certbot"
  ensure_dir "$(dirname "$CERTBOT_HOOK_FILE")"
  cat > "$CERTBOT_HOOK_FILE" <<'EOF_HOOK'
#!/usr/bin/env bash
set -e
systemctl restart accel-ppp.service
EOF_HOOK
  chmod +x "$CERTBOT_HOOK_FILE"
}

ensure_certbot_renewal() {
  msg "Включаю автопродление certbot"
  systemctl enable --now certbot.timer
}

enable_services() {
  msg "Включаю и запускаю сервисы"
  systemctl daemon-reload
  systemctl enable --now sstp-nat.service
  systemctl enable --now accel-ppp.service
}

generate_password() {
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20
}

username_exists() {
  local username="$1"
  [[ -f "$CHAP_FILE" ]] && awk 'NF && $1 !~ /^#/' "$CHAP_FILE" | awk '{print $1}' | grep -Fxq "$username"
}

print_user_summary() {
  local username="$1"
  local password="$2"
  cat <<EOF_SUMMARY

========================================
SSTP VPN client summary
========================================
Server:   $VPN_HOST
Port:     443
VPN type: SSTP
User:     $username
Password: $password

Windows client:
  VPN provider: Windows (built-in)
  Server name or address: $VPN_HOST
  VPN type: SSTP
  Sign-in info: Username and password
========================================
EOF_SUMMARY
}

add_user() {
  local username password
  ensure_chap_file

  while true; do
    read -r -p "Новый username: " username
    [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "Разрешены только буквы, цифры, точка, дефис и подчёркивание"; continue; }
    username_exists "$username" && { warn "Пользователь уже существует"; continue; }
    break
  done

  password="$(generate_password)"
  printf '%s * %s *
' "$username" "$password" >> "$CHAP_FILE"
  chmod 600 "$CHAP_FILE"

  msg "Пользователь $username добавлен"
  print_user_summary "$username" "$password"
}

list_users() {
  ensure_chap_file
  msg "Список пользователей"
  if awk 'NF && $1 !~ /^#/ {print $1}' "$CHAP_FILE" | grep -q .; then
    awk 'NF && $1 !~ /^#/ {print $1}' "$CHAP_FILE" | nl -w2 -s'. '
  else
    printf 'Пользователей пока нет
'
  fi
}

remove_user() {
  local username tmpfile
  ensure_chap_file
  list_users
  read -r -p "Username для удаления: " username
  [[ -n "$username" ]] || { warn "Username пустой"; return 1; }
  username_exists "$username" || { warn "Пользователь не найден"; return 1; }

  tmpfile="$(mktemp)"
  awk -v u="$username" '!(NF && $1 == u)' "$CHAP_FILE" > "$tmpfile"
  cp -a "$CHAP_FILE" "$CHAP_FILE.bak.$(date +%Y%m%d%H%M%S)"
  mv "$tmpfile" "$CHAP_FILE"
  chmod 600 "$CHAP_FILE"
  msg "Пользователь $username удалён"
}

show_status() {
  printf '
Service status:
'
  systemctl --no-pager --full status accel-ppp.service sstp-nat.service certbot.timer || true
}

show_logs() {
  journalctl -u accel-ppp.service -f
}

show_server_summary() {
  printf '
========================================
'
  printf 'SSTP VPN server summary
'
  printf '========================================
'
  printf 'Version       : %s
' "$SCRIPT_VERSION"
  printf 'Hostname/FQDN : %s
' "$VPN_HOST"
  printf 'WAN interface : %s
' "$WAN_IF"
  printf 'VPN gateway   : %s
' "$VPN_GW_IP"
  printf 'VPN subnet    : %s
' "$VPN_SUBNET"
  printf 'VPN pool      : %s
' "$VPN_POOL_RANGE"
  printf 'Allowed src   : %s
' "$CLIENT_IP_RANGES"
  printf 'DNS           : %s, %s
' "$DNS1" "$DNS2"
  if [[ -f "/etc/letsencrypt/live/$VPN_HOST/fullchain.pem" ]]; then
    printf 'Certificate   : present
'
    openssl x509 -in "/etc/letsencrypt/live/$VPN_HOST/fullchain.pem" -noout -dates 2>/dev/null || true
  else
    printf 'Certificate   : not found
'
  fi
  printf '========================================
'
}

show_active_clients() {
  if ! command -v accel-cmd >/dev/null 2>&1; then
    warn "accel-cmd не найден"
    return 1
  fi
  accel-cmd -p 2001 show sessions || true
}

disconnect_client() {
  local ifname
  show_active_clients || return 1
  read -r -p "Введите ifname клиента для отключения (пример: sstp0): " ifname
  [[ -n "$ifname" ]] || { warn "ifname пустой"; return 1; }
  accel-cmd -p 2001 terminate if "$ifname" hard
}

stack_start() { systemctl start sstp-nat.service accel-ppp.service; }
stack_stop() { systemctl stop accel-ppp.service sstp-nat.service; }
stack_restart() { systemctl restart sstp-nat.service accel-ppp.service; }

rewrite_managed_files() {
  write_accel_config
  write_sysctl
  write_nat_rules
  write_service_file
  write_certbot_hook
  systemctl daemon-reload
}

first_run_install() {
  prompt_first_run_values
  install_packages
  build_accel_ppp
  ensure_chap_file
  issue_certificate
  rewrite_managed_files
  ensure_certbot_renewal
  enable_services

  msg "Базовая установка завершена"
  printf 'Теперь можно добавить пользователя через меню.
'
}

main_menu() {
  while true; do
    cat <<'EOF_MENU'

================ SSTP VPN Manager ================
1) Добавить пользователя
2) Удалить пользователя
3) Список пользователей
4) Старт сервиса
5) Стоп сервиса
6) Рестарт сервиса
7) Логи
8) Саммари сервера
9) Статус сервисов
10) Статус certbot.timer
11) Активные клиенты
12) Отключить клиента
13) Перегенерировать конфиг и unit-файлы
0) Выход
==================================================
EOF_MENU
    read -r -p "Выбор: " choice
    case "$choice" in
      1) add_user ;;
      2) remove_user ;;
      3) list_users ;;
      4) stack_start ;;
      5) stack_stop ;;
      6) stack_restart ;;
      7) show_logs ;;
      8) show_server_summary ;;
      9) show_status ;;
      10) systemctl --no-pager --full status certbot.timer || true ;;
      11) show_active_clients ;;
      12) disconnect_client ;;
      13) rewrite_managed_files; stack_restart ;;
      0) exit 0 ;;
      *) warn "Неизвестный пункт меню" ;;
    esac
  done
}

main() {
  require_root
  check_os

  if load_config; then
    main_menu
  else
    first_run_install
    main_menu
  fi
}

main "$@"
