#!/bin/bash
# ========================================
# BedolagaBan Agent - Установка из GHCR
# Для VPN нод (без исходного кода)
# ========================================

set -e

umask 077

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[38;5;203m'
    GREEN='\033[38;5;82m'
    YELLOW='\033[38;5;214m'
    BLUE='\033[38;5;45m'
    MUTED='\033[38;5;246m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MUTED=''
    BOLD=''
    DIM=''
    NC=''
fi

REGISTRY="ghcr.io/pedzeo"
TAG="${TAG:-latest}"
IMAGE="${REGISTRY}/bedolagaban-agent:${TAG}"
INSTALL_DIR="${INSTALL_DIR:-/opt/banhammer-agent}"
SETUP_PROFILE=""
INSTALL_ACTION=""
FORCE_REINSTALL=false

ui_width() {
    local width
    width=$(tput cols 2>/dev/null || echo 76)
    [ "$width" -lt 64 ] && width=64
    [ "$width" -gt 88 ] && width=88
    printf '%s\n' "$width"
}

ui_repeat() {
    local char="$1"
    local count="$2"
    local value
    [ "$count" -gt 0 ] || return 0
    printf -v value '%*s' "$count" ''
    printf '%s' "${value// /$char}"
}

ui_center() {
    local text="$1"
    local width="$2"
    local padding
    if [ "${#text}" -gt "$width" ]; then
        text="${text:0:$((width - 1))}…"
    fi
    padding=$(( (width - ${#text}) / 2 ))
    [ "$padding" -lt 0 ] && padding=0
    printf '%*s%s%*s' "$padding" '' "$text" "$((width - ${#text} - padding))" ''
}

ui_clear() {
    if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
        clear
    fi
}

ui_banner() {
    local product="$1"
    local subtitle="$2"
    local meta="${3:-}"
    local width
    local inner
    width=$(ui_width)
    inner=$((width - 2))
    echo ""
    printf '%b┌' "$BLUE"
    ui_repeat '─' "$inner"
    printf '┐%b\n' "$NC"
    printf '%b│%b%b' "$BLUE" "$NC" "$BOLD"
    ui_center "$product" "$inner"
    printf '%b%b│%b\n' "$NC" "$BLUE" "$NC"
    printf '%b│%b%b' "$BLUE" "$NC" "$MUTED"
    ui_center "$subtitle" "$inner"
    printf '%b%b│%b\n' "$NC" "$BLUE" "$NC"
    if [ -n "$meta" ]; then
        printf '%b│%b%b' "$BLUE" "$NC" "$DIM"
        ui_center "$meta" "$inner"
        printf '%b%b│%b\n' "$NC" "$BLUE" "$NC"
    fi
    printf '%b└' "$BLUE"
    ui_repeat '─' "$inner"
    printf '┘%b\n' "$NC"
}

ui_section() {
    local title="$1"
    local width
    local tail
    width=$(ui_width)
    tail=$((width - ${#title} - 5))
    [ "$tail" -lt 3 ] && tail=3
    echo ""
    printf '%b%b┌─ %s ' "$BLUE" "$BOLD" "$title"
    ui_repeat '─' "$tail"
    printf '%b\n' "$NC"
}

ui_progress() {
    local current="$1"
    local total="$2"
    local title="$3"
    local bar_width=28
    local filled
    local empty
    filled=$((current * bar_width / total))
    empty=$((bar_width - filled))
    echo ""
    printf '  %b[%b' "$MUTED" "$NC"
    printf '%b' "$BLUE"
    ui_repeat '■' "$filled"
    printf '%b' "$MUTED"
    ui_repeat '·' "$empty"
    printf ']%b %b%s/%s%b\n' "$NC" "$BOLD" "$current" "$total" "$NC"
    printf '  %b%s%b\n\n' "$BOLD" "$title" "$NC"
}

ui_menu_item() {
    local number="$1"
    local title="$2"
    local description="${3:-}"
    local marker="${4:-}"
    printf '  %b[%s]%b %b%s%b' "$BLUE" "$number" "$NC" "$BOLD" "$title" "$NC"
    [ -n "$marker" ] && printf ' %b%s%b' "$GREEN" "$marker" "$NC"
    printf '\n'
    [ -n "$description" ] && printf '      %b%s%b\n' "$MUTED" "$description" "$NC"
}

ui_kv() {
    local label="$1"
    local value="$2"
    local padding
    padding=$((24 - ${#label}))
    [ "$padding" -lt 1 ] && padding=1
    printf '  %b%s%b' "$MUTED" "$label" "$NC"
    printf '%*s%s\n' "$padding" '' "$value"
}

ui_command() {
    local label="$1"
    local command="$2"
    local padding
    padding=$((20 - ${#label}))
    [ "$padding" -lt 1 ] && padding=1
    printf '  %b%s%b' "$GREEN" "$label" "$NC"
    printf '%*s%b%s%b\n' "$padding" '' "$MUTED" "$command" "$NC"
}

print_success() { printf '  %b[ OK ]%b %s\n' "$GREEN" "$NC" "$1"; }
print_error() { printf '  %b[ERR ]%b %s\n' "$RED" "$NC" "$1"; }
print_warning() { printf '  %b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"; }
print_info() { printf '  %b[INFO]%b %s\n' "$BLUE" "$NC" "$1"; }

ask_question() {
    local question="$1"
    local answer
    printf '\n  %b?%b %s\n  %b>%b ' "$YELLOW" "$NC" "$question" "$BLUE" "$NC" >&2
    read -r answer
    answer=$(sanitize_terminal_input "$answer")
    echo "$answer"
}

ask_secret() {
    local question="$1"
    local answer
    printf '\n  %b?%b %s\n  %b>%b ' "$YELLOW" "$NC" "$question" "$BLUE" "$NC" >&2
    read -r -s answer
    printf '\n' >&2
    answer=$(sanitize_terminal_input "$answer")
    echo "$answer"
}

sanitize_terminal_input() {
    local value="$1"
    value=${value//$'\e[200~'/}
    value=${value//$'\e[201~'/}
    value=${value//$'\r'/}
    printf '%s' "$value"
}

normalize_yes_no_input() {
    local value
    value=$(sanitize_terminal_input "$1")
    value=${value//[[:space:]]/}
    printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

ask_yes_no() {
    local yn
    while true; do
        printf '\n  %b?%b %s %b[y/n]%b\n  %b>%b ' "$YELLOW" "$NC" "$1" "$MUTED" "$NC" "$BLUE" "$NC" >&2
        read -r yn
        yn=$(normalize_yes_no_input "$yn")
        case $yn in
            y|yes|да ) return 0;;
            n|no|нет ) return 1;;
            * ) printf '  %bВведи y/yes/да или n/no/нет%b\n' "$YELLOW" "$NC" >&2 ;;
        esac
    done
}

ask_port() {
    local question="$1"
    local default_port="$2"
    local value

    while true; do
        value=$(ask_question "$question (Enter=$default_port):")
        value=${value:-$default_port}
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then
            echo "$value"
            return 0
        fi
        printf '%b✗ Порт должен быть числом от 1 до 65535%b\n' "$RED" "$NC" >&2
    done
}

show_usage() {
    cat << EOF
Использование: $0 [режим]

Без аргументов    Интерактивная установка или меню обновления
--quick           Быстрая установка с автоопределением TLS и нагрузки
--advanced        Расширенная установка
--update          Обновить существующий агент
--diagnose        Показать состояние и последние ошибки
--reinstall       Полностью перенастроить агент
--help            Показать эту справку
EOF
}

install_base_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl openssl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl openssl ca-certificates
    else
        return 1
    fi
}

run_agent_preflight() {
    local architecture
    local available_kb
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        print_error "Установщик агента нужно запускать от root"
        exit 1
    fi
    architecture=$(uname -m)
    case "$architecture" in
        x86_64|amd64) print_success "Архитектура поддерживается: $architecture" ;;
        *) print_error "Архитектура $architecture не поддерживается готовым образом агента"; exit 1 ;;
    esac
    available_kb=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')
    if [ "${available_kb:-0}" -lt 1048576 ]; then
        if [ -n "${FOUND_INSTALL_DIR:-}" ]; then
            print_warning "Свободного места меньше 1 ГБ; диагностика доступна, перед обновлением будет выполнена очистка"
        else
            print_error "Для новой установки агента требуется минимум 1 ГБ свободного места"
            exit 1
        fi
    else
        print_success "Свободного места достаточно: $((available_kb / 1024)) МБ"
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
        if ask_yes_no "Установить недостающие curl/OpenSSL автоматически?"; then
            install_base_packages || { print_error "Не удалось установить системные утилиты"; exit 1; }
        else
            print_error "curl и OpenSSL обязательны"
            exit 1
        fi
    fi
    command -v timeout >/dev/null 2>&1 || { print_error "Не найдена системная утилита timeout (coreutils)"; exit 1; }
    if ! command -v docker >/dev/null 2>&1; then
        print_warning "Docker не установлен"
        if ask_yes_no "Установить Docker официальным скриптом?"; then
            local docker_script
            docker_script=$(mktemp)
            curl -fsSL https://get.docker.com -o "$docker_script" || { rm -f "$docker_script"; exit 1; }
            sh "$docker_script"
            rm -f "$docker_script"
            systemctl enable --now docker 2>/dev/null || true
        else
            exit 1
        fi
    fi
    docker info >/dev/null 2>&1 || { print_error "Docker daemon не отвечает"; exit 1; }
    docker compose version >/dev/null 2>&1 || { print_error "Не найден Docker Compose v2"; exit 1; }
    print_success "Docker и Docker Compose готовы"
}

probe_server_transport() {
    local host="$1"
    local port="$2"
    if timeout 8 openssl s_client -connect "${host}:${port}" -servername "$host" -brief </dev/null >/dev/null 2>&1; then
        return 0
    fi
    if timeout 5 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1; then
        return 1
    fi
    return 2
}

discover_remnawave_containers() {
    docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | awk -F'|' '
        tolower($2) ~ /remnawave\/node/ || tolower($1) ~ /^remnanode/ {print $1}
    '
}

choose_remnawave_container() {
    local -a containers
    local choice
    mapfile -t containers < <(discover_remnawave_containers)
    if [ "${#containers[@]}" -eq 0 ]; then
        print_error "На сервере не найден запущенный контейнер RemnaNode"
        print_info "Сначала установи и запусти ноду Remnawave, затем повтори установку агента"
        return 1
    fi
    if [ "${#containers[@]}" -eq 1 ]; then
        REMNAWAVE_CONTAINER_NAME="${containers[0]}"
        print_success "Найдена RemnaNode: $REMNAWAVE_CONTAINER_NAME"
        return 0
    fi

    echo ""
    print_warning "На сервере найдено несколько RemnaNode"
    for i in "${!containers[@]}"; do
        ui_menu_item "$((i + 1))" "${containers[$i]}"
    done
    while true; do
        choice=$(ask_question "К какой ноде подключить агент (1-${#containers[@]}):")
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#containers[@]}" ]; then
            REMNAWAVE_CONTAINER_NAME="${containers[$((choice - 1))]}"
            print_success "Выбрана RemnaNode: $REMNAWAVE_CONTAINER_NAME"
            return 0
        fi
        print_warning "Укажи номер ноды из списка"
    done
}

set_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp
    tmp=$(mktemp)
    if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
        awk -v k="$key" -v v="$value" '
            BEGIN { replaced = 0 }
            $0 ~ "^" k "=" {
                print k "=" v
                replaced = 1
                next
            }
            { print }
            END {
                if (!replaced) {
                    print k "=" v
                }
            }
        ' "$file" > "$tmp"
    else
        if [ -f "$file" ]; then
            cat "$file" > "$tmp"
        fi
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

ensure_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
        return 0
    fi
    printf '%s=%s\n' "$key" "$value" >> "$file"
}

get_env_value() {
    local file="$1"
    local key="$2"
    local default_value="${3:-}"
    local line
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)
    if [ -n "$line" ]; then
        line="${line#*=}"
        line=$(printf '%s' "$line" | tr -d '\r')
        case "$line" in
            \"*\") line="${line#\"}"; line="${line%\"}" ;;
            \'*\') line="${line#\'}"; line="${line%\'}" ;;
        esac
        printf '%s\n' "$line"
    else
        printf '%s\n' "$default_value"
    fi
}

detect_log_dir() {
    local mounted_source
    local remna_container="${REMNAWAVE_CONTAINER_NAME:-remnanode}"
    mounted_source=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/log/remnanode"}}{{.Source}}{{end}}{{end}}' "$remna_container" 2>/dev/null || true)
    if [ -n "$mounted_source" ]; then
        mkdir -p "$mounted_source"
        echo "$mounted_source"
        return 0
    fi
    for log_path in "/var/log/remnanode" "/opt/remnanode/logs" "/var/log/xray" "/var/log/3x-ui"; do
        if [ -d "$log_path" ]; then
            echo "$log_path"
            return 0
        fi
    done
    mkdir -p /var/log/remnanode
    echo "/var/log/remnanode"
}

find_existing_install_dir() {
    local candidate
    local checked="|"
    for candidate in \
        "${INSTALL_DIR}" \
        "/opt/banhammer-agent" \
        "/opt/bedolagaban-agent" \
        "/opt/bedolaga-agent" \
        "/root/banhammer-agent" \
        "$(pwd)"; do
        [ -n "$candidate" ] || continue
        case "$checked" in
            *"|${candidate}|"*) continue ;;
        esac
        checked="${checked}${candidate}|"
        if [ -f "${candidate}/.env" ] && [ -f "${candidate}/docker-compose.yml" ] && \
            grep -qE 'bedolagaban-agent|container_name:[[:space:]]*banhammer-agent' "${candidate}/docker-compose.yml" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

restore_reinstall_backup() {
    [ -n "${REINSTALL_BACKUP_SUFFIX:-}" ] || return 1
    [ -f "${INSTALL_DIR}/.env.bak.${REINSTALL_BACKUP_SUFFIX}" ] || return 1
    cp "${INSTALL_DIR}/.env.bak.${REINSTALL_BACKUP_SUFFIX}" "${INSTALL_DIR}/.env"
    if [ -f "${INSTALL_DIR}/docker-compose.yml.bak.${REINSTALL_BACKUP_SUFFIX}" ]; then
        cp "${INSTALL_DIR}/docker-compose.yml.bak.${REINSTALL_BACKUP_SUFFIX}" "${INSTALL_DIR}/docker-compose.yml"
    fi
    chmod 600 "${INSTALL_DIR}/.env" "${INSTALL_DIR}/docker-compose.yml" 2>/dev/null || true
    if [ -n "${PREVIOUS_AGENT_IMAGE:-}" ]; then
        docker image tag "$PREVIOUS_AGENT_IMAGE" "$IMAGE" >/dev/null || true
    fi
    (cd "$INSTALL_DIR" && docker compose up -d --force-recreate) || true
    print_warning "Предыдущая конфигурация агента восстановлена"
}

restore_agent_update_backup() {
    local env_file="$1"
    local compose_file="$2"
    local backup_suffix="$3"
    local old_image_id="$4"
    cp "${env_file}.bak.${backup_suffix}" "$env_file"
    if [ -f "${compose_file}.bak.${backup_suffix}" ]; then
        cp "${compose_file}.bak.${backup_suffix}" "$compose_file"
    fi
    chmod 600 "$env_file" "$compose_file" 2>/dev/null || true
    if [ -n "$old_image_id" ]; then
        docker image tag "$old_image_id" "$IMAGE" >/dev/null || true
    fi
    if ! (cd "$INSTALL_DIR" && docker compose up -d --force-recreate); then
        print_error "Предыдущие файлы восстановлены, но контейнер не запустился"
        return 1
    fi
    print_warning "Предыдущая конфигурация и образ агента восстановлены"
}

write_agent_compose() {
    local compose_file="${1:-${INSTALL_DIR}/docker-compose.yml}"
    local env_file="${2:-${INSTALL_DIR}/.env}"
    local compose_tmp="${compose_file}.new.$$"
    cat > "$compose_tmp" << COMPOSE
services:
  banhammer-agent:
    image: ${IMAGE}
    container_name: banhammer-agent
    hostname: banhammer-agent
    restart: unless-stopped
    env_file: .env
    environment:
      - LOG_DIR=/var/log/remnanode
      - DB_PATH=/app/data/messages.db
    volumes:
      - \${LOG_DIR:-/var/log/remnanode}:/var/log/remnanode:rw
      - ./data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
      - \${DOCKER_BIN:-/usr/bin/docker}:/usr/bin/docker:ro
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 64M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
COMPOSE
    chmod 600 "$compose_tmp"
    if ! docker compose --env-file "$env_file" -f "$compose_tmp" config --quiet; then
        rm -f "$compose_tmp"
        print_error "Сгенерированная Docker Compose конфигурация агента некорректна"
        return 1
    fi
    mv -f "$compose_tmp" "$compose_file"
    chmod 600 "$compose_file"
}

print_agent_diagnostics() {
    echo ""
    print_info "Диагностика агента:"
    docker inspect -f 'status={{.State.Status}} running={{.State.Running}} exit={{.State.ExitCode}} restart={{.RestartCount}} oom={{.State.OOMKilled}}' banhammer-agent 2>/dev/null || true
    docker compose ps || true
    echo ""
    print_info "Последние логи агента:"
    docker logs --tail=120 banhammer-agent 2>&1 || docker compose logs --tail=120 || true
}

fail_agent_ready() {
    local reason="$1"
    print_error "$reason"
    print_agent_diagnostics
    exit 1
}

verify_agent_runtime() {
    local success_message="${1:-Готово: агент обновлен и работает}"
    print_info "Проверяю, что агент поднялся..."
    local timeout="${AGENT_READY_TIMEOUT:-90}"
    local remna_container
    local xray_command
    local last_reason="агент еще запускается"
    local logs=""
    local agent_version=""
    local xray_bridge_required=0
    local ready=0
    local deadline=$(($(date +%s) + timeout))

    remna_container=$(get_env_value "${INSTALL_DIR}/.env" REMNAWAVE_CONTAINER_NAME "remnanode")
    xray_command=$(get_env_value "${INSTALL_DIR}/.env" XRAY_API_COMMAND "docker exec remnanode rw-core")
    if ! docker inspect "$remna_container" >/dev/null 2>&1; then
        local discovered_container
        discovered_container=$(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | awk -F'|' 'tolower($2) ~ /remnawave\/node/ {print $1; exit}')
        if [ -n "$discovered_container" ]; then
            print_warning "Контейнер ${remna_container} не найден, обнаружен ${discovered_container}"
            remna_container="$discovered_container"
        fi
    fi
    if printf '%s\n' " $xray_command " | grep -Fq " $remna_container "; then
        xray_bridge_required=1
    fi

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ! docker inspect -f '{{.State.Running}}' banhammer-agent 2>/dev/null | grep -q "true"; then
            last_reason="контейнер banhammer-agent не запущен"
            sleep 3
            continue
        fi

        logs=$(docker logs --tail=250 banhammer-agent 2>&1 || true)
        if printf '%s\n' "$logs" | grep -Eiq 'INVALID LICENSE|LICENSE_KEY not configured|Configuration error|ConfigValidationError|Traceback|NameError|ModuleNotFoundError|No module named|Cannot connect to the Docker daemon|No space left on device|Agent cannot start|CRITICAL'; then
            fail_agent_ready "Агент запустился с критической ошибкой"
        fi

        agent_version=$(docker exec banhammer-agent sh -lc 'cat /app/VERSION 2>/dev/null || true' 2>/dev/null | tr -d '\r' | head -n 1)
        if [ -z "$agent_version" ]; then
            last_reason="не удалось прочитать версию агента"
            sleep 3
            continue
        fi

        if ! docker exec banhammer-agent sh -lc 'test -S /var/run/docker.sock' 2>/dev/null; then
            last_reason="Docker socket не доступен внутри агента"
            sleep 3
            continue
        fi

        if ! docker exec banhammer-agent sh -lc 'command -v ipset >/dev/null && command -v iptables >/dev/null' 2>/dev/null; then
            last_reason="в контейнере агента отсутствуют ipset/iptables"
            sleep 3
            continue
        fi
        if ! docker exec banhammer-agent sh -lc 'probe="banhammer_ready_$$"; trap '\''ipset destroy "$probe" >/dev/null 2>&1 || true'\'' EXIT; ipset create "$probe" hash:ip' >/dev/null 2>&1; then
            last_reason="контейнер агента запущен без NET_ADMIN или ядро хоста не поддерживает ipset"
            sleep 3
            continue
        fi

        if ! printf '%s\n' "$logs" | grep -qi 'Configuration validated'; then
            last_reason="агент еще не подтвердил валидную конфигурацию"
            sleep 3
            continue
        fi

        if ! printf '%s\n' "$logs" | grep -qi 'License valid'; then
            last_reason="агент еще не подтвердил лицензию"
            sleep 3
            continue
        fi

        if ! printf '%s\n' "$logs" | grep -qi 'Connected to '; then
            last_reason="агент еще не подключился к центральному серверу"
            sleep 3
            continue
        fi

        if [ "$xray_bridge_required" -eq 1 ]; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$remna_container"; then
                last_reason="контейнер ${remna_container} не найден, Xray routing не сможет применяться"
                sleep 3
                continue
            fi
            local xray_ready=0
            if docker exec "$remna_container" rw-core api lsrules --timeout=5 --server=127.0.0.1:61001 >/dev/null 2>&1; then
                xray_ready=1
            else
                local native_socket
                native_socket=$(docker exec "$remna_container" sh -lc 'cat /run/s6/container_environment/XTLS_API_SOCKET_PATH 2>/dev/null || true' | tr -d '\r\n')
                if [ -n "$native_socket" ] && docker exec "$remna_container" rw-core api lsrules --timeout=5 --server="unix:@$native_socket" >/dev/null 2>&1; then
                    xray_ready=1
                fi
            fi
            if [ "$xray_ready" -ne 1 ]; then
                last_reason="Xray API не отвечает через legacy bridge и native socket"
                sleep 3
                continue
            fi
        fi

        ready=1
        break
    done

    if [ "$ready" -ne 1 ]; then
        fail_agent_ready "Агент не подтвердил готовность за ${timeout} секунд: ${last_reason}"
    fi

    print_success "Контейнер banhammer-agent запущен"
    print_success "Версия агента: ${agent_version}"
    print_success "Docker socket доступен агенту"
    print_success "Конфигурация и лицензия подтверждены"
    print_success "Агент подключился к центральному серверу"
    if [ "$xray_bridge_required" -eq 1 ]; then
        print_success "Xray API bridge отвечает"
    fi

    echo ""
    print_info "Последние логи агента:"
    docker logs --tail=30 banhammer-agent 2>&1 || docker compose logs --tail=30 || true
    echo ""
    print_success "$success_message"
}

upgrade_existing_runtime() {
    local env_file="${INSTALL_DIR}/.env"
    local compose_file="${INSTALL_DIR}/docker-compose.yml"
    local old_image_id
    local current_xray_command
    echo ""
    print_info "Обновление BedolagaBan Agent: ${INSTALL_DIR}"
    if [ ! -f "$env_file" ]; then
        print_error "Existing agent config not found: ${env_file}"
        exit 1
    fi
    print_info "1/7 Проверяю Docker..."
    if ! command -v docker &> /dev/null; then
        print_error "Docker not found"
        exit 1
    fi
    if ! docker compose version &> /dev/null; then
        print_error "Docker Compose v2 not found"
        exit 1
    fi
    print_success "Docker и Docker Compose доступны"

    DOCKER_BIN=$(command -v docker)
    old_image_id=$(docker inspect -f '{{.Image}}' banhammer-agent 2>/dev/null || true)
    REMNAWAVE_CONTAINER_NAME=$(get_env_value "$env_file" REMNAWAVE_CONTAINER_NAME "remnanode")
    if ! docker inspect "$REMNAWAVE_CONTAINER_NAME" >/dev/null 2>&1; then
        choose_remnawave_container || exit 1
    fi
    mkdir -p "${INSTALL_DIR}/data"
    print_info "2/7 Делаю backup текущих файлов..."
    local backup_suffix
    backup_suffix=$(date +%Y%m%d%H%M%S)
    cp "$env_file" "${env_file}.bak.${backup_suffix}"
    if [ -f "$compose_file" ]; then
        cp "$compose_file" "${compose_file}.bak.${backup_suffix}"
    fi
    print_success "Backup создан: *.bak.${backup_suffix}"

    print_info "3/7 Обновляю .env для BLOCK/DIRECT/WARP и Remnawave auto-setup..."
    ensure_env_value "$env_file" LOG_DIR "$(detect_log_dir)"
    ensure_env_value "$env_file" LOG_PATTERN "*.log"
    set_env_value "$env_file" SUSPICIOUS_DESTINATION_AGENT_GUARD_ENABLED true
    set_env_value "$env_file" SUSPICIOUS_DESTINATION_AGENT_BLOCK_ENABLED false
    ensure_env_value "$env_file" SUSPICIOUS_DESTINATION_BLOCK_COMMAND ""
    set_env_value "$env_file" SUSPICIOUS_DESTINATION_BLOCK_TIMEOUT 2
    set_env_value "$env_file" XRAY_ROUTING_BLOCK_ENABLED true
    current_xray_command=$(get_env_value "$env_file" XRAY_API_COMMAND "")
    if [ -z "$current_xray_command" ] || [[ "$current_xray_command" == docker\ exec*rw-core* ]]; then
        set_env_value "$env_file" XRAY_API_COMMAND "docker exec ${REMNAWAVE_CONTAINER_NAME} rw-core"
    fi
    ensure_env_value "$env_file" XRAY_API_SERVER "127.0.0.1:61001"
    set_env_value "$env_file" XRAY_API_TIMEOUT 15
    set_env_value "$env_file" XRAY_API_RETRY_INTERVAL 300
    set_env_value "$env_file" XRAY_ROUTING_RECONCILE_INTERVAL 60
    ensure_env_value "$env_file" XRAY_RULE_DATA_DIR "/var/log/remnanode"
    set_env_value "$env_file" XRAY_ROUTING_AUTO_SETUP_ENABLED true
    set_env_value "$env_file" XRAY_ROUTING_RULES_ENABLED true
    ensure_env_value "$env_file" XRAY_BLOCK_RULE_TAG BANHAMMER_SUSPICIOUS_DESTINATIONS
    ensure_env_value "$env_file" XRAY_BLOCK_OUTBOUND_TAG BLOCK
    ensure_env_value "$env_file" XRAY_DIRECT_RULE_TAG BANHAMMER_DIRECT_DESTINATIONS
    ensure_env_value "$env_file" XRAY_DIRECT_OUTBOUND_TAG DIRECT
    ensure_env_value "$env_file" XRAY_WARP_RULE_TAG BANHAMMER_WARP_DESTINATIONS
    ensure_env_value "$env_file" XRAY_WARP_OUTBOUND_TAG WARP
    set_env_value "$env_file" XRAY_WARP_AUTO_SETUP_ENABLED true
    ensure_env_value "$env_file" XRAY_WARP_WORK_DIR /app/data/warp
    ensure_env_value "$env_file" XRAY_WARP_PROFILE_PATH ""
    ensure_env_value "$env_file" XRAY_WARP_OUTBOUND_CONFIG_PATH ""
    ensure_env_value "$env_file" XRAY_WARP_ENDPOINT ""
    set_env_value "$env_file" XRAY_WARP_MTU 1280
    ensure_env_value "$env_file" REMNAWAVE_DOCKER_COMMAND docker
    set_env_value "$env_file" REMNAWAVE_CONTAINER_NAME "$REMNAWAVE_CONTAINER_NAME"
    ensure_env_value "$env_file" REMNAWAVE_API_BRIDGE_PORT 61001
    set_env_value "$env_file" REMNAWAVE_AUTO_RESTART_ENABLED true
    set_env_value "$env_file" REMNAWAVE_AUTO_LOG_MOUNT_ENABLED true
    set_env_value "$env_file" REMNAWAVE_AUTO_SETUP_TIMEOUT 20
    ensure_env_value "$env_file" REMNAWAVE_WARP_OUTBOUND_CONFIG_PATH /tmp/banhammer-warp-outbound.json
    set_env_value "$env_file" DOCKER_BIN "$DOCKER_BIN"
    chmod 600 "$env_file"
    print_success ".env обновлен"

    print_info "4/7 Обновляю docker-compose.yml..."
    if ! write_agent_compose; then
        restore_agent_update_backup "$env_file" "$compose_file" "$backup_suffix" "$old_image_id" || true
        exit 1
    fi
    print_success "docker-compose.yml обновлен"

    cd "$INSTALL_DIR"
    print_info "Освобождаю место от старых неиспользуемых образов..."
    docker image prune -a -f --filter "until=168h" >/dev/null 2>&1 || true
    print_info "5/7 Скачиваю свежий образ агента: ${IMAGE}"
    if ! docker compose pull; then
        cp "${env_file}.bak.${backup_suffix}" "$env_file"
        [ -f "${compose_file}.bak.${backup_suffix}" ] && cp "${compose_file}.bak.${backup_suffix}" "$compose_file"
        chmod 600 "$env_file" "$compose_file" 2>/dev/null || true
        print_error "Не удалось скачать образ; предыдущая конфигурация восстановлена"
        exit 1
    fi
    print_success "Образ агента скачан"

    print_info "6/7 Пересоздаю контейнер агента..."
    if ! docker compose up -d --force-recreate; then
        print_error "Не удалось пересоздать контейнер агента"
        restore_agent_update_backup "$env_file" "$compose_file" "$backup_suffix" "$old_image_id" || true
        exit 1
    fi
    print_success "Контейнер пересоздан"

    print_info "7/7 Жду запуск и проверяю состояние..."
    sleep "${AGENT_START_DELAY:-8}"
    docker compose ps
    if (verify_agent_runtime "Готово: агент обновлен и работает"); then
        return 0
    fi

    print_warning "Новая версия не прошла проверку. Выполняю откат..."
    restore_agent_update_backup "$env_file" "$compose_file" "$backup_suffix" "$old_image_id" || true
    sleep "${AGENT_START_DELAY:-8}"
    if (verify_agent_runtime "Предыдущая версия агента восстановлена и работает"); then
        print_warning "Обновление отменено, рабочая версия восстановлена"
    else
        print_error "Откат выполнен, но агент не подтвердил готовность"
    fi
    exit 1
}

check_node_logs() {
    local log_dir="$1"
    local access_log="${log_dir}/access.log"
    local error_log="${log_dir}/error.log"
    local access_ok=0
    local error_ok=0

    echo ""
    print_info "Проверка логов ноды в ${log_dir}"

    if [ -f "$access_log" ]; then
        local access_size
        access_size=$(wc -c < "$access_log" 2>/dev/null || echo 0)
        print_success "Найден access.log (${access_size} байт)"
        if [ "$access_size" -gt 0 ]; then
            access_ok=1
        fi
    else
        print_warning "Не найден файл ${access_log}"
    fi

    if [ -f "$error_log" ]; then
        local error_size
        error_size=$(wc -c < "$error_log" 2>/dev/null || echo 0)
        print_success "Найден error.log (${error_size} байт)"
        if [ "$error_size" -gt 0 ]; then
            error_ok=1
        fi
    else
        print_warning "Не найден файл ${error_log}"
    fi

    if [ ! -f "$access_log" ] || [ ! -f "$error_log" ] || { [ "$access_ok" -eq 0 ] && [ "$error_ok" -eq 0 ]; }; then
        echo ""
        print_warning "Похоже, что логи ноды не пишутся или запись логов не настроена"
        print_warning "Проверь конфиг Xray/RemnaNode и включи запись логов, например:"
        echo '  "log": {'
        echo '    "error": "/var/log/remnanode/error.log",'
        echo '    "access": "/var/log/remnanode/access.log",'
        echo '    "loglevel": "info"'
        echo '  }'
        echo ""
        print_warning "Без access.log и error.log агент не сможет нормально читать подключения"
    fi
}

parse_agent_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --quick) SETUP_PROFILE="quick" ;;
            --advanced) SETUP_PROFILE="advanced" ;;
            --upgrade-runtime|--update|update) INSTALL_ACTION="update" ;;
            --diagnose) INSTALL_ACTION="diagnose" ;;
            --reinstall|--install) FORCE_REINSTALL=true ;;
            --help|-h) show_usage; exit 0 ;;
            *) print_error "Неизвестный аргумент: $1"; show_usage; exit 2 ;;
        esac
        shift
    done
}

diagnose_existing_agent() {
    local logs
    cd "$INSTALL_DIR"
    print_agent_diagnostics
    if ! docker inspect -f '{{.State.Running}}' banhammer-agent 2>/dev/null | grep -q true; then
        print_error "Контейнер агента не запущен"
        return 1
    fi
    logs=$(docker logs --tail=300 banhammer-agent 2>&1 || true)
    if ! grep -qi 'Configuration validated' <<< "$logs"; then
        print_error "Агент не подтвердил конфигурацию"
        return 1
    fi
    if ! grep -qi 'License valid' <<< "$logs"; then
        print_error "Агент не подтвердил лицензию"
        return 1
    fi
    if ! grep -qi 'Connected to ' <<< "$logs"; then
        print_error "Агент не подключен к центральному серверу"
        return 1
    fi
    print_success "Агент работает, лицензия и подключение подтверждены"
}

choose_existing_agent_action() {
    ui_section "Установленный агент"
    ui_kv "Каталог" "$INSTALL_DIR"
    echo ""
    ui_menu_item "1" "Обновить агент" "Скачать образ, проверить запуск и откатить при ошибке" "РЕКОМЕНДУЕТСЯ"
    ui_menu_item "2" "Диагностика" "Проверить конфигурацию, лицензию и подключение"
    ui_menu_item "3" "Полная перенастройка" "Текущие файлы будут сохранены в backup"
    ui_menu_item "4" "Выйти"
    while true; do
        local choice
        choice=$(ask_question "Выбери действие (1-4, Enter=1):")
        choice=${choice:-1}
        case "$choice" in
            1) INSTALL_ACTION="update"; return ;;
            2) INSTALL_ACTION="diagnose"; return ;;
            3)
                if ask_yes_no "Перенастроить агент с резервной копией текущих файлов?"; then
                    FORCE_REINSTALL=true
                    return
                fi
                ;;
            4) exit 0 ;;
            *) print_warning "Выбери число от 1 до 4" ;;
        esac
    done
}

if [ "${BEDOLAGABAN_INSTALLER_LIB_ONLY:-0}" = "1" ]; then
    if [ "${BASH_SOURCE[0]}" = "$0" ]; then
        exit 0
    fi
    return 0
fi

parse_agent_arguments "$@"
if [ "${AUTO_UPGRADE_RUNTIME:-}" = "1" ]; then
    INSTALL_ACTION="update"
fi

FOUND_INSTALL_DIR=$(find_existing_install_dir || true)
if [ -n "$FOUND_INSTALL_DIR" ]; then
    INSTALL_DIR="$FOUND_INSTALL_DIR"
fi

ui_clear
ui_banner "BEDOLAGABAN" "NODE AGENT" "${IMAGE}  •  ${INSTALL_DIR}"
run_agent_preflight

if [ -n "$FOUND_INSTALL_DIR" ] && [ "$FORCE_REINSTALL" != "true" ]; then
    [ -n "$INSTALL_ACTION" ] || choose_existing_agent_action
    case "$INSTALL_ACTION" in
        update) upgrade_existing_runtime; exit $? ;;
        diagnose) diagnose_existing_agent; exit $? ;;
    esac
fi

if [ -z "$FOUND_INSTALL_DIR" ] && [ -n "$INSTALL_ACTION" ]; then
    print_error "Установленный агент не найден"
    exit 1
fi

if [ -n "$FOUND_INSTALL_DIR" ] && [ "$FORCE_REINSTALL" = "true" ]; then
    REINSTALL_BACKUP_SUFFIX=$(date +%Y%m%d%H%M%S)
    cp "${INSTALL_DIR}/.env" "${INSTALL_DIR}/.env.bak.${REINSTALL_BACKUP_SUFFIX}"
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] && cp "${INSTALL_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml.bak.${REINSTALL_BACKUP_SUFFIX}"
    print_success "Резервная копия создана: *.bak.${REINSTALL_BACKUP_SUFFIX}"
fi

# ========================================
ui_section "Новая установка"
print_info "Агент отправляет данные о подключениях на центральный сервер"

if ! ask_yes_no "Готов начать установку?"; then
    print_warning "Установка отменена"
    exit 0
fi

if [ -z "$SETUP_PROFILE" ]; then
    ui_section "Режим настройки"
    ui_menu_item "1" "Быстрая установка" "TLS и параметры нагрузки определяются автоматически" "РЕКОМЕНДУЕТСЯ"
    ui_menu_item "2" "Расширенная установка" "Ручной выбор TLS и профиля нагрузки"
    while true; do
        PROFILE_CHOICE=$(ask_question "Выбери режим (1-2, Enter=1):")
        PROFILE_CHOICE=${PROFILE_CHOICE:-1}
        case "$PROFILE_CHOICE" in
            1) SETUP_PROFILE="quick"; break ;;
            2) SETUP_PROFILE="advanced"; break ;;
            *) print_warning "Выбери 1 или 2" ;;
        esac
    done
fi
print_success "Режим: $([ "$SETUP_PROFILE" = "quick" ] && echo "быстрый" || echo "расширенный")"

# Шаг 1: Проверка Docker
ui_progress 1 5 "Проверка Docker"
DOCKER_BIN=$(command -v docker)
print_success "Docker: $(docker --version)"
print_success "Docker Compose: $(docker compose version --short 2>/dev/null || docker compose version)"

# Шаг 2: Настройка директории
ui_progress 2 5 "Подготовка директорий"
mkdir -p "${INSTALL_DIR}/data"
print_success "Директория: ${INSTALL_DIR}"

# Шаг 3: Сбор конфигурации
ui_progress 3 5 "Настройка подключения"
print_info "Эти данные должен предоставить администратор сервера"
echo ""

# NODE_NAME
print_info "Уникальное имя этой ноды (например: node1, germany-1, vps-amsterdam)"
DEFAULT_NODE_NAME=$(hostname -s 2>/dev/null || echo node)
NODE_NAME=$(ask_question "Имя ноды (Enter=${DEFAULT_NODE_NAME}):")
NODE_NAME=${NODE_NAME:-$DEFAULT_NODE_NAME}
while [ -z "$NODE_NAME" ]; do
    print_warning "Имя ноды обязательно!"
    NODE_NAME=$(ask_question "Имя ноды:")
done

# BANHAMMER_HOST
echo ""
print_info "IP адрес или домен сервера BedolagaBan"
while true; do
    SERVER_ADDRESS=$(ask_question "Адрес сервера (например agent.example.com или 1.2.3.4:9999):")
    SERVER_ADDRESS=${SERVER_ADDRESS#http://}
    SERVER_ADDRESS=${SERVER_ADDRESS#https://}
    SERVER_ADDRESS=${SERVER_ADDRESS%/}
    if [[ "$SERVER_ADDRESS" =~ ^([A-Za-z0-9.-]+):([0-9]{1,5})$ ]]; then
        BANHAMMER_HOST="${BASH_REMATCH[1]}"
        DETECTED_SERVER_PORT="${BASH_REMATCH[2]}"
    else
        BANHAMMER_HOST="$SERVER_ADDRESS"
        DETECTED_SERVER_PORT=""
    fi
    if [[ "$BANHAMMER_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
        break
    fi
    print_warning "Укажи только корректный IP или домен без пути"
done

# BANHAMMER_PORT
echo ""
BANHAMMER_PORT=$(ask_port "TCP порт сервера BedolagaBan" "${DETECTED_SERVER_PORT:-${BANHAMMER_PORT:-9999}}")

# AGENT_TOKEN
echo ""
print_info "Нужен AGENT_TOKEN центрального сервера BedolagaBan, не API-токен Remnawave"
print_info "При установке агента из Telegram-админки этот токен подставляется автоматически"
print_info "Для ручной установки выполни на центральном сервере (стандартный путь):"
printf '  %b%s%b\n' "$MUTED" "sudo grep '^AGENT_TOKEN=' /opt/banhammer/.env" "$NC"
print_warning "Не отправляй этот токен посторонним: он общий для подключения твоих агентов"
AGENT_TOKEN=$(ask_secret "Токен подключения агента BedolagaBan (AGENT_TOKEN):")
while [ -z "$AGENT_TOKEN" ]; do
    print_warning "Токен обязателен!"
    AGENT_TOKEN=$(ask_secret "Токен подключения агента BedolagaBan (AGENT_TOKEN):")
done

# Шаг 4: Настройка логов
echo ""
ui_progress 4 5 "Настройка RemnaNode и логов"

choose_remnawave_container || exit 1

# Автоопределение источника mount ноды и создание каталога без ручного ввода.
LOG_DIR=$(detect_log_dir)
mkdir -p "$LOG_DIR"
print_success "Каталог логов подготовлен: $LOG_DIR"

check_node_logs "$LOG_DIR"

# LICENSE_KEY
echo ""
print_info "Лицензионный ключ получен при покупке"
print_info "Пробный ключ можно получить на сайте: https://shop.pedze.ru/"
print_info "Формат: BB-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
LICENSE_KEY=$(ask_secret "Лицензионный ключ:")
while true; do
    if [[ "$LICENSE_KEY" =~ ^BB-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        print_success "Формат ключа корректный"
        break
    else
        print_error "Неверный формат! Ожидается: BB-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        LICENSE_KEY=$(ask_secret "Лицензионный ключ:")
    fi
done

# TLS
echo ""
print_info "Определяю тип подключения к ${BANHAMMER_HOST}:${BANHAMMER_PORT}..."
if probe_server_transport "$BANHAMMER_HOST" "$BANHAMMER_PORT"; then
    TLS_ENABLED="true"
    print_success "Обнаружено TLS-подключение"
else
    TRANSPORT_RESULT=$?
    if [ "$TRANSPORT_RESULT" -eq 1 ]; then
        TLS_ENABLED="false"
        print_success "Обнаружено обычное TCP-подключение без TLS"
    elif [ "$SETUP_PROFILE" = "advanced" ]; then
        print_warning "Центральный сервер сейчас недоступен; автоопределение невозможно"
        if ask_yes_no "Сервер настроен с TLS?"; then
            TLS_ENABLED="true"
        else
            TLS_ENABLED="false"
        fi
    else
        print_error "Не удалось подключиться к ${BANHAMMER_HOST}:${BANHAMMER_PORT}"
        print_info "Проверь адрес, порт и firewall центрального сервера"
        exit 1
    fi
fi

# Профиль нагрузки
echo ""
if [ "$SETUP_PROFILE" = "quick" ]; then
    PROFILE=2
    BATCH_SIZE=100; BATCH_TIMEOUT=0.5; MAX_QUEUE_SIZE=50000; DEDUP_WINDOW=45
    print_success "Автоматический профиль нагрузки: до 10000 пользователей"
else
    ui_section "Профиль нагрузки"
    ui_menu_item "1" "До 1 000 пользователей"
    ui_menu_item "2" "От 1 000 до 10 000" "Сбалансированный профиль" "РЕКОМЕНДУЕТСЯ"
    ui_menu_item "3" "От 10 000 до 50 000"
    ui_menu_item "4" "Более 50 000"
    while true; do
        PROFILE=$(ask_question "Выбери (1-4, Enter=2):")
        PROFILE=${PROFILE:-2}
        case $PROFILE in
            1) BATCH_SIZE=50;  BATCH_TIMEOUT=1.0; MAX_QUEUE_SIZE=10000;  DEDUP_WINDOW=30; break;;
            2) BATCH_SIZE=100; BATCH_TIMEOUT=0.5; MAX_QUEUE_SIZE=50000;  DEDUP_WINDOW=45; break;;
            3) BATCH_SIZE=200; BATCH_TIMEOUT=0.5; MAX_QUEUE_SIZE=100000; DEDUP_WINDOW=60; break;;
            4) BATCH_SIZE=500; BATCH_TIMEOUT=0.3; MAX_QUEUE_SIZE=200000; DEDUP_WINDOW=90; break;;
            *) print_warning "Выбери 1, 2, 3 или 4";;
        esac
    done
fi

ui_section "Проверка настроек"
ui_kv "Нода" "$NODE_NAME"
ui_kv "RemnaNode" "$REMNAWAVE_CONTAINER_NAME"
ui_kv "Центральный сервер" "${BANHAMMER_HOST}:${BANHAMMER_PORT}"
ui_kv "TLS" "$([ "$TLS_ENABLED" = "true" ] && echo "Включен" || echo "Выключен")"
ui_kv "Каталог логов" "$LOG_DIR"
ui_kv "Профиль нагрузки" "$PROFILE"
ui_kv "Секреты" "Токен и лицензия скрыты"
echo ""
if ! ask_yes_no "Установить агент с этими настройками?"; then
    print_warning "Установка отменена"
    exit 0
fi

# Шаг 5: Создание конфигурации и запуск
ui_progress 5 5 "Проверка конфигурации и запуск"

# .env
STAGE_DIR="${INSTALL_DIR}/.installer-stage.$$"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
STAGE_ENV="${STAGE_DIR}/.env"
STAGE_COMPOSE="${STAGE_DIR}/docker-compose.yml"
cat > "$STAGE_ENV" << EOF
# BedolagaBan Agent Configuration
# Создано: $(date)

NODE_NAME=${NODE_NAME}
BANHAMMER_HOST=${BANHAMMER_HOST}
BANHAMMER_PORT=${BANHAMMER_PORT}
AGENT_TOKEN=${AGENT_TOKEN}
LICENSE_KEY=${LICENSE_KEY}
TLS_ENABLED=${TLS_ENABLED}

LOG_DIR=${LOG_DIR}
LOG_PATTERN=*.log

HEARTBEAT_INTERVAL=30
RECONNECT_DELAY=5
STATS_INTERVAL=60

BATCH_SIZE=${BATCH_SIZE}
BATCH_TIMEOUT=${BATCH_TIMEOUT}
MAX_QUEUE_SIZE=${MAX_QUEUE_SIZE}

DEDUP_ENABLED=true
DEDUP_WINDOW_SECONDS=${DEDUP_WINDOW}
DEDUP_INCLUDE_PORT=false

COMPRESSION_ENABLED=true
COMPRESSION_THRESHOLD=1024

FILTER_ENABLED=true
FILTER_PORTS=53,123
SUSPICIOUS_DESTINATION_AGENT_GUARD_ENABLED=true
SUSPICIOUS_DESTINATION_AGENT_BLOCK_ENABLED=false
SUSPICIOUS_DESTINATION_BLOCK_COMMAND=
SUSPICIOUS_DESTINATION_BLOCK_TIMEOUT=2
XRAY_ROUTING_BLOCK_ENABLED=true
XRAY_API_COMMAND=docker exec ${REMNAWAVE_CONTAINER_NAME} rw-core
XRAY_API_SERVER=127.0.0.1:61001
XRAY_API_TIMEOUT=15
XRAY_API_RETRY_INTERVAL=300
XRAY_ROUTING_RECONCILE_INTERVAL=60
XRAY_RULE_DATA_DIR=/var/log/remnanode
XRAY_ROUTING_AUTO_SETUP_ENABLED=true
XRAY_ROUTING_RULES_ENABLED=true
XRAY_BLOCK_RULE_TAG=BANHAMMER_SUSPICIOUS_DESTINATIONS
XRAY_BLOCK_OUTBOUND_TAG=BLOCK
XRAY_DIRECT_RULE_TAG=BANHAMMER_DIRECT_DESTINATIONS
XRAY_DIRECT_OUTBOUND_TAG=DIRECT
XRAY_WARP_RULE_TAG=BANHAMMER_WARP_DESTINATIONS
XRAY_WARP_OUTBOUND_TAG=WARP
XRAY_WARP_AUTO_SETUP_ENABLED=true
XRAY_WARP_WORK_DIR=/app/data/warp
XRAY_WARP_PROFILE_PATH=
XRAY_WARP_OUTBOUND_CONFIG_PATH=
XRAY_WARP_ENDPOINT=
XRAY_WARP_MTU=1280
REMNAWAVE_DOCKER_COMMAND=docker
REMNAWAVE_CONTAINER_NAME=${REMNAWAVE_CONTAINER_NAME}
REMNAWAVE_API_BRIDGE_PORT=61001
REMNAWAVE_AUTO_RESTART_ENABLED=true
REMNAWAVE_AUTO_LOG_MOUNT_ENABLED=true
REMNAWAVE_AUTO_SETUP_TIMEOUT=20
REMNAWAVE_WARP_OUTBOUND_CONFIG_PATH=/tmp/banhammer-warp-outbound.json
DOCKER_BIN=${DOCKER_BIN}

BACKPRESSURE_ENABLED=true
BACKPRESSURE_THRESHOLD=0.8
BACKPRESSURE_MAX_DELAY=5.0
EOF

chmod 600 "$STAGE_ENV"
write_agent_compose "$STAGE_COMPOSE" "$STAGE_ENV"
mv -f "$STAGE_ENV" "${INSTALL_DIR}/.env"
mv -f "$STAGE_COMPOSE" "${INSTALL_DIR}/docker-compose.yml"
rmdir "$STAGE_DIR"
chmod 600 "${INSTALL_DIR}/.env" "${INSTALL_DIR}/docker-compose.yml"
print_success "Конфигурация агента проверена и применена атомарно"

# Запуск
cd "${INSTALL_DIR}"
PREVIOUS_AGENT_IMAGE=$(docker inspect -f '{{.Image}}' banhammer-agent 2>/dev/null || true)

# Проверяем авторизацию в GHCR
echo ""
print_info "Проверяю доступ к реестру образов..."
if ! docker pull "$IMAGE" --quiet 2>/dev/null; then
    print_warning "Нет доступа к ${REGISTRY}. Нужна авторизация."
    print_info "Создай токен: https://github.com/settings/tokens/new"
    print_info "Нужные права: read:packages"
    echo ""
    printf '%bGitHub Personal Access Token: %b' "$YELLOW" "$NC"
    read -r -s GHCR_TOKEN
    echo ""
    if echo "$GHCR_TOKEN" | docker login ghcr.io -u pedzeo --password-stdin 2>/dev/null; then
        print_success "Авторизация успешна"
    else
        print_error "Не удалось авторизоваться в GHCR"
        exit 1
    fi
fi

print_info "Скачивание образа..."
docker image prune -a -f --filter "until=168h" >/dev/null 2>&1 || true
if ! docker compose pull; then
    print_error "Не удалось скачать образ агента; контейнер не изменен"
    restore_reinstall_backup || true
    exit 1
fi

echo ""
print_info "Запуск агента..."
if ! docker compose up -d; then
    print_error "Не удалось запустить контейнер агента"
    restore_reinstall_backup || true
    exit 1
fi

sleep "${AGENT_START_DELAY:-8}"

echo ""
print_info "Статус:"
docker compose ps

if ! (verify_agent_runtime "Готово: агент установлен и работает"); then
    if [ -n "${REINSTALL_BACKUP_SUFFIX:-}" ]; then
        print_warning "Новая конфигурация не прошла проверку, восстанавливаю предыдущую"
        restore_reinstall_backup || true
        sleep "${AGENT_START_DELAY:-8}"
        (verify_agent_runtime "Предыдущая конфигурация восстановлена") || true
    fi
    exit 1
fi

AGENT_VERSION=$(docker exec banhammer-agent sh -lc 'cat /app/VERSION 2>/dev/null || true' 2>/dev/null | tr -d '\r\n')
ui_banner "АГЕНТ ГОТОВ" "Все обязательные проверки пройдены" "BedolagaBan Agent v${AGENT_VERSION:-неизвестно}"
print_success "Агент подключен к центральному серверу и принимает правила"

ui_section "Подключение"
ui_kv "Нода" "$NODE_NAME"
ui_kv "RemnaNode" "$REMNAWAVE_CONTAINER_NAME"
ui_kv "Сервер" "${BANHAMMER_HOST}:${BANHAMMER_PORT}"
ui_kv "TLS" "$([ "$TLS_ENABLED" = "true" ] && echo "Включен" || echo "Выключен")"
ui_kv "Логи" "$LOG_DIR"
ui_kv "Конфигурация" "$INSTALL_DIR/.env"

ui_section "Управление"
ui_command "Логи" "docker compose logs -f"
ui_command "Статус" "docker compose ps"
ui_command "Перезапуск" "docker compose restart"
ui_command "Остановка" "docker compose down"
ui_command "Обновление" "docker compose pull && docker compose up -d"
echo ""
