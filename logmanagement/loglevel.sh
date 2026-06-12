#!/bin/bash

log() {
  local level=$1
  local message=$2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

log "INFO"  "Starting deployment..."
log "WARN"  "Config file missing, using defaults"
log "ERROR" "Failed to connect to database"
log "DEBUG" "DB host = localhost, port = 5432"