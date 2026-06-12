# Concept 1 — Structured Logging

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~20 minutes  
> **Prerequisite:** Basic shell scripting (variables, conditionals, functions)

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Is Structured Logging?](#what-is-structured-logging)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Simplest Log Function](#step-1--the-simplest-log-function)
  - [Step 2 — Add Log Levels](#step-2--add-log-levels)
  - [Step 3 — Write Logs to a File](#step-3--write-logs-to-a-file)
  - [Step 4 — Add Log Level Filtering](#step-4--add-log-level-filtering)
  - [Step 5 — Final Production-Ready Version](#step-5--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners write

```bash
#!/bin/bash

echo "starting deployment"
cp app.tar.gz /opt/myapp
echo "done"
```

**Ask yourself:** *"If this script fails at 2AM, what do you know?"*

The answer is — **nothing useful**. You don't know:

- ❌ When exactly it failed
- ❌ Which step failed
- ❌ How severe it was
- ❌ Where the log is stored
- ❌ Whether it was an error or just info

### Real-world incident scenario

> Your app went down at 2:47AM. Your manager asks — *what happened?*  
> You check the logs and see:
>
> ```
> starting deployment
> done
> ```
>
> That tells you **nothing**. You are completely blind.

This is why **every production script must have structured logging from line one.**

---

## What Is Structured Logging?

Structured logging means every log line has a consistent, predictable format:

| Field | Example | Why |
|---|---|---|
| **Timestamp** | `2024-06-12T02:47:31` | Know exactly when it happened |
| **Level** | `ERROR` / `INFO` / `WARN` | Know how serious it is |
| **Message** | `Failed to connect to DB` | Know what happened |
| **Context** *(optional)* | `app=myapp env=prod` | Know which system |

---

## Build It Step by Step

### Step 1 — The Simplest Log Function

Start here. Just timestamp + message:

```bash
#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting deployment..."
log "Copying files..."
log "Done"
```

**Run it:**

```bash
bash deploy.sh
```

**Output:**

```
[2024-06-12 02:47:31] Starting deployment...
[2024-06-12 02:47:32] Copying files...
[2024-06-12 02:47:33] Done
```

> ✅ Better than `echo` — but we still don't know severity.

---

### Step 2 — Add Log Levels

```bash
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
```

**Output:**

```
[2024-06-12 02:47:31] [INFO ] Starting deployment...
[2024-06-12 02:47:31] [WARN ] Config file missing, using defaults
[2024-06-12 02:47:31] [ERROR] Failed to connect to database
[2024-06-12 02:47:31] [DEBUG] DB host = localhost, port = 5432
```

> ✅ Now we know severity — but logs disappear when the terminal closes.

---

### Step 3 — Write Logs to a File

```bash
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
```

#### What is `tee -a`?

| Flag | Meaning |
|---|---|
| `tee` | Reads from stdin, writes to **both** terminal and file |
| `-a` | **Append** mode — never overwrites existing logs |

**Verify it works:**

```bash
bash deploy.sh
cat /var/log/myapp/deploy.log
```

> ✅ Logs persist — but in prod you don't want DEBUG logs cluttering production files.

---

### Step 4 — Add Log Level Filtering

```bash
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
```

#### Control log verbosity from outside the script

```bash
# Normal run — DEBUG hidden
bash deploy.sh

# Debug run — see everything
LOG_LEVEL=DEBUG bash deploy.sh

# Errors only
LOG_LEVEL=ERROR bash deploy.sh
```

**Output in INFO mode:**

```
[2024-06-12 02:47:31] [INFO ] Deployment started
[2024-06-12 02:47:31] [WARN ] Retrying S3 download...
[2024-06-12 02:47:31] [ERROR] Service failed to start
```

**Output in DEBUG mode:**

```
[2024-06-12 02:47:31] [DEBUG] Connecting to DB host=localhost
[2024-06-12 02:47:31] [INFO ] Deployment started
[2024-06-12 02:47:31] [WARN ] Retrying S3 download...
[2024-06-12 02:47:31] [ERROR] Service failed to start
```

> ✅ This is exactly how tools like **Docker**, **Ansible**, and **Terraform** control verbosity.

---

### Step 5 — Final Production-Ready Version

```bash
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

  # Format: ISO timestamp | app name | level | message
  local entry
  entry="$timestamp [$APP_NAME] [$(printf '%-5s' "$level")] $message"

  # ERROR → stderr + file | Others → stdout + file
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
```

**Final output:**

```
2024-06-12T02:47:31 [myapp] [DEBUG] Script initialized with LOG_LEVEL=DEBUG
2024-06-12T02:47:31 [myapp] [INFO ] Deployment pipeline starting
2024-06-12T02:47:31 [myapp] [WARN ] Environment variable DB_PASS not set, using default
2024-06-12T02:47:31 [myapp] [ERROR] Could not reach health check endpoint after 5 retries
2024-06-12T02:47:31 [myapp] [INFO ] Rollback triggered successfully
```

> ✅ This format works out of the box with **CloudWatch**, **ELK Stack**, and **Datadog** — no parsing config needed.

---

## Mini Exercise for Participants

> **Task:** Write a script called `backup.sh` that:
> - Uses the `log()` function from today
> - Logs `INFO` when backup starts
> - Logs `WARN` if the backup directory doesn't exist
> - Logs `ERROR` if the backup file size is 0 bytes
> - Logs `INFO` when backup completes
> - Writes all logs to `/var/log/myapp/backup.log`

**Expected solution:**

```bash
#!/bin/bash

# Source the log function
source ./log.sh

BACKUP_DIR="/opt/backups"
BACKUP_FILE="$BACKUP_DIR/db-$(date '+%Y%m%d').sql"

log INFO "Backup started"

if [[ ! -d "$BACKUP_DIR" ]]; then
  log WARN "Backup directory missing, creating it..."
  mkdir -p "$BACKUP_DIR"
fi

# Simulate backup — replace with real pg_dump / mysqldump in prod
touch "$BACKUP_FILE"

if [[ ! -s "$BACKUP_FILE" ]]; then
  log ERROR "Backup file is empty — something went wrong"
  exit 1
fi

log INFO "Backup completed → $BACKUP_FILE"
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| Never use raw `echo` in prod | No timestamp, no level, no file — useless during incidents |
| `tee -a` is your friend | Logs to terminal AND file simultaneously |
| `LOG_LEVEL` via env var | Control verbosity without touching the script |
| `ERROR` goes to stderr | Allows `2>error.log` separation in pipelines |
| `$*` after shift | Lets you log multi-word messages cleanly |
| ISO 8601 timestamp | Works with every log aggregation tool (CloudWatch, ELK, Datadog) |

---

## What's Next

**Concept 2 — Argument Parsing & Validation**  
We will layer `-e prod -v 1.4.2` flag support directly on top of this `log()` function, with proper usage messages and input validation.