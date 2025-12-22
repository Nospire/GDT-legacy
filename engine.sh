#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
UI_LANG="${2:-en}"

BASE_URL="${GDT_BASE_URL:-https://fix.geekcom.org}"

CFG_DIR="${HOME}/.scripts/geekcom-deck-tools"
WG_CONF="${CFG_DIR}/client.conf"

SESSION_ID=""
HAVE_SESSION=0
TUNNEL_UP=0
FINISH_SENT=0

# Сюда пишем "сервер", но НЕ маппим руками:
# берём host из Endpoint, либо "unknown"
CURRENT_SERVER_NAME="unknown"

# Пароль sudo, который передаёт GUI (если есть)
SUDO_PASS="${GDT_SUDO_PASS:-}"

mkdir -p "$CFG_DIR"

# ---------------- i18n ----------------

say() {
  local ru_msg="$1"
  local en_msg="$2"
  if [[ "$UI_LANG" == "ru" ]]; then
    echo "$ru_msg"
  else
    echo "$en_msg"
  fi
}

log_info() {
  local ru_msg="$1"
  local en_msg="$2"
  say "[INFO] $ru_msg" "[INFO] $en_msg"
}

log_err() {
  local ru_msg="$1"
  local en_msg="$2"
  say "[ERR] $ru_msg" "[ERR] $en_msg" >&2
}

# Маркеры для оркестратора/парсера логов (держим максимально простыми)
mark() {
  # намеренно без локали: это машинные маркеры
  echo "[#] $*"
}

# ---------------- utils ----------------

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_err "Команда '$1' не найдена. Установите её и повторите." \
            "Command '$1' not found. Install it and retry."
    exit 1
  fi
}

# Стабильный sudo-шлюз: либо пароль от GUI, либо уже активный sudo -n
run_sudo() {
  if [[ -n "$SUDO_PASS" ]]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' -- "$@"
  else
    sudo -n -- "$@"
  fi
}

flush_dns() {
  if command -v resolvectl >/dev/null 2>&1; then
    run_sudo resolvectl flush-caches || true
  elif command -v systemd-resolve >/dev/null 2>&1; then
    run_sudo systemd-resolve --flush-caches || true
  fi
}

json_get() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$key" << 'PY'
import sys, json
key = sys.argv[1]
data = sys.stdin.read()
try:
    obj = json.loads(data)
    val = obj.get(key, "")
    if val is None:
        val = ""
    if not isinstance(val, str):
        val = str(val)
    sys.stdout.write(val)
except Exception:
    pass
PY
  else
    log_err "Нужен либо jq, либо python3 для разбора JSON." \
            "Either jq or python3 is required to parse JSON."
    exit 1
  fi
}

print_endpoint_from_config() {
  grep -E '^[[:space:]]*Endpoint[[:space:]]*=' || true
}

# Достаём host из строки вида: "Endpoint = host:port"
endpoint_host_from_line() {
  local line="$1"
  local ep host
  ep="${line#*=}"
  ep="${ep//[[:space:]]/}"
  host="${ep%%:*}"
  if [[ -n "$host" ]]; then
    echo "$host"
  else
    echo "unknown"
  fi
}

# ---------------- cleanup / finish ----------------

cleanup() {
  # Если есть сессия и ещё не отправляли /finish — считаем, что операция прервалась
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    finish_session "cancelled"
    return
  fi

  if (( TUNNEL_UP )); then
    log_info "Отключаем туннель (wg-quick down)..." \
             "Bringing tunnel down (wg-quick down)..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    log_info "Удаляем временный конфиг VPN." \
             "Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi
}

trap 'cleanup' EXIT INT TERM

finish_session() {
  local result="$1"  # success | cancelled

  # 1) Сначала гасим туннель и чистим конфиг — чтобы /finish ушёл без VPN
  if (( TUNNEL_UP )); then
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    rm -f "$WG_CONF" || true
  fi

  # 2) Затем отправляем /finish
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    if ! curl -fsS -X POST "${BASE_URL}/api/v1/vpn/finish" \
        -H 'content-type: application/json' \
        -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}" \
        >/dev/null 2>&1; then
      log_err "finish: сетевая ошибка при отправке результата в оркестратор." \
              "finish: network error while sending result to orchestrator."
    fi
    FINISH_SENT=1
  fi
}

# ---------------- env checks ----------------

if [[ -z "$ACTION" ]]; then
  if [[ "$UI_LANG" == "ru" ]]; then
    echo "[ERR] Не указано действие." >&2
    echo "Использование: $0 <openh264_fix|steamos_update|flatpak_update|antizapret> [ru|en]" >&2
  else
    echo "[ERR] No ACTION specified." >&2
    echo "Usage: $0 <openh264_fix|steamos_update|flatpak_update|antizapret> [ru|en]" >&2
  fi
  exit 1
fi

need_cmd curl
need_cmd wg-quick
need_cmd ping

# Если пароля нет — требуем активный sudo -n.
if [[ -z "$SUDO_PASS" ]] && ! sudo -n true 2>/dev/null; then
  log_err "sudo не активен. Сначала нажмите кнопку sudo внизу и введите пароль." \
          "sudo is not active. Press the sudo button below and enter your password first."
  mark "DONE result=error code=E_SUDO"
  exit 1
fi

log_info "Geekcom Deck Tools engine started." "Geekcom Deck Tools engine started."
log_info "ACTION: ${ACTION}" "ACTION: ${ACTION}"
log_info "Orchestrator: ${BASE_URL}" "Orchestrator: ${BASE_URL}"

# ---------------- orchestrator API ----------------

request_initial_config() {
  local reason="$1"
  local res

  res=$(
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/request" \
      -H 'content-type: application/json' \
      -d "{\"reason\":\"${reason}\"}"
  )

  SESSION_ID="$(printf '%s' "$res" | json_get session_id || true)"
  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"

  if [[ -z "$SESSION_ID" || -z "$config_text" ]]; then
    log_err "Не удалось получить session_id или config_text от сервиса." \
            "Failed to get session_id or config_text from the service."
    echo "$res" >&2
    return 1
  fi

  HAVE_SESSION=1
  printf '%s\n' "$config_text"
}

request_next_config() {
  local res
  res=$(
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/report-broken" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\"}"
  )

  local new_sid
  new_sid="$(printf '%s' "$res" | json_get new_session_id || true)"
  if [[ -n "$new_sid" ]]; then
    SESSION_ID="$new_sid"
  fi

  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    log_err "Сервис не вернул config_text (возможен лимит попыток)." \
            "Service did not return config_text (attempt limit possible)."
    echo "$res" >&2
    return 1
  fi

  printf '%s\n' "$config_text"
}

# ---------------- VPN bring-up ----------------

ensure_vpn_up() {
  local reason="$1"
  local attempt=1
  local mode="initial"
  local config_text=""

  while :; do
    if [[ "$mode" == "initial" ]]; then
      config_text="$(request_initial_config "$reason")" || return 1
      mode="next"
    else
      config_text="$(request_next_config)" || return 1
    fi

    # маркер: получили конфиг (total пока неизвестен в v1)
    CURRENT_SERVER_NAME="unknown"
    mark "CONFIG index=${attempt} total=unknown format=wireguard server=unknown"

    printf '%s\n' "$config_text" > "$WG_CONF"
    sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" || true
    chmod 600 "$WG_CONF" || true

    local endpoint_line host
    endpoint_line="$(print_endpoint_from_config < "$WG_CONF" | head -n1 || true)"
    if [[ -n "$endpoint_line" ]]; then
      host="$(endpoint_host_from_line "$endpoint_line")"
      CURRENT_SERVER_NAME="$host"
      # необязательный машинный хвост (полезен для дебага)
      mark "WG endpoint=${endpoint_line#*=}"
      # уточняем server в логике (без ручного case)
      mark "CONFIG index=${attempt} total=unknown format=wireguard server=${CURRENT_SERVER_NAME}"
    fi

    # чистим хвосты от прошлых запусков
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    if ! run_sudo wg-quick up "$WG_CONF"; then
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      attempt=$((attempt + 1))
      continue
    fi

    TUNNEL_UP=1
    sleep 2
    flush_dns

    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
      return 0
    fi

    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    TUNNEL_UP=0
    rm -f "$WG_CONF" || true
    attempt=$((attempt + 1))
  done
}

# ---------------- action wrapper ----------------

run_with_vpn() {
  local reason="$1"
  shift

  CURRENT_SERVER_NAME="unknown"
  mark "START action=${ACTION} reason=${reason}"

  if ! ensure_vpn_up "$reason"; then
    log_err "Не удалось получить рабочее VPN-подключение." \
            "Failed to obtain a working VPN connection."
    mark "DONE result=error code=E_NO_CONFIG"
    return 1
  fi

  local status=0
  "$@" || status=$?

  if (( status == 0 )); then
    finish_session "success"
    mark "DONE result=success server=${CURRENT_SERVER_NAME}"
  else
    finish_session "cancelled"
    mark "DONE result=error code=${status}"
  fi

  return "$status"
}

# ---------------- dispatch ----------------

case "$ACTION" in
  openh264_fix)
    run_with_vpn "fix_openh264" "$CFG_DIR/actions/openh264_fix.sh"
    ;;
  steamos_update)
    run_with_vpn "system_update" "$CFG_DIR/actions/steamos_update.sh"
    ;;
  flatpak_update)
    run_with_vpn "system_update" "$CFG_DIR/actions/flatpak_update.sh"
    ;;
  antizapret)
    log_info "Running Geekcom antizapret without VPN (local mode)..." \
             "Running Geekcom antizapret without VPN (local mode)..."
    status=0
    "$CFG_DIR/actions/antizapret.sh" || status=$?
    if (( status == 0 )); then
      mark "DONE result=success"
    else
      mark "DONE result=error code=${status}"
    fi
    exit "$status"
    ;;
  *)
    log_err "Неизвестное действие: ${ACTION}" \
            "Unknown ACTION: ${ACTION}"
    mark "DONE result=error code=E_BAD_ACTION"
    exit 1
    ;;
esac
