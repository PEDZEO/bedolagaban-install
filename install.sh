#!/bin/bash

set -e

umask 077

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REGISTRY="${REGISTRY:-ghcr.io/pedzeo}"
TAG="${TAG:-latest}"
INSTALL_DIR="${INSTALL_DIR:-/opt/banhammer}"
INSTALL_ACTION=""
SETUP_PROFILE=""
FORCE_REINSTALL=false

# Функции для вывода
print_header() {
    echo -e "\n${BLUE}=====================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=====================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

ask_question() {
    local question="$1"
    local answer
    printf "${YELLOW}%s${NC}\n" "$question" >&2
    read -r -p "→ " answer
    echo "$answer"
}

ask_secret() {
    local question="$1"
    local answer
    printf "${YELLOW}%s${NC}\n" "$question" >&2
    read -r -s -p "→ " answer
    printf '\n' >&2
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
            * )
                echo "" >&2
                echo "  → Введи 'y' или 'n'" >&2
                echo "" >&2
                ;;
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

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)$port$"
        return
    fi
    return 1
}

validate_panel_connection() {
    local base_url="${1%/}"
    local token="$2"
    local secret_key="$3"
    local response_file
    local status
    local endpoint
    local -a curl_args
    curl_args=(-sS -L --max-time 12 -o)
    response_file=$(mktemp)
    curl_args+=("$response_file" -w "%{http_code}" -H "Authorization: Bearer $token")
    if [ -n "$secret_key" ]; then
        if [[ "$secret_key" == *:* ]]; then
            curl_args+=(--cookie "${secret_key/:/=}")
        else
            curl_args+=(--cookie "${secret_key}=${secret_key}")
        fi
    fi
    for endpoint in /api/system/health /api/nodes; do
        status=$(curl "${curl_args[@]}" "${base_url}${endpoint}" 2>/dev/null || true)
        if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
            rm -f "$response_file"
            return 0
        fi
    done
    rm -f "$response_file"
    return 1
}

validate_telegram_token() {
    local token="$1"
    local response
    response=$(curl -fsS --max-time 12 "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true)
    grep -q '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response"
}

generate_random_token() {
    openssl rand -base64 32 2>/dev/null | tr -d "=+/" | cut -c1-32 || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32
}

show_usage() {
    cat << EOF
Использование: $0 [режим]

Без аргументов    Интерактивная установка или меню обслуживания
--quick           Быстрая установка с безопасными значениями по умолчанию
--advanced        Расширенная установка со всеми настройками
--update          Обновить существующие сервер и бот
--repair          Пересоздать контейнеры без скачивания образов
--diagnose        Проверить существующую установку
--reinstall       Явно выполнить полную перенастройку
--help            Показать эту справку
EOF
}

get_env_value() {
    local env_file="$1"
    local key="$2"
    [ -f "$env_file" ] || return 0
    sed -n "s/^${key}=//p" "$env_file" | tail -n1
}

is_server_install_dir() {
    local candidate="$1"
    [ -f "${candidate}/.env" ] || return 1
    [ -f "${candidate}/docker-compose.yml" ] || return 1
    grep -qE 'bedolagaban-server|container_name:[[:space:]]*banhammer-lite' \
        "${candidate}/docker-compose.yml" 2>/dev/null
}

find_existing_server_install() {
    local candidate
    for candidate in "$INSTALL_DIR" /opt/banhammer /root/ban /opt/ban; do
        if is_server_install_dir "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

container_is_running() {
    local name="$1"
    [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" = "true" ]
}

container_version() {
    local name="$1"
    local version
    version=$(docker exec "$name" sh -lc 'cat /app/VERSION 2>/dev/null || true' 2>/dev/null | tr -d '\r\n')
    printf '%s\n' "${version:-неизвестно}"
}

wait_for_http_health() {
    local port="$1"
    local timeout="${2:-120}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS --max-time 4 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

wait_for_container() {
    local name="$1"
    local timeout="${2:-90}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if container_is_running "$name"; then
            sleep 8
            if container_is_running "$name"; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

wait_for_healthy_container() {
    local name="$1"
    local timeout="${2:-90}"
    local deadline=$(( $(date +%s) + timeout ))
    local status
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}stopped{{end}}{{end}}' "$name" 2>/dev/null || true)
        case "$status" in
            healthy) return 0 ;;
            running)
                sleep 8
                container_is_running "$name" && return 0
                ;;
            unhealthy|stopped) ;;
        esac
        sleep 3
    done
    return 1
}

print_existing_diagnostics() {
    local env_file="${INSTALL_DIR}/.env"
    local http_port
    local failed=0
    http_port=$(get_env_value "$env_file" HTTP_PORT)
    http_port=${http_port:-8080}

    print_header "Диагностика BedolagaBan"
    print_info "Установка: $INSTALL_DIR"
    print_info "HTTP API: 127.0.0.1:${http_port}"
    echo ""
    (cd "$INSTALL_DIR" && docker compose ps) || failed=1

    if container_is_running banhammer-lite; then
        print_success "Серверный контейнер работает"
    else
        print_error "Серверный контейнер не запущен"
        failed=1
    fi
    if curl -fsS --max-time 5 "http://127.0.0.1:${http_port}/health" >/dev/null 2>&1; then
        print_success "HTTP API отвечает"
    else
        print_error "HTTP API не отвечает"
        failed=1
    fi
    if container_is_running banhammer-bot; then
        print_success "Telegram-бот работает"
    else
        print_error "Telegram-бот не запущен"
        failed=1
    fi

    if [ "$failed" -ne 0 ]; then
        echo ""
        print_info "Последние логи сервера:"
        (cd "$INSTALL_DIR" && docker compose logs --tail=40 banhammer) || true
        echo ""
        print_info "Последние логи бота:"
        (cd "$INSTALL_DIR" && docker compose logs --tail=40 telegram-bot) || true
        return 1
    fi
    return 0
}

rollback_existing_images() {
    local server_image_id="$1"
    local bot_image_id="$2"
    print_warning "Возвращаю предыдущие образы..."
    if [ -n "$server_image_id" ]; then
        docker image tag "$server_image_id" "${REGISTRY}/bedolagaban-server:${TAG}" >/dev/null || true
    fi
    if [ -n "$bot_image_id" ]; then
        docker image tag "$bot_image_id" "${REGISTRY}/bedolagaban-bot:${TAG}" >/dev/null || true
    fi
    if ! (cd "$INSTALL_DIR" && docker compose up -d --no-deps --force-recreate banhammer telegram-bot); then
        print_error "Не удалось запустить предыдущие образы"
        return 1
    fi
}

update_existing_server() {
    local pull_images="${1:-true}"
    local env_file="${INSTALL_DIR}/.env"
    local http_port
    local old_server_image
    local old_bot_image
    http_port=$(get_env_value "$env_file" HTTP_PORT)
    http_port=${http_port:-8080}
    old_server_image=$(docker inspect -f '{{.Image}}' banhammer-lite 2>/dev/null || true)
    old_bot_image=$(docker inspect -f '{{.Image}}' banhammer-bot 2>/dev/null || true)

    print_header "$([ "$pull_images" = "true" ] && echo "Обновление сервера и бота" || echo "Восстановление контейнеров")"
    print_info "Конфигурация и PostgreSQL не изменяются"
    cd "$INSTALL_DIR"

    if [ "$pull_images" = "true" ]; then
        print_info "Удаляю неиспользуемые Docker-образы старше 7 дней..."
        docker image prune -a -f --filter "until=168h" >/dev/null 2>&1 || true
        print_info "Скачиваю новые образы..."
        if ! docker compose pull banhammer telegram-bot; then
            print_error "Не удалось скачать новые образы; запущенная версия не изменена"
            return 1
        fi
    fi

    print_info "Перезапускаю сервер..."
    if ! docker compose up -d --no-deps --force-recreate banhammer; then
        print_error "Не удалось пересоздать серверный контейнер"
        if [ "$pull_images" = "true" ]; then
            rollback_existing_images "$old_server_image" "$old_bot_image" || true
        fi
        return 1
    fi
    if ! wait_for_http_health "$http_port" 120; then
        print_error "Новая версия сервера не прошла проверку готовности"
        docker compose logs --tail=60 banhammer || true
        if [ "$pull_images" = "true" ] && { [ -n "$old_server_image" ] || [ -n "$old_bot_image" ]; }; then
            rollback_existing_images "$old_server_image" "$old_bot_image"
            if wait_for_http_health "$http_port" 90; then
                print_warning "Рабочая предыдущая версия восстановлена"
            else
                print_error "Автоматический откат не подтвердил готовность API"
            fi
        fi
        return 1
    fi

    print_info "Перезапускаю Telegram-бот..."
    if ! docker compose up -d --no-deps --force-recreate telegram-bot; then
        print_error "Не удалось пересоздать контейнер Telegram-бота"
        if [ "$pull_images" = "true" ]; then
            rollback_existing_images "$old_server_image" "$old_bot_image" || true
        fi
        return 1
    fi
    if ! wait_for_container banhammer-bot 90; then
        print_error "Telegram-бот не запустился"
        docker compose logs --tail=60 telegram-bot || true
        if [ "$pull_images" = "true" ] && { [ -n "$old_server_image" ] || [ -n "$old_bot_image" ]; }; then
            rollback_existing_images "$old_server_image" "$old_bot_image"
        fi
        return 1
    fi

    print_success "Сервер и бот обновлены и прошли проверку"
    print_success "Версия сервера: $(container_version banhammer-lite)"
    print_success "Версия бота: $(container_version banhammer-bot)"
    docker compose ps
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --quick) SETUP_PROFILE="quick" ;;
            --advanced) SETUP_PROFILE="advanced" ;;
            --update) INSTALL_ACTION="update" ;;
            --repair) INSTALL_ACTION="repair" ;;
            --diagnose) INSTALL_ACTION="diagnose" ;;
            --reinstall) FORCE_REINSTALL=true ;;
            --help|-h) show_usage; exit 0 ;;
            *) print_error "Неизвестный аргумент: $1"; show_usage; exit 2 ;;
        esac
        shift
    done
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

run_system_preflight() {
    local architecture
    local available_kb
    local memory_kb

    print_header "Предварительная проверка сервера"
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        print_error "Установщик нужно запускать от root"
        print_info "Выполни: sudo -i"
        exit 1
    fi

    architecture=$(uname -m)
    case "$architecture" in
        x86_64|amd64) print_success "Архитектура поддерживается: $architecture" ;;
        *)
            print_error "Архитектура $architecture пока не поддерживается готовыми образами BedolagaBan"
            exit 1
            ;;
    esac

    available_kb=$(df -Pk "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    if [ -z "$available_kb" ]; then
        available_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    fi
    if [ "${available_kb:-0}" -lt 2097152 ]; then
        if [ -n "${EXISTING_INSTALL_DIR:-}" ]; then
            print_warning "Свободного места меньше 2 ГБ; диагностика доступна, перед обновлением будет выполнена очистка"
        else
            print_error "Недостаточно свободного места: для новой установки требуется минимум 2 ГБ"
            exit 1
        fi
    else
        print_success "Свободного места достаточно: $((available_kb / 1024)) МБ"
    fi

    memory_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "${memory_kb:-0}" -lt 524288 ]; then
        print_warning "Оперативной памяти меньше 512 МБ; возможны проблемы при запуске"
        if ! ask_yes_no "Продолжить на сервере с малым объемом RAM?"; then
            exit 0
        fi
    else
        print_success "Оперативной памяти достаточно: $((memory_kb / 1024)) МБ"
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
        print_warning "Не найдены обязательные утилиты curl/OpenSSL"
        if ask_yes_no "Установить их автоматически?"; then
            install_base_packages || {
                print_error "Не удалось установить curl/OpenSSL автоматически"
                exit 1
            }
        else
            print_error "Без curl и OpenSSL продолжить нельзя"
            exit 1
        fi
    fi

    if ! command -v docker >/dev/null 2>&1; then
        print_warning "Docker не установлен"
        if ask_yes_no "Установить Docker официальным скриптом?"; then
            local docker_script
            docker_script=$(mktemp)
            if ! curl -fsSL https://get.docker.com -o "$docker_script"; then
                rm -f "$docker_script"
                print_error "Не удалось скачать официальный установщик Docker"
                exit 1
            fi
            sh "$docker_script"
            rm -f "$docker_script"
            systemctl enable --now docker 2>/dev/null || true
        else
            print_error "Docker обязателен для BedolagaBan"
            exit 1
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        print_error "Docker установлен, но daemon не отвечает"
        print_info "Проверь: systemctl status docker"
        exit 1
    fi
    print_success "Docker daemon работает"

    if ! docker compose version >/dev/null 2>&1; then
        print_error "Не найден Docker Compose v2"
        print_info "Установи пакет docker-compose-plugin"
        exit 1
    fi
    print_success "Docker Compose v2 доступен"
}

choose_existing_action() {
    echo ""
    print_warning "Найдена установленная система: $INSTALL_DIR"
    echo ""
    echo "  1) Обновить сервер и бот (рекомендуется)"
    echo "  2) Проверить состояние и показать ошибки"
    echo "  3) Пересоздать контейнеры без обновления образов"
    echo "  4) Полная перенастройка (с резервной копией)"
    echo "  5) Выйти"
    echo ""
    while true; do
        local choice
        choice=$(ask_question "Выбери действие (1-5, Enter=1):")
        choice=${choice:-1}
        case "$choice" in
            1) INSTALL_ACTION="update"; return ;;
            2) INSTALL_ACTION="diagnose"; return ;;
            3) INSTALL_ACTION="repair"; return ;;
            4)
                if ask_yes_no "Перезаписать конфигурацию после создания резервной копии?"; then
                    FORCE_REINSTALL=true
                    return
                fi
                ;;
            5) exit 0 ;;
            *) print_warning "Выбери число от 1 до 5" ;;
        esac
    done
}

backup_existing_configuration() {
    local backup_dir
    backup_dir="${INSTALL_DIR}/backups/installer-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    [ -f "${INSTALL_DIR}/.env" ] && cp -a "${INSTALL_DIR}/.env" "$backup_dir/.env"
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] && cp -a "${INSTALL_DIR}/docker-compose.yml" "$backup_dir/docker-compose.yml"
    LAST_CONFIG_BACKUP="$backup_dir"
    print_success "Резервная копия конфигурации: $backup_dir"
}

restore_last_configuration() {
    [ -n "${LAST_CONFIG_BACKUP:-}" ] || return 1
    [ -f "${LAST_CONFIG_BACKUP}/.env" ] || return 1
    [ -f "${LAST_CONFIG_BACKUP}/docker-compose.yml" ] || return 1
    cp -a "${LAST_CONFIG_BACKUP}/.env" "${INSTALL_DIR}/.env"
    cp -a "${LAST_CONFIG_BACKUP}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
    chmod 600 "${INSTALL_DIR}/.env" "${INSTALL_DIR}/docker-compose.yml"
    print_warning "Предыдущая конфигурация восстановлена из ${LAST_CONFIG_BACKUP}"
}

rollback_reconfigured_install() {
    local rollback_http_port
    restore_last_configuration || return 1
    if [ -n "${PREVIOUS_SERVER_IMAGE:-}" ]; then
        docker image tag "$PREVIOUS_SERVER_IMAGE" "${REGISTRY}/bedolagaban-server:${TAG}" >/dev/null || true
    fi
    if [ -n "${PREVIOUS_BOT_IMAGE:-}" ]; then
        docker image tag "$PREVIOUS_BOT_IMAGE" "${REGISTRY}/bedolagaban-bot:${TAG}" >/dev/null || true
    fi
    (cd "$INSTALL_DIR" && docker compose up -d --force-recreate) || true
    rollback_http_port=$(get_env_value "${INSTALL_DIR}/.env" HTTP_PORT)
    rollback_http_port=${rollback_http_port:-8080}
    if wait_for_http_health "$rollback_http_port" 90; then
        print_warning "Предыдущая рабочая конфигурация восстановлена"
        return 0
    fi
    print_error "Откат выполнен, но API не подтвердил готовность; проверь логи"
    return 1
}

resolve_domain_ips() {
    local domain="$1"
    if command -v getent &> /dev/null; then
        getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
        return
    fi
    if command -v dig &> /dev/null; then
        dig +short A "$domain" 2>/dev/null | sort -u
        return
    fi
    if command -v nslookup &> /dev/null; then
        nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | sort -u
        return
    fi
}

detect_public_ips() {
    local candidates=""
    if command -v hostname &> /dev/null; then
        candidates=$(hostname -I 2>/dev/null | tr ' ' '\n')
    fi

    if [ -z "$candidates" ] && command -v ip &> /dev/null; then
        candidates=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    fi

    while IFS= read -r candidate; do
        is_public_ipv4 "$candidate" && echo "$candidate"
    done <<< "$candidates" | sort -u
}

is_public_ipv4() {
    local ip="$1"
    local a b c d
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d))
    [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ] || return 1
    [ "$a" -eq 0 ] && return 1
    [ "$a" -eq 10 ] && return 1
    [ "$a" -eq 127 ] && return 1
    [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 1
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 1
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 1
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 1
    [ "$a" -ge 224 ] && return 1
    return 0
}

detect_primary_public_ip() {
    local candidate
    candidate=$(detect_public_ips | head -n1)
    if [ -n "$candidate" ]; then
        echo "$candidate"
        return
    fi

    if command -v curl &> /dev/null; then
        for endpoint in https://api.ipify.org https://checkip.amazonaws.com https://ipv4.icanhazip.com; do
            candidate=$(curl -4 -fsS --max-time 4 "$endpoint" 2>/dev/null | tr -d '[:space:]')
            if is_public_ipv4 "$candidate"; then
                echo "$candidate"
                return
            fi
        done
    fi
}

check_domain_points_here() {
    local domain="$1"
    local domain_ips
    local server_ips

    domain_ips=$(resolve_domain_ips "$domain")
    server_ips=$(detect_public_ips)

    if [ -z "$domain_ips" ]; then
        print_warning "Не удалось определить IP для домена $domain"
        print_info "Проверь DNS-запись вручную перед включением TLS"
        return
    fi

    print_info "IP домена $domain: $(echo "$domain_ips" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

    if [ -z "$server_ips" ]; then
        print_warning "Не удалось определить внешний IP этого сервера"
        print_info "Проверь, что домен указывает на нужную машину"
        return
    fi

    print_info "IP сервера: $(echo "$server_ips" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

    while IFS= read -r domain_ip; do
        [ -z "$domain_ip" ] && continue
        if echo "$server_ips" | grep -qx "$domain_ip"; then
            print_success "Домен $domain указывает на этот сервер"
            return
        fi
    done <<< "$domain_ips"

    print_warning "Домен $domain не указывает на текущий сервер"
    print_info "Агенты могут не подключиться по TLS, пока DNS не будет исправлен"
}

validate_tls_pair() {
    local cert_path="$1"
    local key_path="$2"

    if ! command -v openssl &> /dev/null; then
        print_warning "OpenSSL не найден, полную проверку сертификата и ключа пропускаю"
        return
    fi

    if [ -f "$cert_path" ]; then
        if openssl x509 -in "$cert_path" -noout > /dev/null 2>&1; then
            print_success "Сертификат читается корректно"
        else
            print_warning "Файл сертификата найден, но OpenSSL не может его прочитать"
        fi
    fi

    if [ -f "$key_path" ]; then
        if openssl pkey -in "$key_path" -noout > /dev/null 2>&1; then
            print_success "Приватный ключ читается корректно"
        else
            print_warning "Файл ключа найден, но OpenSSL не может его прочитать"
        fi
    fi

    if [ -f "$cert_path" ] && [ -f "$key_path" ]; then
        local cert_mod
        local key_mod
        cert_mod=$(openssl x509 -noout -modulus -in "$cert_path" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')
        key_mod=$(openssl rsa -noout -modulus -in "$key_path" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')

        if [ -n "$cert_mod" ] && [ -n "$key_mod" ]; then
            if [ "$cert_mod" = "$key_mod" ]; then
                print_success "Сертификат и ключ подходят друг к другу"
            else
                print_warning "Сертификат и ключ не совпадают"
            fi
        else
            print_warning "Не удалось сравнить сертификат и ключ"
        fi

        local cert_end
        cert_end=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2-)
        if [ -n "$cert_end" ]; then
            print_info "Сертификат действует до: $cert_end"
        fi
    fi
}

prepare_tls_paths_for_container() {
    local source_cert="$1"
    local source_key="$2"
    local target_dir="${INSTALL_DIR}/data/certs"
    local target_cert
    local target_key
    target_cert="${target_dir}/$(basename "$source_cert")"
    target_key="${target_dir}/$(basename "$source_key")"

    mkdir -p "$target_dir"
    cp -f "$source_cert" "$target_cert"
    cp -f "$source_key" "$target_key"
    chown 999:999 "$target_cert" "$target_key" 2>/dev/null || true
    chmod 600 "$target_cert" "$target_key" 2>/dev/null || true

    TLS_CERT_PATH="/app/data/certs/$(basename "$source_cert")"
    TLS_KEY_PATH="/app/data/certs/$(basename "$source_key")"
    CADDY_DATA_PATH=""

    print_success "TLS сертификаты скопированы в ${target_dir}"
    print_info "Контейнер будет использовать: $TLS_CERT_PATH и $TLS_KEY_PATH"
}

find_nginx_cert_paths() {
    local domain="$1"
    local cert_candidate=""
    local key_candidate=""
    local cert_name="${domain}.crt"
    local key_name="${domain}.key"

    if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]; then
        cert_candidate="/etc/letsencrypt/live/$domain/fullchain.pem"
    elif [ -f "/etc/letsencrypt/live/$domain/cert.pem" ]; then
        cert_candidate="/etc/letsencrypt/live/$domain/cert.pem"
    elif [ -f "/etc/nginx/ssl/$cert_name" ]; then
        cert_candidate="/etc/nginx/ssl/$cert_name"
    elif [ -f "/etc/ssl/certs/$cert_name" ]; then
        cert_candidate="/etc/ssl/certs/$cert_name"
    fi

    if [ -f "/etc/letsencrypt/live/$domain/privkey.pem" ]; then
        key_candidate="/etc/letsencrypt/live/$domain/privkey.pem"
    elif [ -f "/etc/nginx/ssl/$key_name" ]; then
        key_candidate="/etc/nginx/ssl/$key_name"
    elif [ -f "/etc/ssl/private/$key_name" ]; then
        key_candidate="/etc/ssl/private/$key_name"
    fi

    if [ -n "$cert_candidate" ] || [ -n "$key_candidate" ]; then
        echo "$cert_candidate|$key_candidate"
    fi
}

parse_arguments "$@"

EXISTING_INSTALL_DIR=$(find_existing_server_install || true)
if [ -n "$EXISTING_INSTALL_DIR" ]; then
    INSTALL_DIR="$EXISTING_INSTALL_DIR"
fi

run_system_preflight

if [ -n "$EXISTING_INSTALL_DIR" ] && [ "$FORCE_REINSTALL" != "true" ]; then
    [ -n "$INSTALL_ACTION" ] || choose_existing_action
    case "$INSTALL_ACTION" in
        update) update_existing_server true; exit $? ;;
        repair) update_existing_server false; exit $? ;;
        diagnose)
            if print_existing_diagnostics; then
                print_success "Система работает корректно"
                exit 0
            fi
            exit 1
            ;;
    esac
fi

if [ -z "$EXISTING_INSTALL_DIR" ] && [ -n "$INSTALL_ACTION" ]; then
    print_error "Существующая установка BedolagaBan не найдена"
    print_info "Для новой установки запусти скрипт без --${INSTALL_ACTION}"
    exit 1
fi

if [ -n "$EXISTING_INSTALL_DIR" ] && [ "$FORCE_REINSTALL" = "true" ]; then
    backup_existing_configuration
fi

# Начало установки
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║            BedolagaBan Server Installation                ║
║               Безопасная установка и обновление           ║
║                                                           ║
║    Автоматическая установка сервера мониторинга VPN       ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
print_info "Тег Docker-образов: $TAG"
print_info "Этот скрипт установит и настроит BedolagaBan сервер"
print_info "Тебе будут заданы вопросы о настройке системы"
print_info "В большинстве случаев можно просто нажать Enter"
echo ""

if ! ask_yes_no "Готов начать установку?"; then
    echo ""
    print_warning "Установка отменена"
    exit 0
fi

if [ -z "$SETUP_PROFILE" ]; then
    echo ""
    print_header "Режим настройки"
    echo "  1) Быстрая установка (рекомендуется)"
    echo "     Только обязательные данные, безопасные параметры задаются автоматически"
    echo ""
    echo "  2) Расширенная установка"
    echo "     Свои токены, порты, уведомления, интеграции и параметры автобана"
    echo ""
    while true; do
        SETUP_CHOICE=$(ask_question "Выбери режим (1-2, Enter=1):")
        SETUP_CHOICE=${SETUP_CHOICE:-1}
        case "$SETUP_CHOICE" in
            1) SETUP_PROFILE="quick"; break ;;
            2) SETUP_PROFILE="advanced"; break ;;
            *) print_warning "Выбери 1 или 2" ;;
        esac
    done
fi
if [ "$SETUP_PROFILE" = "quick" ]; then
    print_success "Выбрана быстрая установка"
else
    print_success "Выбрана расширенная установка"
fi

# ========================================
# Шаг 1: Проверка требований
# ========================================
print_header "Шаг 1/8: Проверка системных требований"
print_success "Docker: $(docker --version)"
print_success "Docker Compose: $(docker compose version --short 2>/dev/null || docker compose version)"
print_success "curl и OpenSSL доступны"

# ========================================
# Шаг 2: Настройка директории
# ========================================
print_header "Шаг 2/8: Настройка рабочей директории"

print_info "Директория установки: $INSTALL_DIR"
mkdir -p "${INSTALL_DIR}/data"
print_success "Директории созданы: ${INSTALL_DIR}/data/"

# ========================================
# Шаг 3: Сбор конфигурации
# ========================================
echo ""
print_header "Шаг 3/8: Настройка конфигурации"
echo ""
print_info "Сейчас я задам несколько вопросов для настройки системы"
print_info "Во многих местах можно просто нажать Enter для значения по умолчанию"
echo ""

# --- Токены безопасности ---
print_header "Токены безопасности"
echo ""
DEFAULT_API_TOKEN=$(generate_random_token)
API_TOKEN="$DEFAULT_API_TOKEN"
if [ "$SETUP_PROFILE" = "advanced" ]; then
    print_info "API-токен создан автоматически. Можно ввести свой, значение будет скрыто"
    CUSTOM_API_TOKEN=$(ask_secret "Свой API-токен (Enter = использовать сгенерированный):")
    API_TOKEN=${CUSTOM_API_TOKEN:-$DEFAULT_API_TOKEN}
fi
print_success "API-токен подготовлен и скрыт"

echo ""
DEFAULT_AGENT_TOKEN=$(generate_random_token)
AGENT_TOKEN="$DEFAULT_AGENT_TOKEN"
if [ "$SETUP_PROFILE" = "advanced" ]; then
    print_info "Токен агентов создан автоматически. Можно ввести свой, значение будет скрыто"
    CUSTOM_AGENT_TOKEN=$(ask_secret "Свой токен агентов (Enter = использовать сгенерированный):")
    AGENT_TOKEN=${CUSTOM_AGENT_TOKEN:-$DEFAULT_AGENT_TOKEN}
fi
print_success "Токен агентов подготовлен и скрыт"

# --- License Key ---
echo ""
print_header "Лицензионный ключ"
echo ""
print_info "Введи лицензионный ключ, полученный при покупке"
print_info "Пробный ключ можно получить на сайте: https://shop.pedze.ru/"
print_info "Формат: BB-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
echo ""
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

# --- Remnawave Panel ---
echo ""
print_header "Подключение к Remnawave Panel"
echo ""
print_info "Примеры URL:"
echo "  • https://panel.example.com (рекомендуется)"
echo "  • http://localhost:3000 (если на этом же сервере)"
echo "  • http://1.2.3.4:3000 (по IP адресу)"
echo ""
PANEL_URL=$(ask_question "URL твоей Remnawave Panel:")
while true; do
    if [[ "$PANEL_URL" =~ ^https?:// ]]; then
        print_success "URL корректный"
        break
    else
        print_error "URL должен начинаться с http:// или https://"
        PANEL_URL=$(ask_question "URL твоей Remnawave Panel:")
    fi
done

echo ""
print_info "API токен можно скопировать из настроек панели"
PANEL_TOKEN=$(ask_secret "API токен от Remnawave Panel:")
while [ -z "$PANEL_TOKEN" ]; do
    print_warning "Токен обязателен!"
    PANEL_TOKEN=$(ask_secret "API токен от Remnawave Panel:")
done

PANEL_SECRET_KEY=""
if [ "$SETUP_PROFILE" = "advanced" ]; then
    echo ""
    print_info "PANEL_SECRET_KEY нужен только для панели за защищающим reverse-proxy"
    print_info "Формат: cookie_name:cookie_value"
    PANEL_SECRET_KEY=$(ask_secret "PANEL_SECRET_KEY (Enter = не использовать):")
fi

print_info "Проверяю подключение к Remnawave Panel..."
while ! validate_panel_connection "$PANEL_URL" "$PANEL_TOKEN" "$PANEL_SECRET_KEY"; do
    print_error "Не удалось подтвердить доступ к Remnawave API"
    print_info "Проверь URL, API-токен и PANEL_SECRET_KEY"
    if [ -z "$PANEL_SECRET_KEY" ] && ask_yes_no "Панель защищена cookie от reverse-proxy?"; then
        PANEL_SECRET_KEY=$(ask_secret "PANEL_SECRET_KEY (cookie_name:cookie_value):")
        continue
    fi
    if ! ask_yes_no "Ввести данные панели заново?"; then
        print_warning "Установка остановлена до исправления доступа к панели"
        exit 1
    fi
    PANEL_URL=$(ask_question "URL Remnawave Panel:")
    while [[ ! "$PANEL_URL" =~ ^https?:// ]]; do
        print_error "URL должен начинаться с http:// или https://"
        PANEL_URL=$(ask_question "URL Remnawave Panel:")
    done
    PANEL_TOKEN=$(ask_secret "API токен от Remnawave Panel:")
    while [ -z "$PANEL_TOKEN" ]; do
        print_warning "Токен обязателен"
        PANEL_TOKEN=$(ask_secret "API токен от Remnawave Panel:")
    done
    if [ "$SETUP_PROFILE" = "advanced" ]; then
        PANEL_SECRET_KEY=$(ask_secret "PANEL_SECRET_KEY (Enter = не использовать):")
    else
        PANEL_SECRET_KEY=""
    fi
done
print_success "Remnawave Panel доступна, авторизация работает"

# --- Сетевые порты ---
echo ""
print_header "Сетевые порты BedolagaBan"
echo ""
print_info "HTTP API используется ботом и админскими интеграциями"
print_info "TCP порт используется агентами VPN нод"
echo ""

DEFAULT_HTTP_PORT="${HTTP_PORT:-8080}"
if [ "$SETUP_PROFILE" = "quick" ]; then
    HTTP_PORT="$DEFAULT_HTTP_PORT"
else
    HTTP_PORT=$(ask_port "Порт HTTP API" "$DEFAULT_HTTP_PORT")
fi

DEFAULT_TCP_PORT="${TCP_PORT:-9999}"
if [ "$DEFAULT_TCP_PORT" = "$HTTP_PORT" ]; then
    DEFAULT_TCP_PORT=10000
fi
if [ "$SETUP_PROFILE" = "quick" ]; then
    TCP_PORT="$DEFAULT_TCP_PORT"
else
    TCP_PORT=$(ask_port "TCP порт для агентов" "$DEFAULT_TCP_PORT")
fi
while [ "$TCP_PORT" = "$HTTP_PORT" ]; do
    print_warning "HTTP и TCP не могут использовать один порт: $HTTP_PORT"
    TCP_PORT=$(ask_port "Укажи другой TCP порт для агентов" "$DEFAULT_TCP_PORT")
done

if [ -z "$EXISTING_INSTALL_DIR" ]; then
    while port_in_use "$HTTP_PORT"; do
        print_warning "Порт $HTTP_PORT уже занят"
        HTTP_PORT=$(ask_port "Свободный порт HTTP API" "$((HTTP_PORT + 1))")
    done
    while port_in_use "$TCP_PORT"; do
        print_warning "Порт $TCP_PORT уже занят"
        TCP_PORT=$(ask_port "Свободный TCP порт для агентов" "$((TCP_PORT + 1))")
    done
fi

print_success "HTTP API: $HTTP_PORT/tcp"
print_success "Агенты: $TCP_PORT/tcp"

# --- Telegram Bot ---
echo ""
print_header "Настройка Telegram бота"
echo ""
print_info "Токен можно получить у @BotFather в Telegram"
TELEGRAM_BOT_TOKEN=$(ask_secret "Токен от @BotFather:")
while true; do
    if [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:.+ ]]; then
        print_success "Формат токена корректный"
        break
    else
        print_error "Неверный формат! Ожидается: 123456789:ABCdef..."
        TELEGRAM_BOT_TOKEN=$(ask_secret "Токен от @BotFather:")
    fi
done
print_info "Проверяю токен через Telegram API..."
while ! validate_telegram_token "$TELEGRAM_BOT_TOKEN"; do
    print_error "Telegram API не подтвердил токен"
    if ! ask_yes_no "Ввести токен Telegram заново?"; then
        print_warning "Установка остановлена до исправления токена Telegram"
        exit 1
    fi
    TELEGRAM_BOT_TOKEN=$(ask_secret "Токен от @BotFather:")
    while [[ ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:.+ ]]; do
        print_error "Неверный формат токена"
        TELEGRAM_BOT_TOKEN=$(ask_secret "Токен от @BotFather:")
    done
done
print_success "Telegram-бот найден, токен работает"
echo ""
print_info "Свой ID можно узнать у @userinfobot"
print_info "Можно указать несколько ID через запятую, пробел или точку с запятой"
normalize_telegram_admin_ids() {
    local normalized
    normalized=$(printf '%s' "$1" | sed -E 's/[[:space:];]+/,/g; s/,+/,/g; s/^,//; s/,$//')
    if [[ ! "$normalized" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]]; then
        return 1
    fi
    printf '%s\n' "$normalized" | awk -F',' '
        {
            result = ""
            for (i = 1; i <= NF; i++) {
                if (!seen[$i]++) {
                    result = result (result ? "," : "") $i
                }
            }
            print result
        }
    '
}
while true; do
    TELEGRAM_ADMIN_IDS_RAW=$(ask_question "Telegram ID администраторов:")
    if TELEGRAM_ADMIN_IDS=$(normalize_telegram_admin_ids "$TELEGRAM_ADMIN_IDS_RAW"); then
        TELEGRAM_ADMIN_COUNT=$(awk -F',' '{print NF}' <<< "$TELEGRAM_ADMIN_IDS")
        print_success "Администраторов настроено: $TELEGRAM_ADMIN_COUNT"
        print_info "ID: $TELEGRAM_ADMIN_IDS"
        break
    else
        print_error "Введи один или несколько числовых ID, например: 123456789, 987654321"
    fi
done

# --- Уведомления в группу ---
echo ""
print_header "Уведомления в группу (опционально)"
echo ""
print_info "Можно отправлять уведомления в Telegram группу или в личку админам"
echo ""
if [ "$SETUP_PROFILE" = "advanced" ] && ask_yes_no "Настроить отправку в группу?"; then
    echo ""
    print_info "ID группы начинается с -100..."
    TELEGRAM_NOTIFY_CHAT=$(ask_question "ID группы:")
    echo ""
    if ask_yes_no "Группа с топиками (темами)?"; then
        echo ""
        TELEGRAM_TOPIC_ID=$(ask_question "ID топика:")
    else
        TELEGRAM_TOPIC_ID=""
    fi
else
    TELEGRAM_NOTIFY_CHAT=""
    TELEGRAM_TOPIC_ID=""
    echo ""
    print_info "→ Уведомления будут в личку администраторам"
fi

# --- TLS настройка ---
echo ""
print_header "TLS шифрование для агентов (опционально)"
echo ""
print_info "TLS защищает соединение между агентами и сервером"
print_info "Поддерживается Caddy, Nginx, и любой другой reverse proxy"
print_warning "Если нет домена - можно пропустить (агенты подключатся по IP)"
echo ""

# Инициализируем переменные TLS
TLS_CERT_PATH=""
TLS_KEY_PATH=""
CADDY_DATA_PATH=""
TLS_DOMAIN=""
TLS_MODE=""

if ask_yes_no "Включить TLS шифрование?"; then
    echo ""
    print_info "Выбери источник сертификатов:"
    echo "  1) Caddy (автоопределение Let's Encrypt сертификатов)"
    echo "  2) Nginx / Certbot (автопоиск типовых путей)"
    echo "  3) Указать путь вручную"
    echo ""

    while true; do
        TLS_MODE=$(ask_question "Выбери (1, 2 или 3):")
        case $TLS_MODE in
            1) TLS_MODE="caddy"; break;;
            2) TLS_MODE="nginx"; break;;
            3) TLS_MODE="manual"; break;;
            *) print_warning "Выбери 1, 2 или 3";;
        esac
    done

    if [ "$TLS_MODE" = "caddy" ]; then
        # ===== Режим Caddy =====
        echo ""
        print_info "Например: agent.example.com"
        print_info "Этот домен должен указывать именно на текущий сервер, куда ты ставишь BedolagaBan"
        print_info "Именно сюда будут подключаться все агенты VPN нод"
        TLS_DOMAIN=$(ask_question "Домен для агентов:")

        echo ""
        print_info "Ищу сертификат для домена: $TLS_DOMAIN"

        LOCAL_CADDY_PATHS=(
            "/var/lib/caddy/.local/share/caddy"
            "/root/.local/share/caddy"
            "$HOME/.local/share/caddy"
            "/var/snap/caddy/common/.local/share/caddy"
            "/etc/caddy/.local/share/caddy"
        )

        FOUND_PATH=""

        print_info "Проверяю локальные установки Caddy..."
        for local_path in "${LOCAL_CADDY_PATHS[@]}"; do
            if [ -d "$local_path" ]; then
                DOMAIN_CERT="$local_path/certificates/acme-v02.api.letsencrypt.org-directory/$TLS_DOMAIN/$TLS_DOMAIN.crt"
                if [ -f "$DOMAIN_CERT" ]; then
                    print_success "Найден сертификат для $TLS_DOMAIN"
                    print_info "  → $local_path"
                    FOUND_PATH="$local_path"
                    break
                elif [ -d "$local_path/certificates" ]; then
                    CERT_COUNT=$(find "$local_path/certificates" -name "*.crt" 2>/dev/null | wc -l)
                    if [ "$CERT_COUNT" -gt 0 ] && [ -z "$FOUND_PATH" ]; then
                        print_info "→ Найдены другие сертификаты в: $local_path ($CERT_COUNT шт.)"
                        FOUND_PATH="$local_path"
                    fi
                fi
            fi
        done

        # Ищем в Docker volumes
        if [ -z "$FOUND_PATH" ]; then
            print_info "Проверяю Docker volumes..."
            CADDY_VOLUMES=$(docker volume ls --format '{{.Name}}' | grep -i caddy 2>/dev/null)

            if [ -n "$CADDY_VOLUMES" ]; then
                while IFS= read -r vol; do
                    MOUNTPOINT=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null)
                    if [ -n "$MOUNTPOINT" ] && [ -d "$MOUNTPOINT" ]; then
                        for sub in "caddy/" ""; do
                            DOMAIN_CERT_PATH="$MOUNTPOINT/${sub}certificates/acme-v02.api.letsencrypt.org-directory/$TLS_DOMAIN/$TLS_DOMAIN.crt"
                            if [ -f "$DOMAIN_CERT_PATH" ]; then
                                FOUND_PATH="$MOUNTPOINT/${sub%/}"
                                print_success "Найден сертификат в Docker volume: $vol"
                                break 2
                            fi
                        done
                    fi
                done <<< "$CADDY_VOLUMES"

                if [ -z "$FOUND_PATH" ]; then
                    FIRST_DATA_VOLUME=$(echo "$CADDY_VOLUMES" | grep "_data" | head -n1)
                    if [ -n "$FIRST_DATA_VOLUME" ]; then
                        FOUND_PATH=$(docker volume inspect "$FIRST_DATA_VOLUME" --format '{{.Mountpoint}}' 2>/dev/null)
                        [ -d "$FOUND_PATH/caddy" ] && FOUND_PATH="$FOUND_PATH/caddy"
                        print_info "→ Использую: $FIRST_DATA_VOLUME"
                    fi
                fi
            fi
        fi

        if [ -z "$FOUND_PATH" ]; then
            echo ""
            print_warning "Сертификат не найден автоматически"
            print_info "Укажи путь к директории данных Caddy"
            echo ""
            CADDY_DATA_PATH=$(ask_question "Путь к Caddy data:")
            CADDY_DATA_PATH=${CADDY_DATA_PATH:-/var/lib/caddy/.local/share/caddy}
        else
            echo ""
            CADDY_DATA_PATH=$(ask_question "Путь к Caddy data (Enter для '$FOUND_PATH'):")
            CADDY_DATA_PATH=${CADDY_DATA_PATH:-$FOUND_PATH}
            print_success "Использую: $CADDY_DATA_PATH"
        fi

        # Проверяем сертификат
        if [ -d "$CADDY_DATA_PATH" ]; then
            print_success "Путь существует: $CADDY_DATA_PATH"
            DOMAIN_CERT="$CADDY_DATA_PATH/certificates/acme-v02.api.letsencrypt.org-directory/$TLS_DOMAIN/$TLS_DOMAIN.crt"
            DOMAIN_KEY="$CADDY_DATA_PATH/certificates/acme-v02.api.letsencrypt.org-directory/$TLS_DOMAIN/$TLS_DOMAIN.key"
            if [ -f "$DOMAIN_CERT" ]; then
                print_success "Сертификат для $TLS_DOMAIN найден!"
                if [ -f "$DOMAIN_KEY" ]; then
                    prepare_tls_paths_for_container "$DOMAIN_CERT" "$DOMAIN_KEY"
                else
                    print_warning "Ключ для $TLS_DOMAIN не найден рядом с сертификатом"
                fi
            else
                print_warning "Сертификат для $TLS_DOMAIN НЕ найден"
                print_info "Добавь домен в Caddyfile и перезапусти Caddy"
            fi
        else
            print_warning "Путь не существует: $CADDY_DATA_PATH"
        fi

    elif [ "$TLS_MODE" = "nginx" ]; then
        echo ""
        print_info "Например: agent.example.com"
        print_info "Этот домен должен указывать именно на текущий сервер, куда ты ставишь BedolagaBan"
        print_info "Именно сюда будут подключаться все агенты VPN нод"
        TLS_DOMAIN=$(ask_question "Домен для агентов:")
        while [ -z "$TLS_DOMAIN" ]; do
            print_warning "Домен обязателен для TLS"
            TLS_DOMAIN=$(ask_question "Домен для агентов:")
        done

        echo ""
        print_info "Проверяю DNS домена и ищу сертификаты Nginx/Certbot"
        check_domain_points_here "$TLS_DOMAIN"

        FOUND_NGINX_PAIR=$(find_nginx_cert_paths "$TLS_DOMAIN")
        if [ -n "$FOUND_NGINX_PAIR" ]; then
            TLS_CERT_PATH="${FOUND_NGINX_PAIR%%|*}"
            TLS_KEY_PATH="${FOUND_NGINX_PAIR##*|}"

            [ -n "$TLS_CERT_PATH" ] && print_success "Найден сертификат: $TLS_CERT_PATH"
            [ -n "$TLS_KEY_PATH" ] && print_success "Найден ключ: $TLS_KEY_PATH"
        else
            print_warning "Типовые пути Nginx/Certbot не найдены автоматически"
        fi

        if [ -z "$TLS_CERT_PATH" ]; then
            TLS_CERT_PATH=$(ask_question "Путь к сертификату (.crt/.pem):")
        else
            TLS_CERT_PATH=$(ask_question "Путь к сертификату (.crt/.pem) (Enter для '$TLS_CERT_PATH'):")
            TLS_CERT_PATH=${TLS_CERT_PATH:-${FOUND_NGINX_PAIR%%|*}}
        fi
        while [ -z "$TLS_CERT_PATH" ]; do
            print_warning "Путь обязателен!"
            TLS_CERT_PATH=$(ask_question "Путь к сертификату (.crt/.pem):")
        done

        if [ -n "${FOUND_NGINX_PAIR##*|}" ]; then
            TLS_KEY_PATH=$(ask_question "Путь к приватному ключу (.key/.pem) (Enter для '${FOUND_NGINX_PAIR##*|}'):")
            TLS_KEY_PATH=${TLS_KEY_PATH:-${FOUND_NGINX_PAIR##*|}}
        else
            TLS_KEY_PATH=$(ask_question "Путь к приватному ключу (.key/.pem):")
        fi
        while [ -z "$TLS_KEY_PATH" ]; do
            print_warning "Путь обязателен!"
            TLS_KEY_PATH=$(ask_question "Путь к приватному ключу (.key/.pem):")
        done

        if [ -f "$TLS_CERT_PATH" ]; then
            print_success "Сертификат найден: $TLS_CERT_PATH"
        else
            print_warning "Файл не найден: $TLS_CERT_PATH"
        fi

        if [ -f "$TLS_KEY_PATH" ]; then
            print_success "Ключ найден: $TLS_KEY_PATH"
        else
            print_warning "Файл не найден: $TLS_KEY_PATH"
        fi

        validate_tls_pair "$TLS_CERT_PATH" "$TLS_KEY_PATH"
        prepare_tls_paths_for_container "$TLS_CERT_PATH" "$TLS_KEY_PATH"
        print_info "Для Nginx порт $TCP_PORT нужно проксировать через stream {}, а не через обычный location {}"
        print_info "Если stream не настроен, агенты не подключатся даже при рабочем HTTPS сайте"
    else
        # ===== Ручной режим (Nginx, Certbot, и др.) =====
        echo ""
        print_info "Укажи пути к файлам сертификата и ключа"
        print_info "Примеры (Certbot/Nginx):"
        echo "  • /etc/letsencrypt/live/example.com/fullchain.pem"
        echo "  • /etc/letsencrypt/live/example.com/privkey.pem"
        echo ""

        TLS_CERT_PATH=$(ask_question "Путь к сертификату (.crt/.pem):")
        while [ -z "$TLS_CERT_PATH" ]; do
            print_warning "Путь обязателен!"
            TLS_CERT_PATH=$(ask_question "Путь к сертификату (.crt/.pem):")
        done

        TLS_KEY_PATH=$(ask_question "Путь к приватному ключу (.key/.pem):")
        while [ -z "$TLS_KEY_PATH" ]; do
            print_warning "Путь обязателен!"
            TLS_KEY_PATH=$(ask_question "Путь к приватному ключу (.key/.pem):")
        done

        # Проверяем файлы
        if [ -f "$TLS_CERT_PATH" ]; then
            print_success "Сертификат найден: $TLS_CERT_PATH"
        else
            print_warning "Файл не найден: $TLS_CERT_PATH"
            print_info "Убедись что путь правильный перед запуском"
        fi

        if [ -f "$TLS_KEY_PATH" ]; then
            print_success "Ключ найден: $TLS_KEY_PATH"
        else
            print_warning "Файл не найден: $TLS_KEY_PATH"
            print_info "Убедись что путь правильный перед запуском"
        fi

        validate_tls_pair "$TLS_CERT_PATH" "$TLS_KEY_PATH"
        prepare_tls_paths_for_container "$TLS_CERT_PATH" "$TLS_KEY_PATH"
    fi

    TLS_ENABLED="true"
    AGENT_PUBLIC_HOST="$TLS_DOMAIN"
else
    TLS_ENABLED="false"
    AGENT_PUBLIC_HOST=$(detect_primary_public_ip)
    print_info "→ TLS отключен"
    print_info "→ Агенты будут подключаться по IP без шифрования"
fi

# --- Система автобанов ---
echo ""
print_header "Система автобанов"
echo ""
print_info "Автоматические баны при превышении лимита IP адресов"
echo ""

if [ "$SETUP_PROFILE" = "quick" ] || ask_yes_no "Включить автобаны при превышении лимита?"; then
    PUNISHMENT_ENABLED="true"
    if [ "$SETUP_PROFILE" = "quick" ]; then
        PUNISHMENT_MINUTES="5"
        OBSERVATION_SECONDS="60"
        PROGRESSIVE_BANS_ENABLED="true"
        PROGRESSIVE_BAN_1="5"
        PROGRESSIVE_BAN_2="15"
        PROGRESSIVE_BAN_3="60"
        print_success "Автобаны настроены: 5 минут, наблюдение 60 секунд, прогрессивный режим 5/15/60"
    else
        echo ""
        PUNISHMENT_MINUTES=$(ask_question "Время первого бана (минуты, Enter=5):")
        PUNISHMENT_MINUTES=${PUNISHMENT_MINUTES:-5}
        OBSERVATION_SECONDS=$(ask_question "Период наблюдения (секунды, Enter=60):")
        OBSERVATION_SECONDS=${OBSERVATION_SECONDS:-60}
        echo ""
        print_info "Прогрессивные баны: 1-й → 5 мин, 2-й → 15 мин, 3-й → 60 мин"
        if ask_yes_no "Включить увеличение времени при повторных нарушениях?"; then
            PROGRESSIVE_BANS_ENABLED="true"
            PROGRESSIVE_BAN_1=$(ask_question "Первый бан (минуты, Enter=5):")
            PROGRESSIVE_BAN_1=${PROGRESSIVE_BAN_1:-5}
            PROGRESSIVE_BAN_2=$(ask_question "Второй бан (минуты, Enter=15):")
            PROGRESSIVE_BAN_2=${PROGRESSIVE_BAN_2:-15}
            PROGRESSIVE_BAN_3=$(ask_question "Третий бан (минуты, Enter=60):")
            PROGRESSIVE_BAN_3=${PROGRESSIVE_BAN_3:-60}
        else
            PROGRESSIVE_BANS_ENABLED="false"
            PROGRESSIVE_BAN_1="5"
            PROGRESSIVE_BAN_2="15"
            PROGRESSIVE_BAN_3="60"
        fi
    fi
else
    PUNISHMENT_ENABLED="false"
    PUNISHMENT_MINUTES="5"
    OBSERVATION_SECONDS="60"
    PROGRESSIVE_BANS_ENABLED="false"
    PROGRESSIVE_BAN_1="5"
    PROGRESSIVE_BAN_2="15"
    PROGRESSIVE_BAN_3="60"
    print_info "Автобаны отключены"
fi

# --- Интеграция с BedolagaBot ---
echo ""
print_header "Интеграция с BedolagaBot (опционально)"
echo ""
print_info "Для отправки уведомлений пользователям через BedolagaBot"
echo ""
if [ "$SETUP_PROFILE" = "advanced" ] && ask_yes_no "Интегрировать с BedolagaBot?"; then
    echo ""
    MAIN_BOT_API_URL=$(ask_question "URL API BedolagaBot:")
    echo ""
    MAIN_BOT_API_KEY=$(ask_secret "API ключ BedolagaBot:")
else
    MAIN_BOT_API_URL=""
    MAIN_BOT_API_KEY=""
    print_info "Интеграция с BedolagaBot отключена"
fi

# --- PostgreSQL ---
echo ""
print_header "База данных PostgreSQL (рекомендуется)"
echo ""
print_info "PostgreSQL используется для хранения:"
echo "  • Истории IP адресов"
echo "  • Статистики операторов"
echo "  • Аудит логов"
echo "  • Сессий пользователей"
echo "  • Уведомлений и алертов"
echo ""
print_warning "Без PostgreSQL аналитика будет недоступна!"
echo ""
if [ "$SETUP_PROFILE" = "quick" ] || ask_yes_no "Включить PostgreSQL? (рекомендуется)"; then
    POSTGRES_ENABLED="true"
    echo ""
    DEFAULT_PG_PASSWORD=$(generate_random_token | cut -c1-16)
    POSTGRES_PASSWORD="$DEFAULT_PG_PASSWORD"
    if [ "$SETUP_PROFILE" = "advanced" ]; then
        POSTGRES_PASSWORD=$(ask_secret "Свой пароль PostgreSQL (Enter = сгенерировать безопасный):")
        POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-$DEFAULT_PG_PASSWORD}
        while [ ${#POSTGRES_PASSWORD} -lt 8 ]; do
            print_warning "Пароль слишком короткий! Минимум 8 символов"
            POSTGRES_PASSWORD=$(ask_secret "Пароль PostgreSQL:")
        done
    fi
    print_success "Пароль PostgreSQL подготовлен и скрыт"
    COMPOSE_PROFILES="postgres"
else
    POSTGRES_ENABLED="false"
    POSTGRES_PASSWORD=""
    COMPOSE_PROFILES=""
    print_warning "PostgreSQL отключён - аналитика будет недоступна"
fi

echo ""
print_header "Проверка настроек перед запуском"
echo "  Режим:                 $([ "$SETUP_PROFILE" = "quick" ] && echo "быстрый" || echo "расширенный")"
echo "  Remnawave Panel:       $PANEL_URL"
echo "  HTTP API:              $HTTP_PORT/tcp"
echo "  Подключение агентов:   $TCP_PORT/tcp"
echo "  Публичный адрес:       ${AGENT_PUBLIC_HOST:-не определен}"
echo "  TLS:                   $([ "$TLS_ENABLED" = "true" ] && echo "включен (${TLS_DOMAIN})" || echo "выключен")"
echo "  Администраторов:       ${TELEGRAM_ADMIN_COUNT:-1}"
echo "  Уведомления:           $([ -n "$TELEGRAM_NOTIFY_CHAT" ] && echo "группа ${TELEGRAM_NOTIFY_CHAT}" || echo "личные сообщения администраторам")"
echo "  Автобаны:              $([ "$PUNISHMENT_ENABLED" = "true" ] && echo "включены" || echo "выключены")"
echo "  PostgreSQL:            $([ "$POSTGRES_ENABLED" = "true" ] && echo "включен" || echo "выключен")"
echo "  Секреты:               скрыты, будут сохранены в .env с правами 600"
echo ""
if ! ask_yes_no "Применить эти настройки?"; then
    print_warning "Установка отменена, рабочая конфигурация не изменена"
    exit 0
fi

# ========================================
# Шаг 4: Docker сеть
# ========================================
echo ""
print_header "Шаг 4/8: Настройка Docker сети"
echo ""

print_info "Анализирую URL панели: $PANEL_URL"
echo ""

NEED_NETWORK=false
NETWORK_NAME="remnawave-network"

if [[ "$PANEL_URL" =~ ^http://[a-zA-Z] ]] && [[ ! "$PANEL_URL" =~ localhost ]]; then
    NEED_NETWORK=true

    print_warning "Обнаружен Docker DNS: $PANEL_URL"
    print_info "→ Требуется Docker сеть для связи с Remnawave Panel"
    echo ""

    print_info "Ищу существующую Docker сеть Remnawave..."
    FOUND_NETWORK=$(docker network ls --format '{{.Name}}' | grep -i remna | head -n1)

    if [ -n "$FOUND_NETWORK" ]; then
        NETWORK_NAME="$FOUND_NETWORK"
        print_success "Найдена существующая сеть: $NETWORK_NAME"
    else
        print_warning "Сеть Remnawave не найдена"
        print_info "→ Создаю новую сеть: remnawave-network"
        if docker network create remnawave-network 2>/dev/null; then
            NETWORK_NAME="remnawave-network"
            print_success "Сеть remnawave-network создана!"
        else
            print_error "Не удалось создать Docker сеть"
            print_info "Создай сеть вручную: docker network create remnawave-network"
            exit 1
        fi
    fi
else
    print_success "URL использует HTTPS/localhost/IP"
    print_info "→ Docker сеть НЕ требуется"
fi

# ========================================
# Шаг 5: Создание .env файла
# ========================================
echo ""
print_header "Шаг 5/8: Создание конфигурационного файла"
echo ""

ACTIVE_ENV_FILE="${INSTALL_DIR}/.env"
ACTIVE_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
STAGE_DIR="${INSTALL_DIR}/.installer-stage.$$"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ENV_FILE="${STAGE_DIR}/.env"

print_info "Создаю файл .env со следующими настройками:"
echo ""
print_info "  API_TOKEN: [скрыт]"
print_info "  AGENT_TOKEN: [скрыт]"
print_info "  PANEL_URL: $PANEL_URL"
if [ -n "$PANEL_SECRET_KEY" ]; then
    print_info "  PANEL_SECRET_KEY: [set]"
else
    print_info "  PANEL_SECRET_KEY: [not set]"
fi
print_info "  TELEGRAM_BOT_TOKEN: [скрыт]"
print_info "  TELEGRAM_ADMIN_IDS: $TELEGRAM_ADMIN_IDS"
print_info "  TLS_ENABLED: $TLS_ENABLED"
print_info "  POSTGRES_ENABLED: $POSTGRES_ENABLED"
print_info "  HTTP_PORT: $HTTP_PORT"
print_info "  TCP_PORT: $TCP_PORT"
print_info "  AGENT_PUBLIC_HOST: ${AGENT_PUBLIC_HOST:-[auto at runtime]}"
echo ""

cat > "$ENV_FILE" << EOF
# ============================================
# BedolagaBan Server Configuration
# Создано автоматически: $(date)
# ============================================

# === HTTP/TCP сервер ===
HTTP_HOST=0.0.0.0
HTTP_PORT=$HTTP_PORT
TCP_HOST=0.0.0.0
TCP_PORT=$TCP_PORT
AGENT_PUBLIC_HOST=$AGENT_PUBLIC_HOST

# === Лицензия ===
LICENSE_KEY=$LICENSE_KEY

# === Авторизация ===
API_TOKEN=$API_TOKEN
AGENT_TOKEN=$AGENT_TOKEN

# === Remnawave Panel ===
PANEL_URL=$PANEL_URL
PANEL_TOKEN=$PANEL_TOKEN
PANEL_SECRET_KEY=$PANEL_SECRET_KEY
PANEL_VERIFY_SSL=true
PANEL_SYNC_INTERVAL=60

# === Telegram Bot ===
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ADMIN_IDS=$TELEGRAM_ADMIN_IDS
TELEGRAM_NOTIFY_CHAT=$TELEGRAM_NOTIFY_CHAT
TELEGRAM_TOPIC_ID=$TELEGRAM_TOPIC_ID

# === TLS шифрование ===
TLS_ENABLED=$TLS_ENABLED
TLS_DOMAIN=$TLS_DOMAIN
TLS_CERT_PATH=$TLS_CERT_PATH
TLS_KEY_PATH=$TLS_KEY_PATH
CADDY_DATA_PATH=$CADDY_DATA_PATH

# === Panel API ===
PANEL_USERS_CACHE_LIMIT=10000

# === Интеграция с основным ботом ===
MAIN_BOT_API_URL=$MAIN_BOT_API_URL
MAIN_BOT_API_KEY=$MAIN_BOT_API_KEY

# === Система наказаний ===
PUNISHMENT_ENABLED=$PUNISHMENT_ENABLED
PUNISHMENT_MINUTES=$PUNISHMENT_MINUTES
OBSERVATION_SECONDS=$OBSERVATION_SECONDS

# === Прогрессивные баны ===
PROGRESSIVE_BANS_ENABLED=$PROGRESSIVE_BANS_ENABLED
PROGRESSIVE_BAN_1=$PROGRESSIVE_BAN_1
PROGRESSIVE_BAN_2=$PROGRESSIVE_BAN_2
PROGRESSIVE_BAN_3=$PROGRESSIVE_BAN_3
PROGRESSIVE_BAN_WINDOW_HOURS=24

# === Уведомления ===
NOTIFY_ON_PUNISHMENT=true
NOTIFY_ON_NODE_STATUS=true
DAILY_REPORT_ENABLED=true
DAILY_REPORT_HOUR=9

# === Мониторинг трафика ===
TRAFFIC_MONITOR_ENABLED=false
TRAFFIC_LIMIT_GB=100
TRAFFIC_WINDOW_MINUTES=60
TRAFFIC_CHECK_INTERVAL=5
TRAFFIC_BAN_MINUTES=60

# === Мониторинг типа сети ===
NETWORK_DETECTION_ENABLED=false
NETWORK_BLOCK_MOBILE=false
NETWORK_BLOCK_WIFI=false

# === База данных SQLite (legacy) ===
DB_PATH=/app/data/bedolagaban.db

# === PostgreSQL (аналитика) ===
POSTGRES_ENABLED=$POSTGRES_ENABLED
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=banhammer
POSTGRES_USER=banhammer
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_POOL_MIN=2
POSTGRES_POOL_MAX=10
POSTGRES_CACHE_SIZE=10000
COMPOSE_PROFILES=$COMPOSE_PROFILES

# === Отслеживание IP ===
IP_TTL_MINUTES=30
IP_WINDOW_SECONDS=60

# === BedolagaBan self-update ===
SYSTEM_UPDATE_ENABLED=true
SYSTEM_UPDATE_MODE=registry
SYSTEM_UPDATE_DOCKER_SOCKET=/var/run/docker.sock
SYSTEM_UPDATE_HOST_BASE=$(dirname "$INSTALL_DIR")
SYSTEM_UPDATE_COMPOSE_SUBDIR=$(basename "$INSTALL_DIR")
SYSTEM_UPDATE_SOURCE_SUBDIR=$(basename "$INSTALL_DIR")-src
EOF

chmod 600 "$ENV_FILE"
print_success "Файл .env подготовлен во временном каталоге"

# ========================================
# Создание docker-compose.yml
# ========================================

COMPOSE_FILE="${STAGE_DIR}/docker-compose.yml"

# Определяем секцию networks для remnawave
if [ "$NEED_NETWORK" = true ]; then
    REMNAWAVE_NET_DEF="  remnawave-network:
    external: true
    name: ${NETWORK_NAME}"
    REMNAWAVE_NET_REF="      - remnawave-network"
else
    REMNAWAVE_NET_DEF=""
    REMNAWAVE_NET_REF=""
fi

# Определяем TLS volume mount
TLS_VOLUME=""
if [ "$TLS_ENABLED" = "true" ]; then
    if [ -n "$CADDY_DATA_PATH" ]; then
        # Caddy mode: монтируем директорию данных Caddy
        TLS_VOLUME="      - ${CADDY_DATA_PATH}:/caddy_data:ro"
    elif [ -n "$TLS_CERT_PATH" ]; then
        # Явные cert/key уже лежат в ./data/certs и доступны через ./data:/app/data
        TLS_VOLUME=""
    fi
fi

cat > "$COMPOSE_FILE" << COMPOSE
services:
  banhammer:
    image: ${REGISTRY}/bedolagaban-server:${TAG}
    container_name: banhammer-lite
    restart: unless-stopped
    ports:
      - "\${HTTP_PORT:-8080}:\${HTTP_PORT:-8080}"
      - "\${TCP_PORT:-9999}:\${TCP_PORT:-9999}"
    env_file: .env
    environment:
      - HTTP_HOST=0.0.0.0
      - HTTP_PORT=\${HTTP_PORT:-8080}
      - TCP_HOST=0.0.0.0
      - TCP_PORT=\${TCP_PORT:-9999}
      - SYSTEM_UPDATE_ENABLED=\${SYSTEM_UPDATE_ENABLED:-true}
      - SYSTEM_UPDATE_DOCKER_SOCKET=/var/run/docker.sock
      - SYSTEM_UPDATE_HOST_BASE=\${SYSTEM_UPDATE_HOST_BASE}
      - SYSTEM_UPDATE_SOURCE_SUBDIR=\${SYSTEM_UPDATE_SOURCE_SUBDIR:-banhammer-src}
      - SYSTEM_UPDATE_COMPOSE_SUBDIR=\${SYSTEM_UPDATE_COMPOSE_SUBDIR:-banhammer}
      - SYSTEM_UPDATE_MODE=\${SYSTEM_UPDATE_MODE:-registry}
    volumes:
      - ./data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
${TLS_VOLUME}
    networks:
      - banhammer-network
${REMNAWAVE_NET_REF}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:\${HTTP_PORT:-8080}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

  telegram-bot:
    image: ${REGISTRY}/bedolagaban-bot:${TAG}
    container_name: banhammer-bot
    restart: unless-stopped
    env_file: .env
    environment:
      - API_URL=http://banhammer:\${HTTP_PORT:-8080}
    depends_on:
      - banhammer
    networks:
      - banhammer-network

  postgres:
    image: postgres:16-alpine
    container_name: banhammer-postgres
    restart: unless-stopped
    profiles:
      - postgres
    environment:
      - POSTGRES_DB=banhammer
      - POSTGRES_USER=banhammer
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-changeme}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - banhammer-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U banhammer -d banhammer"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  banhammer-network:
    driver: bridge
${REMNAWAVE_NET_DEF}

volumes:
  postgres_data:
COMPOSE

chmod 600 "$COMPOSE_FILE"
print_info "Проверяю сгенерированную Docker Compose конфигурацию..."
if ! docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet; then
    rm -rf "$STAGE_DIR"
    print_error "Сгенерированная Docker Compose конфигурация некорректна"
    exit 1
fi

if [ -f "$ACTIVE_ENV_FILE" ] || [ -f "$ACTIVE_COMPOSE_FILE" ]; then
    backup_existing_configuration
fi
mv -f "$ENV_FILE" "$ACTIVE_ENV_FILE"
mv -f "$COMPOSE_FILE" "$ACTIVE_COMPOSE_FILE"
rmdir "$STAGE_DIR"
chmod 600 "$ACTIVE_ENV_FILE"
chmod 600 "$ACTIVE_COMPOSE_FILE"
ENV_FILE="$ACTIVE_ENV_FILE"
COMPOSE_FILE="$ACTIVE_COMPOSE_FILE"
print_success "Конфигурация проверена и применена атомарно"

# Создаём сеть если нужно
if [ "$NEED_NETWORK" = true ]; then
    docker network inspect "$NETWORK_NAME" &>/dev/null || docker network create "$NETWORK_NAME" 2>/dev/null || true
fi

# ========================================
# Шаг 6: Проверка портов
# ========================================
echo ""
print_header "Шаг 6/8: Проверка портов"
echo ""

check_port_in_use() {
    local port=$1
    if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        return 0
    else
        return 1
    fi
}

if check_port_in_use "$HTTP_PORT"; then
    print_warning "Порт $HTTP_PORT уже используется другим процессом!"
else
    print_success "Порт $HTTP_PORT свободен (HTTP API)"
fi

if check_port_in_use "$TCP_PORT"; then
    print_warning "Порт $TCP_PORT уже используется другим процессом!"
else
    print_success "Порт $TCP_PORT свободен (TCP для агентов)"
fi

echo ""

# Проверяем firewall
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -n1)

    if echo "$UFW_STATUS" | grep -q "Status: active"; then
        print_info "Обнаружен активный UFW firewall"
        echo ""

        if ! ufw status | grep -q "$HTTP_PORT"; then
            print_info "Автоматически открываю обязательный порт $HTTP_PORT/tcp в UFW"
            if ufw allow "$HTTP_PORT/tcp" >/dev/null 2>&1; then
                print_success "Порт $HTTP_PORT/tcp открыт"
            else
                print_error "Не удалось открыть порт $HTTP_PORT/tcp"
            fi
        else
            print_success "Порт $HTTP_PORT уже открыт в UFW"
        fi

        echo ""

        if ! ufw status | grep -q "$TCP_PORT"; then
            print_info "Автоматически открываю обязательный порт $TCP_PORT/tcp для агентов"
            if ufw allow "$TCP_PORT/tcp" >/dev/null 2>&1; then
                print_success "Порт $TCP_PORT/tcp открыт"
            else
                print_error "Не удалось открыть порт $TCP_PORT/tcp"
            fi
        else
            print_success "Порт $TCP_PORT уже открыт в UFW"
        fi
    else
        print_success "UFW отключен или не активен"
    fi
elif command -v iptables >/dev/null 2>&1; then
    print_info "Обнаружен iptables firewall"
    echo ""

    if ! iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$HTTP_PORT"; then
        print_info "Автоматически открываю обязательный порт $HTTP_PORT/tcp в iptables"
        iptables -A INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT && print_success "Порт $HTTP_PORT/tcp открыт"
    else
        print_success "Порт $HTTP_PORT открыт в iptables"
    fi

    echo ""

    if ! iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$TCP_PORT"; then
        print_info "Автоматически открываю обязательный порт $TCP_PORT/tcp для агентов"
        iptables -A INPUT -p tcp --dport "$TCP_PORT" -j ACCEPT && print_success "Порт $TCP_PORT/tcp открыт"
    else
        print_success "Порт $TCP_PORT открыт в iptables"
    fi
else
    print_success "Firewall не обнаружен (ufw/iptables)"
fi

# ========================================
# Шаг 7: Запуск контейнеров
# ========================================
echo ""
print_header "Шаг 7/8: Запуск Docker контейнеров"
echo ""

cd "$INSTALL_DIR"

PREVIOUS_SERVER_IMAGE=$(docker inspect -f '{{.Image}}' banhammer-lite 2>/dev/null || true)
PREVIOUS_BOT_IMAGE=$(docker inspect -f '{{.Image}}' banhammer-bot 2>/dev/null || true)

# Проверяем авторизацию в GHCR
print_info "Проверяю доступ к реестру образов..."
if ! docker pull "${REGISTRY}/bedolagaban-server:${TAG}" --quiet 2>/dev/null; then
    echo ""
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
        print_info "Проверь токен и попробуй вручную: docker login ghcr.io"
        exit 1
    fi
fi

print_info "Скачиваю образы..."
docker image prune -a -f --filter "until=168h" >/dev/null 2>&1 || true
if ! docker compose pull; then
    print_error "Не удалось скачать Docker-образы"
    if ! rollback_reconfigured_install; then
        print_info "Для новой установки исправь доступ к GHCR и запусти скрипт снова"
    fi
    exit 1
fi

echo ""
print_info "Запускаю контейнеры..."
if docker compose up -d; then
    echo ""
    print_success "Контейнеры запущены!"
else
    echo ""
    print_error "Ошибка при запуске контейнеров"
    print_info "Проверь логи: docker compose logs"
    rollback_reconfigured_install || true
    exit 1
fi

echo ""
print_info "Жду готовность сервисов (до 150 секунд)..."

# ========================================
# Шаг 8: Проверка работоспособности
# ========================================
echo ""
print_header "Шаг 8/8: Проверка работоспособности"
echo ""

print_info "Статус контейнеров:"
docker compose ps

echo ""
print_info "Проверяю HTTP API (health check)..."
INSTALL_HEALTH_OK=true
if wait_for_http_health "$HTTP_PORT" 150; then
    print_success "HTTP API работает"
else
    print_error "HTTP API не подтвердил готовность"
    INSTALL_HEALTH_OK=false
fi

if wait_for_container banhammer-bot 90; then
    print_success "Telegram-бот стабильно работает"
else
    print_error "Telegram-бот не подтвердил готовность"
    INSTALL_HEALTH_OK=false
fi

if [ "$POSTGRES_ENABLED" = "true" ]; then
    if wait_for_healthy_container banhammer-postgres 90; then
        print_success "PostgreSQL готов принимать подключения"
    else
        print_error "PostgreSQL не подтвердил готовность"
        INSTALL_HEALTH_OK=false
    fi
fi

echo ""
print_info "Последние логи сервера:"
echo ""
docker compose logs --tail=15 banhammer

if [ "$INSTALL_HEALTH_OK" != "true" ]; then
    echo ""
    print_error "Установка не прошла итоговую проверку. Успешный статус не будет показан"
    docker compose logs --tail=60 banhammer telegram-bot postgres 2>/dev/null || true
    rollback_reconfigured_install || true
    exit 1
fi

# ========================================
# Итоги
# ========================================
echo ""
echo ""
print_header "Установка завершена!"
echo ""

echo -e "${GREEN}✓ BedolagaBan сервер успешно установлен и запущен!${NC}"
echo ""
echo "   Версия сервера: $(container_version banhammer-lite)"
echo "   Версия бота:    $(container_version banhammer-bot)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${BLUE}ВАЖНАЯ ИНФОРМАЦИЯ${NC}"
echo ""
echo -e "${YELLOW}Секреты API и агентов:${NC}"
echo "   Сохранены в $INSTALL_DIR/.env и не выводятся в терминал"
echo ""
echo -e "${YELLOW}API Endpoint:${NC}"
echo "   http://localhost:$HTTP_PORT"
echo ""
echo -e "${YELLOW}TCP порт для агентов:${NC}"
echo "   $TCP_PORT"
echo ""
if [ "$POSTGRES_ENABLED" = "true" ]; then
echo -e "${YELLOW}PostgreSQL:${NC}"
echo "   Включён (аналитика доступна)"
echo "   Пароль скрыт и хранится в .env"
else
echo -e "${YELLOW}PostgreSQL:${NC}"
echo "   Отключён (аналитика недоступна)"
fi
echo ""
echo -e "${YELLOW}Конфигурация:${NC}"
echo "   $INSTALL_DIR/.env"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${BLUE}ПОЛЕЗНЫЕ КОМАНДЫ${NC}"
echo ""
echo -e "  ${GREEN}Логи сервера:${NC}"
echo "    docker compose logs -f banhammer"
echo ""
echo -e "  ${GREEN}Логи бота:${NC}"
echo "    docker compose logs -f telegram-bot"
echo ""
if [ "$POSTGRES_ENABLED" = "true" ]; then
echo -e "  ${GREEN}Логи PostgreSQL:${NC}"
echo "    docker compose logs -f postgres"
echo ""
fi
echo -e "  ${GREEN}Статус:${NC}"
echo "    docker compose ps"
echo ""
echo -e "  ${GREEN}Остановить:${NC}"
echo "    docker compose down"
echo ""
echo -e "  ${GREEN}Перезапустить:${NC}"
echo "    docker compose restart"
echo ""
echo -e "  ${GREEN}Обновление:${NC}"
echo "    docker compose pull && docker compose up -d"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${BLUE}ПРОВЕРКА API${NC}"
echo ""
echo "  API доступен на http://localhost:$HTTP_PORT (токен хранится в .env)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${BLUE}СЛЕДУЮЩИЕ ШАГИ${NC}"
echo ""
echo -e "  ${YELLOW}1.${NC} Проверь Telegram бота - отправь ему /start"
echo ""
echo -e "  ${YELLOW}2.${NC} Убедись что Remnawave Panel доступен:"
echo "     $PANEL_URL"
echo ""

if [ "$TLS_ENABLED" = "true" ]; then
    echo -e "  ${YELLOW}3.${NC} Настрой Caddy для домена: $TLS_DOMAIN"
    echo ""
    echo -e "  ${YELLOW}4.${NC} Установи агенты на VPN ноды"
else
    echo -e "  ${YELLOW}3.${NC} Открой порт $TCP_PORT для подключения агентов:"
    echo "     sudo ufw allow $TCP_PORT/tcp"
    echo ""
    echo -e "  ${YELLOW}4.${NC} Установи агенты на VPN ноды"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}✓ Готово! Система готова к работе.${NC}"
echo ""

# Сохраняем информацию об установке (без секретов)
cat > "${INSTALL_DIR}/INSTALLATION_INFO.txt" << EOF
BedolagaBan Installation Information
=====================================
Дата установки: $(date)
Директория: $INSTALL_DIR

API Endpoint: http://localhost:$HTTP_PORT
HTTP Port: $HTTP_PORT
TCP Port: $TCP_PORT
TLS Enabled: $TLS_ENABLED
$([ "$TLS_ENABLED" = "true" ] && echo "TLS Domain: $TLS_DOMAIN")

PostgreSQL Enabled: $POSTGRES_ENABLED
Admin IDs: $TELEGRAM_ADMIN_IDS
Panel URL: $PANEL_URL
$([ "$NEED_NETWORK" = true ] && echo "Docker Network: $NETWORK_NAME")

Все секреты хранятся в: .env
EOF
chmod 600 "${INSTALL_DIR}/INSTALLATION_INFO.txt"

echo ""
print_success "Информация об установке сохранена в ${INSTALL_DIR}/INSTALLATION_INFO.txt"
echo ""
