#!/bin/bash
#
# Corridor MDM Provisioning Script for Kandji MacOS Devices
#
# This script is designed to be deployed via Kandji.
# It detects if supported editors (Cursor, VS Code, Windsurf, Devin Desktop)
# are installed, installs the Corridor extension on all detected editors,
# installs the Corridor CLI, and provisions the user with API tokens for
# authentication.
#
# Configuration:
#   CORRIDOR_TEAM_TOKEN - Your team's Universal Team Token (required)
#   CORRIDOR_CLI_SHA256 - Optional expected SHA-256 of the CLI installer.
#
# Kandji Global Variables Used (read from
# /Library/Managed Preferences/io.kandji.globalvariables.plist):
#   EMAIL - User's email from device assignment (injected by Kandji)
#   SERIAL_NUMBER - Device serial number from Kandji global variables
#
# Basic Usage:
#   1. Get a Universal Team Token from your Corridor team settings
#   2. Replace the CORRIDOR_TEAM_TOKEN value below with your token
#   3. Deploy this script via Kandji as a Custom Script
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

MANAGED_PLIST="/Library/Managed Preferences/io.kandji.globalvariables.plist"
PLIST_SERIAL_KEY="SERIAL_NUMBER"
PLIST_EMAIL_KEY="EMAIL"
PLIST_PROFILE_NAME="the Kandji global variables profile"
PLIST_MISSING_HINT="Confirm the Kandji global variables profile has been delivered to this host."
IDENTITY_SOURCE="$MANAGED_PLIST"
# @include managed-plist.sh
# @include common.sh
