# Concept 9 — Slack Notification & Reporting

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~20 minutes  
> **Prerequisite:** Concepts 1–8 must be complete

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Is a Notification & Reporting System?](#what-is-a-notification--reporting-system)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Basic Slack Webhook](#step-1--basic-slack-webhook)
  - [Step 2 — Structured Alert Messages](#step-2--structured-alert-messages)
  - [Step 3 — Severity-Based Routing](#step-3--severity-based-routing)
  - [Step 4 — Daily Summary Report](#step-4--daily-summary-report)
  - [Step 5 — Unified Notify Layer](#step-5--unified-notify-layer)
  - [Step 6 — Final Production-Ready Version](#step-6--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners do

```bash
# Option 1 — No notifications at all
./deploy.sh   # runs silently, nobody knows if it passed or failed

# Option 2 — Email (nobody reads ops emails)
mail -s "Deploy done" team@company.com <<< "deployed"

# Option 3 — Hardcoded one-liners scattered everywhere
curl -X POST "$WEBHOOK" -d '{"text":"deployed"}'   # in deploy.sh
curl -X POST "$WEBHOOK" -d '{"text":"error"}'       # in monitor.sh
curl -X POST "$WEBHOOK" -d '{"text":"rotated"}'     # in log-manager.sh
```

**The problems with this:**

- ❌ Silent scripts — on-call engineers find out about failures from users
- ❌ No context in alerts — *"error"* tells you nothing at 2AM
- ❌ Webhook URL hardcoded in 6 different scripts — rotate it once, fix it 6 times
- ❌ No severity — every message looks the same, critical buried in noise
- ❌ No daily summary — leadership has no visibility into deployment health

### Real-world incident scenario

> A deployment failed at 11PM on a Friday.  
> The script exited with code 1 and wrote to a log file.  
> Nobody was watching the log file.  
> The on-call engineer was paged by the monitoring system at 11:47PM  
> because users started reporting errors — 47 minutes after the failure.  
> If the deploy script had posted a single Slack alert on failure,  
> the on-call would have caught it in under 2 minutes.  
>
> **A `notify()` function wired into every script costs 10 lines.  
> It saves 45 minutes of incident response time.**

---

## What Is a Notification & Reporting System?

A production notification system has three responsibilities:

1. **Real-time alerts** — immediate Slack messages on critical events  
   (deploy started, deploy failed, rollback triggered, anomaly detected)

2. **Severity routing** — INFO goes to `#deployments`, CRITICAL goes to `#incidents`

3. **Scheduled reports** — daily digest posted to `#ops-reports` summarising  
   deploy count, error rates, log sizes, uptime

The goal is **zero-surprise operations** — your team knows what happened  
before anyone has to ask.

---

## Build It Step by Step

### Step 1 — Basic Slack Webhook

First, understand the Slack webhook API:

```bash
#!/bin/bash
set -euo pipefail

# Get your webhook from:
# Slack → Apps → Incoming Webhooks → Add New Webhook

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

send_slack() {
  local message=$1

  # Webhook not configured — skip silently
  if [[ -z "$SLACK_WEBHOOK" ]]; then
    echo "[NOTIFY] Slack not configured — message: $message"
    return 0
  fi

  # Basic payload — just text
  local payload
  payload=$(printf '{"text": "%s"}' "$message")

  local http_code
  http_code=$(curl -sf \
    --max-time 10 \
    -X POST "$SLACK_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    --write-out "%{http_code}" \
    --output /dev/null 2>/dev/null || echo "000")

  if [[ "$http_code" != "200" ]]; then
    echo "[NOTIFY] Slack delivery failed — HTTP $http_code"
    return 1
  fi

  echo "[NOTIFY] Slack message delivered ✓"
}

# Test it
send_slack "Hello from deploy.sh — this is a test message"
```

**Set the webhook securely:**

```bash
# Never hardcode — inject via environment
export SLACK_WEBHOOK="https://hooks.slack.com/services/T00/B00/XXXX"
./deploy.sh -e prod -v 1.4.2

# Or store in a secrets file sourced at startup
source /etc/myapp/secrets.env
```

> ✅ Webhook in environment variable — never in the script, never in Git.

---

### Step 2 — Structured Alert Messages

Plain text is hard to scan at 2AM. Use Slack Block Kit for rich formatting:

```bash
#!/bin/bash
set -euo pipefail

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
APP_NAME="myapp"
HOSTNAME=$(hostname)

send_slack_blocks() {
  local title=$1
  local message=$2
  local color=$3      # good (green) | warning (yellow) | danger (red)
  local icon=$4       # emoji

  [[ -z "$SLACK_WEBHOOK" ]] && return 0

  # Slack attachment payload — color-coded sidebar
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "$color",
      "blocks": [
        {
          "type": "header",
          "text": {
            "type": "plain_text",
            "text": "$icon $title"
          }
        },
        {
          "type": "section",
          "fields": [
            {
              "type": "mrkdwn",
              "text": "*App:*\n$APP_NAME"
            },
            {
              "type": "mrkdwn",
              "text": "*Host:*\n$HOSTNAME"
            },
            {
              "type": "mrkdwn",
              "text": "*Time:*\n$(date '+%Y-%m-%d %H:%M:%S %Z')"
            },
            {
              "type": "mrkdwn",
              "text": "*Message:*\n$message"
            }
          ]
        }
      ]
    }
  ]
}
EOF
)

  curl -sf \
    --max-time 10 \
    -X POST "$SLACK_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "$payload" > /dev/null || true
}

# Usage
send_slack_blocks \
  "Deployment Started" \
  "v1.4.2 deploying to prod" \
  "warning" \
  "🚀"

send_slack_blocks \
  "Deployment Successful" \
  "v1.4.2 is live on prod" \
  "good" \
  "✅"

send_slack_blocks \
  "Deployment Failed" \
  "v1.4.2 failed health check — rolling back" \
  "danger" \
  "❌"
```

**What this looks like in Slack:**

```
🚀 Deployment Started
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
App:      myapp
Host:     prod-server-01
Time:     2024-06-12 09:15:32 IST
Message:  v1.4.2 deploying to prod
```

> ✅ Instantly scannable at 3AM — color, icon, context, timestamp all visible.

---

### Step 3 — Severity-Based Routing

Different severity levels go to different Slack channels:

```bash
#!/bin/bash
set -euo pipefail

# Channel-specific webhooks
# Each channel in Slack needs its own incoming webhook URL
WEBHOOK_DEPLOYMENTS="${SLACK_WEBHOOK_DEPLOYMENTS:-}"   # #deployments
WEBHOOK_INCIDENTS="${SLACK_WEBHOOK_INCIDENTS:-}"       # #incidents (paged)
WEBHOOK_REPORTS="${SLACK_WEBHOOK_REPORTS:-}"           # #ops-reports

notify() {
  local severity=$1    # INFO | WARN | CRITICAL
  local title=$2
  local message=$3

  local webhook color icon

  case $severity in
    INFO)
      webhook="$WEBHOOK_DEPLOYMENTS"
      color="good"
      icon="✅"
      ;;
    WARN)
      webhook="$WEBHOOK_DEPLOYMENTS"
      color="warning"
      icon="⚠️"
      ;;
    CRITICAL)
      # CRITICAL goes to both channels — deployment channel + incident channel
      webhook="$WEBHOOK_INCIDENTS"
      color="danger"
      icon="🚨"
      # Also post to deployments for full history
      [[ -n "$WEBHOOK_DEPLOYMENTS" ]] && \
        _post_to_slack "$WEBHOOK_DEPLOYMENTS" "$title" "$message" "danger" "🚨"
      ;;
    REPORT)
      webhook="$WEBHOOK_REPORTS"
      color="#4A90E2"   # blue for reports
      icon="📊"
      ;;
    *)
      webhook="$WEBHOOK_DEPLOYMENTS"
      color="good"
      icon="ℹ️"
      ;;
  esac

  [[ -z "$webhook" ]] && {
    echo "[NOTIFY][$severity] $title — $message"
    return 0
  }

  _post_to_slack "$webhook" "$title" "$message" "$color" "$icon"
}

_post_to_slack() {
  local webhook=$1 title=$2 message=$3 color=$4 icon=$5

  local payload
  payload=$(cat <<EOF
{
  "attachments": [{
    "color": "$color",
    "blocks": [
      {
        "type": "header",
        "text": {"type": "plain_text", "text": "$icon $title"}
      },
      {
        "type": "section",
        "fields": [
          {"type": "mrkdwn", "text": "*App:*\n${APP_NAME:-myapp}"},
          {"type": "mrkdwn", "text": "*Host:*\n$(hostname)"},
          {"type": "mrkdwn", "text": "*Time:*\n$(date '+%Y-%m-%d %H:%M:%S')"},
          {"type": "mrkdwn", "text": "*Details:*\n$message"}
        ]
      }
    ]
  }]
}
EOF
)

  curl -sf --max-time 10 \
    -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "$payload" > /dev/null || \
    echo "[NOTIFY] Failed to deliver to Slack — $title"
}

# Usage across all scripts
notify INFO     "Deployment Started"    "v1.4.2 → prod"
notify WARN     "Rollback Initiated"    "v1.4.2 failed health check"
notify CRITICAL "Service Down"          "myapp not responding after rollback"
notify REPORT   "Daily Digest"          "3 deploys | 0 failures | 0 alerts"
```

> ✅ INFO and WARN go to `#deployments`. CRITICAL wakes up `#incidents`.  
> Nobody misses a critical alert buried in a noisy channel.

---

### Step 4 — Daily Summary Report

Post a daily digest every morning at 8AM:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_NAME="myapp"
APP_LOG="/var/log/$APP_NAME/app.log"
NGINX_LOG="/var/log/nginx/access.log"
DEPLOY_LOG="/var/log/$APP_NAME/deploy.log"
WEBHOOK_REPORTS="${SLACK_WEBHOOK_REPORTS:-}"
RELEASE_DIR="/opt/$APP_NAME/releases"

generate_daily_report() {
  log INFO "Generating daily summary report..."

  local report_date
  report_date=$(date '+%Y-%m-%d')

  # ── Deploy Stats ──────────────────────────────────
  local deploy_count rollback_count
  deploy_count=$(grep -c "Deployment completed successfully" "$DEPLOY_LOG" 2>/dev/null || echo 0)
  rollback_count=$(grep -c "Rollback Complete" "$DEPLOY_LOG" 2>/dev/null || echo 0)

  local current_version=""
  if [[ -L "/opt/$APP_NAME/current" ]]; then
    current_version=$(basename "$(readlink "/opt/$APP_NAME/current")")
  fi

  # ── Error Stats ───────────────────────────────────
  local app_errors nginx_5xx
  app_errors=$(grep -c "\[ERROR\]" "$APP_LOG"   2>/dev/null || echo 0)
  nginx_5xx=$(awk '$9 ~ /^5/' "$NGINX_LOG" 2>/dev/null | wc -l || echo 0)

  # ── Traffic Stats ─────────────────────────────────
  local total_requests
  total_requests=$(wc -l < "$NGINX_LOG" 2>/dev/null || echo 0)

  # ── Disk Stats ────────────────────────────────────
  local disk_usage log_size
  disk_usage=$(df /opt/$APP_NAME 2>/dev/null | awk 'NR==2{print $5}' || echo "N/A")
  log_size=$(du -sh "$APP_LOG" 2>/dev/null | cut -f1 || echo "N/A")

  # ── Release Count ─────────────────────────────────
  local release_count
  release_count=$(ls -d "$RELEASE_DIR"/*/ 2>/dev/null | wc -l || echo 0)

  # ── Uptime ────────────────────────────────────────
  local uptime_str
  uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')

  log INFO "Report data collected — posting to Slack..."

  [[ -z "$WEBHOOK_REPORTS" ]] && {
    log WARN "SLACK_WEBHOOK_REPORTS not set — printing report to stdout"
    cat <<EOF

════ Daily Ops Report: $report_date ═══
  App             : $APP_NAME
  Current version : ${current_version:-unknown}
  Uptime          : $uptime_str
  Deploys today   : $deploy_count
  Rollbacks today : $rollback_count
  App errors      : $app_errors
  Nginx 5xx       : $nginx_5xx
  Total requests  : $total_requests
  Disk usage      : $disk_usage
  Log file size   : $log_size
  Releases kept   : $release_count
════════════════════════════════════════

EOF
    return 0
  }

  # Determine report health color
  local report_color="good"
  [[ $rollback_count -gt 0 ]] && report_color="warning"
  [[ $app_errors -gt 50   ]] && report_color="danger"

  local payload
  payload=$(cat <<EOF
{
  "attachments": [{
    "color": "$report_color",
    "blocks": [
      {
        "type": "header",
        "text": {"type": "plain_text", "text": "📊 Daily Ops Report — $report_date"}
      },
      {
        "type": "section",
        "fields": [
          {"type": "mrkdwn", "text": "*App:*\n$APP_NAME"},
          {"type": "mrkdwn", "text": "*Current Version:*\n${current_version:-unknown}"},
          {"type": "mrkdwn", "text": "*Uptime:*\n$uptime_str"},
          {"type": "mrkdwn", "text": "*Disk Usage:*\n$disk_usage"}
        ]
      },
      {
        "type": "divider"
      },
      {
        "type": "section",
        "fields": [
          {"type": "mrkdwn", "text": "*Deploys:*\n$deploy_count"},
          {"type": "mrkdwn", "text": "*Rollbacks:*\n$rollback_count"},
          {"type": "mrkdwn", "text": "*App Errors:*\n$app_errors"},
          {"type": "mrkdwn", "text": "*Nginx 5xx:*\n$nginx_5xx"},
          {"type": "mrkdwn", "text": "*Total Requests:*\n$total_requests"},
          {"type": "mrkdwn", "text": "*Log Size:*\n$log_size"}
        ]
      }
    ]
  }]
}
EOF
)

  curl -sf --max-time 10 \
    -X POST "$WEBHOOK_REPORTS" \
    -H 'Content-Type: application/json' \
    -d "$payload" > /dev/null

  log INFO "Daily report posted to Slack ✓"
}

generate_daily_report
```

**Schedule via cron:**

```bash
# Post daily report at 8AM every day
0 8 * * * deploy /opt/scripts/notify.sh report >> /var/log/myapp/notify.log 2>&1
```

**What it looks like in Slack:**

```
📊 Daily Ops Report — 2024-06-12
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
App:              myapp
Current Version:  1.4.2
Uptime:           up 14 days, 3 hours
Disk Usage:       62%

Deploys:          3        Rollbacks:  0
App Errors:       7        Nginx 5xx:  23
Total Requests:   48,291   Log Size:   43MB
```

> ✅ Leadership and engineers both see the daily health at a glance — no dashboards needed.

---

### Step 5 — Unified Notify Layer

Extract `notify()` into `notify.sh` so every script in the project imports it:

```bash
#!/bin/bash
# notify.sh — Unified notification layer
# Source this in any script: source ./notify.sh

# ─── Webhook Config ───────────────────────────────────
# All webhooks injected via environment — never hardcoded
WEBHOOK_DEPLOYMENTS="${SLACK_WEBHOOK_DEPLOYMENTS:-${SLACK_WEBHOOK:-}}"
WEBHOOK_INCIDENTS="${SLACK_WEBHOOK_INCIDENTS:-${SLACK_WEBHOOK:-}}"
WEBHOOK_REPORTS="${SLACK_WEBHOOK_REPORTS:-${SLACK_WEBHOOK:-}}"

APP_NAME="${APP_NAME:-myapp}"

# ─── Internal post function ───────────────────────────
_slack_post() {
  local webhook=$1 title=$2 body=$3 color=$4 icon=$5

  [[ -z "$webhook" ]] && {
    # Fallback to stdout when webhook not configured
    printf '[NOTIFY] %s %s: %s\n' "$icon" "$title" "$body"
    return 0
  }

  local payload
  payload=$(printf '{
    "attachments": [{
      "color": "%s",
      "blocks": [
        {
          "type": "header",
          "text": {"type": "plain_text", "text": "%s %s"}
        },
        {
          "type": "section",
          "fields": [
            {"type": "mrkdwn", "text": "*App:*\\n%s"},
            {"type": "mrkdwn", "text": "*Host:*\\n%s"},
            {"type": "mrkdwn", "text": "*Time:*\\n%s"},
            {"type": "mrkdwn", "text": "*Details:*\\n%s"}
          ]
        }
      ]
    }]
  }' \
    "$color" "$icon" "$title" \
    "$APP_NAME" "$(hostname)" \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$body")

  # || true — notification failure never kills the main script
  curl -sf --max-time 10 \
    -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "$payload" > /dev/null 2>&1 || \
    printf '[NOTIFY] Slack delivery failed: %s\n' "$title"
}

# ─── Public notify() function ─────────────────────────
notify() {
  local severity=$1
  local title=$2
  local body=${3:-""}

  case $severity in
    INFO)
      _slack_post "$WEBHOOK_DEPLOYMENTS" "$title" "$body" "good"    "✅"
      ;;
    WARN)
      _slack_post "$WEBHOOK_DEPLOYMENTS" "$title" "$body" "warning" "⚠️"
      ;;
    CRITICAL)
      _slack_post "$WEBHOOK_INCIDENTS"   "$title" "$body" "danger"  "🚨"
      # Also mirror to deployments channel for history
      [[ "$WEBHOOK_INCIDENTS" != "$WEBHOOK_DEPLOYMENTS" ]] && \
        _slack_post "$WEBHOOK_DEPLOYMENTS" "$title" "$body" "danger" "🚨"
      ;;
    REPORT)
      _slack_post "$WEBHOOK_REPORTS" "$title" "$body" "#4A90E2" "📊"
      ;;
    *)
      _slack_post "$WEBHOOK_DEPLOYMENTS" "$title" "$body" "good" "ℹ️"
      ;;
  esac
}

# ─── Convenience wrappers ─────────────────────────────
notify_deploy_start()   { notify INFO     "Deploy Started"    "$1"; }
notify_deploy_success() { notify INFO     "Deploy Successful" "$1"; }
notify_deploy_failure() { notify CRITICAL "Deploy Failed"     "$1"; }
notify_rollback()       { notify WARN     "Rollback Triggered" "$1"; }
notify_alert()          { notify CRITICAL "Alert"             "$1"; }
```

**Usage in any script:**

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh
source ./notify.sh    # ← one line gives you the full notify system

# In deploy.sh
notify_deploy_start   "v1.4.2 → prod"
notify_deploy_success "v1.4.2 is live"
notify_deploy_failure "v1.4.2 health check failed after 12 retries"
notify_rollback       "Restored to v1.4.1"

# In log-manager.sh
notify_alert "5xx error rate 8.3% (threshold: 5%)"

# In any script — raw severity
notify INFO     "Backup completed"   "12 files, 2.3GB → s3://my-backups"
notify CRITICAL "Disk 95% full"      "/opt on prod-server-01"
```

> ✅ One import. Consistent format. Every script sends the same quality alert.

---

### Step 6 — Final Production-Ready Version

Complete `notify.sh` as a standalone script with CLI mode for cron:

```bash
#!/bin/bash
# notify.sh — Unified notification and reporting system
# Source mode: source ./notify.sh
# CLI mode:    ./notify.sh report
#              ./notify.sh send INFO "title" "message"

set -euo pipefail

# ─── Config ───────────────────────────────────────────
APP_NAME="${APP_NAME:-myapp}"
APP_LOG="/var/log/$APP_NAME/app.log"
NGINX_LOG="/var/log/nginx/access.log"
DEPLOY_LOG="/var/log/$APP_NAME/deploy.log"
RELEASE_DIR="/opt/$APP_NAME/releases"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
NOTIFY_LOG="/var/log/$APP_NAME/notify.log"

WEBHOOK_DEPLOYMENTS="${SLACK_WEBHOOK_DEPLOYMENTS:-${SLACK_WEBHOOK:-}}"
WEBHOOK_INCIDENTS="${SLACK_WEBHOOK_INCIDENTS:-${SLACK_WEBHOOK:-}}"
WEBHOOK_REPORTS="${SLACK_WEBHOOK_REPORTS:-${SLACK_WEBHOOK:-}}"

mkdir -p "$(dirname "$NOTIFY_LOG")"

# ─── Logging (Concept 1) ──────────────────────────────
get_level_weight() {
  case $1 in DEBUG) echo 0 ;; INFO) echo 1 ;; WARN) echo 2 ;; ERROR) echo 3 ;; *) echo 1 ;; esac
}
log() {
  local level=$1; shift
  local msg_weight current_weight
  msg_weight=$(get_level_weight "$level")
  current_weight=$(get_level_weight "$LOG_LEVEL")
  [[ $msg_weight -ge $current_weight ]] || return 0
  printf '%s [%s] [%-5s] %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$APP_NAME" "$level" "$*" \
    | tee -a "$NOTIFY_LOG"
}

# ─── Core post function ───────────────────────────────
_slack_post() {
  local webhook=$1 title=$2 body=$3 color=$4 icon=$5

  if [[ -z "$webhook" ]]; then
    log INFO "[NOTIFY] $icon $title — $body"
    return 0
  fi

  local payload
  payload=$(printf '{
    "attachments": [{
      "color": "%s",
      "blocks": [
        {"type":"header","text":{"type":"plain_text","text":"%s %s"}},
        {"type":"section","fields":[
          {"type":"mrkdwn","text":"*App:*\\n%s"},
          {"type":"mrkdwn","text":"*Host:*\\n%s"},
          {"type":"mrkdwn","text":"*Time:*\\n%s"},
          {"type":"mrkdwn","text":"*Details:*\\n%s"}
        ]}
      ]
    }]
  }' "$color" "$icon" "$title" \
     "$APP_NAME" "$(hostname)" \
     "$(date '+%Y-%m-%d %H:%M:%S')" \
     "$body")

  curl -sf --max-time 10 \
    -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "$payload" > /dev/null 2>&1 && \
    log DEBUG "Delivered: $title" || \
    log WARN  "Failed to deliver: $title"
}

# ─── Public notify() ──────────────────────────────────
notify() {
  local severity=$1 title=$2 body=${3:-""}
  case $severity in
    INFO)     _slack_post "$WEBHOOK_DEPLOYMENTS" "$title" "$body" "good"    "✅" ;;
    WARN)     _slack_post "$WEBHOOK_DEPLOYMENTS" "$title" "$body" "warning" "⚠️" ;;
    CRITICAL)
      _slack_post "$WEBHOOK_INCIDENTS"   "$title" "$body" "danger" "🚨"
      [[ "$WEBHOOK_INCIDENTS" != "$WEBHOOK_DEPLOYMENTS" ]] && \
        _slack_post "$WEBHOOK_DEPLOYMENTS" "$title" "$body" "danger" "🚨"
      ;;
    REPORT)   _slack_post "$WEBHOOK_REPORTS" "$title" "$body" "#4A90E2" "📊" ;;
    *)        _slack_post "$WEBHOOK_DEPLOYMENTS" "$title" "$body" "good"  "ℹ️" ;;
  esac
}

# ─── Convenience wrappers ─────────────────────────────
notify_deploy_start()   { notify INFO     "Deploy Started"     "$1"; }
notify_deploy_success() { notify INFO     "Deploy Successful"  "$1"; }
notify_deploy_failure() { notify CRITICAL "Deploy Failed"      "$1"; }
notify_rollback()       { notify WARN     "Rollback Triggered" "$1"; }
notify_alert()          { notify CRITICAL "Alert"              "$1"; }

# ─── Daily Report ─────────────────────────────────────
generate_daily_report() {
  log INFO "Generating daily report..."
  local date
  date=$(date '+%Y-%m-%d')

  local deploys rollbacks errors nginx_5xx requests disk version uptime_str
  deploys=$(grep -c "Deployment completed"   "$DEPLOY_LOG" 2>/dev/null || echo 0)
  rollbacks=$(grep -c "Rollback Complete"    "$DEPLOY_LOG" 2>/dev/null || echo 0)
  errors=$(grep -c "\[ERROR\]"               "$APP_LOG"    2>/dev/null || echo 0)
  nginx_5xx=$(awk '$9 ~ /^5/' "$NGINX_LOG"  2>/dev/null | wc -l || echo 0)
  requests=$(wc -l < "$NGINX_LOG"           2>/dev/null || echo 0)
  disk=$(df /opt 2>/dev/null | awk 'NR==2{print $5}' || echo "N/A")
  version=$([[ -L "/opt/$APP_NAME/current" ]] \
    && basename "$(readlink "/opt/$APP_NAME/current")" || echo "unknown")
  uptime_str=$(uptime -p 2>/dev/null \
    || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')

  local color="good"
  [[ $rollbacks -gt 0 ]] && color="warning"
  [[ $errors -gt 50   ]] && color="danger"

  local payload
  payload=$(cat <<EOF
{
  "attachments": [{
    "color": "$color",
    "blocks": [
      {"type":"header","text":{"type":"plain_text","text":"📊 Daily Ops Report — $date"}},
      {"type":"section","fields":[
        {"type":"mrkdwn","text":"*App:*\n$APP_NAME"},
        {"type":"mrkdwn","text":"*Version:*\n$version"},
        {"type":"mrkdwn","text":"*Uptime:*\n$uptime_str"},
        {"type":"mrkdwn","text":"*Disk:*\n$disk"}
      ]},
      {"type":"divider"},
      {"type":"section","fields":[
        {"type":"mrkdwn","text":"*Deploys:*\n$deploys"},
        {"type":"mrkdwn","text":"*Rollbacks:*\n$rollbacks"},
        {"type":"mrkdwn","text":"*App Errors:*\n$errors"},
        {"type":"mrkdwn","text":"*Nginx 5xx:*\n$nginx_5xx"},
        {"type":"mrkdwn","text":"*Requests:*\n$requests"},
        {"type":"mrkdwn","text":"*Log Disk:*\n$disk"}
      ]}
    ]
  }]
}
EOF
)

  local webhook="${WEBHOOK_REPORTS:-$WEBHOOK_DEPLOYMENTS}"
  [[ -z "$webhook" ]] && { log WARN "No webhook for report"; return 0; }

  curl -sf --max-time 10 \
    -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "$payload" > /dev/null && \
    log INFO "Daily report posted ✓" || \
    log WARN "Failed to post daily report"
}

# ─── CLI Mode ─────────────────────────────────────────
# Only runs when script is executed directly, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  MODE="${1:-help}"
  case $MODE in
    send)
      # ./notify.sh send CRITICAL "title" "message"
      notify "${2:-INFO}" "${3:-Notification}" "${4:-}"
      ;;
    report)
      generate_daily_report
      ;;
    test)
      log INFO "Sending test notifications to all channels..."
      notify INFO     "Test: Info notification"     "This is an INFO level test"
      notify WARN     "Test: Warn notification"     "This is a WARN level test"
      notify CRITICAL "Test: Critical notification" "This is a CRITICAL level test"
      notify REPORT   "Test: Report notification"   "This is a REPORT level test"
      log INFO "Test notifications sent ✓"
      ;;
    help|*)
      echo ""
      echo "  Usage (CLI):    ./notify.sh <command>"
      echo "  Usage (source): source ./notify.sh"
      echo ""
      echo "  Commands:"
      echo "    send <SEVERITY> <title> <message>   Send a one-off notification"
      echo "    report                               Post daily ops report"
      echo "    test                                 Send test to all channels"
      echo ""
      echo "  Severity levels: INFO | WARN | CRITICAL | REPORT"
      echo ""
      echo "  Environment variables:"
      echo "    SLACK_WEBHOOK               Single webhook (all messages)"
      echo "    SLACK_WEBHOOK_DEPLOYMENTS   #deployments channel"
      echo "    SLACK_WEBHOOK_INCIDENTS     #incidents channel"
      echo "    SLACK_WEBHOOK_REPORTS       #ops-reports channel"
      echo ""
      ;;
  esac
fi
```

**Test all channels:**

```bash
# Set webhook and test
export SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK"
./notify.sh test

# Send one-off from CLI
./notify.sh send CRITICAL "Disk Full" "prod-server-01 at 97%"

# Post daily report
./notify.sh report

# Source in another script
source ./notify.sh
notify_deploy_start "v1.4.2 → prod"
```

**Cron schedule:**

```bash
# /etc/cron.d/myapp-notify
# Daily ops report at 8AM
0 8 * * * deploy SLACK_WEBHOOK_REPORTS=https://hooks.slack.com/... \
  /opt/scripts/notify.sh report >> /var/log/myapp/notify.log 2>&1
```

---

## Mini Exercise for Participants

> **Task:** Update your `backup.sh` from Concept 8 to use `notify.sh`:
>
> - Source `notify.sh` at the top
> - Send `INFO` when backup starts
> - Send `INFO` when backup completes with size info
> - Send `CRITICAL` if backup fails (use `trap`)
> - Send a `REPORT` at the end with backup file count and total size

**Expected solution:**

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh
source ./notify.sh

BACKUP_DIR="/opt/backups"
DATE=$(date '+%Y%m%d')

on_failure() {
  notify_alert "Backup failed on $(hostname) — check $BACKUP_DIR"
}
trap on_failure ERR

notify INFO "Backup Started" "Daily backup starting on $(hostname)"

log INFO "Running backup..."
mkdir -p "$BACKUP_DIR/$DATE"
# ... backup logic ...
touch "$BACKUP_DIR/$DATE/db.sql.gz"    # placeholder

file_count=$(find "$BACKUP_DIR/$DATE" -type f | wc -l)
total_size=$(du -sh "$BACKUP_DIR/$DATE" | cut -f1)

notify INFO "Backup Completed" "$file_count files | $total_size | $BACKUP_DIR/$DATE"

notify REPORT "Backup Summary" \
  "Date: $DATE | Files: $file_count | Size: $total_size | Host: $(hostname)"
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| Webhook in env var | `${SLACK_WEBHOOK:-}` — never hardcoded, never in Git |
| `\|\| true` on curl | Notification failure must never kill the main script |
| Slack Block Kit | Color + icon + fields = scannable at 3AM, not just text |
| Severity-based routing | INFO to `#deployments`, CRITICAL to `#incidents` |
| Single `notify.sh` | One source of truth — rotate webhook URL in one place |
| CLI + source dual mode | `BASH_SOURCE[0]` check — works both ways |
| `|| true` after curl | Notification failure is never fatal to the main process |
| Daily report color | green/yellow/red driven by rollback count and error count |
| Convenience wrappers | `notify_deploy_start()` reads better than `notify INFO "Deploy Started"` |

---

## Complete Project Structure

```
myapp/
├── deploy.sh              # deployment pipeline — concepts 1–7
├── log-manager.sh         # log parsing, monitoring, rotation — concept 8
├── notify.sh              # notification & reporting — concept 9
├── log.sh                 # reusable log() function — concept 1
└── config/
    ├── dev.env
    ├── staging.env
    └── prod.env
```

## How All Scripts Connect

```
deploy.sh ──────────────────────────────────────────────────────┐
  source log.sh      (Concept 1 — logging)                      │
  source notify.sh   (Concept 9 — notifications)                │
  → notify_deploy_start / notify_deploy_success / notify_rollback│
                                                                  ▼
log-manager.sh ──────────────────────────────────────────── Slack Channels
  source log.sh                                             ┌─────────────┐
  source notify.sh                                          │ #deployments│
  → notify_alert (anomaly detected)                         │ #incidents  │
  → notify REPORT (daily digest)                            │ #ops-reports│
                                                            └─────────────┘
notify.sh
  → generate_daily_report (via cron at 8AM)
```

---

## What's Next

**Concept 10 — Putting It All Together**  
The final concept wires every script into a complete, production-grade  
webapp operations toolkit — one `Makefile`-style entry point, full  
end-to-end demo, and a walkthrough of everything built across all 10 concepts.