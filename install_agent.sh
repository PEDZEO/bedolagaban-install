#!/bin/bash
# ========================================
# BedolagaBan Agent - Установка из GHCR
# Для VPN нод (без исходного кода)
# ========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

REGISTRY="ghcr.io/pedzeo"
TAG="${TAG:-latest}"
IMAGE="${REGISTRY}/bedolagaban-agent:${TAG}"
INSTALL_DIR="${INSTALL_DIR:-/opt/banhammer-agent}"

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

ask_question() {
    local question="$1"
    local answer
    printf "${YELLOW}%s${NC}\n" "$question" >&2
    read -r -p "→ " answer
    echo "$answer"
}

ask_yes_no() {
    while true; do
        printf "${YELLOW}%s (y/n): ${NC}" "$1" >&2
        read -r yn
        yn=$(echo "$yn" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        case $yn in
            y|yes|да ) return 0;;
            n|no|нет ) return 1;;
            * ) echo "  → Введи 'y' или 'n'" >&2 ;;
        esac
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
    for log_path in "/var/log/remnanode" "/opt/remnanode/logs" "/var/log/xray" "/var/log/3x-ui"; do
        if [ -d "$log_path" ]; then
            echo "$log_path"
            return 0
        fi
    done
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
        if [ -f "${candidate}/.env" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

write_agent_compose() {
    cat > "${INSTALL_DIR}/docker-compose.yml" << COMPOSE
services:
  banhammer-agent:
    image: ${IMAGE}
    container_name: banhammer-agent
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
    local deadline=$((SECONDS + timeout))

    remna_container=$(get_env_value "${INSTALL_DIR}/.env" REMNAWAVE_CONTAINER_NAME "remnanode")
    xray_command=$(get_env_value "${INSTALL_DIR}/.env" XRAY_API_COMMAND "docker exec remnanode rw-core")
    if printf '%s\n' " $xray_command " | grep -Fq " $remna_container "; then
        xray_bridge_required=1
    fi

    while [ "$SECONDS" -lt "$deadline" ]; do
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
            if ! docker exec "$remna_container" rw-core api lsrules --server=127.0.0.1:61001 >/dev/null 2>&1; then
                last_reason="Xray API bridge пока не отвечает"
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
    mkdir -p "${INSTALL_DIR}/data"
    print_info "2/7 Делаю backup текущих файлов..."
    local backup_suffix
    backup_suffix=$(date +%Y%m%d%H%M%S)
    cp "$env_file" "${env_file}.bak.${backup_suffix}"
    if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        cp "${INSTALL_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml.bak.${backup_suffix}"
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
    ensure_env_value "$env_file" XRAY_API_COMMAND "docker exec remnanode rw-core"
    ensure_env_value "$env_file" XRAY_API_SERVER "127.0.0.1:61001"
    set_env_value "$env_file" XRAY_API_TIMEOUT 5
    set_env_value "$env_file" XRAY_API_RETRY_INTERVAL 300
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
    ensure_env_value "$env_file" REMNAWAVE_CONTAINER_NAME remnanode
    ensure_env_value "$env_file" REMNAWAVE_API_BRIDGE_PORT 61001
    set_env_value "$env_file" REMNAWAVE_AUTO_RESTART_ENABLED true
    set_env_value "$env_file" REMNAWAVE_AUTO_SETUP_TIMEOUT 20
    ensure_env_value "$env_file" REMNAWAVE_WARP_OUTBOUND_CONFIG_PATH /tmp/banhammer-warp-outbound.json
    set_env_value "$env_file" DOCKER_BIN "$DOCKER_BIN"
    print_success ".env обновлен"

    print_info "4/7 Обновляю docker-compose.yml..."
    write_agent_compose
    print_success "docker-compose.yml обновлен"

    cd "$INSTALL_DIR"
    print_info "5/7 Скачиваю свежий образ агента: ${IMAGE}"
    docker compose pull
    print_success "Образ агента скачан"

    print_info "6/7 Пересоздаю контейнер агента..."
    docker compose up -d --force-recreate
    print_success "Контейнер пересоздан"

    print_info "7/7 Жду запуск и проверяю состояние..."
    sleep "${AGENT_START_DELAY:-8}"
    docker compose ps
    verify_agent_runtime "Готово: агент обновлен и работает"
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

if [ "${1:-}" = "--upgrade-runtime" ] || [ "${1:-}" = "--update" ] || [ "${1:-}" = "update" ] || [ "${AUTO_UPGRADE_RUNTIME:-}" = "1" ]; then
    if [ ! -f "${INSTALL_DIR}/.env" ]; then
        FOUND_INSTALL_DIR=$(find_existing_install_dir || true)
        if [ -n "$FOUND_INSTALL_DIR" ]; then
            INSTALL_DIR="$FOUND_INSTALL_DIR"
        fi
    fi
    upgrade_existing_runtime
    exit 0
fi

if [ "${1:-}" != "--reinstall" ] && [ "${1:-}" != "--install" ]; then
    FOUND_INSTALL_DIR=$(find_existing_install_dir || true)
    if [ -n "$FOUND_INSTALL_DIR" ]; then
        INSTALL_DIR="$FOUND_INSTALL_DIR"
        echo ""
        print_warning "Найден установленный BedolagaBan Agent: ${INSTALL_DIR}"
        print_warning "Для новых правил BLOCK/DIRECT/WARP требуется обновить runtime и docker-compose.yml"
        print_info "Скрипт сохранит текущий .env, сделает backup, скачает новый образ и перезапустит агента"
        echo ""
        if ask_yes_no "Обновить агента сейчас?"; then
            upgrade_existing_runtime
        else
            print_warning "Обновление отменено"
            print_info "Для полной переустановки запусти этот скрипт с флагом --reinstall"
        fi
        exit 0
    fi
fi

# ========================================
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║            BedolagaBan Agent Installation                 ║
║                   (Compiled Edition)                      ║
║                                                           ║
║     Установка агента на VPN ноду для мониторинга          ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
print_info "Агент отправляет данные о подключениях на центральный сервер"
echo ""

if ! ask_yes_no "Готов начать установку?"; then
    print_warning "Установка отменена"
    exit 0
fi

# Шаг 1: Проверка Docker
echo ""
print_info "Шаг 1/5: Проверка Docker..."

if ! command -v docker &> /dev/null; then
    print_error "Docker не найден!"
    print_info "Установи Docker: https://docs.docker.com/engine/install/"
    exit 1
fi
print_success "Docker установлен"

DOCKER_BIN=$(command -v docker)

if ! docker compose version &> /dev/null; then
    print_error "Docker Compose v2 не найден!"
    exit 1
fi
print_success "Docker Compose найден"

# Шаг 2: Настройка директории
echo ""
print_info "Шаг 2/5: Создание директорий..."
mkdir -p ${INSTALL_DIR}/data
print_success "Директория: ${INSTALL_DIR}"

# Шаг 3: Сбор конфигурации
echo ""
print_info "Шаг 3/5: Настройка подключения"
print_info "Эти данные должен предоставить администратор сервера"
echo ""

# NODE_NAME
print_info "Уникальное имя этой ноды (например: node1, germany-1, vps-amsterdam)"
NODE_NAME=$(ask_question "Имя ноды:")
while [ -z "$NODE_NAME" ]; do
    print_warning "Имя ноды обязательно!"
    NODE_NAME=$(ask_question "Имя ноды:")
done

# BANHAMMER_HOST
echo ""
print_info "IP адрес или домен сервера BedolagaBan"
BANHAMMER_HOST=$(ask_question "Адрес сервера:")
while [ -z "$BANHAMMER_HOST" ]; do
    print_warning "Адрес сервера обязателен!"
    BANHAMMER_HOST=$(ask_question "Адрес сервера:")
done

# BANHAMMER_PORT
echo ""
BANHAMMER_PORT=$(ask_question "Порт сервера (Enter=9999):")
BANHAMMER_PORT=${BANHAMMER_PORT:-9999}

# AGENT_TOKEN
echo ""
AGENT_TOKEN=$(ask_question "Токен агента:")
while [ -z "$AGENT_TOKEN" ]; do
    print_warning "Токен обязателен!"
    AGENT_TOKEN=$(ask_question "Токен агента:")
done

# Шаг 4: Настройка логов
echo ""
print_info "Шаг 4/5: Настройка логов"

# Автоопределение
FOUND_LOG_DIR=""
for log_path in "/var/log/remnanode" "/opt/remnanode/logs" "/var/log/xray" "/var/log/3x-ui"; do
    if [ -d "$log_path" ]; then
        LOG_COUNT=$(find "$log_path" -name "*.log" 2>/dev/null | wc -l)
        if [ "$LOG_COUNT" -gt 0 ]; then
            print_success "Найдены логи: $log_path ($LOG_COUNT файлов)"
            FOUND_LOG_DIR="$log_path"
            break
        fi
    fi
done

if [ -n "$FOUND_LOG_DIR" ]; then
    LOG_DIR=$(ask_question "Директория логов (Enter='$FOUND_LOG_DIR'):")
    LOG_DIR=${LOG_DIR:-$FOUND_LOG_DIR}
else
    LOG_DIR=$(ask_question "Директория логов:")
    while [ -z "$LOG_DIR" ]; do
        print_warning "Директория обязательна!"
        LOG_DIR=$(ask_question "Директория логов:")
    done
fi

check_node_logs "$LOG_DIR"

# LICENSE_KEY
echo ""
print_info "Лицензионный ключ получен при покупке"
print_info "Пробный ключ можно получить на сайте: https://shop.pedze.ru/"
print_info "Формат: BB-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
LICENSE_KEY=$(ask_question "Лицензионный ключ:")
while true; do
    if [[ "$LICENSE_KEY" =~ ^BB-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        print_success "Формат ключа корректный"
        break
    else
        print_error "Неверный формат! Ожидается: BB-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        LICENSE_KEY=$(ask_question "Лицензионный ключ:")
    fi
done

# TLS
echo ""
if ask_yes_no "Использовать TLS шифрование?"; then
    TLS_ENABLED="true"
else
    TLS_ENABLED="false"
fi

# Профиль нагрузки
echo ""
print_info "Профиль нагрузки:"
echo "  1) До 1000 юзеров"
echo "  2) 1000-10000"
echo "  3) 10000-50000"
echo "  4) 50000+"
echo ""

while true; do
    PROFILE=$(ask_question "Выбери (1-4):")
    case $PROFILE in
        1) BATCH_SIZE=50;  BATCH_TIMEOUT=1.0; MAX_QUEUE_SIZE=10000;  DEDUP_WINDOW=30; break;;
        2) BATCH_SIZE=100; BATCH_TIMEOUT=0.5; MAX_QUEUE_SIZE=50000;  DEDUP_WINDOW=45; break;;
        3) BATCH_SIZE=200; BATCH_TIMEOUT=0.5; MAX_QUEUE_SIZE=100000; DEDUP_WINDOW=60; break;;
        4) BATCH_SIZE=500; BATCH_TIMEOUT=0.3; MAX_QUEUE_SIZE=200000; DEDUP_WINDOW=90; break;;
        *) print_warning "Выбери 1, 2, 3 или 4";;
    esac
done

# Шаг 5: Создание конфигурации и запуск
echo ""
print_info "Шаг 5/5: Запуск агента"

# .env
cat > ${INSTALL_DIR}/.env << EOF
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
XRAY_API_COMMAND=docker exec remnanode rw-core
XRAY_API_SERVER=127.0.0.1:61001
XRAY_API_TIMEOUT=5
XRAY_API_RETRY_INTERVAL=300
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
REMNAWAVE_CONTAINER_NAME=remnanode
REMNAWAVE_API_BRIDGE_PORT=61001
REMNAWAVE_AUTO_RESTART_ENABLED=true
REMNAWAVE_AUTO_SETUP_TIMEOUT=20
REMNAWAVE_WARP_OUTBOUND_CONFIG_PATH=/tmp/banhammer-warp-outbound.json
DOCKER_BIN=${DOCKER_BIN}

BACKPRESSURE_ENABLED=true
BACKPRESSURE_THRESHOLD=0.8
BACKPRESSURE_MAX_DELAY=5.0
EOF

print_success ".env создан"

# docker-compose.yml
cat > ${INSTALL_DIR}/docker-compose.yml << COMPOSE
services:
  banhammer-agent:
    image: ${IMAGE}
    container_name: banhammer-agent
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

print_success "docker-compose.yml создан"

# Запуск
cd ${INSTALL_DIR}

# Скачивание образа
echo ""
print_info "Скачивание образа ${IMAGE}..."

# Пробуем скачать без авторизации (для публичных образов)
if docker compose pull 2>&1 | tee /tmp/pull_output.log; then
    print_success "Образ скачан успешно"
else
    # Проверяем, действительно ли нужна авторизация
    if grep -q "unauthorized\|denied\|authentication required" /tmp/pull_output.log 2>/dev/null; then
        echo ""
        print_warning "Образ требует авторизацию в GitHub Container Registry"
        print_info "Это может быть потому что:"
        print_info "  1. Образ находится в приватном репозитории"
        print_info "  2. GitHub временно ограничил анонимный доступ"
        echo ""
        print_info "Для авторизации нужен GitHub Personal Access Token:"
        print_info "  1. Перейди: https://github.com/settings/tokens/new"
        print_info "  2. Название: bedolagaban-agent"
        print_info "  3. Права: read:packages"
        print_info "  4. Скопируй токен"
        echo ""

        if ask_yes_no "Хочешь авторизоваться сейчас?"; then
            read -sp "$(printf "${YELLOW}GitHub Personal Access Token: ${NC}")" GHCR_TOKEN
            echo ""
            if echo "$GHCR_TOKEN" | docker login ghcr.io -u pedzeo --password-stdin 2>/dev/null; then
                print_success "Авторизация успешна"
                print_info "Повторная попытка скачивания..."
                if docker compose pull; then
                    print_success "Образ скачан успешно"
                else
                    print_error "Не удалось скачать образ даже после авторизации"
                    print_info "Свяжись с администратором или проверь настройки репозитория"
                    exit 1
                fi
            else
                print_error "Не удалось авторизоваться"
                print_info "Проверь токен и попробуй снова"
                exit 1
            fi
        else
            print_warning "Установка прервана. Авторизация обязательна для этого образа."
            exit 1
        fi
    else
        # Другая ошибка (сеть, неверный тег и т.п.)
        print_error "Не удалось скачать образ"
        print_info "Возможные причины:"
        print_info "  - Проблемы с сетью"
        print_info "  - Образ не существует: ${IMAGE}"
        print_info "  - GitHub Container Registry недоступен"
        echo ""
        print_info "Логи ошибки:"
        cat /tmp/pull_output.log 2>/dev/null || echo "(нет логов)"
        exit 1
    fi
fi
rm -f /tmp/pull_output.log 2>/dev/null

echo ""
print_info "Запуск агента..."
docker compose up -d

sleep "${AGENT_START_DELAY:-8}"

echo ""
print_info "Статус:"
docker compose ps

verify_agent_runtime "Готово: агент установлен и работает"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN} Агент установлен и работает!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "  Нода:     ${NODE_NAME}"
echo "  Сервер:   ${BANHAMMER_HOST}:${BANHAMMER_PORT}"
echo "  TLS:      ${TLS_ENABLED}"
echo "  Логи:     ${LOG_DIR}"
echo ""
echo "Команды:"
echo "  cd ${INSTALL_DIR}"
echo "  docker compose logs -f       # Логи"
echo "  docker compose restart       # Перезапуск"
echo "  docker compose down          # Остановка"
echo "  docker compose pull && docker compose up -d  # Обновление"
echo ""
