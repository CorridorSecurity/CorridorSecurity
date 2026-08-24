#!/bin/bash
#
# Corridor MDM Provisioning Script for Fleet MacOS Devices
#
# Detects installed editors (Cursor, VS Code, Windsurf, Devin Desktop), installs
# the Corridor extension on each, installs the Corridor CLI, and provisions
# per-platform API tokens for the signed-in user.
#
# Configuration:
#   CORRIDOR_TEAM_TOKEN - Your team's Universal Team Token (required). Set as a
#     Fleet custom variable named CORRIDOR_TEAM_TOKEN; Fleet substitutes it and
#     masks it in the Fleet UI and API.
#   CORRIDOR_CLI_SHA256 - Optional expected SHA-256 of the CLI installer.
#
# The user's email and device serial are read from
# /Library/Managed Preferences/dev.corridor.mdm.plist, delivered by the
# fleet-dev.corridor.mdm.mobileconfig configuration profile in this directory.
#
# Setup instructions: https://docs.corridor.dev/administration/mdm-support
#
# ============================================================================
# CONFIGURATION - Replace with your actual values
# ============================================================================
CORRIDOR_CLI_SHA256=''

# ============================================================================
# SCRIPT LOGIC - Do not modify below this line
# ============================================================================

set -e
set -o pipefail

# Fixed PATH so utilities cannot be shadowed by fleetd's root environment.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LOG_PREFIX="[Corridor MDM]"
CORRIDOR_API_URL="https://app.corridor.dev/api"
CORRIDOR_CLI_INSTALL_URL="https://app.corridor.dev/cli/install.sh"
MANAGED_PLIST="/Library/Managed Preferences/dev.corridor.mdm.plist"
EXTENSION_INSTALL_TIMEOUT=60
EXTENSION_PHASE_TIMEOUT=150

# Fleet may run from a directory the console user cannot read; use a stable
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

# Fleet stores script output verbatim and does not redact secrets from it.
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

# Quoted heredoc written to a mode-600 temporary file: this mirrors the
# mechanism proven to work in this Fleet tenant. Reading the single token line
# strips its trailing newline, then the file is removed immediately.
ORIGINAL_UMASK=$(umask)
umask 077
CORRIDOR_TOKEN_FILE=$(mktemp "${TMPDIR:-/tmp}/corridor-team-token.XXXXXX")
cat <<'FLEET_TOKEN_EOF' > "$CORRIDOR_TOKEN_FILE"
$FLEET_SECRET_CORRIDOR_TEAM_TOKEN
FLEET_TOKEN_EOF
IFS= read -r CORRIDOR_TEAM_TOKEN < "$CORRIDOR_TOKEN_FILE"
rm -f "$CORRIDOR_TOKEN_FILE"
CORRIDOR_TOKEN_FILE=""
umask "$ORIGINAL_UMASK"

# An undefined Fleet variable leaves the literal placeholder in place.
case "$CORRIDOR_TEAM_TOKEN" in
    "")
        log_error "CORRIDOR_TEAM_TOKEN is not configured: value came through empty (character count: 0). Define the CORRIDOR_TEAM_TOKEN custom variable in Fleet or set your team token in this script."
        exit 1
        ;;
    *FLEET_SECRET_CORRIDOR_TEAM_TOKEN*)
        log_error "CORRIDOR_TEAM_TOKEN is not configured: Fleet left the placeholder in place (character count: ${#CORRIDOR_TEAM_TOKEN}). Define the CORRIDOR_TEAM_TOKEN custom variable in Fleet or set your team token in this script."
        exit 1
        ;;
    "cor-team_...")
        log_error "CORRIDOR_TEAM_TOKEN is not configured: documentation placeholder is still present (character count: ${#CORRIDOR_TEAM_TOKEN}). Define the CORRIDOR_TEAM_TOKEN custom variable in Fleet or set your team token in this script."
        exit 1
        ;;
esac

if ! is_safe_value "$CORRIDOR_TEAM_TOKEN"; then
    log_error "CORRIDOR_TEAM_TOKEN contains unexpected characters. Re-copy the Universal Team Token into the Fleet custom variable without surrounding quotes or whitespace."
    exit 1
fi

# ============================================================================
# Read device configuration from the managed plist
# ============================================================================
# MDM writes this path as root; anything else means the identity is not
# authoritative.
if [ -L "$MANAGED_PLIST" ] || [ ! -f "$MANAGED_PLIST" ]; then
    log_error "Managed preferences file not found at $MANAGED_PLIST. Deploy fleet-dev.corridor.mdm.mobileconfig as a Fleet configuration profile and confirm it has been delivered to this host."
    exit 1
fi

if [ "$(stat -f '%u' "$MANAGED_PLIST")" != "0" ]; then
    log_error "$MANAGED_PLIST is not owned by root. Refusing to read device identity from it."
    exit 1
fi

# plutil reads the file directly, bypassing cfprefsd's cached view.
DEVICE_SERIAL=$(plutil -extract SerialNumber raw -o - "$MANAGED_PLIST" 2>/dev/null || echo "")
USER_EMAIL=$(plutil -extract UserEmail raw -o - "$MANAGED_PLIST" 2>/dev/null || echo "")

if [ -z "$DEVICE_SERIAL" ]; then
    log_error "Could not retrieve device serial number. Ensure the Fleet configuration profile pushes SerialNumber to $MANAGED_PLIST."
    exit 1
fi
if ! is_safe_value "$DEVICE_SERIAL"; then
    log_error "Device serial from $MANAGED_PLIST contains unexpected characters. Refusing to use it."
    exit 1
fi
log_info "Device Serial: $DEVICE_SERIAL"

if [ -z "$USER_EMAIL" ]; then
    log_error "Could not retrieve user email. Ensure the Fleet configuration profile pushes UserEmail to $MANAGED_PLIST, and that Fleet knows this host's end user."
    exit 1
fi
if ! is_safe_value "$USER_EMAIL"; then
    log_error "User email from $MANAGED_PLIST contains unexpected characters. Refusing to use it."
    exit 1
fi
case "$USER_EMAIL" in
    *@*.*) ;;
    *)
        log_error "Value pushed as UserEmail ('$USER_EMAIL') is not an email address. Fleet's FLEET_VAR_HOST_END_USER_IDP_USERNAME resolves to the IdP username, which must be the user's email for Corridor provisioning."
        exit 1
        ;;
esac
log_info "User email: $USER_EMAIL"

# ============================================================================
# Resolve the target user
# ============================================================================
# Console owner only. A "most recent GUI user" fallback would provision the
# MDM-assigned user's token into whichever account last logged in.
CURRENT_USER=$(stat -f "%Su" /dev/console)

case "$CURRENT_USER" in
    ""|root|_*)
        log_info "No user is signed in at the console (console owner: '${CURRENT_USER:-unknown}'). Skipping provisioning; this run will be retried on the next check-in."
        exit 0
        ;;
esac

if ! is_safe_username "$CURRENT_USER"; then
    log_error "Console user name '$CURRENT_USER' contains unexpected characters. Refusing to provision."
    exit 1
fi

CURRENT_USER_UID=$(id -u "$CURRENT_USER" 2>/dev/null || echo "")
case "$CURRENT_USER_UID" in
    ""|*[!0-9]*)
        log_error "Could not resolve a numeric UID for console user '$CURRENT_USER'."
        exit 1
        ;;
esac
if [ "$CURRENT_USER_UID" -lt 500 ]; then
    log_info "Console user '$CURRENT_USER' is a system account (UID $CURRENT_USER_UID). Skipping provisioning."
    exit 0
fi

# dscl wraps long values onto a second line, so flatten before stripping the key.
USER_HOME=$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory 2>/dev/null \
    | tr '\n' ' ' | sed 's/^NFSHomeDirectory: *//; s/ *$//')
if [ -z "$USER_HOME" ] || [ -L "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    log_error "Could not resolve a home directory for '$CURRENT_USER'."
    exit 1
fi
if [ "$(stat -f '%u' "$USER_HOME")" != "$CURRENT_USER_UID" ]; then
    log_error "Home directory $USER_HOME is not owned by '$CURRENT_USER'. Refusing to provision."
    exit 1
fi
log_info "Current User: $CURRENT_USER ($USER_HOME)"

EMAIL_LOCAL_PART="${USER_EMAIL%%@*}"
if [ "$CURRENT_USER" != "$EMAIL_LOCAL_PART" ]; then
    log_warn "Console user '$CURRENT_USER' does not match the MDM-assigned user '$USER_EMAIL'. Tokens for $USER_EMAIL will be written to $USER_HOME - confirm this device is assigned to the person using it."
fi

CORRIDOR_CONFIG_DIR="$USER_HOME/.corridor"

# ============================================================================
# Install the Corridor CLI
# ============================================================================
# Runs as the interactive user so HOME resolves to their ~/.corridor. CI=1 skips
# the interactive plugin setup; CORRIDOR_MDM=1 marks this a persistent managed
# device. Downloaded to a file rather than piped to bash so a truncated download
# cannot partially execute and the bytes can be checksummed first.
log_info "Installing the Corridor CLI for $CURRENT_USER..."

CLI_INSTALLED="false"

if ! CLI_INSTALLER=$(sudo -u "$CURRENT_USER" mktemp /tmp/corridor-cli-install.XXXXXX); then
    CLI_INSTALLER=""
    log_error "Could not create a temporary file to download the Corridor CLI installer (continuing with extension provisioning)"
elif ! sudo -u "$CURRENT_USER" curl -fsSL \
    --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 120 \
    --retry 2 --retry-connrefused \
    -o "$CLI_INSTALLER" "$CORRIDOR_CLI_INSTALL_URL"; then
    log_error "Failed to download the Corridor CLI installer (continuing with extension provisioning)"
elif [ ! -s "$CLI_INSTALLER" ]; then
    log_error "Downloaded Corridor CLI installer is empty (continuing with extension provisioning)"
else
    INSTALLER_SHA256=$(sudo -u "$CURRENT_USER" shasum -a 256 "$CLI_INSTALLER" | awk '{print $1}')
    if [ -n "$CORRIDOR_CLI_SHA256" ] && [ "$INSTALLER_SHA256" != "$CORRIDOR_CLI_SHA256" ]; then
        log_error "Corridor CLI installer checksum mismatch (expected $CORRIDOR_CLI_SHA256, got $INSTALLER_SHA256). Refusing to run it."
    else
        if [ -z "$CORRIDOR_CLI_SHA256" ]; then
            log_info "Corridor CLI installer SHA-256 is $INSTALLER_SHA256 (not verified - set CORRIDOR_CLI_SHA256 to pin it)"
        fi
        if sudo -u "$CURRENT_USER" env HOME="$USER_HOME" CI=1 CORRIDOR_MDM=1 \
            bash "$CLI_INSTALLER"; then
            log_success "Corridor CLI installed successfully"
            CLI_INSTALLED="true"
        else
            log_error "Failed to install the Corridor CLI (continuing with extension provisioning)"
        fi
    fi
fi

rm -f "$CLI_INSTALLER"
CLI_INSTALLER=""

# ============================================================================
# Detect editors and install the Corridor extension
# ============================================================================
# bash 3.x compatible - no associative arrays.
EDITOR_NAMES="Cursor VSCode Windsurf Devin"

get_editor_app_name() {
    case "$1" in
        Cursor)   echo "Cursor.app" ;;
        VSCode)   echo "Visual Studio Code.app" ;;
        Windsurf) echo "Windsurf.app" ;;
        Devin)    echo "Devin.app" ;;
    esac
}

get_editor_platform() {
    case "$1" in
        Cursor)   echo "cursor" ;;
        VSCode)   echo "vscode" ;;
        Windsurf) echo "windsurf" ;;
        # Placeholder until Corridor adds a dedicated Devin Desktop platform.
        Devin)    echo "windsurf" ;;
    esac
}

get_editor_cli() {
    case "$1" in
        Cursor)   echo "cursor" ;;
        VSCode)   echo "code" ;;
        Windsurf) echo "windsurf" ;;
        Devin)    echo "devin-desktop" ;;
    esac
}

get_editor_app() {
    echo "/Applications/$(get_editor_app_name "$1")"
}

# VS Code in particular is often left in ~/Downloads.
get_editor_app_alternative() {
    echo "$USER_HOME/Downloads/$(get_editor_app_name "$1")"
}

get_editor_cli_path() {
    echo "/Applications/$(get_editor_app_name "$1")/Contents/Resources/app/bin/$(get_editor_cli "$1")"
}

get_editor_cli_path_alternative() {
    echo "$USER_HOME/Downloads/$(get_editor_app_name "$1")/Contents/Resources/app/bin/$(get_editor_cli "$1")"
}

get_editor_ext_dir() {
    case "$1" in
        Cursor)  echo ".cursor/extensions" ;;
        VSCode)  echo ".vscode/extensions" ;;
        Windsurf) echo ".windsurf/extensions" ;;
        Devin)   echo ".devin/extensions" ;;
    esac
}

INSTALLED_EDITORS=""
EDITOR_PATHS=""  # Track which path each editor was found at

for editor in $EDITOR_NAMES; do
    APP_PATH=$(get_editor_app "$editor")
    ALT_PATH=$(get_editor_app_alternative "$editor")

    if [ -d "$APP_PATH" ]; then
        INSTALLED_EDITORS="$INSTALLED_EDITORS $editor"
        EDITOR_PATHS="$EDITOR_PATHS $editor:standard"
        log_info "$editor detected at $APP_PATH"
    elif [ -d "$ALT_PATH" ]; then
        INSTALLED_EDITORS="$INSTALLED_EDITORS $editor"
        EDITOR_PATHS="$EDITOR_PATHS $editor:alternative"
        log_info "$editor detected at $ALT_PATH"
    fi
done

INSTALLED_EDITORS=$(echo "$INSTALLED_EDITORS" | sed 's/^ *//')

# One platform per installed editor, plus "cli" if the CLI installed.
PROVISION_PLATFORMS=""
for editor in $INSTALLED_EDITORS; do
    PLATFORM=$(get_editor_platform "$editor")
    case " $PROVISION_PLATFORMS " in
        *" $PLATFORM "*) ;;
        *) PROVISION_PLATFORMS="$PROVISION_PLATFORMS $PLATFORM" ;;
    esac
done
if [ "$CLI_INSTALLED" = "true" ]; then
    case " $PROVISION_PLATFORMS " in
        *" cli "*) ;;
        *) PROVISION_PLATFORMS="$PROVISION_PLATFORMS cli" ;;
    esac
fi
PROVISION_PLATFORMS=$(echo "$PROVISION_PLATFORMS" | sed 's/^ *//')

if [ -z "$INSTALLED_EDITORS" ]; then
    log_info "No supported editors (Cursor, VS Code, Windsurf, Devin) are installed. Skipping Corridor extension installation."
    if [ -z "$PROVISION_PLATFORMS" ]; then
        exit 0
    fi
fi

skip_remaining_editors() {
    if [ -n "$REMAINING_EDITORS" ]; then
        log_warn "Editor extension phase budget of ${EXTENSION_PHASE_TIMEOUT}s exhausted; skipping editors: $REMAINING_EDITORS. They will be retried on the next check-in."
    fi
}

EXTENSION_PHASE_START=$SECONDS
REMAINING_EDITORS="$INSTALLED_EDITORS"
for editor in $INSTALLED_EDITORS; do
    [ -z "$editor" ] && continue

    if [ "$((SECONDS - EXTENSION_PHASE_START))" -ge "$EXTENSION_PHASE_TIMEOUT" ]; then
        skip_remaining_editors
        break
    fi
    REMAINING_EDITORS="${REMAINING_EDITORS#"$editor"}"
    REMAINING_EDITORS="${REMAINING_EDITORS# }"

    if echo "$EDITOR_PATHS" | grep -q "$editor:alternative"; then
        CLI_PATH=$(get_editor_cli_path_alternative "$editor")
    else
        CLI_PATH=$(get_editor_cli_path "$editor")
    fi
    EXT_DIR="$USER_HOME/$(get_editor_ext_dir "$editor")"

    if [ -z "$CLI_PATH" ]; then
        log_error "Unknown editor: $editor"
        exit 1
    fi

    if [ ! -f "$CLI_PATH" ]; then
        log_error "$editor CLI not found at $CLI_PATH"
        exit 1
    fi

    log_info "Installing Corridor extension for $editor..."

    # NODE_USE_SYSTEM_CA=1 adds the macOS System keychain to the editor's bundled
    # CA list, so installs work behind TLS-intercepting proxies (Zscaler, etc.).
    INSTALL_STATUS=0
    run_extension_install || INSTALL_STATUS=$?
    INSTALL_OUTPUT=$(cat "$EXTENSION_OUTPUT_FILE")
    rm -f "$EXTENSION_OUTPUT_FILE"
    EXTENSION_OUTPUT_FILE=""

    if [ "$INSTALL_STATUS" -eq 124 ]; then
        log_warn "Timed out installing the Corridor extension for $editor after ${INSTALL_TIMEOUT_USED}s; it will be retried on the next check-in."
        if [ "$((SECONDS - EXTENSION_PHASE_START))" -ge "$EXTENSION_PHASE_TIMEOUT" ]; then
            skip_remaining_editors
            break
        fi
        continue
    fi

    if echo "$INSTALL_OUTPUT" | grep -qi "already installed"; then
        log_info "Corridor extension is already installed for $editor"
    elif echo "$INSTALL_OUTPUT" | grep -qi "successfully installed\|was successfully installed"; then
        log_success "Corridor extension installed successfully for $editor"
    else
        if ls "$EXT_DIR" 2>/dev/null | grep -qi "corridor"; then
            log_info "Corridor extension is already installed for $editor"
        else
            log_error "Failed to install Corridor extension for $editor: $(redact "$INSTALL_OUTPUT")"
            exit 1
        fi
    fi
done

# ============================================================================
# Provision an API token per platform
# ============================================================================
log_info "Provisioning user with Corridor..."
PLATFORM_FAILURE=0

for PLATFORM in $PROVISION_PLATFORMS; do
    PLATFORM_CONFIG_DIR="$CORRIDOR_CONFIG_DIR/$PLATFORM"

    log_info "Creating API token for $PLATFORM..."

    REQUEST_BODY=$(printf '{"deviceSerial": "%s", "userEmail": "%s", "platform": "%s"}' \
        "$DEVICE_SERIAL" "$USER_EMAIL" "$PLATFORM")

    # Token goes through a config file on stdin to keep this team-wide credential
    # out of argv. No --retry: this call mints a token, so a retried POST would
    # leave extra live credentials behind.
    if ! RESPONSE=$(printf 'header = "Authorization: Bearer %s"\n' "$CORRIDOR_TEAM_TOKEN" \
        | curl -s --config - \
            --proto '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 60 \
            -w "\n%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$REQUEST_BODY" \
            "$CORRIDOR_API_URL/extension-auth/mdm-sync-device"); then
        log_error "Could not reach $CORRIDOR_API_URL to provision $PLATFORM"
        exit 1
    fi

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" != "200" ]; then
        log_warn "Failed to provision token for $PLATFORM. HTTP $HTTP_CODE: $(redact "$BODY")"
        PLATFORM_FAILURE=1
        continue
    fi

    API_TOKEN=$(printf '%s' "$BODY" | sed -n 's/.*"apiToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    API_TOKEN_ID=$(printf '%s' "$BODY" | sed -n 's/.*"apiTokenId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    if [ -z "$API_TOKEN" ]; then
        log_error "Could not extract API token from response for $PLATFORM"
        exit 1
    fi
    if ! is_safe_value "$API_TOKEN" || ! is_safe_value "$API_TOKEN_ID"; then
        log_error "API token response for $PLATFORM contains unexpected characters. Refusing to store it."
        exit 1
    fi

    TOKEN_JSON=$(printf '{\n  "apiToken": "%s",\n  "apiTokenId": "%s",\n  "provisionedAt": "%s"\n}\n' \
        "$API_TOKEN" "$API_TOKEN_ID" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")")

    # Written as the target user, not root: the destination is a directory the
    # user owns, so a root-context mkdir or redirect could be aimed anywhere via
    # a symlink they planted. umask 077 covers creation, the chmods cover a
    # pre-existing directory, and the token arrives on stdin to stay out of argv.
    if ! printf '%s' "$TOKEN_JSON" | sudo -u "$CURRENT_USER" bash -c '
        umask 077
        config_dir="$1"
        platform_dir="$2"
        mkdir -p "$platform_dir" || exit 1
        chmod 700 "$config_dir" "$platform_dir" || exit 1
        cat > "$platform_dir/pending-token" || exit 1
        chmod 600 "$platform_dir/pending-token" || exit 1
    ' _ "$CORRIDOR_CONFIG_DIR" "$PLATFORM_CONFIG_DIR"; then
        log_error "Failed to store the pending token for $PLATFORM under $PLATFORM_CONFIG_DIR"
        exit 1
    fi

    log_info "Pending token for $PLATFORM stored in $PLATFORM_CONFIG_DIR/pending-token"
done

if [ "$PLATFORM_FAILURE" -eq 0 ]; then
    log_success "User provisioned successfully!"
else
    log_warn "One or more platform token provisions failed; successful platforms were processed."
fi
log_info "The Corridor extension will migrate tokens to secure storage on next launch of that editor"

# ============================================================================
# Install agent plugins (Claude Code, Factory Droid, Codex)
# ============================================================================
# `corridor install` migrates the pending CLI token into ~/.corridor/config.env
# and authenticates from it. A missing agent CLI is a non-fatal no-op.
if [ "$CLI_INSTALLED" = "true" ]; then
    log_info "Setting up Corridor agent plugins (Claude Code, etc.) for $CURRENT_USER..."
    if sudo -u "$CURRENT_USER" env HOME="$USER_HOME" \
        PATH="$USER_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        "$CORRIDOR_CONFIG_DIR/bin/corridor" install --yes; then
        log_success "Corridor agent plugins installed"
    else
        log_info "Corridor agent plugin setup skipped or incomplete (non-fatal — e.g. no claude/droid/codex in PATH, or install did not finish). See corridor output above for the cause."
    fi
fi

if [ "$PLATFORM_FAILURE" -ne 0 ]; then
    log_error "Corridor provisioning completed with one or more platform token failures."
    exit 1
fi

log_success "Corridor MDM provisioning complete!"
exit 0
