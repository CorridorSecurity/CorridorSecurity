#!/bin/bash
#
# Corridor MDM Provisioning Script for Fleet MacOS Devices
#
# This script is designed to be deployed via Fleet (fleetdm.com).
# It detects if supported editors (Cursor, VS Code, Windsurf) are installed,
# installs the Corridor extension on all detected editors, and provisions
# the user with an API token for authentication.
#
# Configuration:
#   CORRIDOR_TEAM_TOKEN - Your team's Universal Team Token (required)
#
#   By default this script references Fleet's custom variable
#   $FLEET_SECRET_CORRIDOR_TEAM_TOKEN. Fleet substitutes the value
#   server-side when the script is sent to the host, and masks it in the
#   Fleet UI and API. Alternatively, replace the value below with your
#   token directly (not recommended).
#
#   CORRIDOR_CLI_SHA256 - Optional. Expected SHA-256 of the Corridor CLI
#   installer. When set, the installer is verified before it runs, which
#   pins the fleet-wide rollout to a known-good installer.
#
# Device Configuration (via Fleet configuration profile):
#   This script reads device-specific values from a managed plist:
#     /Library/Managed Preferences/dev.corridor.mdm.plist
#   Keys:
#     UserEmail    - The user's email address
#     SerialNumber - The device serial number
#   Deploy fleet-dev.corridor.mdm.mobileconfig (in this directory) as a
#   Fleet custom configuration profile to populate these keys. It uses
#   Fleet's built-in variables ($FLEET_VAR_HOST_END_USER_IDP_USERNAME and
#   $FLEET_VAR_HOST_HARDWARE_SERIAL), so Fleet must know the host's end
#   user (IdP integration or a human-to-host mapping).
#
# Fleet Setup:
#   1. Get a Universal Team Token from your Corridor team settings
#   2. In Fleet, under Controls > Variables, create a custom variable named
#      CORRIDOR_TEAM_TOKEN (referenced as $FLEET_SECRET_CORRIDOR_TEAM_TOKEN)
#      with your token as the value
#   3. Upload fleet-dev.corridor.mdm.mobileconfig under
#      Controls > OS settings > Configuration profiles, scoped to the fleet
#      containing your target hosts
#   4. Upload this script under Controls > Scripts
#   5. Run it on hosts manually (Hosts > select host > Actions > Run Script),
#      via the API/fleetctl, or automatically through a policy automation
#
#   UI labels above are Fleet 4.84+. Older versions call Configuration
#   profiles "Custom settings", and fleets "teams".
#
#   Note: Fleet runs shell scripts as root, so per-user work below is done
#   as the logged-in user via sudo -u. Script execution must be enabled in
#   fleetd (it is on by default for hosts with Fleet MDM turned on).
#
#   This script requires an active console session: Fleet policy automations
#   run unattended, and provisioning a user's credential while the Mac sits
#   at the login window (or while a different account is in use) would put
#   that credential in the wrong home directory. It exits 0 in that case so
#   the policy can simply run again later.
#
# ============================================================================
# CONFIGURATION - Replace with your actual values
# ============================================================================
# Single-quoted deliberately. Fleet replaces $FLEET_SECRET_* textually before
# the host's shell ever parses this file, so a double-quoted assignment would
# let a token containing shell metacharacters execute as root on this line.
CORRIDOR_TEAM_TOKEN='$FLEET_SECRET_CORRIDOR_TEAM_TOKEN'

# Optional: expected SHA-256 of https://app.corridor.dev/cli/install.sh
CORRIDOR_CLI_SHA256=''

# ============================================================================
# SCRIPT LOGIC - Do not modify below this line
# ============================================================================

set -e
set -o pipefail

# Run with a known PATH rather than whatever fleetd's root context provides,
# so the utilities below cannot be shadowed.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

LOG_PREFIX="[Corridor MDM]"
CORRIDOR_API_URL="https://app.corridor.dev/api"
CORRIDOR_CLI_INSTALL_URL="https://app.corridor.dev/cli/install.sh"
MANAGED_PLIST="/Library/Managed Preferences/dev.corridor.mdm.plist"

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
cleanup() {
    if [ -n "$CLI_INSTALLER" ]; then
        rm -f "$CLI_INSTALLER"
    fi
}
trap cleanup EXIT

# Accept only a conservative character set for values that get interpolated
# into JSON bodies, curl config, and file contents below. Rejecting quotes,
# backslashes, whitespace and shell metacharacters up front is what makes that
# interpolation safe without per-context escaping.
is_safe_value() {
    if [ -z "$1" ] || [ "${#1}" -gt 256 ]; then
        return 1
    fi
    case "$1" in
        *[!A-Za-z0-9._@+=:/-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Local account names are stricter: they become path components and a sudo -u
# target.
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

# Redact anything token-shaped before it reaches the log. Fleet stores script
# output verbatim and does not redact secrets from it, and that output is
# visible to every Fleet user who can see the host.
redact() {
    printf '%s' "$1" | tr -d '\n' | cut -c1-200 | sed 's/cor-[A-Za-z0-9._-]*/[redacted]/g'
}

# Check if configuration is set. With the single-quoted assignment above, an
# undefined Fleet variable leaves the literal placeholder text in place rather
# than an empty string, so check for both.
case "$CORRIDOR_TEAM_TOKEN" in
    ""|'$FLEET_SECRET_CORRIDOR_TEAM_TOKEN'|"cor-team_...")
        log_error "CORRIDOR_TEAM_TOKEN is not configured. Define the CORRIDOR_TEAM_TOKEN custom variable in Fleet or set your team token in this script."
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
# Only trust the plist if it is a regular, root-owned file. MDM writes this
# path as root; a symlink or a file owned by anyone else means the identity
# this script is about to provision is not authoritative.
if [ -L "$MANAGED_PLIST" ] || [ ! -f "$MANAGED_PLIST" ]; then
    log_error "Managed preferences file not found at $MANAGED_PLIST. Deploy fleet-dev.corridor.mdm.mobileconfig as a Fleet configuration profile and confirm it has been delivered to this host."
    exit 1
fi

if [ "$(stat -f '%u' "$MANAGED_PLIST")" != "0" ]; then
    log_error "$MANAGED_PLIST is not owned by root. Refusing to read device identity from it."
    exit 1
fi

# plutil reads the file directly, avoiding cfprefsd's cached view of the domain.
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
        log_error "Value pushed as UserEmail ('$USER_EMAIL') is not an email address. Fleet's \$FLEET_VAR_HOST_END_USER_IDP_USERNAME resolves to the IdP username, which must be the user's email for Corridor provisioning."
        exit 1
        ;;
esac
log_info "User email: $USER_EMAIL"

# ============================================================================
# Resolve the target user
# ============================================================================
# The console owner only. There is deliberately no "most recent GUI user"
# fallback: under a Fleet policy automation this runs unattended, and falling
# back would provision the MDM-assigned user's token into whichever account
# happened to log in last.
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

# Read the home directory from the directory service instead of assuming
# /Users/<name>, then confirm it is a real directory the user owns before root
# touches anything inside it.
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

# The MDM tells us who the device belongs to; the console tells us who is
# using it. They usually differ only in local naming convention, so this is a
# warning rather than a failure - but a real mismatch means a credential is
# about to land in someone else's account.
EMAIL_LOCAL_PART="${USER_EMAIL%%@*}"
if [ "$CURRENT_USER" != "$EMAIL_LOCAL_PART" ]; then
    log_warn "Console user '$CURRENT_USER' does not match the MDM-assigned user '$USER_EMAIL'. Tokens for $USER_EMAIL will be written to $USER_HOME - confirm this device is assigned to the person using it."
fi

CORRIDOR_CONFIG_DIR="$USER_HOME/.corridor"

# ============================================================================
# Install the Corridor CLI
# ============================================================================
# Download and install the Corridor CLI for the logged-in user. The installer
# places the binary under the user's ~/.corridor/bin and symlinks it into
# ~/.local/bin, so it must run as the interactive user (not root) for HOME to
# resolve correctly. CI=1 skips the interactive Claude Code plugin setup, which
# cannot run unattended in an MDM context. CORRIDOR_MDM=1 tells the installer
# this is a persistent managed device so it still updates the shell profile.
#
# The installer is downloaded to a file and run separately rather than piped
# into bash: a truncated download cannot execute as a partial script, and the
# bytes can be checksummed first. This runs on every managed Mac, so pin
# CORRIDOR_CLI_SHA256 above to make that rollout verifiable. The checksum
# guards against a bad upstream artifact, not against the local user - the
# download, the hash and the install all run as that user, who could run
# whatever they like in their own context anyway.
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

# Get the paths -- /Applications or $USER_HOME/Downloads (VS code mainly)
get_editor_app() {
    echo "/Applications/$(get_editor_app_name "$1")"
}

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
    EXT_DIR="$USER_HOME/$(get_editor_ext_dir "$editor")"

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
            log_error "Failed to install Corridor extension for $editor: $(redact "$INSTALL_OUTPUT")"
            exit 1
        fi
    fi
done

# Provision user and create a separate API token for each platform (each
# installed editor plus the Corridor CLI)
log_info "Provisioning user with Corridor..."

for PLATFORM in $PROVISION_PLATFORMS; do
    PLATFORM_CONFIG_DIR="$CORRIDOR_CONFIG_DIR/$PLATFORM"

    log_info "Creating API token for $PLATFORM..."

    # Every interpolated value here has been charset-validated above, so the
    # body cannot be broken out of.
    REQUEST_BODY=$(printf '{"deviceSerial": "%s", "userEmail": "%s", "platform": "%s"}' \
        "$DEVICE_SERIAL" "$USER_EMAIL" "$PLATFORM")

    # The team token goes to curl through a config file on stdin rather than an
    # argument: it authorizes provisioning for the whole team, and argv is the
    # one part of this process that other local accounts may be able to read.
    # No --retry here - this call mints a token, so a retried POST would leave
    # extra live credentials behind.
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
        log_error "Failed to provision token for $PLATFORM. HTTP $HTTP_CODE: $(redact "$BODY")"
        exit 1
    fi

    # Extract API token and token ID from the response
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

    # Write the token as the target user, not as root. The destination lives
    # inside a directory the user already owns, so a root-context mkdir or
    # redirect there can be aimed at any path on the system through a symlink
    # the user planted first. Doing the write as the user removes that
    # privilege boundary rather than trying to validate around it, and also
    # makes the chown that used to follow unnecessary. umask 077 gives the
    # directory 700 and the token file 600 at creation; the explicit chmods
    # cover a directory that already existed. The token arrives over stdin so
    # it never appears in argv.
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
    if sudo -u "$CURRENT_USER" env HOME="$USER_HOME" \
        PATH="$USER_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        "$CORRIDOR_CONFIG_DIR/bin/corridor" install --yes; then
        log_success "Corridor agent plugins installed"
    else
        log_info "Corridor agent plugin setup skipped or incomplete (non-fatal — e.g. no claude/droid/codex in PATH, or install did not finish). See corridor output above for the cause."
    fi
fi

log_success "Corridor MDM provisioning complete!"
exit 0
