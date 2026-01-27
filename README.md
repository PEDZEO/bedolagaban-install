<div align="center">

# BedolagaBan

**Система мониторинга и защиты VPN подключений**

Автоматическое обнаружение мультиаккаунтов, блокировка нарушителей, аналитика трафика

[![Remnawave](https://img.shields.io/badge/Panel-Remnawave-blue)](https://github.com/remnawave)
[![Docker](https://img.shields.io/badge/Docker-Compose%20v2-2496ED)](https://docs.docker.com/compose/)
[![License](https://img.shields.io/badge/License-Commercial-red)](#лицензия)

</div>

---

## Возможности

| | Функция | Описание |
|---|---------|----------|
| **Мониторинг** | Подключения в реальном времени | Отслеживание всех активных сессий |
| **Мультиаккаунты** | Автоматическое обнаружение | Детекция по IP, fingerprint, поведению |
| **Наказания** | Гибкая система банов | Прогрессивные баны, ручные блокировки |
| **Сеть** | Определение типа подключения | Wi-Fi / Mobile / VPN / Datacenter |
| **GeoIP** | Аналитика по странам | Геолокация и ASN всех подключений |
| **Telegram** | Бот для управления | Уведомления, команды, отчёты |
| **API** | REST API | Полный контроль через HTTP |
| **Ноды** | Мульти-серверная архитектура | Агенты на каждой VPN ноде |

## Требования

- **OS:** Linux (Ubuntu 20.04+ / Debian 11+)
- **Docker:** Docker + Docker Compose v2
- **RAM:** 2 GB (сервер) / 256 MB (агент)
- **Панель:** [Remnawave](https://github.com/remnawave)
- **Лицензия:** Лицензионный ключ

## Установка

### Сервер

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PEDZEO/bedolagaban-install/main/install.sh)
```

Интерактивный установщик проведёт через все шаги:

1. Проверка Docker и системных требований
2. Настройка токенов безопасности
3. Ввод лицензионного ключа
4. Подключение к Remnawave Panel
5. Настройка Telegram бота
6. TLS шифрование для агентов
7. Система автобанов
8. PostgreSQL для аналитики
9. Проверка портов и firewall
10. Запуск контейнеров

### Агент (на каждую VPN ноду)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PEDZEO/bedolagaban-install/main/install_agent.sh)
```

Агент собирает данные о подключениях и отправляет на центральный сервер.

## Управление

<details>
<summary><b>Сервер</b> — /opt/banhammer</summary>

```bash
cd /opt/banhammer

docker compose logs -f                              # Логи
docker compose restart                              # Перезапуск
docker compose down                                 # Остановка
docker compose pull && docker compose up -d          # Обновление
```

</details>

<details>
<summary><b>Агент</b> — /opt/banhammer-agent</summary>

```bash
cd /opt/banhammer-agent

docker compose logs -f                              # Логи
docker compose restart                              # Перезапуск
docker compose down                                 # Остановка
docker compose pull && docker compose up -d          # Обновление
```

</details>

## Лицензия

Коммерческое ПО. Все права защищены.

Для приобретения лицензии: [@pedzeeo](https://t.me/pedzeeo)
