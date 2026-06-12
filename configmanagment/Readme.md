# Concept 4 — Config Management

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~20 minutes  
> **Prerequisite:** Concept 1 (Logging) + Concept 2 (Argument Parsing) + Concept 3 (Exit Codes)

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Is Config Management?](#what-is-config-management)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Centralized Config Block](#step-1--centralized-config-block)
  - [Step 2 — Environment-Specific Overrides](#step-2--environment-specific-overrides)
  - [Step 3 — External Config File (.env)](#step-3--external-config-file-env)
  - [Step 4 — Config Validation](#step-4--config-validation)
  - [Step 5 — Final Production-Ready Version](#step-5--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners write

```bash
#!/bin/bash
set -euo pipefail

# Values scattered everywhere across the script
aws s3 cp s3://my-prod-bucket/myapp/1.4.2/app.tar.gz /tmp/
tar -xzf /tmp/app.tar.gz -C /opt/myapp/releases/1.4.2/
systemctl restart myapp
curl -sf http://localhost:3000/health
slack_webhook="https://hooks.slack.com/services/ABC/DEF/XYZ"
curl -s -X POST "$slack_webhook" -d "{\"text\": \"deployed\"}"
```

**The problems with this:**

- ❌ Values are buried inside logic — impossible to find quickly
- ❌ Same bucket name, port, path repeated in 10 different places
- ❌ Change one value → must hunt through 200 lines of script to update all instances
- ❌ `dev` and `prod` use different buckets, ports, paths — you need two separate scripts
- ❌ Secrets like Slack webhook URLs are hardcoded — get committed to Git

### Real-world incident scenario

> A team had `s3://prod-artifacts` hardcoded in 6 places across a 300-line script.  
> When they renamed the bucket, they updated 4 of the 6 occurrences.  
> The two they missed caused deployments to silently pull stale artifacts  
> for two weeks before anyone noticed.
>
> **A single config block at the top would have meant one change, everywhere fixed.**

---

## What Is Config Management?

Config management in shell scripting means:

1. **All values live in one place** — top of the script or a separate file
2. **Logic never contains hardcoded values** — only variable references
3. **Environment differences are handled by overrides** — not separate scripts
4. **Secrets come from environment variables** — never hardcoded

The rule is simple:

> **If a value could ever change, it must be a variable.**

---

## Build It Step by Step

### Step 1 — Centralized Config Block

Move every hardcoded value to the top of the script under a clear config section:

```bash
#!/bin/bash
set -euo pipefail

# ─── Application Config ───────────────────────────────
APP_NAME="myapp"
APP_PORT=3000
APP_DIR="/opt/$APP_NAME"
RELEASE_DIR="$APP_DIR/releases"
SHARED_DIR="$APP_DIR/shared"
CURRENT_LINK="$APP_DIR/current"
KEEP_RELEASES=5

# ─── Infrastructure Config ────────────────────────────
ARTIFACT_BUCKET="s3://my-artifacts/$APP_NAME"
AWS_REGION="ap-south-1"

# ─── Logging Config ───────────────────────────────────
LOG_DIR="/var/log/$APP_NAME"
LOG_FILE="$LOG_DIR/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# ─── Health Check Config ──────────────────────────────
HEALTH_CHECK_URL="http://localhost:$APP_PORT/health"
HEALTH_CHECK_RETRIES=10
HEALTH_CHECK_DELAY=5

# ─── Notification Config ──────────────────────────────
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"    # injected via environment — never hardcoded

# ─── Script Internals ─────────────────────────────────
TEMP_DIR="/tmp/$APP_NAME-$$"
LOCKFILE="/tmp/$APP_NAME.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

**Key teaching points:**

| Pattern | Example | Why |
|---|---|---|
| Derive from parent | `RELEASE_DIR="$APP_DIR/releases"` | Change `APP_DIR` once → everything updates |
| Default with override | `"${LOG_LEVEL:-INFO}"` | Works standalone, overridable from outside |
| Secret from env | `"${SLACK_WEBHOOK:-}"` | Never in the script, never in Git |
| Script's own path | `"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` | Works regardless of where script is called from |

> ✅ Every value in one place. Change anything in 1 line, not 10.

---

### Step 2 — Environment-Specific Overrides

One script that works for all environments — dev, staging, prod:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

# ─── Base Config (shared across all environments) ─────
APP_NAME="myapp"
APP_PORT=3000
APP_DIR="/opt/$APP_NAME"
KEEP_RELEASES=5
HEALTH_CHECK_RETRIES=10
HEALTH_CHECK_DELAY=5

# ─── Environment-Specific Overrides ───────────────────
apply_env_config() {
  local env=$1

  case $env in
    dev)
      ARTIFACT_BUCKET="s3://dev-artifacts/$APP_NAME"
      APP_DIR="/opt/$APP_NAME-dev"
      KEEP_RELEASES=2                  # dev — keep fewer releases
      HEALTH_CHECK_RETRIES=3           # dev — fail faster
      log DEBUG "Dev config applied"
      ;;

    staging)
      ARTIFACT_BUCKET="s3://staging-artifacts/$APP_NAME"
      APP_DIR="/opt/$APP_NAME-staging"
      KEEP_RELEASES=3
      HEALTH_CHECK_RETRIES=5
      log DEBUG "Staging config applied"
      ;;

    prod)
      ARTIFACT_BUCKET="s3://prod-artifacts/$APP_NAME"
      APP_DIR="/opt/$APP_NAME"
      KEEP_RELEASES=5                  # prod — keep more history for rollbacks
      HEALTH_CHECK_RETRIES=10          # prod — be patient, retry more
      log DEBUG "Prod config applied"
      ;;

    *)
      log ERROR "Unknown environment: $env"
      exit 1
      ;;
  esac

  # Derived paths — recalculate after overrides
  RELEASE_DIR="$APP_DIR/releases"
  SHARED_DIR="$APP_DIR/shared"
  CURRENT_LINK="$APP_DIR/current"
  HEALTH_CHECK_URL="http://localhost:$APP_PORT/health"
}

# Called after argument parsing (Concept 2)
apply_env_config "${ENV}"

log INFO "Config loaded for environment: $ENV"
log INFO "Artifact bucket : $ARTIFACT_BUCKET"
log INFO "App directory   : $APP_DIR"
log INFO "Releases to keep: $KEEP_RELEASES"
```

**Run it for each environment:**

```bash
ENV=dev     ./deploy.sh -e dev -v 1.4.2
ENV=staging ./deploy.sh -e staging -v 1.4.2
ENV=prod    ./deploy.sh -e prod -v 1.4.2
```

**Output (dev):**

```
[INFO ] Config loaded for environment: dev
[INFO ] Artifact bucket : s3://dev-artifacts/myapp
[INFO ] App directory   : /opt/myapp-dev
[INFO ] Releases to keep: 2
```

**Output (prod):**

```
[INFO ] Config loaded for environment: prod
[INFO ] Artifact bucket : s3://prod-artifacts/myapp
[INFO ] App directory   : /opt/myapp
[INFO ] Releases to keep: 5
```

> ✅ One script. Three environments. Zero duplication.

---

### Step 3 — External Config File (.env)

For larger projects, move config into a separate file so non-engineers can change values without touching script logic:

**Create the config files:**

```bash
# config/dev.env
APP_PORT=3001
ARTIFACT_BUCKET="s3://dev-artifacts/myapp"
APP_DIR="/opt/myapp-dev"
KEEP_RELEASES=2
HEALTH_CHECK_RETRIES=3
HEALTH_CHECK_DELAY=2
DB_HOST="dev-db.internal"
DB_PORT=5432
```

```bash
# config/staging.env
APP_PORT=3000
ARTIFACT_BUCKET="s3://staging-artifacts/myapp"
APP_DIR="/opt/myapp-staging"
KEEP_RELEASES=3
HEALTH_CHECK_RETRIES=5
HEALTH_CHECK_DELAY=5
DB_HOST="staging-db.internal"
DB_PORT=5432
```

```bash
# config/prod.env
APP_PORT=3000
ARTIFACT_BUCKET="s3://prod-artifacts/myapp"
APP_DIR="/opt/myapp"
KEEP_RELEASES=5
HEALTH_CHECK_RETRIES=10
HEALTH_CHECK_DELAY=5
DB_HOST="prod-db.internal"
DB_PORT=5432
```

**Load the config file in the script:**

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"

load_config() {
  local env=$1
  local config_file="$CONFIG_DIR/${env}.env"

  if [[ ! -f "$config_file" ]]; then
    log ERROR "Config file not found: $config_file"
    exit 1
  fi

  log INFO "Loading config from: $config_file"

  # Source the config file — sets all variables
  # shellcheck source=/dev/null
  source "$config_file"

  log INFO "Config loaded successfully"
}

# Call after parsing -e flag
load_config "${ENV}"

log INFO "App port    : $APP_PORT"
log INFO "DB host     : $DB_HOST"
log INFO "Artifact    : $ARTIFACT_BUCKET"
```

**Your project structure now looks like:**

```
myapp/
├── deploy.sh           # script logic — no hardcoded values
├── log.sh              # logging function (Concept 1)
└── config/
    ├── dev.env         # dev values
    ├── staging.env     # staging values
    └── prod.env        # prod values — commit this, but NOT secrets
```

> ✅ Ops team edits `.env` files. Engineers don't touch deploy logic. Clean separation.

---

### Step 4 — Config Validation

After loading config, verify all required values are present and sensible:

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

validate_config() {
  log INFO "Validating configuration..."

  local errors=0

  # Required variables — must not be empty
  local required_vars=(
    APP_NAME
    APP_PORT
    APP_DIR
    ARTIFACT_BUCKET
    HEALTH_CHECK_URL
    DB_HOST
  )

  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then    # indirect variable reference
      log ERROR "Required config missing: $var"
      errors=$((errors + 1))
    fi
  done

  # Port must be a valid number between 1 and 65535
  if [[ ! "$APP_PORT" =~ ^[0-9]+$ ]] || \
     [[ "$APP_PORT" -lt 1 ]] || \
     [[ "$APP_PORT" -gt 65535 ]]; then
    log ERROR "Invalid APP_PORT: $APP_PORT — must be 1–65535"
    errors=$((errors + 1))
  fi

  # S3 bucket must match expected pattern
  if [[ ! "$ARTIFACT_BUCKET" =~ ^s3:// ]]; then
    log ERROR "Invalid ARTIFACT_BUCKET: $ARTIFACT_BUCKET — must start with s3://"
    errors=$((errors + 1))
  fi

  # Secret check — warn if Slack webhook missing (non-fatal)
  if [[ -z "${SLACK_WEBHOOK:-}" ]]; then
    log WARN "SLACK_WEBHOOK not set — notifications disabled"
  fi

  # Fail if any required config is missing
  if [[ $errors -gt 0 ]]; then
    log ERROR "Config validation failed with $errors error(s)"
    exit 1
  fi

  log INFO "Config validation passed ✓"
}

validate_config
```

**Run with missing variable:**

```
[ERROR] Required config missing: DB_HOST
[ERROR] Required config missing: ARTIFACT_BUCKET
[ERROR] Config validation failed with 2 error(s)
```

> ✅ Script fails at startup with a clear list — not 3 steps into a deployment.

---

### Step 5 — Final Production-Ready Version

Complete script with all four concepts layered together:

```bash
#!/bin/bash
# deploy.sh — Webapp deployment script
# Usage: ./deploy.sh -e <environment> -v <version>
# Usage: ./deploy.sh -r (rollback)

set -euo pipefail

# ─── Script Internals ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"

# ─── Logging (Concept 1) ──────────────────────────────
APP_NAME="myapp"
LOG_DIR="/var/log/$APP_NAME"
LOG_FILE="$LOG_DIR/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

mkdir -p "$LOG_DIR"

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

# ─── Error Handler + Cleanup (Concept 3) ──────────────
TEMP_DIR="/tmp/$APP_NAME-$$"
LOCKFILE="/tmp/$APP_NAME.lock"

handle_error() {
  log ERROR "Failed at line $1 — command: ${BASH_COMMAND}"
}

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

# ─── Usage + Argument Parsing (Concept 2) ─────────────
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

if ! $ROLLBACK; then
  [[ -z "$ENV"     ]] && { log ERROR "Environment (-e) required"; exit 1; }
  [[ -z "$VERSION" ]] && { log ERROR "Version (-v) required";     exit 1; }
  [[ "$ENV" =~ ^(dev|staging|prod)$ ]] || { log ERROR "Invalid env: $ENV"; exit 1; }
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]] || {
    log ERROR "Invalid version: $VERSION"; exit 1
  }
fi

# ─── Config Loading (Concept 4) ───────────────────────
load_config() {
  local env=$1
  local config_file="$CONFIG_DIR/${env}.env"

  [[ -f "$config_file" ]] || { log ERROR "Config not found: $config_file"; exit 1; }

  log INFO "Loading config: $config_file"
  # shellcheck source=/dev/null
  source "$config_file"
}

validate_config() {
  log INFO "Validating config..."
  local errors=0
  local required_vars=(APP_PORT APP_DIR ARTIFACT_BUCKET HEALTH_CHECK_URL)

  for var in "${required_vars[@]}"; do
    [[ -z "${!var:-}" ]] && { log ERROR "Missing config: $var"; errors=$((errors+1)); }
  done

  [[ ! "$APP_PORT" =~ ^[0-9]+$ ]] && { log ERROR "Invalid APP_PORT: $APP_PORT"; errors=$((errors+1)); }
  [[ ! "$ARTIFACT_BUCKET" =~ ^s3:// ]] && { log ERROR "Invalid bucket: $ARTIFACT_BUCKET"; errors=$((errors+1)); }
  [[ -z "${SLACK_WEBHOOK:-}" ]] && log WARN "SLACK_WEBHOOK not set — notifications disabled"

  [[ $errors -gt 0 ]] && { log ERROR "Config validation failed: $errors error(s)"; exit 1; }
  log INFO "Config validation passed ✓"
}

load_config "$ENV"
validate_config

# ─── Print Active Config ───────────────────────────────
log INFO "─── Active Configuration ───────────────────"
log INFO "Environment     : $ENV"
log INFO "Version         : ${VERSION:-N/A (rollback mode)}"
log INFO "App directory   : $APP_DIR"
log INFO "Artifact bucket : $ARTIFACT_BUCKET"
log INFO "Health check    : $HEALTH_CHECK_URL"
log INFO "Releases to keep: $KEEP_RELEASES"
log INFO "────────────────────────────────────────────"

# ─── Main ─────────────────────────────────────────────
mkdir -p "$TEMP_DIR"

if $ROLLBACK; then
  log WARN "Rollback mode — coming in Concept 7"
else
  log INFO "Deployment logic — coming in Concepts 6 & 7"
fi
```

**Run it and show the config summary block:**

```bash
LOG_LEVEL=DEBUG ./deploy.sh -e prod -v 1.4.2
```

```
[INFO ] Loading config: /opt/scripts/config/prod.env
[INFO ] Config validation passed ✓
[INFO ] ─── Active Configuration ───────────────────
[INFO ] Environment     : prod
[INFO ] Version         : 1.4.2
[INFO ] App directory   : /opt/myapp
[INFO ] Artifact bucket : s3://prod-artifacts/myapp
[INFO ] Health check    : http://localhost:3000/health
[INFO ] Releases to keep: 5
[INFO ] ────────────────────────────────────────────
```

> ✅ Every run prints exactly what config it's using — no more guessing which values are active.

---

## Mini Exercise for Participants

> **Task:** Take `backup.sh` from Concept 3 and add config management:
>
> - Create a `config/backup.env` file with at least 5 variables:  
>   `BACKUP_DIR`, `RETENTION_DAYS`, `MAX_SIZE_MB`, `S3_BUCKET`, `NOTIFY_EMAIL`
> - Load the config file at the start of the script
> - Add a `validate_config()` function that checks all 5 are non-empty
> - Print an active config summary block after loading
> - Make sure no values are hardcoded inside the script logic

**`config/backup.env`:**

```bash
BACKUP_DIR="/opt/backups"
RETENTION_DAYS=7
MAX_SIZE_MB=500
S3_BUCKET="s3://my-backups/myapp"
NOTIFY_EMAIL="ops@company.com"
```

**Expected solution:**

```bash
#!/bin/bash
set -euo pipefail

source ./log.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/backup.env"

load_config() {
  [[ -f "$CONFIG_FILE" ]] || { log ERROR "Config not found: $CONFIG_FILE"; exit 1; }
  source "$CONFIG_FILE"
  log INFO "Config loaded from $CONFIG_FILE"
}

validate_config() {
  local errors=0
  for var in BACKUP_DIR RETENTION_DAYS MAX_SIZE_MB S3_BUCKET NOTIFY_EMAIL; do
    [[ -z "${!var:-}" ]] && { log ERROR "Missing config: $var"; errors=$((errors+1)); }
  done
  [[ $errors -gt 0 ]] && { log ERROR "Validation failed: $errors error(s)"; exit 1; }
  log INFO "Config validation passed ✓"
}

load_config
validate_config

log INFO "─── Backup Config ──────────────────────────"
log INFO "Backup dir      : $BACKUP_DIR"
log INFO "Retention days  : $RETENTION_DAYS"
log INFO "Max size MB     : $MAX_SIZE_MB"
log INFO "S3 bucket       : $S3_BUCKET"
log INFO "Notify email    : $NOTIFY_EMAIL"
log INFO "────────────────────────────────────────────"

log INFO "Starting backup..."
# backup logic here
log INFO "Backup complete"
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| Config block at the top | Every value in one place — one change fixes everything |
| Derive variables from parents | `RELEASE_DIR="$APP_DIR/releases"` — change one, all follow |
| `"${VAR:-default}"` pattern | Works standalone, overridable without touching the script |
| Secrets from env vars | `"${SLACK_WEBHOOK:-}"` — never hardcode, never commit to Git |
| External `.env` files | Separate config from logic — ops edits files, not scripts |
| `${!var}` indirect reference | Loop over variable names to validate many at once cleanly |
| Print active config on start | Every run shows exactly what values are being used |
| `$SCRIPT_DIR` for portability | Script finds its own config files regardless of where it's called from |

---

## Project Structure So Far

```
myapp/
├── deploy.sh           # orchestrator — concepts 1–4 fully wired
├── log.sh              # reusable log() function
└── config/
    ├── dev.env         # dev environment values
    ├── staging.env     # staging environment values
    └── prod.env        # prod environment values
```

---

## What's Next

**Concept 5 — Preflight Checks**  
Before the first file is touched or the first S3 download starts, we will add a full preflight gate — disk space, port availability, AWS connectivity, required binaries — so deployments fail fast at the start, not halfway through.