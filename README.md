# IDS Observability — Zeek + Suricata + Grafana

Стек для **реального span-трафика**: Vector читает логи с хоста, отправляет в Loki, Grafana показывает сравнение и алерты. **Grafana доступна только по HTTPS.**

Отличие от [IDS Lab](../IDS): там Docker-лаба с PCAP и пультом; здесь только observability поверх уже работающих Suricata/Zeek на машине.

## Как это работает

### Общая схема

```
  span NIC
      │
      ├── Suricata ──► /var/log/suricata/eve.json
      │                      │
      └── Zeek ──────► /opt/zeek/logs/current/*.log
                             │
                             ▼
                    Vector (tail файлов)
                             │
              parse JSON + нормализация полей
              (vendor, log_type, src_ip, alert_title, …)
                             │
                             ▼
                         Loki (хранение)
                             │
                             ▼
              Grafana HTTPS (дашборды + alert rules)
```

### 1. Suricata и Zeek на хосте

На сенсоре уже крутятся Suricata и Zeek, которые слушают зеркальный (span) интерфейс. Они пишут логи **на диск хоста** — Docker их не генерирует, только читает через bind-mount.

| Движок | Файл | Что берём |
|--------|------|-----------|
| Suricata | `eve.json` | `event_type=alert` — сигнатурные алерты; `event_type=stats` — kernel_drops и счётчики захвата |
| Zeek | `notice.log` | notices (аналог алертов) |
| Zeek | `intel.log` | совпадения с intel-листами |
| Zeek | `capture_loss.log` | пропуски захвата (gaps) |
| Zeek | `stats.log` | объём обработанного трафика |

`conn.log` не собирается — на span-трафике слишком объёмный.

### 2. Vector — сбор и нормализация

Конфиг: `vector/vector.toml`.

- **Источники** — `file` source, tail каждого лог-файла с хоста (`/logs/suricata`, `/logs/zeek` внутри контейнера).
- **Парсинг** — каждая строка JSON; строки с `#` (заголовки Zeek) отбрасываются.
- **Нормализация** — алерты Suricata и notices Zeek приводятся к общим полям:

  | Поле | Назначение |
  |------|------------|
  | `vendor` | `suricata` или `zeek` |
  | `log_type` | `alert`, `notice`, `intel`, `stats`, `capture_loss` |
  | `alert_title` | текст сигнатуры / notice |
  | `src_ip`, `dest_ip` | участники |
  | `community_id` | хеш потока для корреляции |
  | `ts` | время события |

- **Режим чтения**: `read_from = "end"` — только новые строки (production). Для backfill — `vector.bootstrap.toml` (`read_from = "beginning"`).
- **Checkpoint** — Vector запоминает позицию в volume `vector-data`, после перезапуска не дублирует старые строки.

### 3. Loki — хранение

Vector отправляет JSON в Loki с метками `job=ids`, `vendor`, `log_type`. Grafana запрашивает через LogQL (`count_over_time`, `json`, `unwrap`).

Retention по умолчанию — 7 дней (`LOKI_RETENTION=168h`). Loki слушает только `127.0.0.1:3100` — наружу не выставлен.

### 4. Grafana — визуализация и алерты

- **HTTPS обязателен**: при `docker compose up` сервис `cert-init` создаёт self-signed сертификат в `certs/` (или использует ваш `grafana.crt` / `grafana.key`).
- **Дашборд** `IDS: Zeek vs Suricata` — счётчики, графики сравнения, таблицы алертов, корреляция по `community_id`.
- **Alert rules** (`grafana/provisioning/alerting/rules.yaml`) — всплески алертов, kernel drops, capture loss. Contact point (Slack/email) настраивается в UI.

### 5. Сравнение Zeek vs Suricata

Движки видят один span-трафик, но детектируют по-разному:

- **Suricata** — сигнатуры (SID), severity, категории ET/Open rules.
- **Zeek** — поведенческие notices (скрипты Zeek), intel hits.

На дашборде видно, кто что поймал и с какой частотой. При включённом **community id** на обоих движках — поиск по одному потоку в панели «Корреляция».

---

## Быстрый старт (Linux, сенсор)

### Требования

- Docker Compose v2
- Suricata + Zeek уже пишут логи
- Пути в `.env` — **абсолютные** (иначе bind-mount не сработает)

### Установка

```bash
ls -la /var/log/suricata/eve.json
ls -la /opt/zeek/logs/current/

cp .env.example .env
# отредактируйте SURICATA_LOG_DIR, ZEEK_LOG_DIR, GRAFANA_ADMIN_PASSWORD
# для доступа из сети укажите IP/DNS сенсора:
#   GRAFANA_ROOT_URL=https://10.0.0.50:3000
#   GRAFANA_CERT_SAN=DNS:ids-sensor,IP:10.0.0.50,DNS:localhost,IP:127.0.0.1

docker compose up -d
```

Grafana слушает **все интерфейсы** (`0.0.0.0:3000`): **https://\<IP-сенсора\>:3000**.  
Браузер предупредит о self-signed cert — это нормально; для корректного имени в сертификате задайте `GRAFANA_CERT_SAN` и пересоздайте `certs/grafana.*`.

Дашборд: **IDS → IDS: Zeek vs Suricata**

### HTTPS

| Переменная | Назначение |
|------------|------------|
| `GRAFANA_BIND` / `GRAFANA_PORT` | на чём слушать (по умолчанию `0.0.0.0:3000`) |
| `GRAFANA_ROOT_URL` | URL UI, напр. `https://10.0.0.50:3000` |
| `GRAFANA_CERT_CN` | CN сертификата |
| `GRAFANA_CERT_SAN` | SAN: `DNS:…,IP:…` (нужен IP/DNS сенсора) |
| `GRAFANA_TLS_DAYS` | срок self-signed cert |

Loki остаётся только на `127.0.0.1:3100` — наружу не открыт.

**Свой сертификат** (Let's Encrypt / внутренний CA):

```bash
cp your-fullchain.pem certs/grafana.crt
cp your-key.pem certs/grafana.key
chmod 600 certs/grafana.key
docker compose up -d
```

Если `certs/grafana.crt` и `certs/grafana.key` уже есть — `cert-init` их не перезаписывает.

На Linux для ужесточения прав: `chown 472:0 certs/grafana.key && chmod 640 certs/grafana.key` (UID 472 — пользователь Grafana в контейнере).

Ручная генерация (без Docker):

```bash
chmod +x scripts/gen-certs.sh
./scripts/gen-certs.sh ./certs
```

### Первичная загрузка существующих логов

```bash
# в .env: VECTOR_CONFIG=vector.bootstrap.toml
docker compose stop vector
docker compose rm -f vector
docker volume rm ids-observability_vector-data
docker compose up -d
# верните VECTOR_CONFIG=vector.toml (или удалите строку)
```

---

## Проверка на Windows (логи IDS Lab)

В `.env` укажите пути к лабораторным логам (Docker Desktop понимает `C:/…`):

```env
SURICATA_LOG_DIR=C:/Users/admin/Documents/PR/IDS/logs/pcap/suricata
ZEEK_LOG_DIR=C:/Users/admin/Documents/PR/IDS/logs/pcap/zeek
VECTOR_CONFIG=vector.bootstrap.toml
GRAFANA_ROOT_URL=https://localhost:3000
```

---

## Community ID (корреляция)

**Suricata** (`suricata.yaml`):

```yaml
outputs:
  - eve-log:
      community-id: true
      community-id-seed: 0
```

**Zeek** — скрипт `community-id-logs.zeek` из IDS Lab.

На дашборде введите `community_id` в переменную — увидите события обоих движков по одному потоку.

---

## Алерты Grafana

| Правило | Условие |
|---------|---------|
| Suricata spike | >20 alerts / 5 min |
| Zeek notice spike | >10 notices / 5 min |
| Suricata kernel drops | drops > 0 |
| Zeek capture loss | gaps > 0 |

Contact point: *Alerting → Contact points* в UI Grafana.

---

## Совместимость с Linux

| Аспект | Решение |
|--------|---------|
| Переводы строк | `.gitattributes` — LF для всех конфигов |
| Пути логов | Абсолютные Linux-пути в `.env` |
| Zeek JSON | Поля `id.orig_h` / `id.resp_h` (плоские ключи, не вложенный объект) |
| Отсутствующие файлы | Vector ждёт появления `notice.log`, `intel.log` — ошибки нет |
| Права на логи | Пользователь Vector (root в контейнере) должен читать файлы на хосте; при необходимости добавьте группу или `chmod o+r` |
| HTTPS | Только TLS на порту 3000, HSTS и secure cookies включены |

---

## Обслуживание

```bash
docker compose ps
docker compose logs -f vector
docker compose restart vector          # после правок vector.toml
docker compose down -v                 # удалить данные Loki/Grafana (осторожно!)
```

---

## Структура проекта

```
├── docker-compose.yml
├── scripts/gen-certs.sh       # TLS для Grafana
├── certs/                     # grafana.crt / grafana.key (не в git)
├── vector/
│   ├── vector.toml            # production (read from end)
│   └── vector.bootstrap.toml  # backfill (read from beginning)
├── loki/config.yaml
├── grafana/provisioning/      # datasource, dashboard, alert rules
└── .env.example
```

---

## Что дальше

- Contact point / webhook для SOC
- `conn.log` с sampling в Vector
- Экспорт в Elasticsearch через Vector sink
- Замена self-signed cert на корпоративный CA
