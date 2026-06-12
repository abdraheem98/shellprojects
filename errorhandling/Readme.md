# Concept 3 — Exit Codes & Error Handling

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~20 minutes  
> **Prerequisite:** Concept 1 (Structured Logging) + Concept 2 (Argument Parsing)

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Are Exit Codes?](#what-are-exit-codes)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Exit Codes Basics](#step-1--exit-codes-basics)
  - [Step 2 — The Holy Trinity: set -euo pipefail](#step-2--the-holy-trinity-set--euo-pipefail)
  - [Step 3 — trap for Cleanup on Failure](#step-3--trap-for-cleanup-on-failure)
  - [Step 4 — Custom Error Handler](#step-4--custom-error-handler)
  - [Step 5 — Final Production-Ready Version](#step-5--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners write

```bash
#!/bin/bash

cp app.tar.gz /opt/myapp/          # fails silently if file doesn't exist
tar -xzf /opt/myapp/app.tar.gz     # runs anyway on corrupt/missing file
systemctl restart myapp            # restarts with broken files
echo "Deployment done!"            # prints success even though everything broke
```

**Run it when `app.tar.gz` doesn't exist:**

```
cp: cannot stat 'app.tar.gz': No such file or directory
tar: /opt/myapp/app.tar.gz: Cannot open: No such file or directory
Deployment done!
```

> ❌ The script prints **"Deployment done!"** even though it completely failed.  
> Your CI/CD pipeline sees exit code `0` (success) and marks the build green.  
> Production is broken. Nobody knows.

### Real-world incident scenario

> A deployment script copied a corrupt artifact, failed silently,  
> restarted the service with broken files, and reported success to the pipeline.  
> The on-call engineer spent 3 hours debugging a "successful" deployment  
> before realising the artifact was never properly extracted.
>
> **Three lines at the top of the script would have stopped this immediately.**

---

## What Are Exit Codes?

Every command in Linux returns an **exit code** when it finishes:

| Exit Code | Meaning |
|---|---|
| `0` | Success |
| `1` | General error |
| `2` | Misuse of shell command |
| `126` | Command not executable |
| `127` | Command not found |
| `130` | Script terminated by Ctrl+C |

```bash
# Check exit code of last command with $?
ls /tmp
echo $?       # 0 — success

ls /nonexistent
echo $?       # 2 — failed

curl https://invalid-url
echo $?       # non-zero — failed
```

**In CI/CD pipelines:**
- Exit code `0` → pipeline continues, marks step green
- Exit code non-zero → pipeline stops, marks step red, sends alert

> This is why a script that swallows errors and exits `0` is **dangerous in production.**

---

## Build It Step by Step

### Step 1 — Exit Codes Basics

```bash
#!/bin/bash

# Bad — exit code is always 0 regardless of what happened
do_something() {
  cp missing-file.tar.gz /opt/app/
  echo "Copy done"       # prints even if cp failed
}

do_something
echo "Exit code: $?"     # prints 0 — wrong!
```

**The fix — check exit codes explicitly:**

```bash
#!/bin/bash

source ./log.sh

copy_artifact() {
  if cp app.tar.gz /opt/myapp/; then
    log INFO "Artifact copied successfully"
  else
    log ERROR "Failed to copy artifact"
    exit 1    # stop the script immediately with failure code
  fi
}

copy_artifact
echo "Exit code: $?"
```

**Run it with missing file:**

```
[ERROR] Failed to copy artifact
Exit code: 1
```

> ✅ Now the pipeline sees a failure and stops. But doing `if/else` for every command is exhausting — there's a better way.

---

### Step 2 — The Holy Trinity: `set -euo pipefail`

This is the **most important line** in any production shell script.  
Teach participants to write this as the very first line — always, no exceptions.

```bash
#!/bin/bash
set -euo pipefail
```

Break it down one flag at a time:

#### `set -e` — Exit immediately on error

```bash
#!/bin/bash
set -e

cp missing-file.tar.gz /opt/app/    # fails here
echo "This never prints"            # script stops above
echo "Deployment done!"             # script stops above
```

```
cp: cannot stat 'missing-file.tar.gz': No such file or directory
# Script exits with code 1 — pipeline stops immediately
```

#### `set -u` — Treat unset variables as errors

```bash
#!/bin/bash
set -u

echo "Deploying to: $ENVIORNMENT"   # typo — should be ENVIRONMENT
```

```
bash: ENVIORNMENT: unbound variable
# Without -u this silently deploys to empty string ""
```

> This catches one of the most common bugs in shell scripts — **typos in variable names**.

#### `set -o pipefail` — Catch errors inside pipes

```bash
#!/bin/bash

# Without pipefail — this reports success!
cat missing-file.log | grep "ERROR"
echo $?    # prints 0 — grep succeeded even though cat failed

# With pipefail — pipe fails if ANY command in it fails
set -o pipefail
cat missing-file.log | grep "ERROR"
echo $?    # prints 1 — correctly reports failure
```

> Without `pipefail`, errors inside pipes are completely invisible.  
> This is how log parsers and artifact extractors silently fail in prod.

#### All three together

```bash
#!/bin/bash
set -euo pipefail

# Now every command is safe:
# -e  → stops on any error
# -u  → stops on undefined variable
# -o pipefail → stops on pipe errors

log INFO "Script is now safe to run in production"
```

---

### Step 3 — `trap` for Cleanup on Failure

`set -e` stops the script on error — but what about cleanup?  
If the script fails halfway through a deploy, you may have:
- A partial release directory left behind
- A lockfile that never got deleted
- A service left in a broken state

`trap` lets you run a function **automatically** when the script exits — whether it succeeds, fails, or gets killed:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

TEMP_DIR="/tmp/myapp-deploy-$$"    # $$ = current process ID, makes it unique
LOCKFILE="/tmp/myapp-deploy.lock"

# ─── Cleanup function ─────────────────────────────────
cleanup() {
  local exit_code=$?    # capture exit code before it gets overwritten

  log INFO "Running cleanup..."

  # Remove temp files
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" && log INFO "Temp dir removed"

  # Remove lockfile
  [[ -f "$LOCKFILE" ]] && rm -f "$LOCKFILE" && log INFO "Lockfile removed"

  if [[ $exit_code -ne 0 ]]; then
    log ERROR "Script failed with exit code $exit_code — cleanup complete"
  else
    log INFO "Script completed successfully — cleanup complete"
  fi
}

# Register cleanup to run on EXIT (covers success, failure, and Ctrl+C)
trap cleanup EXIT

# ─── Script body ──────────────────────────────────────
# Create lockfile to prevent duplicate runs
touch "$LOCKFILE"
log INFO "Lockfile created: $LOCKFILE"

# Create temp working dir
mkdir -p "$TEMP_DIR"
log INFO "Working in temp dir: $TEMP_DIR"

# Simulate work
log INFO "Downloading artifact..."
cp app.tar.gz "$TEMP_DIR/"           # if this fails, cleanup() still runs

log INFO "Extracting artifact..."
tar -xzf "$TEMP_DIR/app.tar.gz" -C "$TEMP_DIR/"

log INFO "Deploy complete"
```

**Run with missing file — watch cleanup trigger automatically:**

```
[INFO ] Lockfile created: /tmp/myapp-deploy.lock
[INFO ] Working in temp dir: /tmp/myapp-deploy-12345
[INFO ] Downloading artifact...
[INFO ] Running cleanup...
[INFO ] Temp dir removed
[INFO ] Lockfile removed
[ERROR] Script failed with exit code 1 — cleanup complete
```

> ✅ Even though the script crashed, the lockfile and temp dir were cleaned up automatically.

#### trap signals reference

```bash
trap cleanup EXIT      # runs on any exit (success or failure) — use this most
trap cleanup ERR       # runs only on error
trap cleanup INT       # runs on Ctrl+C
trap cleanup TERM      # runs on kill signal
trap cleanup EXIT ERR INT TERM   # cover all cases
```

---

### Step 4 — Custom Error Handler

Instead of just stopping silently, show **where** it failed:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

# ─── Error handler ────────────────────────────────────
handle_error() {
  local exit_code=$?
  local line_number=$1

  log ERROR "Script failed at line $line_number with exit code $exit_code"
  log ERROR "Command: ${BASH_COMMAND}"    # shows the exact command that failed
  log ERROR "Stack trace:"

  # Print call stack
  local i
  for i in "${!FUNCNAME[@]}"; do
    log ERROR "  [$i] ${FUNCNAME[$i]:-main} → ${BASH_SOURCE[$i]:-unknown}:${BASH_LINENO[$i]:-0}"
  done
}

trap 'handle_error $LINENO' ERR

# ─── Script body ──────────────────────────────────────
log INFO "Starting deployment..."

log INFO "Copying artifact..."
cp missing-artifact.tar.gz /opt/myapp/    # this will fail

log INFO "This never runs"
```

**Output when it fails:**

```
[INFO ] Starting deployment...
[INFO ] Copying artifact...
[ERROR] Script failed at line 28 with exit code 1
[ERROR] Command: cp missing-artifact.tar.gz /opt/myapp/
[ERROR] Stack trace:
[ERROR]   [0] handle_error → deploy.sh:28
[ERROR]   [1] main → deploy.sh:0
```

> ✅ You now know the **exact line**, **exact command**, and **call stack** — no more guessing where it failed.

---

### Step 5 — Final Production-Ready Version

Everything combined — logging + argument parsing + exit codes + trap + error handler:

```bash
#!/bin/bash
# deploy.sh — Production-grade deployment script
# Usage: ./deploy.sh -e <environment> -v <version>
# Usage: ./deploy.sh -r

set -euo pipefail

# ─── Configuration ────────────────────────────────────
APP_NAME="myapp"
LOG_DIR="/var/log/$APP_NAME"
LOG_FILE="$LOG_DIR/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
TEMP_DIR="/tmp/$APP_NAME-deploy-$$"
LOCKFILE="/tmp/$APP_NAME-deploy.lock"

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

# ─── Error Handler ────────────────────────────────────
handle_error() {
  local exit_code=$?
  local line_number=$1
  log ERROR "Failed at line $line_number — exit code: $exit_code"
  log ERROR "Command: ${BASH_COMMAND}"
}

# ─── Cleanup ──────────────────────────────────────────
cleanup() {
  local exit_code=$?
  log INFO "Running cleanup..."
  [[ -d "$TEMP_DIR"  ]] && rm -rf "$TEMP_DIR"  && log INFO "Temp dir removed"
  [[ -f "$LOCKFILE"  ]] && rm -f  "$LOCKFILE"  && log INFO "Lockfile removed"
  [[ $exit_code -ne 0 ]] \
    && log ERROR "Deployment FAILED — exit code $exit_code" \
    || log INFO  "Deployment completed successfully"
}

trap 'handle_error $LINENO' ERR
trap cleanup EXIT

# ─── Locking (prevent duplicate runs) ─────────────────
if [[ -f "$LOCKFILE" ]]; then
  log ERROR "Another deployment is already running (lockfile: $LOCKFILE)"
  exit 1
fi
touch "$LOCKFILE"

# ─── Usage (Concept 2) ────────────────────────────────
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

# ─── Argument Parsing (Concept 2) ─────────────────────
ENV=""
VERSION=""
ROLLBACK=false

while getopts "e:v:rh" opt; do
  case $opt in
    e) ENV=$OPTARG     ;;
    v) VERSION=$OPTARG ;;
    r) ROLLBACK=true   ;;
    h) usage           ;;
    *) usage           ;;
  esac
done

# ─── Validation (Concept 2) ───────────────────────────
if ! $ROLLBACK; then
  [[ -z "$ENV"     ]] && { log ERROR "Environment (-e) required"; exit 1; }
  [[ -z "$VERSION" ]] && { log ERROR "Version (-v) required";     exit 1; }
  [[ "$ENV" =~ ^(dev|staging|prod)$ ]] || {
    log ERROR "Invalid environment: $ENV"
    exit 1
  }
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]] || {
    log ERROR "Invalid version format: $VERSION"
    exit 1
  }
fi

# ─── Main ─────────────────────────────────────────────
mkdir -p "$TEMP_DIR"

if $ROLLBACK; then
  log WARN "Rollback mode — will be implemented in Concept 7"
else
  log INFO "Starting deployment: v$VERSION → $ENV"
  log INFO "Temp workspace: $TEMP_DIR"
  # Deploy logic comes in Concepts 6 & 7
  log INFO "Deployment steps will be added in upcoming concepts"
fi
```

**Test all failure scenarios:**

```bash
# Missing artifact — watch error handler + cleanup fire
LOG_LEVEL=DEBUG ./deploy.sh -e prod -v 1.4.2

# Duplicate run — watch lockfile detection
./deploy.sh -e prod -v 1.4.2 &
./deploy.sh -e prod -v 1.4.2    # should be blocked

# Undefined variable — set -u catches it
TYPO_TEST() { echo "$UNSET_VAR"; }

# Pipe failure — set -o pipefail catches it
cat /nonexistent | grep "pattern"
```

---

## Mini Exercise for Participants

> **Task:** Take your `backup.sh` from Concept 2 and harden it:
>
> - Add `set -euo pipefail` at the top
> - Add a `cleanup()` function that removes any temp files if the script fails
> - Add an `handle_error()` function that logs the line number and failed command
> - Register both with `trap`
> - Test it by pointing `-d` to a directory that doesn't exist and verify cleanup runs

**Expected solution:**

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

TEMP_DIR="/tmp/backup-$$"

cleanup() {
  local exit_code=$?
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" && log INFO "Temp dir cleaned up"
  [[ $exit_code -ne 0 ]] \
    && log ERROR "Backup failed with exit code $exit_code" \
    || log INFO  "Backup completed successfully"
}

handle_error() {
  log ERROR "Failed at line $1 — command: ${BASH_COMMAND}"
}

trap 'handle_error $LINENO' ERR
trap cleanup EXIT

# Rest of backup.sh from Concept 2...
DIR=""
TYPE=""
OUTPUT="/tmp/backup"

while getopts "d:t:o:h" opt; do
  case $opt in
    d) DIR=$OPTARG    ;;
    t) TYPE=$OPTARG   ;;
    o) OUTPUT=$OPTARG ;;
    h) usage          ;;
    *) usage          ;;
  esac
done

[[ -z "$DIR"  ]] && { log ERROR "Directory (-d) is required"; exit 1; }
[[ -z "$TYPE" ]] && { log ERROR "Type (-t) is required";      exit 1; }
[[ "$TYPE" =~ ^(full|incremental)$ ]] || { log ERROR "Invalid type: $TYPE"; exit 1; }

mkdir -p "$TEMP_DIR"

log INFO "Starting $TYPE backup of $DIR..."
cp -r "$DIR" "$TEMP_DIR/"    # fails here if DIR doesn't exist — cleanup fires
log INFO "Backup complete → $OUTPUT"
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| `set -e` | Stop immediately on any command failure — no silent errors |
| `set -u` | Catch typos in variable names before they silently deploy to wrong env |
| `set -o pipefail` | Catch failures inside pipes — without this, piped errors are invisible |
| `trap cleanup EXIT` | Cleanup always runs — success, failure, or Ctrl+C |
| `trap 'handle_error $LINENO' ERR` | Know exactly which line and command failed |
| `$BASH_COMMAND` | The exact command that triggered the error — invaluable for debugging |
| `$$` in temp dir name | Process ID makes temp dirs unique — prevents collisions with parallel runs |
| Lockfile pattern | Prevent two deploys running simultaneously — essential for shared servers |

---

## The Three Lines Every Production Script Must Start With

```bash
#!/bin/bash
set -euo pipefail
```

> Write these from memory. Every time. No exceptions.  
> If someone on your team doesn't have these, their script is not production-ready.

---

## What's Next

**Concept 4 — Config Management**  
We will move all hardcoded values (paths, thresholds, URLs, bucket names) out of the script body and into a clean, externalized config block — so the same script works across dev, staging, and prod without a single line change.