<div align="center">

# BedolagaBan Installer

**Интерактивный установщик BedolagaBan для сервера и VPN-нод**

Установщик разворачивает систему мониторинга VPN-подключений, детекции нарушений,
автобанов, Telegram-управления и сбора аналитики для инфраструктуры на базе
**Remnawave Panel**.

[![Panel](https://img.shields.io/badge/Panel-Remnawave-blue)](https://github.com/remnawave)
[![Docker](https://img.shields.io/badge/Docker-Compose%20v2-2496ED)](https://docs.docker.com/compose/)
[![License](https://img.shields.io/badge/License-Commercial-red)](#лицензия)

</div>

---

## Что делает BedolagaBan

BedolagaBan нужен для контроля пользователей VPN и автоматической реакции на
подозрительное поведение.

Система умеет:

- отслеживать подключения с VPN-нод в реальном времени
- определять превышение лимита устройств/IP
- банить пользователей автоматически или вручную
- фиксировать Wi-Fi / mobile / datacenter / ASN признаки
- вести статистику и историю нарушений
- отправлять уведомления и давать управление через Telegram-бота
- работать с Remnawave Panel через API токен и, при необходимости, через `PANEL_SECRET_KEY`

---

## Что ставит этот репозиторий

Установщик разворачивает две части системы.

### 1. Центральный сервер

Сервер BedolagaBan:

- принимает данные от агентов с VPN-нод
- синхронизируется с Remnawave Panel
- считает лимиты, нарушения и наказания
- поднимает HTTP API
- запускает Telegram-бота
- хранит данные в локальной БД или PostgreSQL

Обычно ставится на отдельный сервер управления или на тот же сервер, где уже
крутится панель.

### 2. Агент на VPN-ноде

Агент:

- читает логи Xray/RemnaNode
- собирает подключения пользователей
- отправляет события на центральный сервер

Агент ставится на **каждую VPN-ноду**, которую нужно мониторить.

---

## Для кого этот установщик

Подходит, если ты хочешь:

- быстро развернуть BedolagaBan без ручной сборки `.env`
- подключить систему к существующей Remnawave Panel
- централизованно мониторить несколько VPN-нод
- получить рабочую установку через Docker Compose

Не подходит, если тебе нужен только исходный код для ручной кастомной интеграции.
В таком случае лучше использовать основной репозиторий проекта.

---

## Что нужно заранее подготовить

Перед установкой подготовь:

- Linux сервер: Ubuntu 20.04+ / Debian 11+ / совместимый дистрибутив
- Docker и Docker Compose v2
- лицензионный ключ BedolagaBan
- URL твоей Remnawave Panel
- API токен панели
- Telegram bot token от `@BotFather`
- Telegram ID администратора

Если панель закрыта через reverse-proxy/NGINX, дополнительно может понадобиться:

- `PANEL_SECRET_KEY` в формате `cookie_name:cookie_value`
- пример: `UinFiwLL:QHxwyZyP`

---

## Что спрашивает установщик

Во время установки серверного контура скрипт задаёт вопросы и сам формирует `.env`.

Основные блоки:

1. Проверка Docker и системных требований
2. Генерация токенов безопасности
3. Ввод лицензионного ключа
4. Подключение к Remnawave Panel
5. Ввод API токена панели
6. Необязательный `PANEL_SECRET_KEY` для reverse-proxy
7. Настройка Telegram-бота
8. TLS для агентов
9. Система автобанов и аналитика
10. Запуск контейнеров

Если `PANEL_SECRET_KEY` не нужен, просто нажми `Enter` и установка продолжится
по старому сценарию.

---

## Быстрая установка

### Сервер

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PEDZEO/bedolagaban-install/main/install.sh)
```

После установки сервер обычно оказывается в:

```bash
/opt/banhammer
```

### Агент на VPN-ноде

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PEDZEO/bedolagaban-install/main/install_agent.sh)
```

После установки агент обычно оказывается в:

```bash
/opt/banhammer-agent
```

---

## Как работает схема целиком

Поток данных выглядит так:

1. Пользователь подключается к VPN-ноду.
2. Агент на ноде читает логи подключений.
3. Агент отправляет события на сервер BedolagaBan.
4. Сервер сопоставляет пользователя с данными из Remnawave Panel.
5. Система считает лимиты, сеть, ASN, историю и другие признаки.
6. При нарушении создаётся бан, уведомление или запись в аналитику.
7. Администратор видит это в Telegram-боте и через API.

---

## Когда использовать `PANEL_SECRET_KEY`

По умолчанию BedolagaBan подключается к панели через:

- `PANEL_URL`
- `PANEL_TOKEN`

Если доступ к панели закрыт через NGINX/reverse-proxy и API без cookie режется,
установщик позволяет сразу сохранить:

```env
PANEL_SECRET_KEY=cookie_name:cookie_value
```

Например:

```env
PANEL_SECRET_KEY=UinFiwLL:QHxwyZyP
```

Это полезно, если панель не отдаёт API без дополнительной cookie-авторизации.

---

## Обновление

### Сервер

```bash
cd /opt/banhammer
docker compose pull
docker compose up -d --force-recreate
```

### Агент

```bash
cd /opt/banhammer-agent
docker compose pull
docker compose up -d --force-recreate
```

---

## Полезные команды

### Сервер

```bash
cd /opt/banhammer
docker compose ps
docker compose logs -f
docker logs -f banhammer-lite
docker logs -f banhammer-bot
```

### Агент

```bash
cd /opt/banhammer-agent
docker compose ps
docker compose logs -f
```

---

## Частые проблемы

### Панель не подключается

Проверь:

- правильный ли `PANEL_URL`
- рабочий ли `PANEL_TOKEN`
- нужен ли `PANEL_SECRET_KEY`
- не режет ли reverse-proxy запросы в API
- не требуется ли внутренний Docker URL вместо публичного домена

### Агент не виден на сервере

Проверь:

- совпадает ли `AGENT_TOKEN` на сервере и ноде
- доступен ли порт `9999/tcp`
- читаются ли логи Xray/RemnaNode
- показывает ли сервер в логах `Node registered`

### install.sh не запускается

Если на Linux видишь ошибку вида:

```text
cannot execute: required file not found
```

исправь окончания строк:

```bash
dos2unix install.sh
chmod +x install.sh
./install.sh
```

или:

```bash
sed -i 's/\r$//' install.sh
chmod +x install.sh
./install.sh
```

---

## Что хранится после установки

После работы установщика у тебя остаются:

- `.env` с конфигурацией
- `docker-compose.yml`
- директории данных проекта
- рабочие контейнеры сервера/бота или агента

Установщик не просто запускает контейнеры, а оставляет понятную структуру для
дальнейшего обслуживания.

---

## Лицензия

Коммерческое ПО. Все права защищены.

Для приобретения лицензии и доступа:

- Сайт оплаты: [shop.pedze.ru](https://shop.pedze.ru/)
- Telegram: [@ban](https://t.me/bedolagaban)
