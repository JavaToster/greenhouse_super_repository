# Greenhouse

Микросервисная система удалённого управления коммерческими теплицами. Позволяет владельцам регистрировать кластеры теплиц, назначать рабочих, подключать IoT-устройства и собирать телеметрию с датчиков (температура, влажность воздуха, влажность почвы, освещённость).

Проект организован как **git super-repository** с тремя независимыми сервисами, подключёнными как **git submodules**.

## Архитектура

```
                          ┌──────────────────────┐
                          │   greenhouse-         │
                          │   authentication      │ :8080 (пример)
                          │                       │
                          │  Telegram-пользователи │
                          │  JWT-выдача           │
                          └──────────┬────────────┘
                                     │ HTTP (Feign / RestClient)
                     ┌───────────────┼────────────────┐
                     │                                │
          ┌──────────▼───────────┐         ┌──────────▼───────────┐
          │  greenhouse-          │         │  greenhouse-          │
          │  inventory            │◄────────┤  telemetry            │
          │                       │  HTTP   │                       │
          │  Кластеры, устройства,│         │  Приём и чтение       │
          │  активация девайсов   │         │  показаний датчиков   │
          └──────────┬────────────┘         └──────────┬────────────┘
                      │                                 │
                      └────────────────┬────────────────┘
                                        │
                          ┌─────────────▼─────────────┐
                          │   PostgreSQL   │   Redis    │
                          │ (3 отдельные   │ (challenges,│
                          │   базы)        │  temp secrets)│
                          └────────────────────────────┘
```

| Сервис | Назначение | Своя БД |
|---|---|---|
| `greenhouse_authentication` | Регистрация/вход пользователей (через Telegram ID), управление ролями, выдача JWT | `greenhouse_authorization` |
| `greenhouse_inventory` | Кластеры теплиц, назначение рабочих, регистрация и challenge-response аутентификация IoT-устройств | `greenhouse_inventory` |
| `greenhouse_telemetries` | Приём показаний с устройств и выдача истории телеметрии владельцам кластеров | `greenhouse_telemetries` |

Сервисы общаются друг с другом по HTTP (Spring Cloud OpenFeign), используя общий JWT-секрет для проверки токенов между сервисами.

## Технологический стек

- **Java 21**, **Spring Boot 4.x**
- Spring Web MVC, Spring Security (JWT, ролевая модель)
- Spring Data JPA / JDBC, **PostgreSQL**
- Spring Data Redis (challenge-response для устройств, временные секреты)
- Spring Cloud OpenFeign (межсервисные HTTP-вызовы)
- Liquibase (миграции БД)
- Docker / Docker Compose (multi-stage build: `maven:3.9.5-eclipse-temurin-21` → `eclipse-temurin:21-jre-jammy`)

## Ролевая модель

| Роль | Кто это | Доступ |
|---|---|---|
| `ADMIN` | Администратор системы | Полный доступ ко всем сервисам |
| `OWNER` | Владелец теплицы | Управляет своими кластерами, рабочими, видит устройства и телеметрию своих кластеров |
| `INSTALLER` | Монтажник | Регистрирует кластеры и устройства, получает секреты устройств при активации |
| `WORKER` | Рабочий | Доступ на чтение к кластерам, к которым прикреплён |
| `DEVICE` | IoT-устройство | Отдельный принципал — после challenge-response аутентификации может только отправлять телеметрию |

## API

### `greenhouse_authentication` — `/auth`, `/api/users`

| Метод | Путь | Доступ | Описание |
|---|---|---|---|
| POST | `/auth/sing-up` | public | Регистрация пользователя |
| POST | `/auth/sing-in` | public | Вход, выдача JWT |
| GET | `/api/users/{telegramId}` | ADMIN, INSTALLER, OWNER | Получить пользователя по Telegram ID |
| POST | `/api/users/batch` | — | Получить список пользователей по списку ID |
| PATCH | `/api/users/{telegramId}/role` | ADMIN | Назначить роль пользователю |
| DELETE | `/api/users/{telegramId}/remove` | ADMIN | Удалить пользователя |

### `greenhouse_inventory` — `/api/clusters`, `/api/devices`, `/api/devices/auth`

| Метод | Путь | Доступ | Описание |
|---|---|---|---|
| GET | `/api/clusters` | ADMIN, OWNER, WORKER | Список кластеров (с фильтром по owner/worker) |
| POST | `/api/clusters` | INSTALLER, ADMIN | Регистрация нового кластера + генерация устройств |
| POST | `/api/clusters/{clusterId}/workers` | OWNER | Назначить рабочего на кластер |
| DELETE | `/api/clusters/{clusterId}/workers` | OWNER | Снять рабочего с кластера |
| GET | `/api/devices/secrets/{token}` | INSTALLER, ADMIN | Получить и активировать секреты устройств по токену активации |
| GET | `/api/devices/my-clusters/{clusterId}` | OWNER | Список устройств в своём кластере |
| DELETE | `/api/devices/{id}/remove` | ADMIN | Удалить устройство |
| POST | `/api/devices/auth/challenge/{deviceId}` | public | Шаг 1 challenge-response: получить challenge |
| POST | `/api/devices/auth/verify` | public | Шаг 2: подтвердить подписью, получить JWT для устройства |

### `greenhouse_telemetries` — `/api/telemetries`

| Метод | Путь | Доступ | Описание |
|---|---|---|---|
| POST | `/api/telemetries` | DEVICE | Устройство отправляет показания датчиков |
| GET | `/api/telemetries/clusters/{clusterId}` | OWNER | История телеметрии по кластеру (параметр `size`, по умолчанию 50) |

## Аутентификация устройств (challenge-response)

Устройства не используют логин/пароль. Вместо этого:

1. Устройство запрашивает `POST /api/devices/auth/challenge/{deviceId}` — сервис генерирует случайный `challenge` и кладёт его в Redis с TTL 30 секунд.
2. Устройство вычисляет `HMAC-SHA256(challenge, secret)` (hex-кодировка) и отправляет на `POST /api/devices/auth/verify` вместе с `challenge` и `deviceId`.
3. Сервис сверяет присланную подпись с вычисленной на основе расшифрованного секрета устройства из БД. При совпадении — выдаёт JWT с ролью `DEVICE`.

Секрет устройства генерируется один раз при создании (`rawSecret`, `@Transient`, не хранится в БД постоянно) и передаётся монтажнику через одноразовый Redis-токен активации (`/api/devices/secrets/{token}`).

## Запуск проекта

### Требования

- Docker и Docker Compose
- Git (с поддержкой submodules)

### 1. Клонирование с submodules

```bash
git clone --recurse-submodules <url-супер-репозитория>
cd Greenhouse
```

Если репозиторий уже клонирован без submodules:

```bash
git submodule update --init --recursive
```

### 2. Настройка окружения

Скопируй пример переменных окружения и заполни реальными значениями:

```bash
cp .env.example .env
```

Обязательные переменные (см. `.env.example`): порты сервисов, креды Postgres, секрет JWT (общий для всех сервисов), ключ шифрования секретов устройств, SMTP-настройки для писем.

### 3. Запуск

```bash
docker compose up -d --build
```

Первый запуск скачает базовые образы и зависимости Maven — это может занять несколько минут в зависимости от скорости интернета. Повторные сборки используют layer-кэш Docker и кэш Maven-зависимостей.

### 4. Проверка

```bash
docker compose ps
```

Все сервисы должны быть в статусе `Up`, `postgres` и `redis` — `healthy`.

### Остановка

```bash
docker compose down        # остановить контейнеры
docker compose down -v     # + удалить данные (Postgres, Redis)
```

## Структура репозитория

```
Greenhouse/
├── docker-compose.yaml
├── infra/
│   └── postgres/
│       └── init-multiple-dbs.sh      # создаёт 3 БД в одном Postgres-инстансе
├── greenhouse_authentication/         # submodule
├── greenhouse_inventory/              # submodule
└── greenhouse_telemetries/            # submodule
```

Каждый сервис — самостоятельный Maven-проект со своим `Dockerfile` (multi-stage build) и независимой историей коммитов в собственном репозитории.

## Известные ограничения / TODO

- Опечатка в эндпоинтах `/auth/sing-up`, `/auth/sing-in` (должно быть `sign-up`/`sign-in`) — оставлено как есть, чтобы не сломать совместимость без отдельного релиза.
- Kafka упоминается в зависимостях, но не подключена и не используется в текущей конфигурации — интеграция в планах.
- Эндпоинт получения списка всех пользователей (`getAllUsers`) в `UserController` не имеет `@GetMapping` — требует доработки маршрута.
