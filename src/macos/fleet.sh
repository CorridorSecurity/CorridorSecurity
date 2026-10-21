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

# @include prelude.sh

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

MANAGED_PLIST="/Library/Managed Preferences/dev.corridor.mdm.plist"
PLIST_SERIAL_KEY="SerialNumber"
PLIST_EMAIL_KEY="UserEmail"
PLIST_PROFILE_NAME="the Fleet configuration profile"
PLIST_MISSING_HINT="Deploy fleet-dev.corridor.mdm.mobileconfig as a Fleet configuration profile and confirm it has been delivered to this host."
PLIST_EMAIL_EMPTY_HINT="and that Fleet knows this host's end user"
IDENTITY_SOURCE="$MANAGED_PLIST"
EMAIL_SHAPE_HINT="Fleet's FLEET_VAR_HOST_END_USER_IDP_USERNAME resolves to the IdP username, which must be the user's email for Corridor provisioning."
# @include managed-plist.sh
# @include common.sh
