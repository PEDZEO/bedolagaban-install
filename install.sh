#!/bin/bash

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REGISTRY="${REGISTRY:-ghcr.io/pedzeo}"
TAG="${TAG:-latest}"
INSTALL_DIR="${INSTALL_DIR:-/opt/banhammer}"

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

generate_random_token() {
    openssl rand -base64 32 2>/dev/null | tr -d "=+/" | cut -c1-32 || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32
}

# Начало установки
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║            BedolagaBan Server Installation                ║
║                      Version 1.0.0                        ║
║                                                           ║
║    Автоматическая установка сервера мониторинга VPN       ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF

echo ""
print_info "Этот скрипт установит и настроит BedolagaBan сервер"
print_info "Тебе будут заданы вопросы о настройке системы"
print_info "В большинстве случаев можно просто нажать Enter"
echo ""

if ! ask_yes_no "Готов начать установку?"; then
    echo ""
    print_warning "Установка отменена"
    exit 0
fi

# ========================================
# Шаг 1: Проверка требований
# ========================================
print_header "Шаг 1/8: Проверка системных требований"

print_info "Проверяю наличие Docker..."
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version)
    print_success "Docker установлен: $DOCKER_VERSION"
else
    print_error "Docker не найден!"
    print_info "Установи Docker: https://docs.docker.com/engine/install/"
    exit 1
fi

print_info "Проверяю наличие Docker Compose..."
if docker compose version &> /dev/null; then
    COMPOSE_VERSION=$(docker compose version)
    print_success "Docker Compose установлен: $COMPOSE_VERSION"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_VERSION=$(docker-compose --version)
    print_success "Docker Compose установлен: $COMPOSE_VERSION"
else
    print_error "Docker Compose не найден!"
    print_info "Установи Docker Compose: https://docs.docker.com/compose/install/"
    exit 1
fi

print_info "Проверяю наличие OpenSSL для генерации токенов..."
if command -v openssl &> /dev/null; then
    print_success "OpenSSL установлен"
else
    print_warning "OpenSSL не найден, токены нужно будет ввести вручную"
fi

# ========================================
# Шаг 2: Настройка директории
# ========================================
print_header "Шаг 2/8: Настройка рабочей директории"

print_info "Директория установки: $INSTALL_DIR"
mkdir -p ${INSTALL_DIR}/data
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
if command -v openssl &> /dev/null; then
    DEFAULT_API_TOKEN=$(generate_random_token)
    print_success "Сгенерирован API токен: $DEFAULT_API_TOKEN"
    echo ""
    print_info "Этот токен используется для доступа к HTTP API"
    API_TOKEN=$(ask_question "Нажми Enter чтобы использовать этот токен, или введи свой:")
    if [ -z "$API_TOKEN" ]; then
        API_TOKEN=$DEFAULT_API_TOKEN
        print_success "Использую сгенерированный токен"
    fi
else
    API_TOKEN=$(ask_question "Введи API токен (минимум 32 символа):")
    while [ ${#API_TOKEN} -lt 32 ]; do
        print_warning "Токен слишком короткий! Минимум 32 символа"
        API_TOKEN=$(ask_question "Введи API токен (минимум 32 символа):")
    done
fi

echo ""
if command -v openssl &> /dev/null; then
    DEFAULT_AGENT_TOKEN=$(generate_random_token)
    print_success "Сгенерирован токен для агентов: $DEFAULT_AGENT_TOKEN"
    echo ""
    print_info "Этот токен нужно будет указать на всех VPN нодах"
    AGENT_TOKEN=$(ask_question "Нажми Enter чтобы использовать этот токен, или введи свой:")
    if [ -z "$AGENT_TOKEN" ]; then
        AGENT_TOKEN=$DEFAULT_AGENT_TOKEN
        print_success "Использую сгенерированный токен"
    fi
else
    AGENT_TOKEN=$(ask_question "Введи токен для агентов:")
fi

# --- License Key ---
echo ""
print_header "Лицензионный ключ"
echo ""
print_info "Введи лицензионный ключ, полученный при покупке"
print_info "Формат: BB-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
echo ""
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
print_info "JWT токен можно скопировать из настроек панели"
PANEL_TOKEN=$(ask_question "JWT токен от Remnawave Panel:")
while [ -z "$PANEL_TOKEN" ]; do
    print_warning "Токен обязателен!"
    PANEL_TOKEN=$(ask_question "JWT токен от Remnawave Panel:")
done

# --- Telegram Bot ---
echo ""
print_header "Настройка Telegram бота"
echo ""
print_info "Токен можно получить у @BotFather в Telegram"
TELEGRAM_BOT_TOKEN=$(ask_question "Токен от @BotFather:")
while true; do
    if [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:.+ ]]; then
        print_success "Формат токена корректный"
        break
    else
        print_error "Неверный формат! Ожидается: 123456789:ABCdef..."
        TELEGRAM_BOT_TOKEN=$(ask_question "Токен от @BotFather:")
    fi
done
echo ""
print_info "Свой ID можно узнать у @userinfobot"
TELEGRAM_ADMIN_IDS=$(ask_question "Твой Telegram ID:")
while true; do
    if [[ "$TELEGRAM_ADMIN_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        print_success "ID корректный"
        break
    else
        print_error "Введи числовой Telegram ID (или несколько через запятую)"
        TELEGRAM_ADMIN_IDS=$(ask_question "Твой Telegram ID:")
    fi
done

# --- Уведомления в группу ---
echo ""
print_header "Уведомления в группу (опционально)"
echo ""
print_info "Можно отправлять уведомления в Telegram группу или в личку админам"
echo ""
if ask_yes_no "Настроить отправку в группу?"; then
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
    echo "  2) Указать путь вручную (Nginx, Certbot, любой другой)"
    echo ""

    while true; do
        TLS_MODE=$(ask_question "Выбери (1 или 2):")
        case $TLS_MODE in
            1) TLS_MODE="caddy"; break;;
            2) TLS_MODE="manual"; break;;
            *) print_warning "Выбери 1 или 2";;
        esac
    done

    if [ "$TLS_MODE" = "caddy" ]; then
        # ===== Режим Caddy =====
        echo ""
        print_info "Например: agent.example.com"
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
            if [ -f "$DOMAIN_CERT" ]; then
                print_success "Сертификат для $TLS_DOMAIN найден!"
            else
                print_warning "Сертификат для $TLS_DOMAIN НЕ найден"
                print_info "Добавь домен в Caddyfile и перезапусти Caddy"
            fi
        else
            print_warning "Путь не существует: $CADDY_DATA_PATH"
        fi

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
    fi

    TLS_ENABLED="true"
else
    TLS_ENABLED="false"
    print_info "→ TLS отключен"
    print_info "→ Агенты будут подключаться по IP без шифрования"
fi

# --- Система автобанов ---
echo ""
print_header "Система автобанов"
echo ""
print_info "Автоматические баны при превышении лимита IP адресов"
echo ""

if ask_yes_no "Включить автобаны при превышении лимита?"; then
    PUNISHMENT_ENABLED="true"
    echo ""
    print_info "Рекомендуется: 5 минут"
    PUNISHMENT_MINUTES=$(ask_question "Время первого бана (минуты, Enter=5):")
    if [ -z "$PUNISHMENT_MINUTES" ]; then
        PUNISHMENT_MINUTES="5"
        print_success "Использую 5 минут"
    fi
    echo ""
    print_info "Период наблюдения защищает от ложных срабатываний при смене IP"
    print_info "Рекомендуется: 60 секунд"
    OBSERVATION_SECONDS=$(ask_question "Период наблюдения (секунды, Enter=60):")
    if [ -z "$OBSERVATION_SECONDS" ]; then
        OBSERVATION_SECONDS="60"
        print_success "Использую 60 секунд"
    fi

    echo ""
    print_info "Прогрессивные баны: 1-й → 5 мин, 2-й → 15 мин, 3-й → 60 мин"
    if ask_yes_no "Включить увеличение времени при повторных нарушениях?"; then
        PROGRESSIVE_BANS_ENABLED="true"
        echo ""
        print_info "Настройка времени банов (Enter = значения по умолчанию)"
        PROGRESSIVE_BAN_1=$(ask_question "Первый бан (минуты, Enter=5):")
        PROGRESSIVE_BAN_1=${PROGRESSIVE_BAN_1:-5}
        PROGRESSIVE_BAN_2=$(ask_question "Второй бан (минуты, Enter=15):")
        PROGRESSIVE_BAN_2=${PROGRESSIVE_BAN_2:-15}
        PROGRESSIVE_BAN_3=$(ask_question "Третий бан (минуты, Enter=60):")
        PROGRESSIVE_BAN_3=${PROGRESSIVE_BAN_3:-60}
        print_success "Прогрессивные баны: $PROGRESSIVE_BAN_1 → $PROGRESSIVE_BAN_2 → $PROGRESSIVE_BAN_3 минут"
    else
        PROGRESSIVE_BANS_ENABLED="false"
        PROGRESSIVE_BAN_1="5"
        PROGRESSIVE_BAN_2="15"
        PROGRESSIVE_BAN_3="60"
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

# --- Интеграция с основным ботом ---
echo ""
print_header "Интеграция с основным ботом (опционально)"
echo ""
print_info "Для отправки уведомлений пользователям через основной бот"
echo ""
if ask_yes_no "Интегрировать с основным ботом?"; then
    echo ""
    MAIN_BOT_API_URL=$(ask_question "URL API основного бота:")
    echo ""
    MAIN_BOT_API_KEY=$(ask_question "API ключ основного бота:")
else
    MAIN_BOT_API_URL=""
    MAIN_BOT_API_KEY=""
    print_info "Интеграция с основным ботом отключена"
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
if ask_yes_no "Включить PostgreSQL? (рекомендуется)"; then
    POSTGRES_ENABLED="true"
    echo ""
    print_info "Пароль для базы данных (минимум 8 символов)"
    if command -v openssl &> /dev/null; then
        DEFAULT_PG_PASSWORD=$(generate_random_token | cut -c1-16)
        print_success "Сгенерирован пароль: $DEFAULT_PG_PASSWORD"
        echo ""
        POSTGRES_PASSWORD=$(ask_question "Нажми Enter чтобы использовать этот пароль, или введи свой:")
        if [ -z "$POSTGRES_PASSWORD" ]; then
            POSTGRES_PASSWORD=$DEFAULT_PG_PASSWORD
            print_success "Использую сгенерированный пароль"
        fi
    else
        POSTGRES_PASSWORD=$(ask_question "Введи пароль для PostgreSQL:")
        while [ ${#POSTGRES_PASSWORD} -lt 8 ]; do
            print_warning "Пароль слишком короткий! Минимум 8 символов"
            POSTGRES_PASSWORD=$(ask_question "Введи пароль для PostgreSQL:")
        done
    fi
    COMPOSE_PROFILES="postgres"
else
    POSTGRES_ENABLED="false"
    POSTGRES_PASSWORD=""
    COMPOSE_PROFILES=""
    print_warning "PostgreSQL отключён - аналитика будет недоступна"
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

ENV_FILE="${INSTALL_DIR}/.env"

print_info "Создаю файл .env со следующими настройками:"
echo ""
print_info "  API_TOKEN: ${API_TOKEN:0:10}..."
print_info "  AGENT_TOKEN: ${AGENT_TOKEN:0:10}..."
print_info "  PANEL_URL: $PANEL_URL"
print_info "  TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:0:10}..."
print_info "  TELEGRAM_ADMIN_IDS: $TELEGRAM_ADMIN_IDS"
print_info "  TLS_ENABLED: $TLS_ENABLED"
print_info "  POSTGRES_ENABLED: $POSTGRES_ENABLED"
echo ""

cat > "$ENV_FILE" << EOF
# ============================================
# BedolagaBan Server Configuration
# Создано автоматически: $(date)
# ============================================

# === HTTP/TCP сервер ===
HTTP_HOST=0.0.0.0
HTTP_PORT=8080
TCP_HOST=0.0.0.0
TCP_PORT=9999

# === Лицензия ===
LICENSE_KEY=$LICENSE_KEY

# === Авторизация ===
API_TOKEN=$API_TOKEN
AGENT_TOKEN=$AGENT_TOKEN

# === Remnawave Panel ===
PANEL_URL=$PANEL_URL
PANEL_TOKEN=$PANEL_TOKEN
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
EOF

print_success "Файл .env создан: $ENV_FILE"

# ========================================
# Создание docker-compose.yml
# ========================================

COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

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
        # Manual mode: монтируем директорию с сертификатами
        CERT_DIR=$(dirname "$TLS_CERT_PATH")
        TLS_VOLUME="      - ${CERT_DIR}:${CERT_DIR}:ro"
    fi
fi

cat > "$COMPOSE_FILE" << COMPOSE
services:
  banhammer:
    image: ${REGISTRY}/bedolagaban-server:${TAG}
    container_name: banhammer-lite
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "9999:9999"
    env_file: .env
    environment:
      - HTTP_HOST=0.0.0.0
      - HTTP_PORT=8080
      - TCP_HOST=0.0.0.0
      - TCP_PORT=9999
    volumes:
      - ./data:/app/data
${TLS_VOLUME}
    networks:
      - banhammer-network
${REMNAWAVE_NET_REF}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
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
      - API_URL=http://banhammer:8080
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

print_success "docker-compose.yml создан"

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

HTTP_PORT=8080
TCP_PORT=9999

check_port_in_use() {
    local port=$1
    if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        return 0
    else
        return 1
    fi
}

PORTS_OK=true

if check_port_in_use $HTTP_PORT; then
    print_warning "Порт $HTTP_PORT уже используется другим процессом!"
    PORTS_OK=false
else
    print_success "Порт $HTTP_PORT свободен (HTTP API)"
fi

if check_port_in_use $TCP_PORT; then
    print_warning "Порт $TCP_PORT уже используется другим процессом!"
    PORTS_OK=false
else
    print_success "Порт $TCP_PORT свободен (TCP для агентов)"
fi

echo ""

# Проверяем firewall
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(sudo ufw status 2>/dev/null | head -n1)

    if echo "$UFW_STATUS" | grep -q "Status: active"; then
        print_info "Обнаружен активный UFW firewall"
        echo ""

        if ! sudo ufw status | grep -q "$HTTP_PORT"; then
            print_warning "Порт $HTTP_PORT не открыт в UFW"
            if ask_yes_no "Открыть порт $HTTP_PORT/tcp в UFW?"; then
                sudo ufw allow $HTTP_PORT/tcp >/dev/null 2>&1 && print_success "Порт $HTTP_PORT/tcp открыт" || print_error "Не удалось открыть порт"
            fi
        else
            print_success "Порт $HTTP_PORT уже открыт в UFW"
        fi

        echo ""

        if ! sudo ufw status | grep -q "$TCP_PORT"; then
            print_warning "Порт $TCP_PORT не открыт в UFW"
            if ask_yes_no "Открыть порт $TCP_PORT/tcp в UFW? (нужен для агентов)"; then
                sudo ufw allow $TCP_PORT/tcp >/dev/null 2>&1 && print_success "Порт $TCP_PORT/tcp открыт" || print_error "Не удалось открыть порт"
            else
                print_warning "Порт $TCP_PORT не открыт - агенты НЕ смогут подключиться!"
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

    if ! sudo iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$HTTP_PORT"; then
        print_warning "Порт $HTTP_PORT не найден в iptables"
        if ask_yes_no "Открыть порт $HTTP_PORT/tcp?"; then
            sudo iptables -A INPUT -p tcp --dport $HTTP_PORT -j ACCEPT && print_success "Порт $HTTP_PORT/tcp открыт"
        fi
    else
        print_success "Порт $HTTP_PORT открыт в iptables"
    fi

    echo ""

    if ! sudo iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$TCP_PORT"; then
        print_warning "Порт $TCP_PORT не найден в iptables"
        if ask_yes_no "Открыть порт $TCP_PORT/tcp? (нужен для агентов)"; then
            sudo iptables -A INPUT -p tcp --dport $TCP_PORT -j ACCEPT && print_success "Порт $TCP_PORT/tcp открыт"
        fi
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

# Проверяем авторизацию в GHCR
print_info "Проверяю доступ к реестру образов..."
if ! docker pull ${REGISTRY}/bedolagaban-server:${TAG} --quiet 2>/dev/null; then
    echo ""
    print_warning "Нет доступа к ${REGISTRY}. Нужна авторизация."
    print_info "Создай токен: https://github.com/settings/tokens/new"
    print_info "Нужные права: read:packages"
    echo ""
    read -sp "$(printf "${YELLOW}GitHub Personal Access Token: ${NC}")" GHCR_TOKEN
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
docker compose pull

echo ""
print_info "Запускаю контейнеры..."
if docker compose up -d; then
    echo ""
    print_success "Контейнеры запущены!"
else
    echo ""
    print_error "Ошибка при запуске контейнеров"
    print_info "Проверь логи: docker compose logs"
    exit 1
fi

echo ""
print_info "Жду пока сервисы запустятся (10 секунд)..."
sleep 10

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
if curl -s http://localhost:8080/health > /dev/null 2>&1; then
    print_success "HTTP API работает!"
else
    print_warning "HTTP API не отвечает (может еще запускаться)"
fi

echo ""
print_info "Последние логи сервера:"
echo ""
docker compose logs --tail=15 banhammer

# ========================================
# Итоги
# ========================================
echo ""
echo ""
print_header "Установка завершена!"
echo ""

echo -e "${GREEN}✓ BedolagaBan сервер успешно установлен и запущен!${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${BLUE}ВАЖНАЯ ИНФОРМАЦИЯ${NC}"
echo ""
echo -e "${YELLOW}API Token (для HTTP API):${NC}"
echo "   $API_TOKEN"
echo ""
echo -e "${YELLOW}Agent Token (для установки на VPN ноды):${NC}"
echo "   $AGENT_TOKEN"
echo ""
echo -e "${YELLOW}API Endpoint:${NC}"
echo "   http://localhost:8080"
echo ""
echo -e "${YELLOW}TCP порт для агентов:${NC}"
echo "   9999"
echo ""
if [ "$POSTGRES_ENABLED" = "true" ]; then
echo -e "${YELLOW}PostgreSQL:${NC}"
echo "   Включён (аналитика доступна)"
echo "   Пароль: $POSTGRES_PASSWORD"
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
echo "  curl -H \"Authorization: Bearer $API_TOKEN\" http://localhost:8080/api/stats"
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
    echo -e "  ${YELLOW}3.${NC} Открой порт 9999 для подключения агентов:"
    echo "     sudo ufw allow 9999/tcp"
    echo ""
    echo -e "  ${YELLOW}4.${NC} Установи агенты на VPN ноды"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}✓ Готово! Система готова к работе.${NC}"
echo ""

# Сохраняем информацию об установке (без секретов)
cat > ${INSTALL_DIR}/INSTALLATION_INFO.txt << EOF
BedolagaBan Installation Information
=====================================
Дата установки: $(date)
Директория: $INSTALL_DIR

API Endpoint: http://localhost:8080
TCP Port: 9999
TLS Enabled: $TLS_ENABLED
$([ "$TLS_ENABLED" = "true" ] && echo "TLS Domain: $TLS_DOMAIN")

PostgreSQL Enabled: $POSTGRES_ENABLED
Admin IDs: $TELEGRAM_ADMIN_IDS
Panel URL: $PANEL_URL
$([ "$NEED_NETWORK" = true ] && echo "Docker Network: $NETWORK_NAME")

Все секреты хранятся в: .env
EOF

echo ""
print_success "Информация об установке сохранена в ${INSTALL_DIR}/INSTALLATION_INFO.txt"
echo ""
