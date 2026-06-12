# Concept 6 — Artifact Download & Extraction

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~20 minutes  
> **Prerequisite:** Concepts 1–5 must be complete

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Is Artifact Management?](#what-is-artifact-management)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Download from S3](#step-1--download-from-s3)
  - [Step 2 — Checksum Verification](#step-2--checksum-verification)
  - [Step 3 — Extract into Versioned Directory](#step-3--extract-into-versioned-directory)
  - [Step 4 — Link Shared Resources](#step-4--link-shared-resources)
  - [Step 5 — Install Dependencies](#step-5--install-dependencies)
  - [Step 6 — Final Production-Ready Version](#step-6--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners write

```bash
#!/bin/bash
set -euo pipefail

# Download and deploy in one messy block
aws s3 cp s3://prod-artifacts/myapp/app.tar.gz /opt/myapp/
cd /opt/myapp
tar -xzf app.tar.gz
npm install
systemctl restart myapp
```

**The problems with this:**

- ❌ Every deploy overwrites the same directory — no version history, no rollback possible
- ❌ No checksum verification — corrupt artifact deploys silently
- ❌ `npm install` in the live directory — installs mid-traffic, causes race conditions
- ❌ `.env` and `uploads/` get wiped on every deploy
- ❌ No cleanup of old downloads — `/tmp` fills up over time
- ❌ If extraction fails halfway, the live directory is corrupt

### Real-world incident scenario

> A team's deploy script overwrote `/opt/myapp` directly.  
> A network blip corrupted the artifact mid-download.  
> `tar` partially extracted over the running app files.  
> The service restarted with a mix of old and new files.  
> The app served inconsistent responses for 45 minutes  
> before someone noticed and manually restored from backup.
>
> **A versioned release directory and checksum verification  
> would have caught the corrupt artifact before a single file was touched.**

---

## What Is Artifact Management?

Artifact management means:

1. **Download to a temp location** — never directly to the live directory
2. **Verify integrity** — checksum before extraction
3. **Extract to a versioned directory** — `/releases/1.4.2/` not `/current/`
4. **Link shared resources** — `.env`, `uploads/`, `logs/` persist across releases
5. **Install dependencies in isolation** — inside the release dir, not live
6. **Atomic cutover** — symlink swap happens in Concept 7 (zero-downtime)

The pattern looks like this:

```
/opt/myapp/
├── releases/
│   ├── 1.4.0/          ← old release (kept for rollback)
│   ├── 1.4.1/          ← previous release
│   └── 1.4.2/          ← new release (being prepared)
│       ├── app.js
│       ├── node_modules/
│       ├── .env         → symlink to shared/.env
│       └── uploads/     → symlink to shared/uploads/
├── shared/
│   ├── .env            ← persists across ALL releases
│   └── uploads/        ← persists across ALL releases
└── current             → symlink to releases/1.4.2/ (set in Concept 7)
```

---

## Build It Step by Step

### Step 1 — Download from S3

Download to a temp location first — never directly to the release directory:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_NAME="myapp"
ARTIFACT_BUCKET="s3://prod-artifacts/$APP_NAME"
AWS_REGION="ap-south-1"
TEMP_DIR="/tmp/$APP_NAME-$$"

download_artifact() {
  local version=$1
  local artifact_key="$version/app.tar.gz"
  local artifact_path="$ARTIFACT_BUCKET/$artifact_key"
  local local_path="$TEMP_DIR/app.tar.gz"

  mkdir -p "$TEMP_DIR"

  log INFO "Downloading artifact: $artifact_path"
  log INFO "Destination        : $local_path"

  # --no-progress suppresses the progress bar in CI logs
  if ! aws s3 cp "$artifact_path" "$local_path" \
    --region "$AWS_REGION" \
    --no-progress; then
    log ERROR "Download failed: $artifact_path"
    exit 1
  fi

  # Verify the file was actually written and is not empty
  if [[ ! -s "$local_path" ]]; then
    log ERROR "Downloaded file is empty: $local_path"
    exit 1
  fi

  local size_mb
  size_mb=$(du -m "$local_path" | cut -f1)
  log INFO "Download complete — size: ${size_mb}MB ✓"

  echo "$local_path"    # return the local path for next step
}

ARTIFACT_LOCAL=$(download_artifact "1.4.2")
log INFO "Artifact ready at: $ARTIFACT_LOCAL"
```

**Output:**

```
[INFO ] Downloading artifact: s3://prod-artifacts/myapp/1.4.2/app.tar.gz
[INFO ] Destination         : /tmp/myapp-12345/app.tar.gz
[INFO ] Download complete — size: 487MB ✓
[INFO ] Artifact ready at: /tmp/myapp-12345/app.tar.gz
```

> ✅ Artifact sits safely in `/tmp` — live directory completely untouched.

---

### Step 2 — Checksum Verification

Always verify the artifact's integrity before extraction.  
A corrupt download should **never** reach your release directory:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

ARTIFACT_BUCKET="s3://prod-artifacts/myapp"
AWS_REGION="ap-south-1"

verify_checksum() {
  local artifact_path=$1     # local path of downloaded artifact
  local version=$2

  log INFO "Verifying artifact checksum..."

  # Download the expected checksum file from S3
  # Convention: artifact is app.tar.gz, checksum is app.tar.gz.sha256
  local checksum_remote="$ARTIFACT_BUCKET/$version/app.tar.gz.sha256"
  local checksum_local="$TEMP_DIR/app.tar.gz.sha256"

  if ! aws s3 cp "$checksum_remote" "$checksum_local" \
    --region "$AWS_REGION" \
    --no-progress 2>/dev/null; then
    log WARN "No checksum file found in S3 — skipping verification"
    log WARN "Consider adding checksum generation to your build pipeline"
    return 0
  fi

  log INFO "Checksum file downloaded: $checksum_local"

  # sha256sum -c verifies the file against the expected hash
  # The .sha256 file format: "<hash>  <filename>"
  # We need to run it from the same directory as the artifact
  local artifact_dir
  artifact_dir=$(dirname "$artifact_path")
  local artifact_name
  artifact_name=$(basename "$artifact_path")

  # Rewrite the checksum file to use just the filename (not full path)
  local expected_hash
  expected_hash=$(awk '{print $1}' "$checksum_local")
  echo "$expected_hash  $artifact_name" > "$checksum_local"

  if ! (cd "$artifact_dir" && sha256sum -c "$checksum_local" --status); then
    log ERROR "Checksum verification FAILED"
    log ERROR "Expected : $expected_hash"
    log ERROR "Got      : $(sha256sum "$artifact_path" | awk '{print $1}')"
    log ERROR "Artifact may be corrupt or tampered with — aborting"
    exit 1
  fi

  log INFO "Checksum verified ✓ ($expected_hash)"
}

verify_checksum "$ARTIFACT_LOCAL" "1.4.2"
```

**Output — checksum mismatch:**

```
[ERROR] Checksum verification FAILED
[ERROR] Expected : a3f1b2c4d5e6...
[ERROR] Got      : 000000000000...
[ERROR] Artifact may be corrupt or tampered with — aborting
```

**Output — checksum passed:**

```
[INFO ] Checksum file downloaded: /tmp/myapp-12345/app.tar.gz.sha256
[INFO ] Checksum verified ✓ (a3f1b2c4d5e67890abcdef1234567890abcdef1234567890abcdef1234567890)
```

**How to generate the checksum in your build pipeline:**

```bash
# In your CI/CD pipeline (GitHub Actions / Jenkins) — add this after build
sha256sum app.tar.gz > app.tar.gz.sha256
aws s3 cp app.tar.gz       s3://prod-artifacts/myapp/1.4.2/
aws s3 cp app.tar.gz.sha256 s3://prod-artifacts/myapp/1.4.2/
```

> ✅ Corrupt or tampered artifacts never reach your server.

---

### Step 3 — Extract into Versioned Directory

Each release gets its own directory — never extract over an existing one:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_DIR="/opt/myapp"
RELEASE_DIR="$APP_DIR/releases"

extract_artifact() {
  local artifact_path=$1
  local version=$2
  local release_path="$RELEASE_DIR/$version"

  # Never overwrite an existing release
  if [[ -d "$release_path" ]]; then
    log WARN "Release directory already exists: $release_path"
    log WARN "Removing and re-extracting..."
    rm -rf "$release_path"
  fi

  mkdir -p "$release_path"
  log INFO "Extracting artifact to: $release_path"

  # -C extracts into the target directory
  # --strip-components=1 removes the top-level folder inside the tarball
  # (common pattern: tar contains myapp-1.4.2/ wrapper folder)
  if ! tar -xzf "$artifact_path" \
    -C "$release_path" \
    --strip-components=1 2>&1 | tee -a "$LOG_FILE"; then
    log ERROR "Extraction failed — removing corrupt release directory"
    rm -rf "$release_path"
    exit 1
  fi

  # Verify extraction produced files
  local file_count
  file_count=$(find "$release_path" -type f | wc -l)

  if [[ $file_count -eq 0 ]]; then
    log ERROR "Extraction produced no files — artifact may be empty"
    rm -rf "$release_path"
    exit 1
  fi

  log INFO "Extraction complete — $file_count files extracted ✓"
  log INFO "Release path: $release_path"
}

extract_artifact "$ARTIFACT_LOCAL" "1.4.2"
```

**Output — successful extraction:**

```
[INFO ] Extracting artifact to: /opt/myapp/releases/1.4.2
[INFO ] Extraction complete — 847 files extracted ✓
[INFO ] Release path: /opt/myapp/releases/1.4.2
```

**Output — extraction failed:**

```
[ERROR] Extraction failed — removing corrupt release directory
```

> ✅ Corrupt extraction is caught and cleaned up before it can go live.

---

### Step 4 — Link Shared Resources

`.env` files, uploads, and logs must **survive across every deploy** — they live in `shared/` and are symlinked into each release:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

APP_DIR="/opt/myapp"
SHARED_DIR="$APP_DIR/shared"
RELEASE_DIR="$APP_DIR/releases"

# Resources that must persist across releases
SHARED_RESOURCES=(
  ".env"            # environment variables — never inside the release
  "uploads"         # user-uploaded files
  "storage"         # app-generated files
  "logs"            # app log files
)

setup_shared_directory() {
  log INFO "Setting up shared directory: $SHARED_DIR"
  mkdir -p "$SHARED_DIR"

  # Create shared resources if they don't exist yet (first deploy)
  [[ -f "$SHARED_DIR/.env"     ]] || touch "$SHARED_DIR/.env"
  [[ -d "$SHARED_DIR/uploads"  ]] || mkdir -p "$SHARED_DIR/uploads"
  [[ -d "$SHARED_DIR/storage"  ]] || mkdir -p "$SHARED_DIR/storage"
  [[ -d "$SHARED_DIR/logs"     ]] || mkdir -p "$SHARED_DIR/logs"

  log INFO "Shared directory ready ✓"
}

link_shared_resources() {
  local version=$1
  local release_path="$RELEASE_DIR/$version"

  log INFO "Linking shared resources into release: $version"

  for resource in "${SHARED_RESOURCES[@]}"; do
    local target="$SHARED_DIR/$resource"
    local link="$release_path/$resource"

    # Remove whatever the artifact put here (placeholder files)
    [[ -e "$link" || -L "$link" ]] && rm -rf "$link"

    # Create symlink: release/.env → shared/.env
    ln -sfn "$target" "$link"

    log INFO "  Linked: $link → $target"
  done

  log INFO "Shared resources linked ✓"
}

setup_shared_directory
link_shared_resources "1.4.2"
```

**Output:**

```
[INFO ] Setting up shared directory: /opt/myapp/shared
[INFO ] Shared directory ready ✓
[INFO ] Linking shared resources into release: 1.4.2
[INFO ]   Linked: /opt/myapp/releases/1.4.2/.env     → /opt/myapp/shared/.env
[INFO ]   Linked: /opt/myapp/releases/1.4.2/uploads  → /opt/myapp/shared/uploads
[INFO ]   Linked: /opt/myapp/releases/1.4.2/storage  → /opt/myapp/shared/storage
[INFO ]   Linked: /opt/myapp/releases/1.4.2/logs     → /opt/myapp/shared/logs
[INFO ] Shared resources linked ✓
```

**Verify the symlinks:**

```bash
ls -la /opt/myapp/releases/1.4.2/
```

```
lrwxrwxrwx  .env     -> /opt/myapp/shared/.env
lrwxrwxrwx  uploads  -> /opt/myapp/shared/uploads
lrwxrwxrwx  storage  -> /opt/myapp/shared/storage
lrwxrwxrwx  logs     -> /opt/myapp/shared/logs
-rw-r--r--  app.js
-rw-r--r--  package.json
drwxr-xr-x  src/
```

> ✅ User uploads and environment config survive every deploy — never lost again.

---

### Step 5 — Install Dependencies

Install inside the release directory — never in the live app:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

RELEASE_DIR="/opt/myapp/releases"
NODE_ENV="production"

install_dependencies() {
  local version=$1
  local release_path="$RELEASE_DIR/$version"

  log INFO "Installing dependencies in: $release_path"

  # Verify package.json exists before running npm
  if [[ ! -f "$release_path/package.json" ]]; then
    log ERROR "package.json not found in release: $release_path"
    exit 1
  fi

  cd "$release_path"

  # npm ci is faster and stricter than npm install
  # - Uses package-lock.json exactly — no version drift
  # - Fails if package-lock.json is missing or out of sync
  # - Always installs clean (removes node_modules first)
  log INFO "Running: npm ci --production"

  if ! NODE_ENV="$NODE_ENV" npm ci --production 2>&1 | tee -a "$LOG_FILE"; then
    log ERROR "Dependency installation failed"
    exit 1
  fi

  # Count installed packages for verification
  local pkg_count
  pkg_count=$(find "$release_path/node_modules" -maxdepth 1 -type d | wc -l)
  log INFO "Dependencies installed — $pkg_count packages ✓"
}

install_dependencies "1.4.2"
```

**Output:**

```
[INFO ] Installing dependencies in: /opt/myapp/releases/1.4.2
[INFO ] Running: npm ci --production
added 312 packages in 18s
[INFO ] Dependencies installed — 313 packages ✓
```

**Why `npm ci` over `npm install`:**

| | `npm install` | `npm ci` |
|---|---|---|
| Uses `package-lock.json` | Sometimes | Always (strict) |
| Version drift possible | Yes | No |
| Removes `node_modules` first | No | Yes |
| Fails if lock file missing | No | Yes |
| Speed | Slower | Faster |
| Safe for production | ❌ | ✅ |

> ✅ Dependencies installed in the new release — live app is completely unaffected.

---

### Step 6 — Final Production-Ready Version

All artifact steps wired into a single `prepare_release()` function:

```bash
#!/bin/bash
# deploy.sh — Concepts 1–6 fully integrated
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
LOG_DIR="/var/log/$APP_NAME"
LOG_FILE="$LOG_DIR/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
TEMP_DIR="/tmp/$APP_NAME-$$"
LOCKFILE="/tmp/$APP_NAME.lock"
NODE_ENV="production"

SHARED_RESOURCES=(.env uploads storage logs)
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

# ─── Argument Parsing (Concept 2) ─────────────────────
ENV=""
VERSION=""
ROLLBACK=false
while getopts "e:v:rh" opt; do
  case $opt in
    e) ENV=$OPTARG ;;  v) VERSION=$OPTARG ;;
    r) ROLLBACK=true ;; h) echo "Usage: $0 -e <env> -v <ver> | -r"; exit 0 ;;
    *) exit 1 ;;
  esac
done
if ! $ROLLBACK; then
  [[ -z "$ENV"     ]] && { log ERROR "-e required"; exit 1; }
  [[ -z "$VERSION" ]] && { log ERROR "-v required"; exit 1; }
  [[ "$ENV" =~ ^(dev|staging|prod)$ ]] || { log ERROR "Invalid env: $ENV"; exit 1; }
fi

# ─── Preflight (Concept 5) ────────────────────────────
run_preflight() {
  log INFO "════ Starting Preflight Checks ═════════════"
  for bin in "${REQUIRED_BINARIES[@]}"; do
    command -v "$bin" &>/dev/null || { log ERROR "Missing: $bin"; exit 1; }
  done
  log INFO "All binaries present ✓"
  log INFO "════ Preflight Passed ═══════════════════════"
}
run_preflight

# ─── Artifact Management (Concept 6) ──────────────────
download_artifact() {
  local version=$1
  local local_path="$TEMP_DIR/app.tar.gz"
  mkdir -p "$TEMP_DIR"

  log INFO "── Downloading Artifact ─────────────────────"
  aws s3 cp "$ARTIFACT_BUCKET/$version/app.tar.gz" "$local_path" \
    --region "$AWS_REGION" --no-progress

  [[ -s "$local_path" ]] || { log ERROR "Downloaded file is empty"; exit 1; }

  local size_mb
  size_mb=$(du -m "$local_path" | cut -f1)
  log INFO "Downloaded: ${size_mb}MB ✓"
  echo "$local_path"
}

verify_checksum() {
  local artifact_path=$1
  local version=$2
  local checksum_local="$TEMP_DIR/app.tar.gz.sha256"

  log INFO "── Verifying Checksum ───────────────────────"
  if ! aws s3 cp "$ARTIFACT_BUCKET/$version/app.tar.gz.sha256" \
    "$checksum_local" --region "$AWS_REGION" --no-progress 2>/dev/null; then
    log WARN "No checksum file found — skipping verification"
    return 0
  fi

  local expected_hash artifact_name artifact_dir
  expected_hash=$(awk '{print $1}' "$checksum_local")
  artifact_name=$(basename "$artifact_path")
  artifact_dir=$(dirname  "$artifact_path")
  echo "$expected_hash  $artifact_name" > "$checksum_local"

  (cd "$artifact_dir" && sha256sum -c "$checksum_local" --status) || {
    log ERROR "Checksum FAILED — artifact may be corrupt"
    exit 1
  }
  log INFO "Checksum verified ✓"
}

extract_artifact() {
  local artifact_path=$1
  local version=$2
  local release_path="$RELEASE_DIR/$version"

  log INFO "── Extracting Artifact ──────────────────────"
  [[ -d "$release_path" ]] && rm -rf "$release_path"
  mkdir -p "$release_path"

  tar -xzf "$artifact_path" -C "$release_path" --strip-components=1 || {
    rm -rf "$release_path"
    log ERROR "Extraction failed — release directory removed"
    exit 1
  }

  local file_count
  file_count=$(find "$release_path" -type f | wc -l)
  [[ $file_count -eq 0 ]] && { log ERROR "Extraction produced no files"; exit 1; }
  log INFO "$file_count files extracted to $release_path ✓"
}

link_shared_resources() {
  local version=$1
  local release_path="$RELEASE_DIR/$version"

  log INFO "── Linking Shared Resources ─────────────────"
  mkdir -p "$SHARED_DIR"
  [[ -f "$SHARED_DIR/.env"    ]] || touch "$SHARED_DIR/.env"
  [[ -d "$SHARED_DIR/uploads" ]] || mkdir -p "$SHARED_DIR/uploads"
  [[ -d "$SHARED_DIR/storage" ]] || mkdir -p "$SHARED_DIR/storage"
  [[ -d "$SHARED_DIR/logs"    ]] || mkdir -p "$SHARED_DIR/logs"

  for resource in "${SHARED_RESOURCES[@]}"; do
    local link="$release_path/$resource"
    [[ -e "$link" || -L "$link" ]] && rm -rf "$link"
    ln -sfn "$SHARED_DIR/$resource" "$link"
    log INFO "  Linked: $resource → shared/$resource"
  done
  log INFO "Shared resources linked ✓"
}

install_dependencies() {
  local version=$1
  local release_path="$RELEASE_DIR/$version"

  log INFO "── Installing Dependencies ──────────────────"
  [[ -f "$release_path/package.json" ]] || {
    log ERROR "package.json not found in release"
    exit 1
  }

  cd "$release_path"
  NODE_ENV="$NODE_ENV" npm ci --production 2>&1 | tee -a "$LOG_FILE"

  local pkg_count
  pkg_count=$(find "$release_path/node_modules" -maxdepth 1 -type d | wc -l)
  log INFO "$pkg_count packages installed ✓"
}

prepare_release() {
  local version=$1
  log INFO "════ Preparing Release: v$version ══════════"

  local artifact_path
  artifact_path=$(download_artifact    "$version")
  verify_checksum   "$artifact_path"   "$version"
  extract_artifact  "$artifact_path"   "$version"
  link_shared_resources                "$version"
  install_dependencies                 "$version"

  log INFO "════ Release v$version Ready ════════════════"
}

# ─── Main ─────────────────────────────────────────────
mkdir -p "$TEMP_DIR"

if $ROLLBACK; then
  log WARN "Rollback mode — coming in Concept 7"
else
  prepare_release "$VERSION"
  log INFO "Release prepared — cutover and health check coming in Concept 7"
fi
```

**Full output — successful artifact preparation:**

```
[INFO ] ════ Starting Preflight Checks ═════════════
[INFO ] All binaries present ✓
[INFO ] ════ Preflight Passed ═══════════════════════
[INFO ] ════ Preparing Release: v1.4.2 ══════════════
[INFO ] ── Downloading Artifact ─────────────────────
[INFO ] Downloaded: 487MB ✓
[INFO ] ── Verifying Checksum ───────────────────────
[INFO ] Checksum verified ✓
[INFO ] ── Extracting Artifact ──────────────────────
[INFO ] 847 files extracted to /opt/myapp/releases/1.4.2 ✓
[INFO ] ── Linking Shared Resources ─────────────────
[INFO ]   Linked: .env     → shared/.env
[INFO ]   Linked: uploads  → shared/uploads
[INFO ]   Linked: storage  → shared/storage
[INFO ]   Linked: logs     → shared/logs
[INFO ] Shared resources linked ✓
[INFO ] ── Installing Dependencies ──────────────────
[INFO ] 313 packages installed ✓
[INFO ] ════ Release v1.4.2 Ready ════════════════════
[INFO ] Release prepared — cutover and health check coming in Concept 7
```

---

## Mini Exercise for Participants

> **Task:** Add artifact management to `backup.sh` from Concept 5:
>
> - Download the latest DB dump from S3 bucket (from config) to a temp location
> - Verify its checksum against a `.sha256` file in the same S3 path
> - Extract it to a versioned directory: `$BACKUP_DIR/$(date '+%Y%m%d')/`
> - Symlink `$BACKUP_DIR/latest` to the newly extracted directory
> - Log each step with INFO / ERROR levels

**Expected solution:**

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

TEMP_DIR="/tmp/backup-$$"
BACKUP_DIR="/opt/backups"
S3_BUCKET="s3://my-backups/myapp"
DATE=$(date '+%Y%m%d')
RESTORE_DIR="$BACKUP_DIR/$DATE"

trap "rm -rf $TEMP_DIR" EXIT

download_backup() {
  mkdir -p "$TEMP_DIR"
  log INFO "Downloading backup from S3..."
  aws s3 cp "$S3_BUCKET/latest/db.tar.gz" "$TEMP_DIR/db.tar.gz" --no-progress
  [[ -s "$TEMP_DIR/db.tar.gz" ]] || { log ERROR "Downloaded file is empty"; exit 1; }
  log INFO "Download complete ✓"
}

verify_checksum() {
  log INFO "Verifying checksum..."
  aws s3 cp "$S3_BUCKET/latest/db.tar.gz.sha256" \
    "$TEMP_DIR/db.tar.gz.sha256" --no-progress 2>/dev/null || {
    log WARN "No checksum file — skipping"
    return 0
  }
  local hash
  hash=$(awk '{print $1}' "$TEMP_DIR/db.tar.gz.sha256")
  echo "$hash  db.tar.gz" > "$TEMP_DIR/db.tar.gz.sha256"
  (cd "$TEMP_DIR" && sha256sum -c db.tar.gz.sha256 --status) || {
    log ERROR "Checksum failed — backup may be corrupt"
    exit 1
  }
  log INFO "Checksum verified ✓"
}

extract_backup() {
  mkdir -p "$RESTORE_DIR"
  log INFO "Extracting to $RESTORE_DIR..."
  tar -xzf "$TEMP_DIR/db.tar.gz" -C "$RESTORE_DIR" --strip-components=1
  ln -sfn "$RESTORE_DIR" "$BACKUP_DIR/latest"
  log INFO "Extraction complete — latest → $RESTORE_DIR ✓"
}

download_backup
verify_checksum
extract_backup
log INFO "Backup restore complete"
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| Download to `/tmp` first | Never touch the live directory until artifact is verified |
| Always verify checksums | Corrupt artifacts must never reach your release directory |
| Extract to versioned dirs | `releases/1.4.2/` not `current/` — enables instant rollback |
| `--strip-components=1` | Removes the wrapper folder commonly found inside tarballs |
| Shared dir + symlinks | `.env` and `uploads/` persist across every deploy forever |
| `npm ci` over `npm install` | Strict, reproducible, fast — the only safe choice in prod |
| Install in release dir | Dependencies install in isolation — live app is never touched |
| `prepare_release()` wrapper | One function orchestrates all artifact steps cleanly |

---

## Release Directory State After Concept 6

```
/opt/myapp/
├── releases/
│   ├── 1.4.0/              ← old (kept for rollback)
│   ├── 1.4.1/              ← previous (kept for rollback)
│   └── 1.4.2/              ← NEW — fully prepared, not yet live
│       ├── app.js
│       ├── package.json
│       ├── node_modules/   ← installed fresh by npm ci
│       ├── .env            → symlink → shared/.env
│       ├── uploads/        → symlink → shared/uploads/
│       ├── storage/        → symlink → shared/storage/
│       └── logs/           → symlink → shared/logs/
├── shared/
│   ├── .env                ← persists forever
│   ├── uploads/            ← persists forever
│   ├── storage/            ← persists forever
│   └── logs/               ← persists forever
└── current                 → still pointing to 1.4.1 (not yet swapped)
```

> The new release is **fully prepared but not yet live**.  
> The symlink swap and health check happen in Concept 7.

---

## What's Next

**Concept 7 — Zero-Downtime Deployment & Rollback**  
With the release fully prepared, we will perform the atomic symlink swap,
reload the service, run the health check with retry logic, and implement
automatic rollback if the health check fails — completing the full
deployment pipeline.