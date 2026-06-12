# Concept 5 — Preflight Checks

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~20 minutes  
> **Prerequisite:** Concept 1 (Logging) + Concept 2 (Argument Parsing) + Concept 3 (Exit Codes) + Concept 4 (Config Management)

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Are Preflight Checks?](#what-are-preflight-checks)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Check Required Binaries](#step-1--check-required-binaries)
  - [Step 2 — Check Disk Space](#step-2--check-disk-space)
  - [Step 3 — Check Port Availability](#step-3--check-port-availability)
  - [Step 4 — Check AWS Connectivity](#step-4--check-aws-connectivity)
  - [Step 5 — Check Service Dependencies](#step-5--check-service-dependencies)
  - [Step 6 — Final Production-Ready Version](#step-6--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners write

```bash
#!/bin/bash
set -euo pipefail

# Jump straight into deployment
aws s3 cp s3://prod-artifacts/myapp/1.4.2/app.tar.gz /opt/myapp/releases/
tar -xzf /opt/myapp/releases/app.tar.gz
npm install --production
systemctl restart myapp
```

**What happens when:**

- `aws` CLI is not installed → crashes at step 1 with cryptic error
- Disk is 95% full → `tar` extracts halfway, corrupts the release directory
- Port 3000 is already held by a zombie process → app fails to start silently
- S3 bucket is in the wrong region → download hangs for 30 seconds then fails
- `npm` is missing → dependencies never install, app starts with old `node_modules`

**Every one of these failures happens mid-deployment** — after files have already been moved, after the old release symlink has been updated, after the service has been stopped.

### Real-world incident scenario

> A deployment script ran on a server with only 200MB of disk space remaining.  
> The artifact was 800MB. `tar` extracted 200MB and then crashed mid-extraction.  
> The release directory was corrupt. The symlink had already been updated.  
> The rollback script also failed — because it needed disk space too.  
> The server was down for 4 hours while engineers manually cleaned up disk space  
> and rebuilt the release.
>
> **A 3-line disk space check at the top would have prevented all of it.**

---

## What Are Preflight Checks?

Preflight checks are a **gate at the very start of the script** that verifies the environment is ready before touching anything.

The rule is:

> **Fail fast at the beginning — never fail halfway through.**

A mid-deployment failure is always worse than a pre-deployment failure because:
- Files may be partially written
- Services may be in a stopped or broken state
- Rollback may also be blocked by the same issue

Think of preflight checks like a pilot's pre-flight checklist — you don't start the engine and then check if there's fuel.

---

## Build It Step by Step

### Step 1 — Check Required Binaries

Verify every tool the script depends on is installed before running a single command:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

# List every binary the script will use
REQUIRED_BINARIES=(
  aws        # artifact download from S3
  tar        # artifact extraction
  curl       # health check
  systemctl  # service management
  npm        # dependency install
  jq         # JSON parsing for API responses
)

check_binaries() {
  log INFO "Checking required binaries..."

  local missing=0

  for bin in "${REQUIRED_BINARIES[@]}"; do
    if command -v "$bin" &>/dev/null; then
      log DEBUG "$bin → $(command -v "$bin")"
    else
      log ERROR "Required binary not found: $bin"
      missing=$((missing + 1))
    fi
  done

  if [[ $missing -gt 0 ]]; then
    log ERROR "$missing required binary/binaries missing — cannot proceed"
    exit 1
  fi

  log INFO "All required binaries present ✓"
}

check_binaries
```

**Run it with a missing binary:**

```
[DEBUG] aws     → /usr/local/bin/aws
[DEBUG] tar     → /bin/tar
[DEBUG] curl    → /usr/bin/curl
[ERROR] Required binary not found: jq
[ERROR] 1 required binary/binaries missing — cannot proceed
```

**Also check binary versions where it matters:**

```bash
check_aws_version() {
  local version
  version=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
  local major
  major=$(echo "$version" | cut -d. -f1)

  if [[ "$major" -lt 2 ]]; then
    log ERROR "AWS CLI v2 required — found v$version"
    exit 1
  fi

  log INFO "AWS CLI version: $version ✓"
}
```

> ✅ Script stops immediately with a clear message — not 5 steps later with a cryptic error.

---

### Step 2 — Check Disk Space

Always verify there is enough free disk space before downloading or extracting anything:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

# How much free space is needed (in MB)
MIN_FREE_MB=1024      # 1GB minimum for the release dir
ARTIFACT_SIZE_MB=500  # estimated artifact size

check_disk_space() {
  local path=$1
  local required_mb=$2

  # Create the path if it doesn't exist yet
  mkdir -p "$path"

  local free_kb
  free_kb=$(df "$path" | awk 'NR==2 {print $4}')
  local free_mb=$(( free_kb / 1024 ))

  log INFO "Disk check: $path — Free: ${free_mb}MB | Required: ${required_mb}MB"

  if [[ $free_mb -lt $required_mb ]]; then
    log ERROR "Insufficient disk space on $path"
    log ERROR "  Available : ${free_mb}MB"
    log ERROR "  Required  : ${required_mb}MB"
    log ERROR "  Shortfall : $(( required_mb - free_mb ))MB"
    exit 1
  fi

  log INFO "Disk space check passed ✓ (${free_mb}MB available)"
}

# Check both the release dir AND the temp dir
check_disk_space "/opt/myapp/releases"  "$MIN_FREE_MB"
check_disk_space "/tmp"                 "$ARTIFACT_SIZE_MB"
```

**Run it on a nearly full disk:**

```
[INFO ] Disk check: /opt/myapp/releases — Free: 180MB | Required: 1024MB
[ERROR] Insufficient disk space on /opt/myapp/releases
[ERROR]   Available : 180MB
[ERROR]   Required  : 1024MB
[ERROR]   Shortfall : 844MB
```

**Add a disk usage warning even when space is sufficient:**

```bash
check_disk_with_warning() {
  local path=$1
  local required_mb=$2
  local warn_threshold=80    # warn if disk is more than 80% full

  mkdir -p "$path"

  local use_percent
  use_percent=$(df "$path" | awk 'NR==2 {print $5}' | tr -d '%')

  if [[ $use_percent -ge $warn_threshold ]]; then
    log WARN "Disk usage on $path is ${use_percent}% — consider cleanup"
  fi

  # Still enforce the hard minimum
  check_disk_space "$path" "$required_mb"
}
```

> ✅ Catches disk issues before a single byte is written to disk.

---

### Step 3 — Check Port Availability

Before starting the app, verify the port it needs is either free or held by the right process:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_PORT=3000
APP_NAME="myapp"

check_port() {
  local port=$1

  log INFO "Checking port $port availability..."

  if ss -tlnp | grep -q ":${port}\\b"; then
    # Port is in use — find out by what
    local pid process
    pid=$(ss -tlnp | grep ":${port}\\b" | grep -oP 'pid=\K[0-9]+' | head -1)
    process=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")

    if [[ "$process" == "$APP_NAME" ]] || [[ "$process" == "node" ]]; then
      log INFO "Port $port held by $APP_NAME (PID $pid) — expected, will reload"
    else
      log ERROR "Port $port is held by unexpected process: $process (PID $pid)"
      log ERROR "Resolve this manually before deploying"
      exit 1
    fi
  else
    log INFO "Port $port is free ✓"
  fi
}

check_port "$APP_PORT"
```

**Output — port held by wrong process:**

```
[INFO ] Checking port 3000 availability...
[ERROR] Port 3000 is held by unexpected process: python3 (PID 8823)
[ERROR] Resolve this manually before deploying
```

**Output — port held by the app itself (expected during redeploy):**

```
[INFO ] Checking port 3000 availability...
[INFO ] Port 3000 held by myapp (PID 4521) — expected, will reload
```

**Output — port is free (fresh deploy):**

```
[INFO ] Checking port 3000 availability...
[INFO ] Port 3000 is free ✓
```

> ✅ Distinguishes between "port free", "port held by our app", and "port stolen by something else".

---

### Step 4 — Check AWS Connectivity

Verify AWS credentials and S3 access before trying to download the artifact:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

ARTIFACT_BUCKET="s3://prod-artifacts/myapp"
AWS_REGION="ap-south-1"

check_aws_access() {
  log INFO "Checking AWS connectivity..."

  # Check AWS credentials are configured
  if ! aws sts get-caller-identity --region "$AWS_REGION" &>/dev/null; then
    log ERROR "AWS credentials not configured or expired"
    log ERROR "Run 'aws configure' or check your IAM role"
    exit 1
  fi

  local account_id
  account_id=$(aws sts get-caller-identity \
    --query Account \
    --output text \
    --region "$AWS_REGION")
  log INFO "AWS identity verified — account: $account_id ✓"

  # Check S3 bucket is accessible
  log INFO "Checking S3 bucket access: $ARTIFACT_BUCKET"
  if ! aws s3 ls "$ARTIFACT_BUCKET" --region "$AWS_REGION" &>/dev/null; then
    log ERROR "Cannot access S3 bucket: $ARTIFACT_BUCKET"
    log ERROR "Check bucket name, region, and IAM permissions"
    exit 1
  fi

  log INFO "S3 bucket accessible ✓"
}

check_artifact_exists() {
  local version=$1
  local artifact_path="$ARTIFACT_BUCKET/$version/app.tar.gz"

  log INFO "Checking artifact exists: $artifact_path"

  if ! aws s3 ls "$artifact_path" --region "$AWS_REGION" &>/dev/null; then
    log ERROR "Artifact not found in S3: $artifact_path"
    log ERROR "Verify the version number and that the build pipeline completed"
    exit 1
  fi

  # Get artifact size for disk space planning
  local size_bytes
  size_bytes=$(aws s3 ls "$artifact_path" --region "$AWS_REGION" | awk '{print $3}')
  local size_mb=$(( size_bytes / 1024 / 1024 ))
  log INFO "Artifact found — size: ${size_mb}MB ✓"
}

check_aws_access
check_artifact_exists "${VERSION}"
```

**Output — credentials expired:**

```
[ERROR] AWS credentials not configured or expired
[ERROR] Run 'aws configure' or check your IAM role
```

**Output — artifact not found:**

```
[ERROR] Artifact not found in S3: s3://prod-artifacts/myapp/9.9.9/app.tar.gz
[ERROR] Verify the version number and that the build pipeline completed
```

**Output — all good:**

```
[INFO ] AWS identity verified — account: 123456789012 ✓
[INFO ] S3 bucket accessible ✓
[INFO ] Artifact found — size: 487MB ✓
```

> ✅ Catches missing artifacts and expired credentials before the download even starts.

---

### Step 5 — Check Service Dependencies

Verify that databases, caches, and other services the app needs are reachable:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

# Loaded from config (Concept 4)
DB_HOST="prod-db.internal"
DB_PORT=5432
REDIS_HOST="prod-redis.internal"
REDIS_PORT=6379
TIMEOUT=5   # seconds to wait for connection

check_tcp_connection() {
  local host=$1
  local port=$2
  local name=$3

  log INFO "Checking connectivity: $name ($host:$port)..."

  if timeout "$TIMEOUT" bash -c \
    "echo > /dev/tcp/$host/$port" 2>/dev/null; then
    log INFO "$name is reachable ✓"
  else
    log ERROR "$name is NOT reachable at $host:$port"
    log ERROR "Deployment cannot proceed — app will fail to start"
    exit 1
  fi
}

check_service_dependencies() {
  log INFO "Checking service dependencies..."

  check_tcp_connection "$DB_HOST"    "$DB_PORT"    "PostgreSQL"
  check_tcp_connection "$REDIS_HOST" "$REDIS_PORT" "Redis"

  log INFO "All service dependencies reachable ✓"
}

check_service_dependencies
```

**Output — Redis unreachable:**

```
[INFO ] Checking connectivity: PostgreSQL (prod-db.internal:5432)...
[INFO ] PostgreSQL is reachable ✓
[INFO ] Checking connectivity: Redis (prod-redis.internal:6379)...
[ERROR] Redis is NOT reachable at prod-redis.internal:6379
[ERROR] Deployment cannot proceed — app will fail to start
```

> ✅ Stops the deploy when a dependency is down — before the app starts and crashes immediately.

---

### Step 6 — Final Production-Ready Version

All preflight checks wired together into a single `run_preflight()` gate:

```bash
#!/bin/bash
# deploy.sh — Concepts 1–5 fully integrated
set -euo pipefail

# ─── Config (from Concept 4) ──────────────────────────
APP_NAME="myapp"
APP_PORT=3000
APP_DIR="/opt/$APP_NAME"
RELEASE_DIR="$APP_DIR/releases"
ARTIFACT_BUCKET="s3://prod-artifacts/$APP_NAME"
AWS_REGION="ap-south-1"
DB_HOST="prod-db.internal"
DB_PORT=5432
REDIS_HOST="prod-redis.internal"
REDIS_PORT=6379
MIN_FREE_MB=1024
ARTIFACT_SIZE_MB=500
HEALTH_CHECK_URL="http://localhost:$APP_PORT/health"
LOG_DIR="/var/log/$APP_NAME"
LOG_FILE="$LOG_DIR/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
TEMP_DIR="/tmp/$APP_NAME-$$"
LOCKFILE="/tmp/$APP_NAME.lock"

REQUIRED_BINARIES=(aws tar curl systemctl npm)

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
    echo "$entry" | tee -a "$LOG_FILE" >&2
  else
    echo "$entry" | tee -a "$LOG_FILE"
  fi
}

# ─── Error + Cleanup (Concept 3) ──────────────────────
handle_error() { log ERROR "Failed at line $1 — command: ${BASH_COMMAND}"; }
cleanup() {
  local exit_code=$?
  log INFO "Running cleanup..."
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" && log INFO "Temp dir removed"
  [[ -f "$LOCKFILE" ]] && rm -f  "$LOCKFILE" && log INFO "Lockfile removed"
  [[ $exit_code -ne 0 ]] \
    && log ERROR "Deployment FAILED — exit code $exit_code" \
    || log INFO  "Deployment completed successfully"
}
trap 'handle_error $LINENO' ERR
trap cleanup EXIT

# ─── Lockfile ─────────────────────────────────────────
[[ -f "$LOCKFILE" ]] && { log ERROR "Deploy already running"; exit 1; }
touch "$LOCKFILE"

# ─── Argument Parsing + Validation (Concept 2) ────────
ENV=""
VERSION=""
ROLLBACK=false

while getopts "e:v:rh" opt; do
  case $opt in
    e) ENV=$OPTARG     ;;
    v) VERSION=$OPTARG ;;
    r) ROLLBACK=true   ;;
    h) echo "Usage: $0 -e <env> -v <version> | -r"; exit 0 ;;
    *) exit 1          ;;
  esac
done

if ! $ROLLBACK; then
  [[ -z "$ENV"     ]] && { log ERROR "-e required"; exit 1; }
  [[ -z "$VERSION" ]] && { log ERROR "-v required"; exit 1; }
  [[ "$ENV" =~ ^(dev|staging|prod)$ ]] || { log ERROR "Invalid env: $ENV"; exit 1; }
fi

# ─── Preflight Checks (Concept 5) ─────────────────────
check_binaries() {
  log INFO "── Preflight: Binaries ──────────────────────"
  local missing=0
  for bin in "${REQUIRED_BINARIES[@]}"; do
    if command -v "$bin" &>/dev/null; then
      log DEBUG "$bin → $(command -v "$bin")"
    else
      log ERROR "Missing binary: $bin"
      missing=$((missing + 1))
    fi
  done
  [[ $missing -gt 0 ]] && { log ERROR "$missing binary/binaries missing"; exit 1; }
  log INFO "All binaries present ✓"
}

check_disk_space() {
  log INFO "── Preflight: Disk Space ────────────────────"
  local paths_and_sizes=(
    "/opt/$APP_NAME:$MIN_FREE_MB"
    "/tmp:$ARTIFACT_SIZE_MB"
  )
  for entry in "${paths_and_sizes[@]}"; do
    local path="${entry%%:*}"
    local required="${entry##*:}"
    mkdir -p "$path"
    local free_mb
    free_mb=$(( $(df "$path" | awk 'NR==2 {print $4}') / 1024 ))
    log INFO "$path — Free: ${free_mb}MB | Required: ${required}MB"
    if [[ $free_mb -lt $required ]]; then
      log ERROR "Insufficient disk space on $path (${free_mb}MB < ${required}MB)"
      exit 1
    fi
  done
  log INFO "Disk space checks passed ✓"
}

check_port() {
  log INFO "── Preflight: Port ──────────────────────────"
  if ss -tlnp | grep -q ":${APP_PORT}\\b"; then
    local pid process
    pid=$(ss -tlnp | grep ":${APP_PORT}\\b" | grep -oP 'pid=\K[0-9]+' | head -1)
    process=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    if [[ "$process" == "$APP_NAME" ]] || [[ "$process" == "node" ]]; then
      log INFO "Port $APP_PORT held by $APP_NAME — expected ✓"
    else
      log ERROR "Port $APP_PORT held by unexpected process: $process (PID $pid)"
      exit 1
    fi
  else
    log INFO "Port $APP_PORT is free ✓"
  fi
}

check_aws_access() {
  log INFO "── Preflight: AWS ───────────────────────────"
  if ! aws sts get-caller-identity --region "$AWS_REGION" &>/dev/null; then
    log ERROR "AWS credentials missing or expired"
    exit 1
  fi
  log INFO "AWS credentials valid ✓"

  if ! aws s3 ls "$ARTIFACT_BUCKET" --region "$AWS_REGION" &>/dev/null; then
    log ERROR "S3 bucket not accessible: $ARTIFACT_BUCKET"
    exit 1
  fi
  log INFO "S3 bucket accessible ✓"

  if ! $ROLLBACK; then
    local artifact_path="$ARTIFACT_BUCKET/$VERSION/app.tar.gz"
    if ! aws s3 ls "$artifact_path" --region "$AWS_REGION" &>/dev/null; then
      log ERROR "Artifact not found: $artifact_path"
      exit 1
    fi
    log INFO "Artifact exists ✓"
  fi
}

check_dependencies() {
  log INFO "── Preflight: Service Dependencies ──────────"
  local services=(
    "$DB_HOST:$DB_PORT:PostgreSQL"
    "$REDIS_HOST:$REDIS_PORT:Redis"
  )
  for svc in "${services[@]}"; do
    local host="${svc%%:*}"
    local rest="${svc#*:}"
    local port="${rest%%:*}"
    local name="${rest##*:}"
    if timeout 5 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
      log INFO "$name reachable ✓"
    else
      log ERROR "$name NOT reachable at $host:$port"
      exit 1
    fi
  done
  log INFO "All dependencies reachable ✓"
}

run_preflight() {
  log INFO "════ Starting Preflight Checks ═════════════"
  check_binaries
  check_disk_space
  check_port
  check_aws_access
  check_dependencies
  log INFO "════ All Preflight Checks Passed ═══════════"
}

# ─── Main ─────────────────────────────────────────────
mkdir -p "$TEMP_DIR"
run_preflight

if $ROLLBACK; then
  log WARN "Rollback mode — coming in Concept 7"
else
  log INFO "Environment : $ENV"
  log INFO "Version     : $VERSION"
  log INFO "Preflight passed — ready to deploy"
  # Artifact download + deployment logic — Concepts 6 & 7
fi
```

**Full preflight output — all green:**

```
[INFO ] ════ Starting Preflight Checks ═════════════
[INFO ] ── Preflight: Binaries ──────────────────────
[INFO ] All binaries present ✓
[INFO ] ── Preflight: Disk Space ────────────────────
[INFO ] /opt/myapp — Free: 4200MB | Required: 1024MB
[INFO ] /tmp       — Free: 8100MB | Required: 500MB
[INFO ] Disk space checks passed ✓
[INFO ] ── Preflight: Port ──────────────────────────
[INFO ] Port 3000 is free ✓
[INFO ] ── Preflight: AWS ───────────────────────────
[INFO ] AWS credentials valid ✓
[INFO ] S3 bucket accessible ✓
[INFO ] Artifact exists ✓
[INFO ] ── Preflight: Service Dependencies ──────────
[INFO ] PostgreSQL reachable ✓
[INFO ] Redis reachable ✓
[INFO ] All dependencies reachable ✓
[INFO ] ════ All Preflight Checks Passed ═══════════
[INFO ] Preflight passed — ready to deploy
```

---

## Mini Exercise for Participants

> **Task:** Add preflight checks to `backup.sh` from Concept 4:
>
> - Check that `aws`, `tar`, and `gzip` binaries are present
> - Check the backup destination has at least `MAX_SIZE_MB` free (from config)
> - Check that the S3 bucket from config is accessible
> - Check that the source directory (`-d` flag) actually exists and is readable
> - Wire all four into a single `run_preflight()` function

**Expected solution:**

```bash
run_preflight() {
  log INFO "════ Starting Preflight Checks ═════════════"

  # 1. Binaries
  for bin in aws tar gzip; do
    command -v "$bin" &>/dev/null || { log ERROR "Missing: $bin"; exit 1; }
    log INFO "$bin found ✓"
  done

  # 2. Disk space
  local free_mb
  free_mb=$(( $(df "$BACKUP_DIR" | awk 'NR==2 {print $4}') / 1024 ))
  [[ $free_mb -lt $MAX_SIZE_MB ]] && {
    log ERROR "Insufficient disk space: ${free_mb}MB < ${MAX_SIZE_MB}MB"
    exit 1
  }
  log INFO "Disk space: ${free_mb}MB available ✓"

  # 3. S3 access
  aws s3 ls "$S3_BUCKET" &>/dev/null || {
    log ERROR "S3 bucket not accessible: $S3_BUCKET"
    exit 1
  }
  log INFO "S3 bucket accessible ✓"

  # 4. Source directory
  [[ -d "$DIR" && -r "$DIR" ]] || {
    log ERROR "Source directory not found or not readable: $DIR"
    exit 1
  }
  log INFO "Source directory readable ✓"

  log INFO "════ All Preflight Checks Passed ═══════════"
}

run_preflight
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| Fail fast at the start | A pre-deploy failure is always safer than a mid-deploy failure |
| `command -v` for binary checks | Portable across all Linux distros — prefer over `which` |
| `df + awk` for disk space | Check both the release dir AND the temp/download dir |
| `ss -tlnp` for port check | Know if the port is free, ours, or stolen by another process |
| `aws sts get-caller-identity` | Fastest way to verify AWS credentials are valid |
| `/dev/tcp` for TCP checks | Built into bash — no `nc` or `telnet` required |
| Group into `run_preflight()` | One function to call — clean entry point, easy to extend |
| Check artifact before download | Know it's there before committing to the deployment |

---

## Preflight vs Validation — What's the Difference?

| | Validation (Concept 2) | Preflight (Concept 5) |
|---|---|---|
| **What it checks** | Script inputs (flags, args) | Environment & infrastructure |
| **When it runs** | Right after argument parsing | After validation, before any work |
| **Examples** | Is `-e` one of dev/staging/prod? | Is port 3000 free? Is S3 accessible? |
| **If it fails** | Bad user input — fix the command | Environment problem — fix the server |

---

## Project Structure So Far

```
myapp/
├── deploy.sh           # orchestrator — concepts 1–5 fully wired
├── log.sh              # reusable log() function
└── config/
    ├── dev.env
    ├── staging.env
    └── prod.env
```

---

## What's Next

**Concept 6 — Artifact Download & Extraction**  
With the preflight gate in place, we will now safely download the artifact from S3, verify its checksum, extract it into a versioned release directory, and link shared resources — knowing the environment is 100% ready before we touch a single file.