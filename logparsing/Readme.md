# Concept 8 — Log Parsing & Rotation

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~20 minutes  
> **Prerequisite:** Concepts 1–7 must be complete

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Is Log Parsing & Rotation?](#what-is-log-parsing--rotation)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Parse Nginx Access Logs](#step-1--parse-nginx-access-logs)
  - [Step 2 — Parse Application Error Logs](#step-2--parse-application-error-logs)
  - [Step 3 — Detect Anomalies & Alert](#step-3--detect-anomalies--alert)
  - [Step 4 — Manual Log Rotation](#step-4--manual-log-rotation)
  - [Step 5 — Logrotate Configuration](#step-5--logrotate-configuration)
  - [Step 6 — Final Production-Ready Version](#step-6--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners ignore

```bash
# Most beginners never think about logs until something breaks
# Then they find:

ls -lh /var/log/nginx/
# -rw-r--r-- 1 root root 47G access.log      ← 47 GIGABYTES
# -rw-r--r-- 1 root root 12G error.log

df -h /
# /dev/sda1  50G  49G  100M  100%             ← disk is full
```

**What happens when the disk is full:**

- ❌ Nginx stops writing logs — silent, no warning
- ❌ App cannot write temp files — crashes unpredictably
- ❌ Database cannot write WAL files — corruption risk
- ❌ SSH may stop working — server becomes unreachable
- ❌ Deployments fail — no space for artifact extraction

### Real-world incident scenario

> A production server ran for 8 months with no log rotation.  
> A traffic spike generated 3GB of access logs in one night.  
> The disk hit 100% at 3AM.  
> The Node.js app crashed — it could not write session temp files.  
> MySQL stopped — it could not flush the InnoDB buffer.  
> The server became completely unresponsive.  
> Recovery took 6 hours: SSH in, manually delete logs, restart services.  
>
> **A single logrotate config and a weekly cron would have prevented all of it.**

---

## What Is Log Parsing & Rotation?

**Log Parsing** — reading log files programmatically to extract:
- Error rates and patterns
- Slow response times
- Top IPs, top endpoints
- Anomalies that need alerting

**Log Rotation** — managing log file size by:
- Archiving the current log file when it hits a size/age threshold
- Compressing the archive
- Deleting archives older than a retention window
- Signalling the app to open a fresh log file

Together they answer two questions every DevOps engineer must handle:

> *"What is happening in my app right now?"*  
> *"Why is my disk full at 3AM?"*

---

## Build It Step by Step

### Step 1 — Parse Nginx Access Logs

Nginx default log format:

```
$remote_addr - $remote_user [$time_local] "$request" $status $bytes_sent "$http_referer" "$http_user_agent"
```

Example log line:

```
203.0.113.42 - - [12/Jun/2024:09:15:32 +0530] "GET /api/orders HTTP/1.1" 200 1482 "-" "Mozilla/5.0"
```

**Parse it with `awk`:**

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

NGINX_LOG="/var/log/nginx/access.log"

parse_access_log() {
  log INFO "Parsing nginx access log: $NGINX_LOG"

  if [[ ! -f "$NGINX_LOG" ]]; then
    log ERROR "Log file not found: $NGINX_LOG"
    exit 1
  fi

  local total_requests
  total_requests=$(wc -l < "$NGINX_LOG")
  log INFO "Total requests in log: $total_requests"

  echo ""
  echo "── Top 10 IP Addresses ──────────────────────────"
  # $1 = IP address (first field)
  awk '{print $1}' "$NGINX_LOG" \
    | sort \
    | uniq -c \
    | sort -rn \
    | head -10 \
    | awk '{printf "  %8s requests  %s\n", $1, $2}'

  echo ""
  echo "── Top 10 Requested Endpoints ───────────────────"
  # $7 = request path (7th field)
  awk '{print $7}' "$NGINX_LOG" \
    | sort \
    | uniq -c \
    | sort -rn \
    | head -10 \
    | awk '{printf "  %8s requests  %s\n", $1, $2}'

  echo ""
  echo "── HTTP Status Code Breakdown ───────────────────"
  # $9 = status code (9th field)
  awk '{print $9}' "$NGINX_LOG" \
    | sort \
    | uniq -c \
    | sort -rn \
    | awk '{printf "  HTTP %s  →  %s requests\n", $2, $1}'

  echo ""
  echo "── 5xx Error Requests ───────────────────────────"
  # Filter lines where status starts with 5
  local error_count
  error_count=$(awk '$9 ~ /^5/' "$NGINX_LOG" | wc -l)
  local error_rate
  error_rate=$(awk "BEGIN {printf \"%.2f\", ($error_count / $total_requests) * 100}")
  echo "  5xx errors : $error_count"
  echo "  Error rate : ${error_rate}%"

  if (( $(echo "$error_rate > 5" | bc -l) )); then
    log WARN "High 5xx error rate detected: ${error_rate}%"
  fi
}

parse_access_log
```

**Output:**

```
── Top 10 IP Addresses ──────────────────────────
      4821 requests  203.0.113.42
      2103 requests  198.51.100.7
       987 requests  192.168.1.1

── Top 10 Requested Endpoints ───────────────────
      8432 requests  /api/orders
      3201 requests  /api/products
      1832 requests  /health

── HTTP Status Code Breakdown ───────────────────
  HTTP 200  →  14832 requests
  HTTP 404  →  432 requests
  HTTP 500  →  89 requests
  HTTP 302  →  21 requests

── 5xx Error Requests ───────────────────────────
  5xx errors : 89
  Error rate : 0.58%
```

> ✅ Instant visibility into traffic patterns — no Kibana required.

---

### Step 2 — Parse Application Error Logs

Parse structured app logs written by the `log()` function from Concept 1:

```
2024-06-12T09:15:32 [myapp] [ERROR] Failed to connect to Redis
2024-06-12T09:15:33 [myapp] [WARN ] Response time > 2s on /api/orders
2024-06-12T09:15:34 [myapp] [INFO ] Request completed: GET /api/orders 200
```

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_LOG="/var/log/myapp/app.log"

parse_app_log() {
  local since_minutes=${1:-60}    # default: last 60 minutes

  log INFO "Parsing app log — last ${since_minutes} minutes: $APP_LOG"

  [[ -f "$APP_LOG" ]] || { log ERROR "App log not found: $APP_LOG"; exit 1; }

  # Build timestamp for filtering (last N minutes)
  local since_ts
  since_ts=$(date -d "${since_minutes} minutes ago" '+%Y-%m-%dT%H:%M' 2>/dev/null \
    || date -v "-${since_minutes}M" '+%Y-%m-%dT%H:%M')   # macOS fallback

  echo ""
  echo "── Error Summary (last ${since_minutes} min) ────────────────"

  # Count each log level
  local info_count warn_count error_count
  info_count=$(grep  "\[INFO \]" "$APP_LOG" | awk -F'T' '$1"T"substr($2,1,5) >= "'"$since_ts"'"' | wc -l)
  warn_count=$(grep  "\[WARN \]" "$APP_LOG" | awk -F'T' '$1"T"substr($2,1,5) >= "'"$since_ts"'"' | wc -l)
  error_count=$(grep "\[ERROR\]" "$APP_LOG" | awk -F'T' '$1"T"substr($2,1,5) >= "'"$since_ts"'"' | wc -l)

  echo "  INFO  : $info_count"
  echo "  WARN  : $warn_count"
  echo "  ERROR : $error_count"

  echo ""
  echo "── Recent Errors ────────────────────────────────"
  grep "\[ERROR\]" "$APP_LOG" \
    | awk -F'T' '$1"T"substr($2,1,5) >= "'"$since_ts"'"' \
    | tail -10 \
    | while IFS= read -r line; do
        echo "  $line"
      done

  echo ""
  echo "── Top Error Messages ───────────────────────────"
  # Extract just the message after [ERROR]
  grep "\[ERROR\]" "$APP_LOG" \
    | sed 's/.*\[ERROR\] //' \
    | sort \
    | uniq -c \
    | sort -rn \
    | head -5 \
    | awk '{
        count = $1
        $1 = ""
        sub(/^ /, "")
        printf "  %5s times  %s\n", count, $0
      }'

  if [[ $error_count -gt 0 ]]; then
    log WARN "$error_count ERROR entries found in last ${since_minutes} minutes"
  else
    log INFO "No errors in last ${since_minutes} minutes ✓"
  fi
}

parse_app_log 60
```

**Output:**

```
── Error Summary (last 60 min) ────────────────
  INFO  : 2847
  WARN  : 43
  ERROR : 12

── Recent Errors ────────────────────────────────
  2024-06-12T09:10:11 [myapp] [ERROR] Failed to connect to Redis
  2024-06-12T09:12:44 [myapp] [ERROR] DB query timeout on /api/orders
  2024-06-12T09:15:32 [myapp] [ERROR] Failed to connect to Redis

── Top Error Messages ───────────────────────────
      8 times  Failed to connect to Redis
      3 times  DB query timeout on /api/orders
      1 times  Unhandled exception in payment processor
```

> ✅ Redis connection errors dominate — now you know exactly where to look.

---

### Step 3 — Detect Anomalies & Alert

Combine parsing with the Slack notification pattern from Concept 7:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

NGINX_LOG="/var/log/nginx/access.log"
APP_LOG="/var/log/myapp/app.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# Thresholds
ERROR_RATE_THRESHOLD=5        # 5xx error rate %
SLOW_REQUEST_THRESHOLD=2000   # milliseconds
ERROR_COUNT_THRESHOLD=10      # app errors per 5 min
SPIKE_MULTIPLIER=3            # traffic 3x normal = spike

notify_alert() {
  local severity=$1
  local message=$2
  log WARN "ALERT [$severity]: $message"
  [[ -z "$SLACK_WEBHOOK" ]] && return 0
  local icon="⚠️"
  [[ "$severity" == "CRITICAL" ]] && icon="🚨"
  curl -sf -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    -d "{\"text\":\"$icon [$severity] $HOSTNAME | $message\"}" > /dev/null || true
}

check_error_rate() {
  local window_minutes=${1:-5}
  log INFO "Checking 5xx error rate (last ${window_minutes} min)..."

  local since_ts
  since_ts=$(date -d "${window_minutes} minutes ago" '+%d/%b/%Y:%H:%M' 2>/dev/null \
    || date -v "-${window_minutes}M" '+%d/%b/%Y:%H:%M')

  # Filter log to time window
  local recent_lines total_requests error_requests error_rate

  recent_lines=$(awk -v ts="$since_ts" \
    '$4 > "["ts' "$NGINX_LOG" 2>/dev/null || echo "")

  total_requests=$(echo "$recent_lines" | wc -l)
  error_requests=$(echo "$recent_lines" | awk '$9 ~ /^5/' | wc -l)

  [[ $total_requests -eq 0 ]] && {
    log WARN "No requests in last ${window_minutes} minutes"
    return 0
  }

  error_rate=$(awk "BEGIN {printf \"%.1f\", ($error_requests/$total_requests)*100}")
  log INFO "5xx error rate: ${error_rate}% ($error_requests / $total_requests requests)"

  if (( $(echo "$error_rate > $ERROR_RATE_THRESHOLD" | bc -l) )); then
    notify_alert "CRITICAL" \
      "High 5xx rate: ${error_rate}% (${error_requests}/${total_requests} requests in last ${window_minutes}min)"
  fi
}

check_app_errors() {
  local window_minutes=${1:-5}
  log INFO "Checking app error count (last ${window_minutes} min)..."

  local since_ts
  since_ts=$(date -d "${window_minutes} minutes ago" '+%Y-%m-%dT%H:%M' 2>/dev/null \
    || date -v "-${window_minutes}M" '+%Y-%m-%dT%H:%M')

  local error_count
  error_count=$(awk -v ts="$since_ts" \
    '$1 >= ts && /\[ERROR\]/' "$APP_LOG" | wc -l)

  log INFO "App errors in last ${window_minutes} min: $error_count"

  if [[ $error_count -gt $ERROR_COUNT_THRESHOLD ]]; then
    # Get the most common error for the alert message
    local top_error
    top_error=$(awk -v ts="$since_ts" \
      '$1 >= ts && /\[ERROR\]/' "$APP_LOG" \
      | sed 's/.*\[ERROR\] //' \
      | sort | uniq -c | sort -rn | head -1 \
      | awk '{$1=""; print substr($0,2)}')

    notify_alert "WARNING" \
      "$error_count app errors in ${window_minutes}min — top error: $top_error"
  fi
}

check_traffic_spike() {
  log INFO "Checking for traffic spikes..."

  # Compare last 5 min vs previous 5 min
  local now_ts prev_ts prev_prev_ts
  now_ts=$(date -d "5 minutes ago"  '+%d/%b/%Y:%H:%M' 2>/dev/null || date -v "-5M"  '+%d/%b/%Y:%H:%M')
  prev_ts=$(date -d "10 minutes ago" '+%d/%b/%Y:%H:%M' 2>/dev/null || date -v "-10M" '+%d/%b/%Y:%H:%M')

  local recent_count baseline_count
  recent_count=$(awk -v ts="$now_ts" '$4 > "["ts' "$NGINX_LOG" | wc -l)
  baseline_count=$(awk -v s="$prev_ts" -v e="$now_ts" \
    '$4 > "["s && $4 < "["e' "$NGINX_LOG" | wc -l)

  [[ $baseline_count -eq 0 ]] && return 0

  local ratio
  ratio=$(awk "BEGIN {printf \"%.1f\", $recent_count/$baseline_count}")
  log INFO "Traffic: last 5min=$recent_count | previous 5min=$baseline_count | ratio=${ratio}x"

  if (( $(echo "$ratio > $SPIKE_MULTIPLIER" | bc -l) )); then
    notify_alert "WARNING" \
      "Traffic spike: ${ratio}x normal (${recent_count} req/5min vs ${baseline_count} baseline)"
  fi
}

run_anomaly_checks() {
  log INFO "════ Running Anomaly Checks ═════════════════"
  check_error_rate 5
  check_app_errors 5
  check_traffic_spike
  log INFO "════ Anomaly Checks Complete ════════════════"
}

run_anomaly_checks
```

**This script runs every 5 minutes via cron:**

```bash
# /etc/cron.d/myapp-monitor
*/5 * * * * deploy /opt/scripts/log-monitor.sh >> /var/log/myapp/monitor.log 2>&1
```

> ✅ Continuous automated monitoring — Slack alerts before users start complaining.

---

### Step 4 — Manual Log Rotation

Teach the concept before showing logrotate:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_NAME="myapp"
LOG_FILE="/var/log/$APP_NAME/app.log"
MAX_SIZE_MB=100
KEEP_DAYS=14

rotate_log() {
  local log_file=$1
  local max_size_mb=${2:-$MAX_SIZE_MB}

  [[ -f "$log_file" ]] || { log WARN "Log file not found: $log_file"; return 0; }

  # Check current size
  local size_mb
  size_mb=$(du -m "$log_file" | cut -f1)
  log INFO "Log file: $log_file | Size: ${size_mb}MB | Threshold: ${max_size_mb}MB"

  if [[ $size_mb -lt $max_size_mb ]]; then
    log INFO "No rotation needed — size ${size_mb}MB is under threshold"
    return 0
  fi

  log INFO "Rotating log — size ${size_mb}MB exceeds ${max_size_mb}MB threshold"

  local archive="${log_file}.$(date '+%Y%m%d-%H%M%S')"

  # Step 1: Move current log to archive name
  mv "$log_file" "$archive"
  log INFO "Archived: $log_file → $archive"

  # Step 2: Create fresh empty log with same permissions
  touch "$log_file"
  chmod 640 "$log_file"
  log INFO "Fresh log file created: $log_file"

  # Step 3: Compress the archive
  gzip "$archive"
  log INFO "Compressed: ${archive}.gz"

  # Step 4: Signal app to reopen log file handle (SIGHUP)
  # Without this, the app still writes to the moved file
  local app_pid
  if app_pid=$(pgrep -f "$APP_NAME" | head -1); then
    kill -HUP "$app_pid"
    log INFO "Sent SIGHUP to $APP_NAME (PID $app_pid) — log handle reopened"
  else
    log WARN "Could not find $APP_NAME PID — log handle not refreshed"
    log WARN "App may still write to rotated file until restart"
  fi

  log INFO "Log rotation complete ✓"
}

purge_old_logs() {
  local log_dir
  log_dir=$(dirname "$LOG_FILE")
  local keep_days=${1:-$KEEP_DAYS}

  log INFO "Purging logs older than $keep_days days in: $log_dir"

  local count
  count=$(find "$log_dir" -name "*.gz" -mtime "+$keep_days" | wc -l)

  if [[ $count -eq 0 ]]; then
    log INFO "No old logs to purge"
    return 0
  fi

  find "$log_dir" -name "*.gz" -mtime "+$keep_days" -delete
  log INFO "Purged $count old log archive(s) ✓"
}

rotate_log "$LOG_FILE"
purge_old_logs
```

**Output — rotation triggered:**

```
[INFO ] Log file: /var/log/myapp/app.log | Size: 147MB | Threshold: 100MB
[INFO ] Rotating log — size 147MB exceeds 100MB threshold
[INFO ] Archived: /var/log/myapp/app.log → /var/log/myapp/app.log.20240612-091532
[INFO ] Fresh log file created: /var/log/myapp/app.log
[INFO ] Compressed: /var/log/myapp/app.log.20240612-091532.gz
[INFO ] Sent SIGHUP to myapp (PID 4521) — log handle reopened
[INFO ] Log rotation complete ✓
[INFO ] Purged 2 old log archive(s) ✓
```

> ✅ This is exactly what logrotate does internally — understanding it manually makes the config make sense.

---

### Step 5 — Logrotate Configuration

Production standard — let the OS tool handle rotation automatically:

```bash
# /etc/logrotate.d/myapp
/var/log/myapp/*.log {
    daily                     # rotate every day
    rotate 14                 # keep 14 days of archives
    compress                  # gzip old logs
    delaycompress             # compress yesterday's log, not today's
    missingok                 # don't error if log file is missing
    notifempty                # skip rotation if log file is empty
    create 0640 www-data adm  # create new log with these permissions
    dateext                   # use date in archive filename (app.log-20240612)
    dateformat -%Y%m%d        # format for date extension

    # After rotation, signal the app to reopen its log file handle
    postrotate
        /usr/bin/systemctl kill --signal=HUP myapp 2>/dev/null || true
    endscript
}
```

```bash
# /etc/logrotate.d/nginx  (standard nginx config for reference)
/var/log/nginx/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        nginx -s reopen
    endscript
}
```

**Test logrotate config without actually rotating:**

```bash
# Dry run — shows what would happen
logrotate -d /etc/logrotate.d/myapp

# Force rotation now (ignore date threshold)
logrotate -f /etc/logrotate.d/myapp

# Verbose output
logrotate -v /etc/logrotate.d/myapp
```

**Manual vs logrotate — when to use each:**

| Scenario | Use |
|---|---|
| Standard daily log files | logrotate |
| Rotation based on file size (not time) | Manual script + cron |
| Custom pre/post logic beyond SIGHUP | Manual script |
| Quick one-off emergency rotation | Manual script |
| Team server, standard setup | logrotate |

> ✅ logrotate handles scheduling, compression, and retention automatically.  
> Your manual script is the fallback and the learning tool.

---

### Step 6 — Final Production-Ready Version

Complete log management script — parse, alert, rotate, purge:

```bash
#!/bin/bash
# log-manager.sh — Log parsing, anomaly detection, and rotation
# Usage: ./log-manager.sh [parse|rotate|monitor|all]

set -euo pipefail

# ─── Config ───────────────────────────────────────────
APP_NAME="myapp"
APP_LOG="/var/log/$APP_NAME/app.log"
NGINX_LOG="/var/log/nginx/access.log"
LOG_DIR="/var/log/$APP_NAME"
REPORT_LOG="$LOG_DIR/log-manager.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

MAX_LOG_SIZE_MB=100
KEEP_DAYS=14
ERROR_RATE_THRESHOLD=5
ERROR_COUNT_THRESHOLD=10
MONITOR_WINDOW_MIN=5

mkdir -p "$LOG_DIR"

# ─── Logging (Concept 1) ──────────────────────────────
get_level_weight() {
  case $1 in
    DEBUG) echo 0 ;; INFO) echo 1 ;;
    WARN)  echo 2 ;; ERROR) echo 3 ;; *) echo 1 ;;
  esac
}
log() {
  local level=$1; shift
  local message=$*
  local msg_weight current_weight
  msg_weight=$(get_level_weight "$level")
  current_weight=$(get_level_weight "$LOG_LEVEL")
  [[ $msg_weight -ge $current_weight ]] || return 0
  local entry
  entry="$(date '+%Y-%m-%dT%H:%M:%S') [$APP_NAME] [$(printf '%-5s' "$level")] $message"
  if [[ "$level" == "ERROR" ]]; then
    echo "$entry" | tee -a "$REPORT_LOG" >&2
  else
    echo "$entry" | tee -a "$REPORT_LOG"
  fi
}

notify_alert() {
  local severity=$1
  local message=$2
  log WARN "ALERT [$severity]: $message"
  [[ -z "$SLACK_WEBHOOK" ]] && return 0
  local icon="⚠️"
  [[ "$severity" == "CRITICAL" ]] && icon="🚨"
  curl -sf -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    -d "{\"text\":\"$icon [$severity] $HOSTNAME | $message\"}" > /dev/null || true
}

# ─── Log Parsing ──────────────────────────────────────
parse_nginx_log() {
  [[ -f "$NGINX_LOG" ]] || { log WARN "Nginx log not found"; return 0; }
  log INFO "════ Nginx Access Log Report ════════════════"

  local total
  total=$(wc -l < "$NGINX_LOG")
  log INFO "Total requests: $total"

  echo ""
  echo "── Top 5 IPs ────────────────────────────────────"
  awk '{print $1}' "$NGINX_LOG" | sort | uniq -c | sort -rn | head -5 \
    | awk '{printf "  %8s  %s\n", $1, $2}'

  echo ""
  echo "── Top 5 Endpoints ──────────────────────────────"
  awk '{print $7}' "$NGINX_LOG" | sort | uniq -c | sort -rn | head -5 \
    | awk '{printf "  %8s  %s\n", $1, $2}'

  echo ""
  echo "── Status Codes ─────────────────────────────────"
  awk '{print $9}' "$NGINX_LOG" | sort | uniq -c | sort -rn \
    | awk '{printf "  HTTP %-3s  →  %s\n", $2, $1}'

  local errors
  errors=$(awk '$9 ~ /^5/' "$NGINX_LOG" | wc -l)
  local rate
  rate=$(awk "BEGIN {printf \"%.2f\", ($errors/$total)*100}")
  echo ""
  echo "── 5xx Summary ──────────────────────────────────"
  echo "  Errors : $errors | Rate: ${rate}%"

  log INFO "════ Nginx Report Complete ══════════════════"
}

parse_app_log() {
  [[ -f "$APP_LOG" ]] || { log WARN "App log not found"; return 0; }
  log INFO "════ App Log Report ══════════════════════════"

  local info warn error
  info=$(grep -c "\[INFO \]"  "$APP_LOG" || echo 0)
  warn=$(grep -c "\[WARN \]"  "$APP_LOG" || echo 0)
  error=$(grep -c "\[ERROR\]" "$APP_LOG" || echo 0)

  echo ""
  echo "── Log Level Summary ────────────────────────────"
  echo "  INFO  : $info"
  echo "  WARN  : $warn"
  echo "  ERROR : $error"

  if [[ $error -gt 0 ]]; then
    echo ""
    echo "── Top 5 Error Messages ─────────────────────────"
    grep "\[ERROR\]" "$APP_LOG" \
      | sed 's/.*\[ERROR\] //' \
      | sort | uniq -c | sort -rn | head -5 \
      | awk '{count=$1; $1=""; printf "  %5s times  %s\n", count, substr($0,2)}'
  fi

  log INFO "════ App Log Report Complete ════════════════"
}

# ─── Anomaly Detection ────────────────────────────────
run_anomaly_checks() {
  log INFO "════ Anomaly Detection ══════════════════════"

  # 5xx error rate
  if [[ -f "$NGINX_LOG" ]]; then
    local total errors rate
    total=$(wc -l < "$NGINX_LOG")
    errors=$(awk '$9 ~ /^5/' "$NGINX_LOG" | wc -l)
    rate=$(awk "BEGIN {printf \"%.1f\", ($errors/$total)*100}" 2>/dev/null || echo "0")
    log INFO "5xx error rate: ${rate}%"
    if (( $(echo "$rate > $ERROR_RATE_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
      notify_alert "CRITICAL" "5xx error rate ${rate}% exceeds threshold ${ERROR_RATE_THRESHOLD}%"
    fi
  fi

  # App error count (last N minutes)
  if [[ -f "$APP_LOG" ]]; then
    local since_ts error_count
    since_ts=$(date -d "${MONITOR_WINDOW_MIN} minutes ago" '+%Y-%m-%dT%H:%M' 2>/dev/null \
      || date -v "-${MONITOR_WINDOW_MIN}M" '+%Y-%m-%dT%H:%M')
    error_count=$(awk -v ts="$since_ts" '$1 >= ts && /\[ERROR\]/' "$APP_LOG" | wc -l)
    log INFO "App errors in last ${MONITOR_WINDOW_MIN}min: $error_count"
    if [[ $error_count -gt $ERROR_COUNT_THRESHOLD ]]; then
      notify_alert "WARNING" "$error_count app errors in last ${MONITOR_WINDOW_MIN} minutes"
    fi
  fi

  log INFO "════ Anomaly Detection Complete ════════════"
}

# ─── Log Rotation ─────────────────────────────────────
rotate_logs() {
  log INFO "════ Log Rotation ═══════════════════════════"

  local logs_to_rotate=("$APP_LOG")
  [[ -f "$NGINX_LOG" ]] && logs_to_rotate+=("$NGINX_LOG")

  for log_file in "${logs_to_rotate[@]}"; do
    [[ -f "$log_file" ]] || continue

    local size_mb
    size_mb=$(du -m "$log_file" | cut -f1)
    log INFO "Checking: $log_file (${size_mb}MB)"

    if [[ $size_mb -ge $MAX_LOG_SIZE_MB ]]; then
      local archive="${log_file}.$(date '+%Y%m%d-%H%M%S')"
      mv "$log_file" "$archive"
      touch "$log_file"
      chmod 640 "$log_file"
      gzip "$archive"
      log INFO "Rotated and compressed: $(basename "$archive").gz"

      # Signal app to reopen log handle
      if pgrep -f "$APP_NAME" &>/dev/null; then
        pkill -HUP -f "$APP_NAME" || true
        log INFO "SIGHUP sent to $APP_NAME"
      fi
    else
      log INFO "No rotation needed (${size_mb}MB < ${MAX_LOG_SIZE_MB}MB)"
    fi
  done

  # Purge old archives
  local purged
  purged=$(find "$LOG_DIR" -name "*.gz" -mtime "+$KEEP_DAYS" | wc -l)
  if [[ $purged -gt 0 ]]; then
    find "$LOG_DIR" -name "*.gz" -mtime "+$KEEP_DAYS" -delete
    log INFO "Purged $purged archive(s) older than $KEEP_DAYS days"
  fi

  log INFO "════ Rotation Complete ══════════════════════"
}

# ─── Entrypoint ───────────────────────────────────────
MODE="${1:-all}"

case $MODE in
  parse)   parse_nginx_log; parse_app_log ;;
  rotate)  rotate_logs ;;
  monitor) run_anomaly_checks ;;
  all)
    parse_nginx_log
    parse_app_log
    run_anomaly_checks
    rotate_logs
    ;;
  *)
    echo "Usage: $0 [parse|rotate|monitor|all]"
    exit 1
    ;;
esac
```

**Usage:**

```bash
# Run everything
./log-manager.sh all

# Just parse and report
./log-manager.sh parse

# Just rotate logs
./log-manager.sh rotate

# Just run anomaly checks (cron every 5 min)
./log-manager.sh monitor
```

**Cron schedule:**

```bash
# /etc/cron.d/myapp-log-manager

# Anomaly check every 5 minutes
*/5 * * * * deploy /opt/scripts/log-manager.sh monitor >> /var/log/myapp/monitor.log 2>&1

# Full report + rotation daily at midnight
0 0 * * *   deploy /opt/scripts/log-manager.sh all    >> /var/log/myapp/monitor.log 2>&1
```

---

## Mini Exercise for Participants

> **Task:** Write a `log-report.sh` script that:
>
> - Accepts `-n <minutes>` flag (default 60) for time window
> - Parses `/var/log/myapp/app.log` and prints count of each log level
> - Lists the top 3 most frequent ERROR messages in that window
> - Prints total log file size and alerts if > 50MB
> - Rotates the log if it exceeds 50MB

**Expected solution:**

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_LOG="/var/log/myapp/app.log"
WINDOW=60

while getopts "n:" opt; do
  case $opt in n) WINDOW=$OPTARG ;; *) exit 1 ;; esac
done

[[ -f "$APP_LOG" ]] || { log ERROR "Log not found: $APP_LOG"; exit 1; }

since_ts=$(date -d "${WINDOW} minutes ago" '+%Y-%m-%dT%H:%M' 2>/dev/null \
  || date -v "-${WINDOW}M" '+%Y-%m-%dT%H:%M')

echo "── Log Level Counts (last ${WINDOW} min) ──────────"
for level in "INFO " "WARN " "ERROR"; do
  count=$(awk -v ts="$since_ts" -v lvl="$level" \
    '$1 >= ts && $0 ~ lvl' "$APP_LOG" | wc -l)
  printf "  %-6s: %s\n" "$level" "$count"
done

echo ""
echo "── Top 3 Error Messages ──────────────────────────"
awk -v ts="$since_ts" '$1 >= ts && /\[ERROR\]/' "$APP_LOG" \
  | sed 's/.*\[ERROR\] //' \
  | sort | uniq -c | sort -rn | head -3 \
  | awk '{count=$1; $1=""; printf "  %4s times  %s\n", count, substr($0,2)}'

size_mb=$(du -m "$APP_LOG" | cut -f1)
echo ""
log INFO "Log file size: ${size_mb}MB"

if [[ $size_mb -gt 50 ]]; then
  log WARN "Log exceeds 50MB — rotating..."
  archive="${APP_LOG}.$(date '+%Y%m%d-%H%M%S')"
  mv "$APP_LOG" "$archive"
  touch "$APP_LOG"
  gzip "$archive"
  log INFO "Rotated → $(basename "$archive").gz"
fi
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| `awk '{print $N}'` | Extract any field from structured log lines |
| `sort \| uniq -c \| sort -rn` | The universal frequency analysis pipeline |
| `grep -c` | Count matching lines — faster than `grep \| wc -l` |
| `sed 's/.*\[ERROR\] //'` | Strip prefix to extract just the message |
| `mv` then `touch` then `gzip` | The three-step manual rotation pattern |
| `kill -HUP <pid>` | Signal app to reopen log file after rotation |
| `logrotate -d` | Dry run — always test your config before relying on it |
| `delaycompress` | Compress yesterday's log not today's — keeps today readable |
| `find -mtime +N -delete` | Purge old archives — never let this step be missing |

---

## Log Management Cheat Sheet

```bash
# Check log file sizes
du -sh /var/log/myapp/*.log

# Real-time error monitoring
tail -f /var/log/myapp/app.log | grep "\[ERROR\]"

# Count errors in last 100 lines
tail -100 /var/log/myapp/app.log | grep -c "\[ERROR\]"

# Top IPs from nginx log
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10

# All 5xx errors with timestamps
awk '$9 ~ /^5/' /var/log/nginx/access.log | awk '{print $4, $9, $7}'

# Force logrotate for one app
logrotate -f /etc/logrotate.d/myapp

# Check disk usage by directory
du -sh /var/log/* | sort -rh | head -10

# Watch disk fill rate in real time
watch -n5 "df -h / && echo '' && du -sh /var/log/myapp/*.log"
```

---

## Project Structure So Far

```
myapp/
├── deploy.sh              # deployment pipeline — concepts 1–7
├── log-manager.sh         # log parsing, monitoring, rotation — concept 8
├── log.sh                 # reusable log() function
└── config/
    ├── dev.env
    ├── staging.env
    └── prod.env
```

---

## What's Next

**Concept 9 — Slack Notification & Reporting**  
We will build a dedicated notification and reporting system — structured  
Slack alerts with context, daily summary reports sent on a schedule,  
and a unified `notify()` layer used by both `deploy.sh` and `log-manager.sh`.