# Concept 2 — Argument Parsing & Validation

> **Session:** Shell Scripting for DevOps — Real-Time Project Concepts  
> **Duration:** ~20 minutes  
> **Prerequisite:** Concept 1 — Structured Logging (`log()` function must be ready)

---

## Table of Contents

- [Why Do We Need This?](#why-do-we-need-this)
- [What Is Argument Parsing?](#what-is-argument-parsing)
- [Build It Step by Step](#build-it-step-by-step)
  - [Step 1 — Positional Arguments](#step-1--positional-arguments-the-basic-way)
  - [Step 2 — Named Flags with getopts](#step-2--named-flags-with-getopts)
  - [Step 3 — Input Validation](#step-3--input-validation)
  - [Step 4 — Usage / Help Message](#step-4--usage--help-message)
  - [Step 5 — Final Production-Ready Version](#step-5--final-production-ready-version)
- [Mini Exercise](#mini-exercise-for-participants)
- [Key Takeaways](#key-takeaways)

---

## Why Do We Need This?

### What beginners write

```bash
#!/bin/bash

ENV="prod"          # hardcoded
VERSION="1.4.2"     # hardcoded

echo "Deploying $VERSION to $ENV..."
```

**The problems with this:**

- ❌ You must edit the script every time you deploy a new version
- ❌ No way to reuse the same script for dev / staging / prod
- ❌ Someone will forget to change the value and deploy wrong version to prod
- ❌ No way to run it from a CI/CD pipeline with dynamic values

### What actually happens in production

```bash
# CI/CD pipeline calls your script like this
./deploy.sh -e prod -v 1.4.2

# Or a rollback
./deploy.sh --rollback

# Or someone tests on dev
./deploy.sh -e dev -v 1.5.0-beta
```

Your script must **accept inputs at runtime**, **validate them**, and **fail loudly** with a helpful message if something is wrong — not silently deploy to the wrong environment.

### Real-world incident scenario

> A junior engineer hardcoded `ENV="prod"` while testing locally,  
> committed the script, and the CI pipeline deployed a broken build  
> straight to production. No error. No warning. Silent failure.  
>
> **Proper argument parsing + validation would have caught this.**

---

## What Is Argument Parsing?

Argument parsing means your script accepts **inputs at runtime** instead of having values hardcoded inside.

There are two styles:

| Style | Example | When to use |
|---|---|---|
| **Positional** | `./deploy.sh prod 1.4.2` | Simple scripts, fixed order |
| **Named flags** | `./deploy.sh -e prod -v 1.4.2` | Production scripts, readable, order-independent |

Named flags are the **production standard** — always use them for DevOps scripts.

---

## Build It Step by Step

### Step 1 — Positional Arguments (The Basic Way)

Teach this first so participants understand `$1`, `$2`:

```bash
#!/bin/bash

# $0 = script name
# $1 = first argument
# $2 = second argument

ENV=$1
VERSION=$2

echo "Deploying version $VERSION to $ENV..."
```

**Run it:**

```bash
bash deploy.sh prod 1.4.2
```

**Output:**

```
Deploying version 1.4.2 to prod...
```

**The problem — run it wrong:**

```bash
bash deploy.sh 1.4.2 prod    # swapped — no error, wrong behavior
bash deploy.sh               # missing args — no error, deploys nothing
```

> ❌ Positional args break silently. Order matters and nobody enforces it.

---

### Step 2 — Named Flags with `getopts`

`getopts` is the built-in bash tool for parsing `-flag value` style arguments:

```bash
#!/bin/bash

# Source log function from Concept 1
source ./log.sh

ENV=""
VERSION=""

while getopts "e:v:" opt; do
  case $opt in
    e) ENV=$OPTARG ;;       # -e prod
    v) VERSION=$OPTARG ;;   # -v 1.4.2
    *) echo "Unknown option: $opt"; exit 1 ;;
  esac
done

log INFO "Environment : $ENV"
log INFO "Version     : $VERSION"
```

#### How `getopts` works

```
getopts "e:v:h"
         │ │ │
         │ │ └── -h flag (no colon = no value expected)
         │ └──── -v flag (colon = expects a value after it)
         └────── -e flag (colon = expects a value after it)
```

| Variable | Meaning |
|---|---|
| `$opt` | The current flag letter (`e`, `v`, `h`) |
| `$OPTARG` | The value passed after the flag (`prod`, `1.4.2`) |

**Run it:**

```bash
bash deploy.sh -e prod -v 1.4.2
bash deploy.sh -v 1.4.2 -e prod    # order doesn't matter anymore
```

**Output:**

```
2024-06-12T09:15:32 [myapp] [INFO ] Environment : prod
2024-06-12T09:15:32 [myapp] [INFO ] Version     : 1.4.2
```

> ✅ Order-independent, readable, and self-documenting.

---

### Step 3 — Input Validation

Flags are parsed — but what if someone passes an empty value or a wrong environment name?

```bash
#!/bin/bash

source ./log.sh

ENV=""
VERSION=""

while getopts "e:v:" opt; do
  case $opt in
    e) ENV=$OPTARG ;;
    v) VERSION=$OPTARG ;;
    *) exit 1 ;;
  esac
done

# ─── Validation ───────────────────────────────────────

# Check required flags are provided
if [[ -z "$ENV" ]]; then
  log ERROR "Environment (-e) is required"
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  log ERROR "Version (-v) is required"
  exit 1
fi

# Check environment is one of the allowed values
if [[ ! "$ENV" =~ ^(dev|staging|prod)$ ]]; then
  log ERROR "Invalid environment '$ENV'. Allowed: dev | staging | prod"
  exit 1
fi

# Check version format matches semantic versioning (e.g. 1.4.2)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  log ERROR "Invalid version '$VERSION'. Expected format: X.Y.Z (e.g. 1.4.2)"
  exit 1
fi

log INFO "Validation passed — deploying v$VERSION to $ENV"
```

**Run valid input:**

```bash
bash deploy.sh -e prod -v 1.4.2
# 2024-06-12T09:15:32 [myapp] [INFO ] Validation passed — deploying v1.4.2 to prod
```

**Run invalid inputs — show each one to the class:**

```bash
bash deploy.sh -e production -v 1.4.2
# [ERROR] Invalid environment 'production'. Allowed: dev | staging | prod

bash deploy.sh -e prod -v latest
# [ERROR] Invalid version 'latest'. Expected format: X.Y.Z (e.g. 1.4.2)

bash deploy.sh -e prod
# [ERROR] Version (-v) is required
```

> ✅ Every bad input produces a **clear, actionable error message** — no silent failures.

---

### Step 4 — Usage / Help Message

Every production script must have a `-h` flag that prints usage instructions:

```bash
#!/bin/bash

source ./log.sh

usage() {
  echo ""
  echo "  Usage: $(basename "$0") [OPTIONS]"
  echo ""
  echo "  Options:"
  echo "    -e <environment>   Target environment: dev | staging | prod"
  echo "    -v <version>       App version to deploy: e.g. 1.4.2"
  echo "    -r                 Rollback to previous release"
  echo "    -h                 Show this help message"
  echo ""
  echo "  Examples:"
  echo "    $(basename "$0") -e prod -v 1.4.2"
  echo "    $(basename "$0") -e staging -v 2.0.0-beta"
  echo "    $(basename "$0") -r"
  echo ""
  exit 0
}

ENV=""
VERSION=""
ROLLBACK=false

while getopts "e:v:rh" opt; do
  case $opt in
    e) ENV=$OPTARG ;;
    v) VERSION=$OPTARG ;;
    r) ROLLBACK=true ;;
    h) usage ;;
    *) usage ;;     # unknown flag → show help
  esac
done
```

**Run it:**

```bash
bash deploy.sh -h
```

**Output:**

```
  Usage: deploy.sh [OPTIONS]

  Options:
    -e <environment>   Target environment: dev | staging | prod
    -v <version>       App version to deploy: e.g. 1.4.2
    -r                 Rollback to previous release
    -h                 Show this help message

  Examples:
    deploy.sh -e prod -v 1.4.2
    deploy.sh -e staging -v 2.0.0-beta
    deploy.sh -r
```

> ✅ `$(basename "$0")` automatically uses the actual script name — no hardcoding.

---

### Step 5 — Final Production-Ready Version

Bringing everything together — log function + flags + validation + usage:

```bash
#!/bin/bash
# deploy.sh — Webapp deployment script
# Usage: ./deploy.sh -e <environment> -v <version>
# Usage: ./deploy.sh -r (rollback)

set -euo pipefail

# ─── Source Logging (from Concept 1) ─────────────────
APP_NAME="myapp"
LOG_DIR="/var/log/$APP_NAME"
LOG_FILE="$LOG_DIR/deploy.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

mkdir -p "$LOG_DIR"

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

# ─── Usage ────────────────────────────────────────────
usage() {
  echo ""
  echo "  Usage: $(basename "$0") [OPTIONS]"
  echo ""
  echo "  Options:"
  echo "    -e <environment>   Target environment: dev | staging | prod"
  echo "    -v <version>       App version: e.g. 1.4.2"
  echo "    -r                 Rollback to previous release"
  echo "    -h                 Show this help message"
  echo ""
  echo "  Examples:"
  echo "    $(basename "$0") -e prod -v 1.4.2"
  echo "    $(basename "$0") -e dev  -v 2.0.0-beta"
  echo "    $(basename "$0") -r"
  echo ""
  exit 0
}

# ─── Parse Arguments ──────────────────────────────────
ENV=""
VERSION=""
ROLLBACK=false

while getopts "e:v:rh" opt; do
  case $opt in
    e) ENV=$OPTARG ;;
    v) VERSION=$OPTARG ;;
    r) ROLLBACK=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# ─── Validation ───────────────────────────────────────
validate_inputs() {
  if $ROLLBACK; then
    log INFO "Rollback mode activated — skipping input validation"
    return 0
  fi

  [[ -z "$ENV"     ]] && { log ERROR "Environment (-e) is required"; usage; }
  [[ -z "$VERSION" ]] && { log ERROR "Version (-v) is required";     usage; }

  [[ "$ENV" =~ ^(dev|staging|prod)$ ]] || {
    log ERROR "Invalid environment '$ENV'. Allowed: dev | staging | prod"
    exit 1
  }

  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]] || {
    log ERROR "Invalid version '$VERSION'. Expected: X.Y.Z or X.Y.Z-suffix"
    exit 1
  }

  log INFO "Inputs validated — ENV=$ENV | VERSION=$VERSION"
}

# ─── Main ─────────────────────────────────────────────
validate_inputs

if $ROLLBACK; then
  log WARN "Starting rollback..."
  # rollback logic will come in Concept 7
else
  log INFO "Starting deployment of v$VERSION to $ENV..."
  # deploy logic will come in Concept 6 & 7
fi
```

**Test all scenarios with the class:**

```bash
# Valid deploy
./deploy.sh -e prod -v 1.4.2

# Valid deploy with pre-release version
./deploy.sh -e staging -v 2.0.0-beta

# Rollback
./deploy.sh -r

# Missing env
./deploy.sh -v 1.4.2

# Wrong environment name
./deploy.sh -e production -v 1.4.2

# Bad version format
./deploy.sh -e dev -v latest

# Help
./deploy.sh -h
```

---

## Mini Exercise for Participants

> **Task:** Write a script called `backup.sh` that accepts:
>
> - `-d <directory>` — directory to back up (required)
> - `-t <type>` — backup type: `full` or `incremental` (required)
> - `-o <output>` — output path for backup file (optional, default: `/tmp/backup`)
> - `-h` — show usage
>
> It should:
> - Validate all required flags are provided
> - Validate `-t` is either `full` or `incremental`
> - Log each step using the `log()` function from Concept 1
> - Print a clear usage message when `-h` is passed or input is invalid

**Expected solution:**

```bash
#!/bin/bash

source ./log.sh

usage() {
  echo ""
  echo "  Usage: $(basename "$0") [OPTIONS]"
  echo ""
  echo "  Options:"
  echo "    -d <directory>   Directory to back up (required)"
  echo "    -t <type>        Backup type: full | incremental (required)"
  echo "    -o <output>      Output path (default: /tmp/backup)"
  echo "    -h               Show help"
  echo ""
  exit 0
}

DIR=""
TYPE=""
OUTPUT="/tmp/backup"

while getopts "d:t:o:h" opt; do
  case $opt in
    d) DIR=$OPTARG ;;
    t) TYPE=$OPTARG ;;
    o) OUTPUT=$OPTARG ;;
    h) usage ;;
    *) usage ;;
  esac
done

[[ -z "$DIR"  ]] && { log ERROR "Directory (-d) is required"; usage; }
[[ -z "$TYPE" ]] && { log ERROR "Backup type (-t) is required"; usage; }

[[ "$TYPE" =~ ^(full|incremental)$ ]] || {
  log ERROR "Invalid type '$TYPE'. Allowed: full | incremental"
  exit 1
}

log INFO "Starting $TYPE backup of $DIR → $OUTPUT"
# backup logic goes here
log INFO "Backup complete"
```

---

## Key Takeaways

| Lesson | One Line Summary |
|---|---|
| Never hardcode environment values | Scripts must be reusable across dev / staging / prod |
| Use named flags over positional args | `-e prod` is readable; `$1 $2` breaks on wrong order |
| Always validate inputs | Catch bad values before they cause silent production failures |
| Use `[[ =~ regex ]]` for pattern validation | Cleanest way to validate version format and env names |
| Always include a `usage()` function | Every script someone else runs needs a help message |
| `$(basename "$0")` for script name | Self-referencing — works even if script is renamed |

---

## What's Next

**Concept 3 — Exit Codes & Error Handling**  
We will add `set -euo pipefail`, `trap` on failure, and proper exit codes on top of the script we built today — so the deployment pipeline stops immediately when something goes wrong instead of silently continuing.