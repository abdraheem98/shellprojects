#!/bin/bash

# ─── Log Configuration ────────────────────────────────
APP_NAME="myapp"
LOG_DIR="/var/log/$APP_NAME"
LOG_FILE="$LOG_DIR/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
MAX_LOG_SIZE_MB=50

mkdir -p "$LOG_DIR"

# ─── Level Weight ─────────────────────────────────────
get_level_weight() {
  case $1 in
    DEBUG) echo 0 ;;
    INFO)  echo 1 ;;
    WARN)  echo 2 ;;
    ERROR) echo 3 ;;
    *)     echo 1 ;;
  esac
}

# ─── Auto Rotate if Log Too Big ───────────────────────
check_log_size() {
  if [[ -f "$LOG_FILE" ]]; then
    local size_mb
    size_mb=$(du -m "$LOG_FILE" | cut -f1)
    if [[ $size_mb -gt $MAX_LOG_SIZE_MB ]]; then
      mv "$LOG_FILE" "${LOG_FILE}.$(date '+%Y%m%d%H%M%S').bak"
      echo "Log rotated due to size limit (${size_mb}MB)" > "$LOG_FILE"
    fi
  fi
}

# ─── Core log() Function ──────────────────────────────
log() {
  local level=$1; shift
  local message=$*            # capture everything after level as message

  local msg_weight current_weight
  msg_weight=$(get_level_weight "$level")
  current_weight=$(get_level_weight "$LOG_LEVEL")

  [[ $msg_weight -ge $current_weight ]] || return 0

  # Check log size before every write
  check_log_size

  local timestamp
  timestamp=$(date '+%Y-%m-%dT%H:%M:%S')

  # Format: ISO timestamp | level | message
  local entry
  entry="$timestamp [$APP_NAME] [$(printf '%-5s' "$level")] $message"

  # ERROR → stderr + file. Others → stdout + file
  if [[ "$level" == "ERROR" ]]; then
    echo "$entry" | tee -a "$LOG_FILE" >&2
  else
    echo "$entry" | tee -a "$LOG_FILE"
  fi
}

# ─── Test It ──────────────────────────────────────────
log DEBUG "Script initialized with LOG_LEVEL=$LOG_LEVEL"
log INFO  "Deployment pipeline starting"
log WARN  "Environment variable DB_PASS not set, using default"
log ERROR "Could not reach health check endpoint after 5 retries"
log INFO  "Rollback triggered successfully"