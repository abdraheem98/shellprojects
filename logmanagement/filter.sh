#!/bin/bash

LOG_FILE="/var/log/myapp/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"    # default INFO, override via env var

mkdir -p "$(dirname "$LOG_FILE")"

# Assign numeric weight to each level
get_level_weight() {
  case $1 in
    DEBUG) echo 0 ;;
    INFO)  echo 1 ;;
    WARN)  echo 2 ;;
    ERROR) echo 3 ;;
    *)     echo 1 ;;
  esac
}

log() {
  local level=$1
  local message=$2

  # Only log if level >= configured LOG_LEVEL
  local msg_weight current_weight
  msg_weight=$(get_level_weight "$level")
  current_weight=$(get_level_weight "$LOG_LEVEL")

  if [[ $msg_weight -ge $current_weight ]]; then
    local entry
    entry="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    echo "$entry" | tee -a "$LOG_FILE"
  fi
}

log "DEBUG" "Connecting to DB host=localhost"   # filtered out in INFO mode
log "INFO"  "Deployment started"
log "WARN"  "Retrying S3 download..."
log "ERROR" "Service failed to start"