# Concept 10 — Putting It All Together

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~25 minutes  
> **Prerequisite:** Concepts 1–9 must be complete

---

## Table of Contents

- [What We Built](#what-we-built)
- [Final Project Structure](#final-project-structure)
- [ops.sh — The Single Entry Point](#opssh--the-single-entry-point)
- [Full End-to-End Demo](#full-end-to-end-demo)
- [Wiring Everything Together](#wiring-everything-together)
- [The Complete Flow Diagram](#the-complete-flow-diagram)
- [Production Checklist](#production-checklist)
- [Cron Schedule — Full Setup](#cron-schedule--full-setup)
- [Environment Variables Reference](#environment-variables-reference)
- [What Every Concept Contributed](#what-every-concept-contributed)
- [Key Takeaways](#key-takeaways)

---

## What We Built

Over 9 concepts, we built a **production-grade webapp operations toolkit**
from scratch — entirely in shell script. Here is what each concept added:

| # | Concept | What It Added |
|---|---|---|
| 1 | Structured Logging | `log()` with levels, timestamps, file output |
| 2 | Argument Parsing | `-e`, `-v`, `-r` flags with validation |
| 3 | Exit Codes & Error Handling | `set -euo pipefail`, `trap`, lockfile |
| 4 | Config Management | External `.env` files, no hardcoded values |
| 5 | Preflight Checks | Disk, binaries, AWS, port, dependencies |
| 6 | Artifact Download | S3 download, checksum, extract, shared links |
| 7 | Zero-Downtime Deploy | Symlink swap, reload, health check, rollback |
| 8 | Log Parsing & Rotation | `awk` parsing, anomaly detection, logrotate |
| 9 | Notifications | Slack alerts, severity routing, daily report |
| 10 | **All Together** | Single entry point, full demo, production checklist |

---

## Final Project Structure

```
myapp-ops/
├── ops.sh                 ← single entry point for everything
├── deploy.sh              ← deployment pipeline (concepts 1–7)
├── log-manager.sh         ← log parsing, monitoring, rotation (concept 8)
├── notify.sh              ← notifications and daily report (concept 9)
├── log.sh                 ← shared logging function (concept 1)
├── config/
│   ├── dev.env            ← dev environment values
│   ├── staging.env        ← staging environment values
│   └── prod.env           ← prod environment values
└── /etc/
    ├── logrotate.d/myapp  ← logrotate config (concept 8)
    └── cron.d/myapp       ← cron schedule (all scripts)
```

---

## ops.sh — The Single Entry Point

One script to run everything — deploy, rollback, monitor, report, rotate:

```bash
#!/bin/bash
# ops.sh — Single entry point for the myapp operations toolkit
#
# Usage:
#   ./ops.sh deploy  -e <env> -v <version>
#   ./ops.sh rollback
#   ./ops.sh monitor
#   ./ops.sh rotate
#   ./ops.sh report
#   ./ops.sh status
#   ./ops.sh logs    [-n <lines>]
#   ./ops.sh help

set -euo pipefail

# ─── Script Location ──────────────────────────────────
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Source shared modules ────────────────────────────
source "$OPS_DIR/log.sh"
source "$OPS_DIR/notify.sh"

# ─── Config ───────────────────────────────────────────
APP_NAME="myapp"
APP_DIR="/opt/$APP_NAME"
CURRENT_LINK="$APP_DIR/current"
RELEASE_DIR="$APP_DIR/releases"
LOG_DIR="/var/log/$APP_NAME"
APP_PORT=3000

# ─── Usage ────────────────────────────────────────────
usage() {
  cat <<EOF

  ┌─────────────────────────────────────────────────────┐
  │           myapp Operations Toolkit                   │
  └─────────────────────────────────────────────────────┘

  Usage: $(basename "$0") <command> [options]

  Commands:
    deploy   -e <env> -v <version>   Deploy a new version
    rollback                          Roll back to previous release
    monitor                           Run anomaly checks on logs
    rotate                            Rotate log files now
    report                            Post daily ops report to Slack
    status                            Show current live version and health
    logs     [-n <lines>]            Tail the deploy log (default: 50 lines)
    help                              Show this message

  Environments: dev | staging | prod

  Examples:
    $(basename "$0") deploy  -e prod -v 1.4.2
    $(basename "$0") deploy  -e staging -v 2.0.0-beta
    $(basename "$0") rollback
    $(basename "$0") status
    $(basename "$0") logs -n 100
    $(basename "$0") monitor

  Environment Variables:
    SLACK_WEBHOOK                     Single webhook for all alerts
    SLACK_WEBHOOK_DEPLOYMENTS         #deployments channel
    SLACK_WEBHOOK_INCIDENTS           #incidents channel
    SLACK_WEBHOOK_REPORTS             #ops-reports channel
    LOG_LEVEL                         DEBUG | INFO | WARN | ERROR (default: INFO)

EOF
  exit 0
}

# ─── Status Command ───────────────────────────────────
show_status() {
  echo ""
  echo "  ── App Status ────────────────────────────────────"

  # Current live version
  local current_version="none"
  if [[ -L "$CURRENT_LINK" ]]; then
    current_version=$(basename "$(readlink "$CURRENT_LINK")")
  fi
  printf "  %-20s %s\n" "Live version:" "$current_version"

  # Service status
  local service_status
  if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
    service_status="running ✓"
  else
    service_status="STOPPED ✗"
  fi
  printf "  %-20s %s\n" "Service status:" "$service_status"

  # Health check
  local health_status
  if curl -sf --max-time 5 \
    "http://localhost:$APP_PORT/health" > /dev/null 2>&1; then
    health_status="healthy ✓"
  else
    health_status="UNHEALTHY ✗"
  fi
  printf "  %-20s %s\n" "Health check:" "$health_status"

  # Available releases
  echo ""
  echo "  ── Available Releases ────────────────────────────"
  if [[ -d "$RELEASE_DIR" ]]; then
    ls -dt "$RELEASE_DIR"/*/ 2>/dev/null | while read -r release; do
      local version
      version=$(basename "$release")
      local marker=""
      [[ "$release" == "$(readlink "$CURRENT_LINK" 2>/dev/null)/" ]] && \
        marker=" ← LIVE"
      printf "  %s%s\n" "$version" "$marker"
    done
  else
    echo "  No releases found"
  fi

  # Disk usage
  echo ""
  echo "  ── Disk Usage ────────────────────────────────────"
  df -h /opt 2>/dev/null | awk 'NR==2 {
    printf "  %-20s %s used of %s (%s)\n", "Disk:", $3, $2, $5
  }'
  du -sh "$LOG_DIR" 2>/dev/null | \
    awk '{printf "  %-20s %s\n", "Log directory:", $1}'

  # Log error summary
  echo ""
  echo "  ── Last Hour ─────────────────────────────────────"
  local app_log="$LOG_DIR/app.log"
  if [[ -f "$app_log" ]]; then
    local since_ts
    since_ts=$(date -d "1 hour ago" '+%Y-%m-%dT%H:%M' 2>/dev/null \
      || date -v "-1H" '+%Y-%m-%dT%H:%M')
    local errors warns
    errors=$(awk -v ts="$since_ts" \
      '$1 >= ts && /\[ERROR\]/' "$app_log" | wc -l)
    warns=$(awk  -v ts="$since_ts" \
      '$1 >= ts && /\[WARN \]/' "$app_log" | wc -l)
    printf "  %-20s %s\n" "Errors (1hr):" "$errors"
    printf "  %-20s %s\n" "Warnings (1hr):" "$warns"
  fi

  echo ""
}

# ─── Logs Command ─────────────────────────────────────
tail_logs() {
  local lines=50
  while getopts "n:" opt; do
    case $opt in n) lines=$OPTARG ;; *) ;; esac
  done
  local deploy_log="$LOG_DIR/deploy.log"
  if [[ ! -f "$deploy_log" ]]; then
    log WARN "No deploy log found at $deploy_log"
    exit 0
  fi
  echo ""
  echo "  ── Last $lines lines of deploy log ────────────────"
  echo ""
  tail -n "$lines" "$deploy_log"
  echo ""
}

# ─── Command Router ───────────────────────────────────
COMMAND="${1:-help}"
shift || true

case $COMMAND in
  deploy)
    log INFO "Running deploy..."
    exec "$OPS_DIR/deploy.sh" "$@"
    ;;

  rollback)
    log INFO "Running rollback..."
    exec "$OPS_DIR/deploy.sh" -r
    ;;

  monitor)
    log INFO "Running anomaly checks..."
    exec "$OPS_DIR/log-manager.sh" monitor
    ;;

  rotate)
    log INFO "Running log rotation..."
    exec "$OPS_DIR/log-manager.sh" rotate
    ;;

  parse)
    log INFO "Parsing logs..."
    exec "$OPS_DIR/log-manager.sh" parse
    ;;

  report)
    log INFO "Posting daily report..."
    exec "$OPS_DIR/notify.sh" report
    ;;

  status)
    show_status
    ;;

  logs)
    tail_logs "$@"
    ;;

  help|--help|-h)
    usage
    ;;

  *)
    log ERROR "Unknown command: $COMMAND"
    usage
    ;;
esac
```

---

## Full End-to-End Demo

Run these commands live in front of the class — in this exact order:

### 1. Show the toolkit

```bash
./ops.sh help
```

```
  ┌─────────────────────────────────────────────────────┐
  │           myapp Operations Toolkit                   │
  └─────────────────────────────────────────────────────┘

  Commands:
    deploy   -e <env> -v <version>   Deploy a new version
    rollback                          Roll back to previous release
    monitor                           Run anomaly checks on logs
    ...
```

---

### 2. Show current status (before deploy)

```bash
./ops.sh status
```

```
  ── App Status ────────────────────────────────────────
  Live version:        1.4.1
  Service status:      running ✓
  Health check:        healthy ✓

  ── Available Releases ────────────────────────────────
  1.4.1  ← LIVE
  1.4.0

  ── Disk Usage ────────────────────────────────────────
  Disk:                4.2G used of 50G (8%)
  Log directory:       43M
```

---

### 3. Run a successful deploy

```bash
LOG_LEVEL=DEBUG ./ops.sh deploy -e prod -v 1.4.2
```

```
[INFO ] ════ Preflight Checks ═══════════════════════
[INFO ] All binaries present ✓
[INFO ] Disk space: 4300MB ✓
[INFO ] AWS credentials valid ✓
[INFO ] Artifact exists ✓
[INFO ] ════ Preflight Passed ═══════════════════════
[INFO ] ════ Preparing Release: v1.4.2 ══════════════
[INFO ] ── Downloading Artifact ─────────────────────
[INFO ] Downloaded: 487MB ✓
[INFO ] ── Verifying Checksum ───────────────────────
[INFO ] Checksum verified ✓
[INFO ] ── Extracting Artifact ──────────────────────
[INFO ] 847 files extracted ✓
[INFO ] ── Linking Shared Resources ─────────────────
[INFO ] Shared resources linked ✓
[INFO ] ── Installing Dependencies ──────────────────
[INFO ] 313 packages installed ✓
[INFO ] ════ Release v1.4.2 Ready ════════════════════
[INFO ] ════ Performing Cutover: v1.4.2 ══════════════
[INFO ] ── Symlink Swap ─────────────────────────────
[INFO ] Swap complete — current → 1.4.2 ✓
[INFO ] ── Service Reload ───────────────────────────
[INFO ] Service active ✓
[INFO ] ── Health Check ─────────────────────────────
[INFO ] Health check passed — HTTP 200 ✓
[INFO ] ════ Cutover Complete — v1.4.2 is live ═══════
[INFO ] ── Cleaning Up Old Releases ─────────────────
[INFO ] Removed 1 old release(s) ✓
[INFO ] Deployment completed successfully
```

---

### 4. Show status after deploy

```bash
./ops.sh status
```

```
  ── App Status ────────────────────────────────────────
  Live version:        1.4.2          ← updated
  Service status:      running ✓
  Health check:        healthy ✓

  ── Available Releases ────────────────────────────────
  1.4.2  ← LIVE
  1.4.1
  1.4.0
```

---

### 5. Simulate a failed deploy (the most important demo)

```bash
# Point health check to wrong port to simulate failure
APP_PORT=9999 ./ops.sh deploy -e prod -v 1.4.3
```

```
[INFO ] ════ Performing Cutover: v1.4.3 ══════════════
[INFO ] Swap complete — current → 1.4.3 ✓
[WARN ] Attempt 1/12 — HTTP 000
[WARN ] Attempt 2/12 — HTTP 000
[WARN ] Attempt 3/12 — HTTP 000
...
[ERROR] Health check FAILED after 12 attempts
[WARN ] ════ Initiating Rollback ════════════════════
[WARN ] Failed release: 1.4.3
[WARN ] Rolling back to: 1.4.2
[WARN ] Symlink restored to: 1.4.2
[WARN ] Service reloaded with previous release
[WARN ] Rollback health check passed ✓
[WARN ] ════ Rollback Complete — 1.4.2 is live ════
[ERROR] Deployment FAILED — exit code 1
```

---

### 6. Run anomaly checks

```bash
./ops.sh monitor
```

```
[INFO ] ════ Anomaly Detection ══════════════════════
[INFO ] 5xx error rate: 0.6%
[INFO ] App errors in last 5min: 3
[INFO ] ════ Anomaly Detection Complete ════════════
```

---

### 7. Rotate logs

```bash
./ops.sh rotate
```

```
[INFO ] ════ Log Rotation ═══════════════════════════
[INFO ] Checking: /var/log/myapp/app.log (43MB)
[INFO ] No rotation needed (43MB < 100MB)
[INFO ] No archives to purge
[INFO ] ════ Rotation Complete ══════════════════════
```

---

### 8. Post daily report

```bash
./ops.sh report
```

```
[INFO ] Generating daily report...
[INFO ] Daily report posted to Slack ✓
```

---

### 9. Tail deploy logs

```bash
./ops.sh logs -n 20
```

---

## Wiring Everything Together

Here is how every concept flows into the final toolkit:

```bash
# ops.sh sources these two shared modules
source ./log.sh       # Concept 1  — every script uses log()
source ./notify.sh    # Concept 9  — every script uses notify()

# ops.sh delegates to these three scripts
./deploy.sh           # Concepts 2,3,4,5,6,7 — full deploy pipeline
./log-manager.sh      # Concept 8  — parse, monitor, rotate
./notify.sh report    # Concept 9  — daily report
```

Every script follows the same pattern:

```bash
#!/bin/bash
set -euo pipefail              # Concept 3
source ./log.sh                # Concept 1
source ./notify.sh             # Concept 9
source config/$ENV.env         # Concept 4
[lockfile check]               # Concept 3
[argument parsing]             # Concept 2
[validation]                   # Concept 2
[trap setup]                   # Concept 3
[preflight gate]               # Concept 5
[core logic]                   # Concepts 6,7,8
[notification]                 # Concept 9
```

---

## The Complete Flow Diagram

```
ops.sh deploy -e prod -v 1.4.2
│
├─► Concept 2: Parse & validate args (-e prod -v 1.4.2)
│
├─► Concept 3: trap cleanup on EXIT | trap handle_error on ERR
│              Create lockfile → prevent duplicate deploys
│
├─► Concept 4: Load config/prod.env
│              Apply environment overrides
│              Validate all config values
│
├─► Concept 5: Preflight gate
│              ✓ Binaries present
│              ✓ Disk space sufficient
│              ✓ AWS credentials valid
│              ✓ Artifact exists in S3
│              ✓ Port available / held by us
│              ✓ DB + Redis reachable
│
├─► Concept 6: prepare_release(1.4.2)
│              ✓ Download artifact from S3
│              ✓ Verify SHA256 checksum
│              ✓ Extract to releases/1.4.2/
│              ✓ Link shared/.env, uploads/, logs/
│              ✓ npm ci --production
│
├─► Concept 7: perform_cutover(1.4.2)
│              ✓ Atomic symlink swap (current → 1.4.2)
│              ✓ systemctl reload-or-restart myapp
│              ✓ Health check retry loop (12 attempts × 5s)
│              │
│              ├── PASS → cleanup_old_releases()
│              │          notify INFO "Deploy Successful"
│              │          exit 0 ✅
│              │
│              └── FAIL → rollback(1.4.2)
│                         Swap back to 1.4.1
│                         Reload service
│                         Verify rollback health
│                         notify CRITICAL "Deploy Failed"
│                         exit 1 ❌
│
└─► Concept 3: trap cleanup EXIT
               Remove temp dir
               Remove lockfile
               Log final status
```

---

## Production Checklist

Before running this toolkit on a real server, verify every item:

### Security
- [ ] Webhook URLs in environment variables — never in scripts or Git
- [ ] `.env` config files not committed — add to `.gitignore`
- [ ] Deploy script runs as a dedicated `deploy` user — not `root`
- [ ] S3 bucket has bucket policy — least-privilege IAM role
- [ ] Lockfile path is only writable by the `deploy` user
- [ ] Log files have `640` permissions — app writes, ops reads

### Reliability
- [ ] `set -euo pipefail` at the top of every script
- [ ] `trap cleanup EXIT` registered before any work starts
- [ ] Lockfile prevents concurrent deployments
- [ ] Health check retries are generous enough for slow app starts
- [ ] Rollback is tested — run a forced failure before going live
- [ ] At least 2 releases kept at all times — rollback is always possible

### Observability
- [ ] Structured log format — timestamp, level, message on every line
- [ ] Deploy log written to persistent file — survives session close
- [ ] Slack notifications wired for both success and failure
- [ ] Daily report cron configured and tested
- [ ] Anomaly monitor cron running every 5 minutes

### Operations
- [ ] logrotate config in `/etc/logrotate.d/myapp`
- [ ] Cron jobs in `/etc/cron.d/myapp` — not personal crontabs
- [ ] `ops.sh help` explains every command clearly
- [ ] Secrets injected via environment — CI/CD pipeline sets `SLACK_WEBHOOK`
- [ ] Tested on staging before prod — every time

---

## Cron Schedule — Full Setup

```bash
# /etc/cron.d/myapp
# Run as the deploy user — not root

# Anomaly detection every 5 minutes
*/5 * * * * deploy /opt/myapp-ops/ops.sh monitor >> /var/log/myapp/monitor.log 2>&1

# Log rotation check daily at midnight
0 0 * * *   deploy /opt/myapp-ops/ops.sh rotate  >> /var/log/myapp/rotate.log 2>&1

# Daily ops report at 8AM
0 8 * * *   deploy /opt/myapp-ops/ops.sh report  >> /var/log/myapp/report.log 2>&1

# Weekly full log parse and summary (Sunday 9AM)
0 9 * * 0   deploy /opt/myapp-ops/ops.sh parse   >> /var/log/myapp/parse.log 2>&1
```

---

## Environment Variables Reference

| Variable | Used In | Description |
|---|---|---|
| `ENV` | deploy.sh | Target environment (dev/staging/prod) |
| `LOG_LEVEL` | All scripts | DEBUG \| INFO \| WARN \| ERROR |
| `SLACK_WEBHOOK` | notify.sh | Single webhook — fallback for all channels |
| `SLACK_WEBHOOK_DEPLOYMENTS` | notify.sh | #deployments channel |
| `SLACK_WEBHOOK_INCIDENTS` | notify.sh | #incidents channel |
| `SLACK_WEBHOOK_REPORTS` | notify.sh | #ops-reports channel |
| `NODE_ENV` | deploy.sh | Passed to npm ci (production) |
| `AWS_REGION` | deploy.sh | Region for S3 and STS calls |
| `AWS_PROFILE` | deploy.sh | Optional — named AWS profile |

**Set them for a deploy:**

```bash
export LOG_LEVEL=DEBUG
export SLACK_WEBHOOK="https://hooks.slack.com/services/..."
./ops.sh deploy -e prod -v 1.4.2
```

**Set them in CI/CD (GitHub Actions example):**

```yaml
- name: Deploy to prod
  env:
    SLACK_WEBHOOK: ${{ secrets.SLACK_WEBHOOK }}
    AWS_REGION: ap-south-1
  run: ./ops.sh deploy -e prod -v ${{ github.ref_name }}
```

---

## What Every Concept Contributed

Look at the final `deploy.sh` and identify exactly where each concept lives:

```bash
#!/bin/bash
set -euo pipefail                  # ← Concept 3: holy trinity

source ./log.sh                    # ← Concept 1: structured logging
source ./notify.sh                 # ← Concept 9: notifications

APP_NAME="myapp"                   # ← Concept 4: config block
source config/$ENV.env             # ← Concept 4: external config

trap 'handle_error $LINENO' ERR    # ← Concept 3: error handler
trap cleanup EXIT                  # ← Concept 3: cleanup on any exit

while getopts "e:v:rh" opt; do    # ← Concept 2: argument parsing
  ...
done

validate_inputs                    # ← Concept 2: input validation
load_config "$ENV"                 # ← Concept 4: env-specific overrides
validate_config                    # ← Concept 4: config validation

run_preflight                      # ← Concept 5: preflight gate
  check_binaries                   # ← Concept 5
  check_disk_space                 # ← Concept 5
  check_port                       # ← Concept 5
  check_aws_access                 # ← Concept 5
  check_dependencies               # ← Concept 5

prepare_release "$VERSION"         # ← Concept 6: artifact management
  download_artifact                # ← Concept 6
  verify_checksum                  # ← Concept 6
  extract_artifact                 # ← Concept 6
  link_shared_resources            # ← Concept 6
  install_dependencies             # ← Concept 6

perform_cutover "$VERSION"         # ← Concept 7: zero-downtime deploy
  perform_symlink_swap             # ← Concept 7
  reload_service                   # ← Concept 7
  run_health_check                 # ← Concept 7
  rollback (if needed)             # ← Concept 7

cleanup_old_releases               # ← Concept 7
notify_deploy_success              # ← Concept 9
```

---

## Key Takeaways

### Technical skills built

| Skill | Where Used |
|---|---|
| `set -euo pipefail` | Every script — non-negotiable |
| `trap` for cleanup | Every script — always register before work starts |
| `getopts` for flags | Every script — never positional args in prod |
| `awk` for log parsing | log-manager.sh — the DevOps Swiss army knife |
| `ln -sfn` atomic swap | deploy.sh — the heart of zero-downtime |
| `/dev/tcp` for TCP checks | deploy.sh — no extra tools needed |
| `sha256sum -c` checksum | deploy.sh — never skip this |
| Slack Block Kit | notify.sh — readable alerts at 3AM |
| `BASH_SOURCE[0]` dual mode | notify.sh — source or execute |
| `command -v` binary check | deploy.sh — portable across distros |

### Engineering principles learned

| Principle | Demonstrated In |
|---|---|
| Fail fast at the start | Concept 5 — preflight gate |
| Fail loud with context | Concepts 1, 3 — structured logs + error handler |
| Never touch live until ready | Concept 6 — versioned release dirs |
| Atomic operations only | Concept 7 — symlink swap |
| Auto-recover before alerting | Concept 7 — rollback then notify |
| Config separate from logic | Concept 4 — external `.env` files |
| Secrets in environment | Concept 9 — never hardcoded |
| One entry point | Concept 10 — `ops.sh` |

---

## Final Words for the Class

Every script in this toolkit started as a blank file and a single
`echo` statement. By adding one concept at a time — logging, then
arguments, then error handling, then config, then preflight, then
artifact management, then zero-downtime cutover, then log management,
then notifications — we ended up with a system that:

- Deploys safely with zero downtime
- Rolls back automatically in under 30 seconds
- Never runs two deploys simultaneously
- Checks its environment before touching anything
- Verifies artifact integrity before deploying
- Keeps the last 5 releases for instant rollback
- Monitors for anomalies every 5 minutes
- Rotates logs before the disk fills up
- Sends structured Slack alerts on every event
- Posts a daily health report every morning

**This is what production shell scripting looks like.**  
Not clever one-liners — careful, layered, testable engineering.

The same principles — fail fast, fail loud, clean up after yourself,
never hardcode, always validate — apply whether you are writing shell
scripts, Python, Go, or Terraform. The language changes. The discipline
does not.