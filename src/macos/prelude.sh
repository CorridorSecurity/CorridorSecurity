set -e
set -o pipefail

# Fixed PATH so utilities cannot be shadowed by the MDM agent's root environment.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LOG_PREFIX="[Corridor MDM]"
CORRIDOR_API_URL="https://app.corridor.dev/api"
CORRIDOR_CLI_INSTALL_URL="https://app.corridor.dev/cli/install.sh"
EXTENSION_INSTALL_TIMEOUT=60
EXTENSION_PHASE_TIMEOUT=150

# The MDM agent may run from a directory the console user cannot read; use a stable
# working directory so child processes do not emit getcwd errors.
cd /

log_info() {
    echo "$LOG_PREFIX INFO: $1"
}

log_error() {
    echo "$LOG_PREFIX ERROR: $1" >&2
}

log_warn() {
    echo "$LOG_PREFIX WARNING: $1"
}

log_success() {
    echo "$LOG_PREFIX SUCCESS: $1"
}

CLI_INSTALLER=""
CORRIDOR_TOKEN_FILE=""
EXTENSION_OUTPUT_FILE=""
cleanup() {
    if [ -n "$CLI_INSTALLER" ]; then
        rm -f "$CLI_INSTALLER"
    fi
    if [ -n "$CORRIDOR_TOKEN_FILE" ]; then
        rm -f "$CORRIDOR_TOKEN_FILE"
    fi
    if [ -n "$EXTENSION_OUTPUT_FILE" ]; then
        rm -f "$EXTENSION_OUTPUT_FILE"
    fi
}
trap cleanup EXIT

# Rejecting quotes, backslashes and whitespace here is what makes it safe to
# interpolate these values into JSON, curl config and file contents below.
is_safe_value() {
    if [ -z "$1" ] || [ "${#1}" -gt 256 ]; then
        return 1
    fi
    case "$1" in
        *[!A-Za-z0-9._@+=:/-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Stricter: account names become path components and a sudo -u target.
is_safe_username() {
    if [ -z "$1" ] || [ "${#1}" -gt 64 ]; then
        return 1
    fi
    case "$1" in
        -*|.*) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# MDM consoles store script output verbatim and do not redact secrets from it.
# Team tokens use cor-…; minted API tokens use cor_… — both must be scrubbed.
redact() {
    printf '%s' "$1" | tr -d '\n' | cut -c1-200 | sed -E 's/cor[_-][A-Za-z0-9._-]*/[redacted]/g'
}

kill_process_tree() {
    local parent_pid="$1"
    local child_pid
    for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null); do
        kill_process_tree "$child_pid"
    done
    kill -TERM "$parent_pid" 2>/dev/null || true
    kill -KILL "$parent_pid" 2>/dev/null || true
}

run_extension_install() {
    EXTENSION_OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/corridor-extension.XXXXXX")
    launchctl asuser "$CURRENT_USER_UID" sudo -u "$CURRENT_USER" \
        env NODE_USE_SYSTEM_CA=1 "$CLI_PATH" \
        --install-extension corridor.Corridor --force \
        > "$EXTENSION_OUTPUT_FILE" 2>&1 &
    local install_pid=$!
    local elapsed=0
    local phase_remaining=$((EXTENSION_PHASE_TIMEOUT - (SECONDS - EXTENSION_PHASE_START)))
    local install_timeout="$EXTENSION_INSTALL_TIMEOUT"
    if [ "$phase_remaining" -lt "$install_timeout" ]; then
        install_timeout="$phase_remaining"
    fi
    INSTALL_TIMEOUT_USED="$install_timeout"
    while kill -0 "$install_pid" 2>/dev/null; do
        if [ "$elapsed" -ge "$install_timeout" ]; then
            kill_process_tree "$install_pid"
            wait "$install_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$install_pid"
}
