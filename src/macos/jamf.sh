#!/bin/bash
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

# @include prelude.sh
# @include token-check.sh

MANAGED_PLIST="/Library/Managed Preferences/dev.corridor.mdm.plist"
PLIST_SERIAL_KEY="SerialNumber"
PLIST_EMAIL_KEY="UserEmail"
PLIST_PROFILE_NAME="the configuration profile"
PLIST_MISSING_HINT="Deploy dev.corridor.mdm.plist as a Jamf Pro configuration profile and confirm it has been delivered to this host."
IDENTITY_SOURCE="$MANAGED_PLIST"
# @include managed-plist.sh
# @include common.sh
