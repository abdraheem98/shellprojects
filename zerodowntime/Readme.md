# Concept 7 — Zero-Downtime Deployment & Rollback

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~25 minutes  
> **Prerequisite:** Concepts 1–6 must be complete

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Is Zero-Downtime Deployment?](#what-is-zero-downtime-deployment)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Atomic Symlink Swap](#step-1--atomic-symlink-swap)
  - [Step 2 — Service Reload vs Restart](#step-2--service-reload-vs-restart)
  - [Step 3 — Health Check with Retry Loop](#step-3--health-check-with-retry-loop)
  - [Step 4 — Automatic Rollback](#step-4--automatic-rollback)
  - [Step 5 — Release Cleanup](#step-5--release-cleanup)
  - [Step 6 — Final Production-Ready Version](#step-6--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners write

```bash
#!/bin/bash
set -euo pipefail

# Stop → deploy → start — classic downtime pattern
systemctl stop myapp
cp -r /tmp/release/* /opt/myapp/
systemctl start myapp
echo "Done"
```

**The problems with this:**

- ❌ `systemctl stop` → your app is DOWN while files are being copied
- ❌ If `cp` fails halfway, files are partially updated — app won't start
- ❌ No health check — script reports success even if app crashes on start
- ❌ No rollback — if anything goes wrong, manual recovery required
- ❌ Every deploy = downtime = users see errors = business loses money

### Real-world incident scenario

> A team deployed at 2PM on a weekday.  
> `systemctl stop myapp` ran fine.  
> `cp` failed midway — new config file was incompatible with old schema.  
> `systemctl start myapp` failed — partially updated files, crashed immediately.  
> Rolling back meant manually copying old files from a backup they barely maintained.  
> The app was down for **47 minutes** while 12,000 active users got 502 errors.  
>
> **An atomic symlink swap + auto-rollback would have recovered in under 30 seconds.**

---

## What Is Zero-Downtime Deployment?

Zero-downtime deployment means:

1. The new release is **fully prepared** before the live app is touched (done in Concept 6)
2. The **symlink swap** is atomic — the OS switches in one instruction
3. The service is **reloaded** (not stopped then started) — in-flight requests complete
4. A **health check** confirms the new version is serving traffic
5. If health check fails — **automatic rollback** in seconds, not minutes

The key insight:

> **`ln -sfn` is atomic at the OS level.**  
> The filesystem switches the pointer in a single operation.  
> There is no moment where `current` points to nothing.

---

## Build It Step by Step

### Step 1 — Atomic Symlink Swap

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_DIR="/opt/myapp"
CURRENT_LINK="$APP_DIR/current"
RELEASE_DIR="$APP_DIR/releases"

perform_symlink_swap() {
  local version=$1
  local release_path="$RELEASE_DIR/$version"

  # Verify the release directory is ready
  if [[ ! -d "$release_path" ]]; then
    log ERROR "Release directory not found: $release_path"
    log ERROR "Run prepare_release() from Concept 6 first"
    exit 1
  fi

  # Capture what current is pointing to before the swap
  local previous_release=""
  if [[ -L "$CURRENT_LINK" ]]; then
    previous_release=$(readlink "$CURRENT_LINK")
    log INFO "Current live release : $(basename "$previous_release")"
  else
    log INFO "No previous release found — this is a fresh deploy"
  fi

  log INFO "New release          : $version"
  log INFO "Performing symlink swap..."

  # ln -sfn is atomic — no downtime window
  # -s = symbolic link
  # -f = force (overwrite existing)
  # -n = treat destination as normal file if symlink
  ln -sfn "$release_path" "$CURRENT_LINK"

  # Verify the swap
  local live_release
  live_release=$(readlink "$CURRENT_LINK")

  if [[ "$live_release" != "$release_path" ]]; then
    log ERROR "Symlink swap failed — current still points to: $live_release"
    exit 1
  fi

  log INFO "Symlink swap complete ✓"
  log INFO "  Before : ${previous_release:-none}"
  log INFO "  After  : $release_path"

  echo "$previous_release"   # return previous for rollback use
}

PREVIOUS=$(perform_symlink_swap "1.4.2")
```

**Output:**

```
[INFO ] Current live release : 1.4.1
[INFO ] New release          : 1.4.2
[INFO ] Performing symlink swap...
[INFO ] Symlink swap complete ✓
[INFO ]   Before : /opt/myapp/releases/1.4.1
[INFO ]   After  : /opt/myapp/releases/1.4.2
```

**Verify on the server:**

```bash
ls -la /opt/myapp/current
# current -> /opt/myapp/releases/1.4.2
```

> ✅ The switch happens in one atomic OS instruction. Zero downtime.

---

### Step 2 — Service Reload vs Restart

After the symlink swap, the service must pick up the new code:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_NAME="myapp"

reload_service() {
  log INFO "Reloading service: $APP_NAME"

  # reload-or-restart:
  #   → if service supports reload (SIGHUP): in-flight requests complete
  #   → if not: falls back to full restart
  if systemctl reload-or-restart "$APP_NAME"; then
    log INFO "Service reloaded ✓"
  else
    log ERROR "Service reload failed"
    exit 1
  fi

  # Give the process a moment to initialize
  sleep 2

  # Verify the service is actually running after reload
  if ! systemctl is-active --quiet "$APP_NAME"; then
    local status
    status=$(systemctl status "$APP_NAME" --no-pager 2>&1 | head -20)
    log ERROR "Service is not running after reload"
    log ERROR "systemctl status output:"
    log ERROR "$status"
    exit 1
  fi

  log INFO "Service is active and running ✓"
}

reload_service
```

**Reload vs Restart — explain the difference:**

| Action | What Happens | In-Flight Requests | Downtime |
|---|---|---|---|
| `systemctl stop` + `start` | Full stop, then start | ❌ Dropped | Yes |
| `systemctl restart` | Kill + start | ❌ Dropped | Brief |
| `systemctl reload` | SIGHUP — graceful | ✅ Complete | Zero |
| `reload-or-restart` | Reload if supported, else restart | ✅ Best effort | Minimal |

> ✅ `reload-or-restart` is the safest choice — tries graceful first, falls back if needed.

---

### Step 3 — Health Check with Retry Loop

Never trust the service reload alone — verify the app is actually serving traffic:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_PORT=3000
HEALTH_CHECK_URL="http://localhost:$APP_PORT/health"
HEALTH_CHECK_RETRIES=12
HEALTH_CHECK_DELAY=5
EXPECTED_VERSION=""    # optional — verify specific version is live

run_health_check() {
  local version=$1
  log INFO "Running health check: $HEALTH_CHECK_URL"
  log INFO "Retries: $HEALTH_CHECK_RETRIES | Delay: ${HEALTH_CHECK_DELAY}s"

  local attempt=0
  local http_code response

  until [[ $attempt -ge $HEALTH_CHECK_RETRIES ]]; do
    attempt=$(( attempt + 1 ))
    log INFO "Health check attempt $attempt/$HEALTH_CHECK_RETRIES..."

    # -s  = silent
    # -f  = fail on HTTP 4xx/5xx
    # -o  = output response body to variable
    # -w  = write http status code
    # --max-time = timeout per request
    http_code=$(curl -sf \
      --max-time 10 \
      --output /tmp/health_response.json \
      --write-out "%{http_code}" \
      "$HEALTH_CHECK_URL" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
      log INFO "Health check passed — HTTP $http_code ✓"

      # Optional: verify version in response body
      if [[ -f /tmp/health_response.json ]]; then
        local live_version
        live_version=$(jq -r '.version // empty' /tmp/health_response.json 2>/dev/null || echo "")
        if [[ -n "$live_version" ]]; then
          log INFO "Live version confirmed: $live_version"
          if [[ "$live_version" != "$version" ]]; then
            log WARN "Version mismatch — expected $version, got $live_version"
          fi
        fi
      fi

      return 0    # health check passed

    elif [[ "$http_code" == "000" ]]; then
      log WARN "Attempt $attempt: no response (app may still be starting)"
    else
      log WARN "Attempt $attempt: HTTP $http_code — app not healthy yet"
    fi

    [[ $attempt -lt $HEALTH_CHECK_RETRIES ]] && sleep "$HEALTH_CHECK_DELAY"
  done

  # All retries exhausted
  log ERROR "Health check FAILED after $HEALTH_CHECK_RETRIES attempts"
  log ERROR "App is not responding at $HEALTH_CHECK_URL"
  return 1    # caller will trigger rollback
}

# Call — if it returns non-zero, rollback
if ! run_health_check "1.4.2"; then
  log ERROR "Health check failed — triggering rollback"
  # rollback() called in Step 4
fi
```

**Output — healthy:**

```
[INFO ] Health check attempt 1/12... HTTP 200 ✓
[INFO ] Live version confirmed: 1.4.2
```

**Output — app slow to start:**

```
[WARN ] Attempt 1: no response (app may still be starting)
[WARN ] Attempt 2: HTTP 503 — app not healthy yet
[WARN ] Attempt 3: HTTP 503 — app not healthy yet
[INFO ] Health check attempt 4/12... HTTP 200 ✓
```

**Output — all retries exhausted:**

```
[WARN ] Attempt 1: no response
[WARN ] Attempt 2: no response
...
[ERROR] Health check FAILED after 12 attempts
[ERROR] App is not responding at http://localhost:3000/health
```

> ✅ Waits patiently for slow starts. Fails loudly when the app is genuinely broken.

---

### Step 4 — Automatic Rollback

If the health check fails — roll back to the previous release automatically:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_NAME="myapp"
APP_DIR="/opt/myapp"
CURRENT_LINK="$APP_DIR/current"
RELEASE_DIR="$APP_DIR/releases"

rollback() {
  local failed_version=${1:-"unknown"}

  log WARN "════ Initiating Rollback ════════════════════"
  log WARN "Failed release: $failed_version"

  # Find previous release — sorted by modification time
  local releases
  releases=($(ls -dt "$RELEASE_DIR"/*/))

  if [[ ${#releases[@]} -lt 2 ]]; then
    log ERROR "No previous release to roll back to"
    log ERROR "Manual intervention required"
    exit 1
  fi

  # releases[0] = current (failed), releases[1] = previous
  local previous_release
  previous_release="${releases[1]}"
  local previous_version
  previous_version=$(basename "$previous_release")

  log WARN "Rolling back to: $previous_version"

  # Swap symlink back to previous release
  ln -sfn "$previous_release" "$CURRENT_LINK"
  log WARN "Symlink restored to: $previous_version"

  # Reload service with previous release
  systemctl reload-or-restart "$APP_NAME"
  log WARN "Service reloaded with previous release"

  # Verify rollback health
  local attempt=0
  until [[ $attempt -ge 6 ]]; do
    attempt=$(( attempt + 1 ))
    if curl -sf --max-time 10 \
      "http://localhost:3000/health" &>/dev/null; then
      log WARN "Rollback health check passed ✓"
      log WARN "════ Rollback Complete: $previous_version is live ════"
      return 0
    fi
    sleep 5
  done

  log ERROR "Rollback health check also failed"
  log ERROR "CRITICAL: Both new and previous releases are broken"
  log ERROR "Manual intervention required immediately"
  exit 1
}

rollback_if_failed() {
  local version=$1
  local previous=$2

  if ! run_health_check "$version"; then
    rollback "$version"
    # Exit with failure so CI/CD pipeline marks the build red
    exit 1
  fi
}
```

**Output — rollback triggered:**

```
[ERROR] Health check FAILED after 12 attempts
[WARN ] ════ Initiating Rollback ════════════════════
[WARN ] Failed release: 1.4.2
[WARN ] Rolling back to: 1.4.1
[WARN ] Symlink restored to: 1.4.1
[WARN ] Service reloaded with previous release
[WARN ] Rollback health check passed ✓
[WARN ] ════ Rollback Complete: 1.4.1 is live ════
```

**This is the sequence participants should understand:**

```
Deploy starts
    │
    ▼
prepare_release()     ← Concept 6 (files, deps, symlinks)
    │
    ▼
perform_symlink_swap() ← current → 1.4.2  (atomic)
    │
    ▼
reload_service()       ← graceful reload
    │
    ▼
run_health_check()
    │
    ├── PASS ──→ cleanup old releases → notify Slack → exit 0  ✅
    │
    └── FAIL ──→ rollback() → current → 1.4.1 → reload → verify → exit 1  ⚠️
```

> ✅ Rollback is automatic, fast, and tested — not a 3AM manual scramble.

---

### Step 5 — Release Cleanup

After a successful deploy, remove old releases to prevent disk filling up:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

RELEASE_DIR="/opt/myapp/releases"
KEEP_RELEASES=5

cleanup_old_releases() {
  log INFO "Cleaning up old releases (keeping last $KEEP_RELEASES)..."

  # List releases sorted newest first
  local all_releases
  all_releases=($(ls -dt "$RELEASE_DIR"/*/))

  local total=${#all_releases[@]}

  if [[ $total -le $KEEP_RELEASES ]]; then
    log INFO "Only $total releases exist — no cleanup needed"
    return 0
  fi

  local to_delete=$(( total - KEEP_RELEASES ))
  log INFO "Total releases: $total | Keeping: $KEEP_RELEASES | Deleting: $to_delete"

  # Delete the oldest releases (last N in the sorted list)
  local deleted=0
  for release in "${all_releases[@]:$KEEP_RELEASES}"; do
    local version
    version=$(basename "$release")
    log INFO "Removing old release: $version"
    rm -rf "$release"
    deleted=$(( deleted + 1 ))
  done

  log INFO "Cleanup complete — removed $deleted old release(s) ✓"
}

cleanup_old_releases
```

**Output — cleanup after 6th deploy:**

```
[INFO ] Total releases: 6 | Keeping: 5 | Deleting: 1
[INFO ] Removing old release: 1.3.9
[INFO ] Cleanup complete — removed 1 old release(s) ✓
```

**Disk usage before and after:**

```bash
du -sh /opt/myapp/releases/*
# 487M  1.4.0    ← deleted
# 487M  1.4.1
# 487M  1.4.2
# 487M  1.4.3
# 487M  1.4.4
# 487M  1.4.5    ← newest
```

> ✅ Always have the last 5 releases available for rollback — never more than needed.

---

### Step 6 — Final Production-Ready Version

The complete deployment pipeline — all 7 concepts in one script:

```bash
#!/bin/bash
# deploy.sh — Complete production deployment pipeline
# Concepts 1–7 fully integrated
#
# Usage: ./deploy.sh -e <environment> -v <version>
#        ./deploy.sh -r   (rollback to previous release)

set -euo pipefail

# ─── Config ───────────────────────────────────────────
APP_NAME="myapp"
APP_PORT=3000
APP_DIR="/opt/$APP_NAME"
RELEASE_DIR="$APP_DIR/releases"
SHARED_DIR="$APP_DIR/shared"
CURRENT_LINK="$APP_DIR/current"
ARTIFACT_BUCKET="s3://prod-artifacts/$APP_NAME"
AWS_REGION="ap-south-1"
KEEP_RELEASES=5
HEALTH_CHECK_URL="http://localhost:$APP_PORT/health"
HEALTH_CHECK_RETRIES=12
HEALTH_CHECK_DELAY=5
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LOG_DIR="/var/log/$APP_NAME"
LOG_FILE="$LOG_DIR/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
TEMP_DIR="/tmp/$APP_NAME-$$"
LOCKFILE="/tmp/$APP_NAME.lock"
NODE_ENV="production"
SHARED_RESOURCES=(.env uploads storage logs)
REQUIRED_BINARIES=(aws tar curl systemctl npm jq)

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

# ─── Notifications ────────────────────────────────────
notify() {
  local message=$1
  log INFO "$message"
  [[ -z "$SLACK_WEBHOOK" ]] && return 0
  curl -sf -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    -d "{\"text\":\"$APP_NAME | $HOSTNAME | $message\"}" > /dev/null || true
}

# ─── Error + Cleanup (Concept 3) ──────────────────────
handle_error() { log ERROR "Failed at line $1 — command: ${BASH_COMMAND}"; }
cleanup() {
  local exit_code=$?
  log INFO "Running cleanup..."
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" && log INFO "Temp dir removed"
  [[ -f "$LOCKFILE" ]] && rm -f  "$LOCKFILE" && log INFO "Lockfile removed"
  [[ $exit_code -ne 0 ]] \
    && notify "❌ Deployment FAILED — check logs: $LOG_FILE" \
    || notify "✅ Deployment successful"
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
usage() {
  echo ""
  echo "  Usage: $(basename "$0") [OPTIONS]"
  echo ""
  echo "  Options:"
  echo "    -e <environment>   Target: dev | staging | prod"
  echo "    -v <version>       Version: e.g. 1.4.2"
  echo "    -r                 Rollback to previous release"
  echo "    -h                 Show help"
  echo ""
  exit 0
}
while getopts "e:v:rh" opt; do
  case $opt in
    e) ENV=$OPTARG ;;  v) VERSION=$OPTARG ;;
    r) ROLLBACK=true ;; h) usage ;; *) usage ;;
  esac
done
if ! $ROLLBACK; then
  [[ -z "$ENV"     ]] && { log ERROR "-e required"; exit 1; }
  [[ -z "$VERSION" ]] && { log ERROR "-v required"; exit 1; }
  [[ "$ENV" =~ ^(dev|staging|prod)$ ]] || { log ERROR "Invalid env: $ENV"; exit 1; }
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]] || {
    log ERROR "Invalid version: $VERSION"; exit 1
  }
fi

# ─── Preflight (Concept 5) ────────────────────────────
run_preflight() {
  log INFO "════ Preflight Checks ═══════════════════════"
  local missing=0
  for bin in "${REQUIRED_BINARIES[@]}"; do
    command -v "$bin" &>/dev/null || { log ERROR "Missing binary: $bin"; missing=$((missing+1)); }
  done
  [[ $missing -gt 0 ]] && exit 1
  log INFO "All binaries present ✓"
  if ! $ROLLBACK; then
    local free_mb
    free_mb=$(( $(df "$APP_DIR" 2>/dev/null || df /opt | awk 'NR==2 {print $4}') / 1024 ))
    [[ $free_mb -lt 1024 ]] && { log ERROR "Insufficient disk: ${free_mb}MB"; exit 1; }
    log INFO "Disk space: ${free_mb}MB ✓"
    aws sts get-caller-identity --region "$AWS_REGION" &>/dev/null || {
      log ERROR "AWS credentials invalid"; exit 1
    }
    log INFO "AWS credentials valid ✓"
    aws s3 ls "$ARTIFACT_BUCKET/$VERSION/app.tar.gz" \
      --region "$AWS_REGION" &>/dev/null || {
      log ERROR "Artifact not found: $VERSION"; exit 1
    }
    log INFO "Artifact exists ✓"
  fi
  log INFO "════ Preflight Passed ═══════════════════════"
}

# ─── Artifact Management (Concept 6) ──────────────────
prepare_release() {
  local version=$1
  local artifact_local="$TEMP_DIR/app.tar.gz"
  local release_path="$RELEASE_DIR/$version"

  mkdir -p "$TEMP_DIR"
  log INFO "════ Preparing Release: v$version ══════════"

  # Download
  log INFO "── Downloading Artifact ─────────────────────"
  aws s3 cp "$ARTIFACT_BUCKET/$version/app.tar.gz" "$artifact_local" \
    --region "$AWS_REGION" --no-progress
  [[ -s "$artifact_local" ]] || { log ERROR "Empty download"; exit 1; }
  log INFO "Downloaded ✓"

  # Checksum
  log INFO "── Verifying Checksum ───────────────────────"
  local checksum_local="$TEMP_DIR/app.tar.gz.sha256"
  if aws s3 cp "$ARTIFACT_BUCKET/$version/app.tar.gz.sha256" \
    "$checksum_local" --region "$AWS_REGION" --no-progress 2>/dev/null; then
    local hash
    hash=$(awk '{print $1}' "$checksum_local")
    echo "$hash  app.tar.gz" > "$checksum_local"
    (cd "$TEMP_DIR" && sha256sum -c app.tar.gz.sha256 --status) || {
      log ERROR "Checksum failed — aborting"; exit 1
    }
    log INFO "Checksum verified ✓"
  else
    log WARN "No checksum file — skipping"
  fi

  # Extract
  log INFO "── Extracting Artifact ──────────────────────"
  [[ -d "$release_path" ]] && rm -rf "$release_path"
  mkdir -p "$release_path"
  tar -xzf "$artifact_local" -C "$release_path" --strip-components=1 || {
    rm -rf "$release_path"; log ERROR "Extraction failed"; exit 1
  }
  local file_count
  file_count=$(find "$release_path" -type f | wc -l)
  log INFO "$file_count files extracted ✓"

  # Shared resources
  log INFO "── Linking Shared Resources ─────────────────"
  mkdir -p "$SHARED_DIR"
  for res in .env uploads storage logs; do
    [[ -e "$SHARED_DIR/$res" ]] || { [[ "$res" == ".env" ]] && touch "$SHARED_DIR/$res" || mkdir -p "$SHARED_DIR/$res"; }
    local link="$release_path/$res"
    [[ -e "$link" || -L "$link" ]] && rm -rf "$link"
    ln -sfn "$SHARED_DIR/$res" "$link"
  done
  log INFO "Shared resources linked ✓"

  # Dependencies
  log INFO "── Installing Dependencies ──────────────────"
  if [[ -f "$release_path/package.json" ]]; then
    cd "$release_path"
    NODE_ENV="$NODE_ENV" npm ci --production 2>&1 | tee -a "$LOG_FILE"
    log INFO "Dependencies installed ✓"
  else
    log WARN "No package.json found — skipping npm ci"
  fi

  log INFO "════ Release v$version Ready ════════════════"
}

# ─── Health Check (Concept 7) ─────────────────────────
run_health_check() {
  log INFO "── Health Check ─────────────────────────────"
  local attempt=0 http_code

  until [[ $attempt -ge $HEALTH_CHECK_RETRIES ]]; do
    attempt=$(( attempt + 1 ))
    http_code=$(curl -sf --max-time 10 \
      --output /tmp/health_response.json \
      --write-out "%{http_code}" \
      "$HEALTH_CHECK_URL" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
      log INFO "Health check passed — HTTP $http_code ✓"
      return 0
    fi

    log WARN "Attempt $attempt/$HEALTH_CHECK_RETRIES — HTTP $http_code"
    [[ $attempt -lt $HEALTH_CHECK_RETRIES ]] && sleep "$HEALTH_CHECK_DELAY"
  done

  log ERROR "Health check FAILED after $HEALTH_CHECK_RETRIES attempts"
  return 1
}

# ─── Rollback (Concept 7) ─────────────────────────────
rollback() {
  local failed_version=${1:-"unknown"}
  log WARN "════ Initiating Rollback ════════════════════"
  notify "⚠️ Rolling back from $failed_version"

  local releases
  releases=($(ls -dt "$RELEASE_DIR"/*/))

  if [[ ${#releases[@]} -lt 2 ]]; then
    log ERROR "No previous release to roll back to"
    exit 1
  fi

  local previous_path="${releases[1]}"
  local previous_version
  previous_version=$(basename "$previous_path")

  log WARN "Restoring: $previous_version"
  ln -sfn "$previous_path" "$CURRENT_LINK"
  systemctl reload-or-restart "$APP_NAME"

  local attempt=0
  until [[ $attempt -ge 6 ]]; do
    attempt=$(( attempt + 1 ))
    curl -sf --max-time 10 "$HEALTH_CHECK_URL" &>/dev/null && {
      log WARN "Rollback successful — $previous_version is live ✓"
      notify "⚠️ Rollback complete: $previous_version is live"
      log WARN "════ Rollback Complete ══════════════════════"
      return 0
    }
    sleep 5
  done

  log ERROR "CRITICAL: Rollback health check failed"
  log ERROR "Manual intervention required immediately"
  notify "🚨 CRITICAL: Rollback also failed — manual fix required"
  exit 1
}

# ─── Cutover (Concept 7) ──────────────────────────────
perform_cutover() {
  local version=$1
  log INFO "════ Performing Cutover: v$version ══════════"

  # Capture previous release before swap
  local previous=""
  [[ -L "$CURRENT_LINK" ]] && previous=$(readlink "$CURRENT_LINK")

  # Atomic symlink swap
  log INFO "── Symlink Swap ─────────────────────────────"
  ln -sfn "$RELEASE_DIR/$version" "$CURRENT_LINK"
  log INFO "Swap complete — current → $version ✓"

  # Reload service
  log INFO "── Service Reload ───────────────────────────"
  systemctl reload-or-restart "$APP_NAME"
  sleep 2
  systemctl is-active --quiet "$APP_NAME" || {
    log ERROR "Service not active after reload"
    rollback "$version"
    exit 1
  }
  log INFO "Service active ✓"

  # Health check — auto rollback on failure
  if ! run_health_check; then
    rollback "$version"
    exit 1
  fi

  log INFO "════ Cutover Complete — v$version is live ═══"
}

# ─── Release Cleanup (Concept 7) ──────────────────────
cleanup_old_releases() {
  log INFO "── Cleaning Up Old Releases ─────────────────"
  local all_releases
  all_releases=($(ls -dt "$RELEASE_DIR"/*/))
  local total=${#all_releases[@]}

  if [[ $total -le $KEEP_RELEASES ]]; then
    log INFO "Only $total releases — no cleanup needed"
    return 0
  fi

  local deleted=0
  for release in "${all_releases[@]:$KEEP_RELEASES}"; do
    log INFO "Removing: $(basename "$release")"
    rm -rf "$release"
    deleted=$(( deleted + 1 ))
  done
  log INFO "Removed $deleted old release(s) ✓"
}

# ─── Main Entrypoint ──────────────────────────────────
mkdir -p "$TEMP_DIR" "$RELEASE_DIR" "$SHARED_DIR"
run_preflight

if $ROLLBACK; then
  rollback "manual"
else
  notify "🚀 Deploy started: v$VERSION → $ENV"
  prepare_release "$VERSION"
  perform_cutover "$VERSION"
  cleanup_old_releases
  notify "✅ Deploy complete: v$VERSION is live on $ENV"
fi
```

---

## Full End-to-End Output — Successful Deploy

```
[INFO ] ════ Preflight Checks ═══════════════════════
[INFO ] All binaries present ✓
[INFO ] Disk space: 4300MB ✓
[INFO ] AWS credentials valid ✓
[INFO ] Artifact exists ✓
[INFO ] ════ Preflight Passed ═══════════════════════
[INFO ] ════ Preparing Release: v1.4.2 ══════════════
[INFO ] ── Downloading Artifact ─────────────────────
[INFO ] Downloaded ✓
[INFO ] ── Verifying Checksum ───────────────────────
[INFO ] Checksum verified ✓
[INFO ] ── Extracting Artifact ──────────────────────
[INFO ] 847 files extracted ✓
[INFO ] ── Linking Shared Resources ─────────────────
[INFO ] Shared resources linked ✓
[INFO ] ── Installing Dependencies ──────────────────
[INFO ] Dependencies installed ✓
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
[INFO ] Removing: 1.3.9
[INFO ] Removed 1 old release(s) ✓
[INFO ] Running cleanup...
[INFO ] Temp dir removed
[INFO ] Lockfile removed
[INFO ] Deployment completed successfully
```

---

## Mini Exercise for Participants

> **Task:** Add cutover and rollback to `backup.sh` from Concept 6:
>
> - After extraction, atomically swap `$BACKUP_DIR/latest` symlink to new backup
> - Verify the backup directory is non-empty after the swap (health check equivalent)
> - If verification fails, roll back `latest` to the previous backup directory
> - Clean up backups older than `RETENTION_DAYS` (from config)

**Expected solution:**

```bash
perform_backup_cutover() {
  local new_backup=$1
  local previous=""

  [[ -L "$BACKUP_DIR/latest" ]] && previous=$(readlink "$BACKUP_DIR/latest")

  log INFO "Swapping latest → $new_backup"
  ln -sfn "$new_backup" "$BACKUP_DIR/latest"

  # Verify
  local file_count
  file_count=$(find "$BACKUP_DIR/latest" -type f | wc -l)

  if [[ $file_count -eq 0 ]]; then
    log ERROR "Backup verification failed — no files found"
    if [[ -n "$previous" ]]; then
      log WARN "Restoring previous backup: $previous"
      ln -sfn "$previous" "$BACKUP_DIR/latest"
    fi
    exit 1
  fi

  log INFO "Backup verified — $file_count files ✓"
}

cleanup_old_backups() {
  log INFO "Cleaning up backups older than $RETENTION_DAYS days..."
  find "$BACKUP_DIR" -maxdepth 1 -type d \
    -mtime "+$RETENTION_DAYS" \
    ! -name "$(basename "$(readlink "$BACKUP_DIR/latest")")" \
    -exec rm -rf {} + \
    && log INFO "Old backups removed ✓"
}
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| `ln -sfn` is atomic | The OS switches the pointer in one instruction — zero downtime |
| `reload-or-restart` | Graceful reload preserves in-flight requests — always prefer over restart |
| Health check retry loop | Patience for slow starts + loud failure when genuinely broken |
| Auto-rollback on failure | Recovery in seconds, not minutes — never rely on manual rollback |
| Rollback health check | Always verify rollback worked — don't assume |
| `KEEP_RELEASES=5` | Enough history for rollback — not so much that disk fills up |
| Notify on every outcome | Success AND failure — on-call engineers need both |
| Exit non-zero after rollback | CI/CD pipeline must know the deploy failed even if rollback succeeded |

---

## Complete Project Structure

```
myapp/
├── deploy.sh              # complete pipeline — all 7 concepts
├── log.sh                 # reusable log() function
└── config/
    ├── dev.env
    ├── staging.env
    └── prod.env
```

## The Complete Deployment Flow

```
./deploy.sh -e prod -v 1.4.2
       │
       ├── Concept 2 → Parse & validate args
       ├── Concept 3 → Set traps, create lockfile
       ├── Concept 4 → Load prod.env config
       ├── Concept 5 → Preflight gate
       ├── Concept 6 → Download → checksum → extract → link → npm ci
       └── Concept 7 → Symlink swap → reload → health check
                              │
                    PASS ─────┴───── FAIL
                      │                │
               Cleanup old        Rollback to
               releases           previous release
                      │                │
               Slack ✅          Slack ⚠️ + exit 1
```

---

## What's Next

**Concept 8 — Log Parsing & Rotation**  
With the deployment pipeline complete, we now focus on what happens after —  
parsing nginx and app logs for errors, slow responses, and anomalies,  
rotating logs by size and age, and shipping structured logs to CloudWatch or ELK.