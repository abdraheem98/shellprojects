#!/bin/bash

LOG_FILE="/var/log/myapp/deploy.log"

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local level=$1
  local message=$2
  local entry
  entry="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"

  # tee → prints to terminal AND writes to file simultaneously
  echo "$entry" | tee -a "$LOG_FILE"
}

log "INFO"  "Starting deployment..."
log "WARN"  "Config file missing, using defaults"
log "ERROR" "Failed to connect to database"