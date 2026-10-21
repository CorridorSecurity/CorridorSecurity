#!/bin/bash
# GENERATED from src/macos/jamf.sh by scripts/build.sh - edit the source, not this file.
#
# Corridor MDM Provisioning Script for Jamf Pro MacOS Devices
#
# This script is designed to be deployed via Jamf Pro as a policy script.
# It detects if supported editors (Cursor, VS Code, Windsurf, Devin Desktop)
# are installed, installs the Corridor extension on all detected editors,
# installs the Corridor CLI, and provisions the user with API tokens for
# authentication.
#
# Configuration:
#   CORRIDOR_TEAM_TOKEN - Your team's Universal Team Token (required)
#   CORRIDOR_CLI_SHA256 - Optional expected SHA-256 of the CLI installer.
#
# Device Configuration (via Jamf Pro configuration profile):
#   This script reads device-specific values from a managed plist:
#     /Library/Managed Preferences/dev.corridor.mdm.plist
#   Keys:
#     UserEmail    - The user's email address
#     SerialNumber - The device serial number
#
# Jamf Pro Setup:
#   1. Get a Universal Team Token from your Corridor team settings
#   2. Replace the CORRIDOR_TEAM_TOKEN value below with your token
#   3. Create a configuration profile that pushes a plist to
#      /Library/Managed Preferences/dev.corridor.mdm.plist with
#      the UserEmail and SerialNumber keys
#   4. Add this script to Jamf Pro under Settings > Scripts
#   5. Create a policy, add this script, and scope it to your target computers
#
# ============================================================================
# CONFIGURATION - Replace with your actual values
# ============================================================================
CORRIDOR_TEAM_TOKEN="cor-team_..."
CORRIDOR_CLI_SHA256=''

# ============================================================================
# SCRIPT LOGIC - Do not modify below this line
# ============================================================================

set -e
set -o pipefail

# Fixed PATH so utilities cannot be shadowed by the MDM agent's root environment.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LOG_PREFIX="[Corridor MDM]"
CORRIDOR_API_URL="https://app.corridor.dev/api"
CORRIDOR_CLI_INSTALL_URL="https://app.corridor.dev/cli/install.sh"
# First CLI release with `corridor mdm provision`. Older CLIs use the in-script path.
CORRIDOR_MIN_PROVISION_VERSION="0.0.91"

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
if [ -z "$CORRIDOR_TEAM_TOKEN" ] || [ "$CORRIDOR_TEAM_TOKEN" = "cor-team_..." ]; then
    log_error "CORRIDOR_TEAM_TOKEN is not configured. Set your team token in the configuration section at the top of this script."
    exit 1
fi

if ! is_safe_value "$CORRIDOR_TEAM_TOKEN"; then
    log_error "CORRIDOR_TEAM_TOKEN contains unexpected characters. Re-copy the Universal Team Token without surrounding quotes or whitespace."
    exit 1
fi


MANAGED_PLIST="/Library/Managed Preferences/dev.corridor.mdm.plist"
PLIST_SERIAL_KEY="SerialNumber"
PLIST_EMAIL_KEY="UserEmail"
PLIST_PROFILE_NAME="the configuration profile"
PLIST_MISSING_HINT="Deploy dev.corridor.mdm.plist as a Jamf Pro configuration profile and confirm it has been delivered to this host."
IDENTITY_SOURCE="$MANAGED_PLIST"
# ============================================================================
# Read device configuration from the managed plist
# ============================================================================
# Expects MANAGED_PLIST, PLIST_SERIAL_KEY, PLIST_EMAIL_KEY, IDENTITY_SOURCE and
# the hint variables used in the messages below.
# MDM writes this path as root; anything else means the identity is not
# authoritative.
if [ -L "$MANAGED_PLIST" ] || [ ! -f "$MANAGED_PLIST" ]; then
    log_error "Managed preferences file not found at $MANAGED_PLIST. $PLIST_MISSING_HINT"
    exit 1
fi

if [ "$(stat -f '%u' "$MANAGED_PLIST")" != "0" ]; then
    log_error "$MANAGED_PLIST is not owned by root. Refusing to read device identity from it."
    exit 1
fi

# plutil reads the file directly, bypassing cfprefsd's cached view.
DEVICE_SERIAL=$(plutil -extract "$PLIST_SERIAL_KEY" raw -o - "$MANAGED_PLIST" 2>/dev/null || echo "")
USER_EMAIL=$(plutil -extract "$PLIST_EMAIL_KEY" raw -o - "$MANAGED_PLIST" 2>/dev/null || echo "")

if [ -z "$DEVICE_SERIAL" ]; then
    log_error "Could not retrieve device serial number. Ensure $PLIST_PROFILE_NAME pushes $PLIST_SERIAL_KEY to $MANAGED_PLIST."
    exit 1
fi

if [ -z "$USER_EMAIL" ]; then
    log_error "Could not retrieve user email. Ensure $PLIST_PROFILE_NAME pushes $PLIST_EMAIL_KEY to $MANAGED_PLIST${PLIST_EMAIL_EMPTY_HINT:+, $PLIST_EMAIL_EMPTY_HINT}."
    exit 1
fi

# ============================================================================
# Validate device identity
# ============================================================================
# IDENTITY_SOURCE names where the values came from, for error messages.
if ! is_safe_value "$DEVICE_SERIAL"; then
    log_error "Device serial from $IDENTITY_SOURCE contains unexpected characters. Refusing to use it."
    exit 1
fi
log_info "Device Serial: $DEVICE_SERIAL"

if ! is_safe_value "$USER_EMAIL"; then
    log_error "User email from $IDENTITY_SOURCE contains unexpected characters. Refusing to use it."
    exit 1
fi
case "$USER_EMAIL" in
    *@*.*) ;;
    *)
        log_error "User email '$USER_EMAIL' from $IDENTITY_SOURCE is not an email address.${EMAIL_SHAPE_HINT:+ $EMAIL_SHAPE_HINT}"
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
        log_error "No user is signed in at the console (console owner: '${CURRENT_USER:-unknown}'). Corridor installs per user, so run this script while the developer is signed in. Exiting 1 so the MDM records a failure and retries on a later check-in."
        exit 1
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
    log_error "Console user '$CURRENT_USER' is a system account (UID $CURRENT_USER_UID). Refusing to provision."
    exit 1
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
# Provision through the Corridor CLI
# ============================================================================
CORRIDOR_BIN="$CORRIDOR_CONFIG_DIR/bin/corridor"

# version_at_least <version> <minimum>: numeric x.y.z compare. Anything that is
# not plain digits (a dev build, a prerelease tag) fails, so it takes the
# legacy path.
version_at_least() {
    local have want i
    IFS=. read -r -a have <<< "$1"
    IFS=. read -r -a want <<< "$2"
    for i in 0 1 2; do
        case "${have[$i]:-}" in ""|*[!0-9]*) return 1 ;; esac
        [ "${have[$i]}" -gt "${want[$i]}" ] && return 0
        [ "${have[$i]}" -lt "${want[$i]}" ] && return 1
    done
    return 0
}

CLI_VERSION=""
if [ "$CLI_INSTALLED" = "true" ] && [ -x "$CORRIDOR_BIN" ]; then
    CLI_VERSION=$(sudo -u "$CURRENT_USER" env HOME="$USER_HOME" "$CORRIDOR_BIN" --version 2>/dev/null \
        | awk 'NR == 1 { print $NF }' || echo "")
fi

if version_at_least "$CLI_VERSION" "$CORRIDOR_MIN_PROVISION_VERSION"; then
    log_info "Provisioning $CURRENT_USER with corridor $CLI_VERSION..."
    # The team token goes on stdin to stay out of argv. launchctl asuser puts the
    # editor CLIs in the user's GUI session, as running them from Terminal would.
    if printf '%s\n' "$CORRIDOR_TEAM_TOKEN" \
        | launchctl asuser "$CURRENT_USER_UID" sudo -u "$CURRENT_USER" env HOME="$USER_HOME" \
            "$CORRIDOR_BIN" mdm provision \
            --email "$USER_EMAIL" --serial "$DEVICE_SERIAL" --api-url "$CORRIDOR_API_URL"; then
        exit 0
    fi
    log_error "corridor mdm provision failed. See its output above; the MDM will retry on a later check-in."
    exit 1
fi

if [ "$CLI_INSTALLED" = "true" ]; then
    log_info "Corridor CLI version '${CLI_VERSION:-unknown}' is older than $CORRIDOR_MIN_PROVISION_VERSION; using in-script provisioning."
fi

# ============================================================================
# Legacy in-script provisioning
# ============================================================================
# Used when the installed CLI predates `corridor mdm provision`
# (CORRIDOR_MIN_PROVISION_VERSION) or did not install. Remove once every
# supported CLI release has the command.
EXTENSION_INSTALL_TIMEOUT=60
EXTENSION_PHASE_TIMEOUT=150

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
        EXTENSION_FAILURE=1
        log_warn "Editor extension phase budget of ${EXTENSION_PHASE_TIMEOUT}s exhausted; skipping editors: $REMAINING_EDITORS. They will be retried on the next check-in."
    fi
}

EXTENSION_FAILURE=0
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
        EXTENSION_FAILURE=1
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
        if [ -n "$(find "$EXT_DIR" -maxdepth 1 -iname "*corridor*" -print -quit 2>/dev/null)" ]; then
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

if [ "$EXTENSION_FAILURE" -ne 0 ] || [ "$PLATFORM_FAILURE" -ne 0 ]; then
    log_error "Corridor provisioning completed with one or more extension or platform token failures."
    exit 1
fi

log_success "Corridor MDM provisioning complete!"
exit 0
