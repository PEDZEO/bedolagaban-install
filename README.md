# BedolagaBan

Система мониторинга и управления VPN подключениями. Автоматическое обнаружение мультиаккаунтов, блокировка нарушителей, мониторинг трафика и сетевой активности.

## Возможности

- Мониторинг подключений в реальном времени
- Автоматическое обнаружение мультиаккаунтов
- Система наказаний с гибкими правилами
- Определение типа сети (Wi-Fi / Mobile / VPN)
- GeoIP аналитика
- Telegram бот для управления
- REST API
- Поддержка нескольких VPN нод через агенты

## Требования

- Linux (Ubuntu 20.04+ / Debian 11+)
- Docker + Docker Compose v2
- 2 GB RAM (сервер), 256 MB RAM (агент)
- Лицензионный ключ

## Установка сервера

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PEDZEO/bedolagaban-install/main/install.sh)
```

Скрипт проведёт через все шаги:
1. Проверка Docker
2. Настройка панели (3x-ui / Marzban / Remnanode)
3. Настройка Telegram бота
4. Настройка безопасности (API токены, TLS)
5. Настройка PostgreSQL
6. Настройка портов и firewall
7. Запуск контейнеров

## Установка агента на VPN ноду

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PEDZEO/bedolagaban-install/main/install_agent.sh)
```

Агент устанавливается на каждую VPN ноду и отправляет данные о подключениях на центральный сервер.

## Управление

После установки сервера:

```bash
cd /opt/banhammer

# Логи
docker compose logs -f

# Перезапуск
docker compose restart

# Остановка
docker compose down

# Обновление
docker compose pull && docker compose up -d
```

После установки агента:

```bash
cd /opt/banhammer-agent

# Логи
docker compose logs -f

# Перезапуск
docker compose restart

# Обновление
docker compose pull && docker compose up -d
```

## Лицензия

Коммерческое ПО. Все права защищены. Для приобретения лицензии обращайтесь в Telegram: [@pedzeeo](https://t.me/pedzeeo)
