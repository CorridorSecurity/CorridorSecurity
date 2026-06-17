#!/bin/bash
#
# Corridor MDM Provisioning Script for Jamf Pro MacOS Devices
#
# This script is designed to be deployed via Jamf Pro as a policy script.
# It detects if supported editors (Cursor, VS Code, Windsurf) are installed,
# installs the Corridor extension on all detected editors, and provisions
# the user with an API token for authentication.
#
# Configuration:
#   CORRIDOR_TEAM_TOKEN - Your team's Universal Team Token (required)
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

# ============================================================================
# SCRIPT LOGIC - Do not modify below this line
# ============================================================================

set -e

LOG_PREFIX="[Corridor MDM]"
CORRIDOR_API_URL="https://app.corridor.dev/api"

# Read device configuration from managed plist (pushed via Jamf Pro configuration profile)
JAMF_USER_EMAIL=$(defaults read /Library/Managed\ Preferences/dev.corridor.mdm.plist UserEmail 2>/dev/null || echo "")
JAMF_SERIAL_NUMBER=$(defaults read /Library/Managed\ Preferences/dev.corridor.mdm.plist SerialNumber 2>/dev/null || echo "")

log_info() {
    echo "$LOG_PREFIX INFO: $1"
}

log_error() {
    echo "$LOG_PREFIX ERROR: $1" >&2
}

log_success() {
    echo "$LOG_PREFIX SUCCESS: $1"
}

# Function to get the currently logged-in interactive user
get_current_user() {
    # Get the user who owns the console (most reliable method, esp since the user may be root)
    local user
    user=$(stat -f "%Su" /dev/console)

    # Filter out system accounts
    if [ "$user" = "root" ] || [ "$user" = "_mbsetupuser" ]; then
        # Fallback: get the most recent GUI user
        user=$(last -1 -t console | awk '{print $1}' | head -1)
    fi

    echo "$user"
}

# Check if configuration is set
if [ "$CORRIDOR_TEAM_TOKEN" = "cor-team_..." ] || [ -z "$CORRIDOR_TEAM_TOKEN" ]; then
    log_error "CORRIDOR_TEAM_TOKEN is not configured. Please set your team token."
    exit 1
fi

# Set the device serial from managed plist
DEVICE_SERIAL="$JAMF_SERIAL_NUMBER"
if [ -z "$DEVICE_SERIAL" ]; then
    log_error "Could not retrieve device serial number. Ensure the configuration profile pushes SerialNumber to /Library/Managed Preferences/dev.corridor.mdm.plist."
    exit 1
fi
log_info "Device Serial: $DEVICE_SERIAL"

# Set the user email from managed plist
USER_EMAIL="$JAMF_USER_EMAIL"
if [ -z "$USER_EMAIL" ]; then
    log_error "Could not retrieve user email. Ensure the configuration profile pushes UserEmail to /Library/Managed Preferences/dev.corridor.mdm.plist."
    exit 1
fi
log_info "User email: $USER_EMAIL"

# Get the current logged-in interactive user
CURRENT_USER=$(get_current_user)
if [ -z "$CURRENT_USER" ]; then
    log_error "Could not retrieve logged-in username"
    exit 1
fi
log_info "Current User: $CURRENT_USER"

# ============================================================================
# Install the Corridor CLI
# ============================================================================
# Download and install the Corridor CLI for the logged-in user. The installer
# places the binary under the user's ~/.corridor/bin and symlinks it into
# ~/.local/bin, so it must run as the interactive user (not root) for HOME to
# resolve correctly. CI=1 skips the interactive Claude Code plugin setup, which
# cannot run unattended in an MDM context. CORRIDOR_MDM=1 tells the installer
# this is a persistent managed device so it still updates the shell profile.
log_info "Installing the Corridor CLI for $CURRENT_USER..."

CORRIDOR_CONFIG_DIR="/Users/$CURRENT_USER/.corridor"
CLI_INSTALLED="false"

if sudo -u "$CURRENT_USER" env HOME="/Users/$CURRENT_USER" CI=1 CORRIDOR_MDM=1 \
    bash -c 'set -o pipefail; curl -fsSL https://app.corridor.dev/cli/install.sh | bash'; then
    log_success "Corridor CLI installed successfully"
    CLI_INSTALLED="true"
else
    log_error "Failed to install the Corridor CLI (continuing with extension provisioning)"
fi

# Define supported editors (bash 3.x compatible - no associative arrays)
EDITOR_NAMES="Cursor VSCode Windsurf"

# Define editor app names
get_editor_app_name() {
    case "$1" in
        Cursor)   echo "Cursor.app" ;;
        VSCode)   echo "Visual Studio Code.app" ;;
        Windsurf) echo "Windsurf.app" ;;
    esac
}

# Define editor platform names
get_editor_platform() {
    case "$1" in
        Cursor)   echo "cursor" ;;
        VSCode)   echo "vscode" ;;
        Windsurf) echo "windsurf" ;;
    esac
}

# Define editor CLI binary names
get_editor_cli() {
    case "$1" in
        Cursor)   echo "cursor" ;;
        VSCode)   echo "code" ;;
        Windsurf) echo "windsurf" ;;
    esac
}

# Get the paths -- /Applications or /Users/${CURRENT_USER}/Downloads (VS code mainly)
get_editor_app() {
    echo "/Applications/$(get_editor_app_name "$1")"
}

get_editor_app_alternative() {
    echo "/Users/${CURRENT_USER}/Downloads/$(get_editor_app_name "$1")"
}

get_editor_cli_path() {
    echo "/Applications/$(get_editor_app_name "$1")/Contents/Resources/app/bin/$(get_editor_cli "$1")"
}

get_editor_cli_path_alternative() {
    echo "/Users/${CURRENT_USER}/Downloads/$(get_editor_app_name "$1")/Contents/Resources/app/bin/$(get_editor_cli "$1")"
}

get_editor_ext_dir() {
    case "$1" in
        Cursor)  echo ".cursor/extensions" ;;
        VSCode)  echo ".vscode/extensions" ;;
        Windsurf) echo ".windsurf/extensions" ;;
    esac
}

# Check which editors are installed
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

# Trim leading space
INSTALLED_EDITORS=$(echo "$INSTALLED_EDITORS" | sed 's/^ *//')

# Build the list of platforms to provision tokens for: the platform for each
# installed editor, plus "cli" if the Corridor CLI installed successfully.
PROVISION_PLATFORMS=""
for editor in $INSTALLED_EDITORS; do
    PROVISION_PLATFORMS="$PROVISION_PLATFORMS $(get_editor_platform "$editor")"
done
if [ "$CLI_INSTALLED" = "true" ]; then
    PROVISION_PLATFORMS="$PROVISION_PLATFORMS cli"
fi
PROVISION_PLATFORMS=$(echo "$PROVISION_PLATFORMS" | sed 's/^ *//')

# Nothing to do if there are no editors and the CLI did not install
if [ -z "$INSTALLED_EDITORS" ]; then
    log_info "No supported editors (Cursor, VS Code, Windsurf) are installed. Skipping Corridor extension installation."
    if [ -z "$PROVISION_PLATFORMS" ]; then
        exit 0
    fi
fi

# Install Corridor extension for each installed editor
for editor in $INSTALLED_EDITORS; do
    # Skip empty entries
    [ -z "$editor" ] && continue

    # Determine which CLI path to use based on where editor was found
    if echo "$EDITOR_PATHS" | grep -q "$editor:alternative"; then
        CLI_PATH=$(get_editor_cli_path_alternative "$editor")
    else
        CLI_PATH=$(get_editor_cli_path "$editor")
    fi
    EXT_DIR="/Users/$CURRENT_USER/$(get_editor_ext_dir "$editor")"

    # Check if CLI path was resolved
    if [ -z "$CLI_PATH" ]; then
        log_error "Unknown editor: $editor"
        exit 1
    fi

    # Check if CLI exists
    if [ ! -f "$CLI_PATH" ]; then
        log_error "$editor CLI not found at $CLI_PATH"
        exit 1
    fi

    log_info "Installing Corridor extension for $editor..."

    # Run as the logged-in user to ensure proper extension installation.
    # NODE_USE_SYSTEM_CA=1 makes the editor's bundled Node trust roots from the
    # macOS System keychain in addition to its bundled CA list, which lets
    # extension installs succeed behind TLS-intercepting corporate proxies
    # (Zscaler, Netskope, Palo Alto, etc.) whose root CA is admin-trusted.
    INSTALL_OUTPUT=$(sudo -u "$CURRENT_USER" env NODE_USE_SYSTEM_CA=1 "$CLI_PATH" --install-extension corridor.Corridor --force 2>&1) || true

    if echo "$INSTALL_OUTPUT" | grep -qi "already installed"; then
        log_info "Corridor extension is already installed for $editor"
    elif echo "$INSTALL_OUTPUT" | grep -qi "successfully installed\|was successfully installed"; then
        log_success "Corridor extension installed successfully for $editor"
    else
        # Check if the extension directory exists as a fallback
        if ls "$EXT_DIR" 2>/dev/null | grep -qi "corridor"; then
            log_info "Corridor extension is already installed for $editor"
        else
            log_error "Failed to install Corridor extension for $editor: $INSTALL_OUTPUT"
            exit 1
        fi
    fi
done

# Provision user and create a separate API token for each platform (each
# installed editor plus the Corridor CLI)
log_info "Provisioning user with Corridor..."

for PLATFORM in $PROVISION_PLATFORMS; do
    PLATFORM_CONFIG_DIR="$CORRIDOR_CONFIG_DIR/$PLATFORM"
    CORRIDOR_PENDING_TOKEN_FILE="$PLATFORM_CONFIG_DIR/pending-token"

    log_info "Creating API token for $PLATFORM..."

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $CORRIDOR_TEAM_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"deviceSerial\": \"$DEVICE_SERIAL\", \"userEmail\": \"$USER_EMAIL\", \"platform\": \"$PLATFORM\"}" \
        "$CORRIDOR_API_URL/extension-auth/mdm-sync-device")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Failed to provision token for $PLATFORM. HTTP $HTTP_CODE: $BODY"
        exit 1
    fi

    # Extract API token and token ID from response
    API_TOKEN=$(echo "$BODY" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
    API_TOKEN_ID=$(echo "$BODY" | grep -o '"apiTokenId":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$API_TOKEN" ]; then
        log_error "Could not extract API token from response for $PLATFORM"
        exit 1
    fi

    # Create platform-specific config directory and write pending token file.
    # Use umask 077 in a subshell so the directory is born 700 and the file is
    # born 600, ensuring the API token is never world-readable on disk.
    (
        umask 077

        # Create platform-specific config directory with proper permissions
        mkdir -p "$PLATFORM_CONFIG_DIR"

        # Write pending token file
        cat > "$CORRIDOR_PENDING_TOKEN_FILE" << EOF
{
  "apiToken": "$API_TOKEN",
  "apiTokenId": "$API_TOKEN_ID",
  "provisionedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    )

    chmod 700 "$PLATFORM_CONFIG_DIR"
    chmod 600 "$CORRIDOR_PENDING_TOKEN_FILE"
    chown -R "$CURRENT_USER" "$CORRIDOR_CONFIG_DIR"
    log_info "Pending token for $PLATFORM stored in $CORRIDOR_PENDING_TOKEN_FILE"
done

log_success "User provisioned successfully!"
log_info "The Corridor extension will migrate tokens to secure storage on next launch of that editor"

# ============================================================================
# Install agent plugins (Claude Code, Factory Droid, Codex)
# ============================================================================
# With the CLI installed and the device's "cli" token provisioned above,
# configure the agent plugins for the user. `corridor install` migrates the
# pending CLI token into ~/.corridor/config.env at startup and authenticates
# from it non-interactively (--yes auto-confirms all interactive prompts). It detects which agent CLIs
# are present in PATH (claude, droid, codex); a missing agent CLI is a non-fatal
# no-op so it never blocks the managed rollout.
if [ "$CLI_INSTALLED" = "true" ]; then
    log_info "Setting up Corridor agent plugins (Claude Code, etc.) for $CURRENT_USER..."
    if sudo -u "$CURRENT_USER" env HOME="/Users/$CURRENT_USER" \
        PATH="/Users/$CURRENT_USER/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        "/Users/$CURRENT_USER/.corridor/bin/corridor" install --yes; then
        log_success "Corridor agent plugins installed"
    else
        log_info "Corridor agent plugin setup skipped or incomplete (non-fatal — e.g. no claude/droid/codex in PATH, or install did not finish). See corridor output above for the cause."
    fi
fi

log_success "Corridor MDM provisioning complete!"
exit 0