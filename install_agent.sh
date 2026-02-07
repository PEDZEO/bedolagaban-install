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

# LICENSE_KEY
echo ""
print_info "Лицензионный ключ получен при покупке"
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
      - \${LOG_DIR:-/var/log/remnanode}:/var/log/remnanode:ro
      - ./data:/app/data
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

sleep 5

echo ""
print_info "Статус:"
docker compose ps

echo ""
print_info "Логи:"
docker compose logs --tail=15

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN} Агент установлен!${NC}"
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
