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
# Jamf Pro Script Parameters (configure these in the Jamf Pro policy):
#   $1 - Mount point of the target drive (reserved by Jamf Pro)
#   $2 - Computer name (reserved by Jamf Pro)
#   $3 - Username of the currently logged-in user (reserved by Jamf Pro)
#   $4 - User's email address (set to "$EMAIL" in Jamf Pro policy)
#   $5 - Device serial number (set to "$SERIALNUMBER" in Jamf Pro policy)
#
# Jamf Pro Policy Setup:
#   1. Get a Universal Team Token from your Corridor team settings
#   2. Replace the CORRIDOR_TEAM_TOKEN value below with your token
#   3. Add this script to Jamf Pro under Settings > Scripts
#   4. Set Parameter Labels:
#        Parameter 4 Label: "User Email"
#        Parameter 5 Label: "Serial Number"
#   5. Create a policy, add this script, and set parameter values:
#        Parameter 4: $EMAIL
#        Parameter 5: $SERIALNUMBER
#   6. Scope the policy to your target computers
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

# Jamf Pro script parameters ($1-$3 are reserved by Jamf Pro)
# Parameter 4 Label: "User Email"       → set to "$EMAIL" in policy
# Parameter 5 Label: "Serial Number"    → set to "$SERIALNUMBER" in policy
JAMF_USER_EMAIL="${4}"
JAMF_SERIAL_NUMBER="${5}"

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

# Set the device serial from Jamf Pro script parameter ($5 = $SERIALNUMBER)
DEVICE_SERIAL="$JAMF_SERIAL_NUMBER"
if [ -z "$DEVICE_SERIAL" ]; then
    log_error "Could not retrieve device serial number. Ensure Parameter 5 is set to \$SERIALNUMBER in the Jamf Pro policy."
    exit 1
fi
log_info "Device Serial: $DEVICE_SERIAL"

# Set the user email from Jamf Pro script parameter ($4 = $EMAIL)
USER_EMAIL="$JAMF_USER_EMAIL"
if [ -z "$USER_EMAIL" ]; then
    log_error "Could not retrieve user email. Ensure Parameter 4 is set to \$EMAIL in the Jamf Pro policy."
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

# Exit if no editors are installed
if [ -z "$INSTALLED_EDITORS" ]; then
    log_info "No supported editors (Cursor, VS Code, Windsurf) are installed. Skipping Corridor extension installation."
    exit 0
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

    # Run as the logged-in user to ensure proper extension installation
    # Capture output and exit code - "already installed" is not a failure
    INSTALL_OUTPUT=$(sudo -u "$CURRENT_USER" "$CLI_PATH" --install-extension corridor.Corridor --force 2>&1) || true

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

# Provision user and create separate API tokens for each installed editor
CORRIDOR_CONFIG_DIR="/Users/$CURRENT_USER/.corridor"

log_info "Provisioning user with Corridor..."

for editor in $INSTALLED_EDITORS; do
    PLATFORM=$(get_editor_platform "$editor")
    EDITOR_CONFIG_DIR="$CORRIDOR_CONFIG_DIR/$PLATFORM"
    CORRIDOR_PENDING_TOKEN_FILE="$EDITOR_CONFIG_DIR/pending-token"

    log_info "Creating API token for $editor ($PLATFORM)..."

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $CORRIDOR_TEAM_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"deviceSerial\": \"$DEVICE_SERIAL\", \"userEmail\": \"$USER_EMAIL\", \"platform\": \"$PLATFORM\"}" \
        "$CORRIDOR_API_URL/extension-auth/mdm-sync-device")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Failed to provision user for $editor. HTTP $HTTP_CODE: $BODY"
        exit 1
    fi

    # Extract API token and token ID from response
    API_TOKEN=$(echo "$BODY" | grep -o '"apiToken":"[^"]*"' | cut -d'"' -f4)
    API_TOKEN_ID=$(echo "$BODY" | grep -o '"apiTokenId":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$API_TOKEN" ]; then
        log_error "Could not extract API token from response for $editor"
        exit 1
    fi

    # Create editor-specific config directory with proper permissions
    sudo -u "$CURRENT_USER" mkdir -p "$EDITOR_CONFIG_DIR"
    chmod 700 "$EDITOR_CONFIG_DIR"

    # Write pending token file
    sudo -u "$CURRENT_USER" cat > "$CORRIDOR_PENDING_TOKEN_FILE" << EOF
{
  "apiToken": "$API_TOKEN",
  "apiTokenId": "$API_TOKEN_ID",
  "provisionedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

    chmod 600 "$CORRIDOR_PENDING_TOKEN_FILE"
    chown "$CURRENT_USER" "$CORRIDOR_PENDING_TOKEN_FILE"
    log_info "Pending token for $editor stored in $CORRIDOR_PENDING_TOKEN_FILE"
done

log_success "User provisioned successfully!"
log_info "The Corridor extension will migrate tokens to secure storage on next launch of that editor"

log_success "Corridor MDM provisioning complete!"
exit 0
