#!/bin/bash
#
# Corridor MDM Provisioning Script for Intune macOS Devices
#
# This script is designed to be deployed via Microsoft Intune.
# It detects if supported editors (Cursor, VS Code, Windsurf, Devin Desktop)
# are installed, installs the Corridor extension on all detected editors,
# installs the Corridor CLI, and provisions the user with API tokens for
# authentication.
#
# Configuration:
#   CORRIDOR_TEAM_TOKEN - Your team's Universal Team Token (required)
#   GRAPH_API_TOKEN - Microsoft Graph API token with Read.All permission on DeviceManagement.ManagedDevices (required)
#   CORRIDOR_CLI_SHA256 - Optional expected SHA-256 of the CLI installer.
#
# Device Information:
#   Device serial is retrieved from ioreg (falling back to system_profiler)
#   User email is retrieved from Microsoft Graph API using device serial
#
# Usage:
#   1. Get a Universal Team Token from your Corridor team settings
#   2. Replace the CORRIDOR_TEAM_TOKEN value below with your token
#   3. Get a Microsoft Graph API token with DeviceManagementManagedDevices.Read.All permission
#   4. Replace the GRAPH_API_TOKEN value below with your token
#   5. Deploy this script via Intune as a MacOS script
#
# ============================================================================
# CONFIGURATION - Replace with your actual values
# ============================================================================
CORRIDOR_TEAM_TOKEN="cor-team_..."
GRAPH_API_TOKEN="YOUR_GRAPH_API_TOKEN_HERE"
CORRIDOR_CLI_SHA256=''

# ============================================================================
# SCRIPT LOGIC - Do not modify below this line
# ============================================================================

# @include prelude.sh
# @include token-check.sh

if [ -z "$GRAPH_API_TOKEN" ] || [ "$GRAPH_API_TOKEN" = "YOUR_GRAPH_API_TOKEN_HERE" ]; then
    log_error "GRAPH_API_TOKEN is not configured. Please set your Microsoft Graph API token."
    exit 1
fi

# Unlike is_safe_value there is no length cap: Graph tokens are long JWTs.
case "$GRAPH_API_TOKEN" in
    *[!A-Za-z0-9._~+/=-]*)
        log_error "GRAPH_API_TOKEN contains unexpected characters. Re-copy the token without surrounding quotes or whitespace."
        exit 1
        ;;
esac

get_device_serial() {
    local serial
    serial=$(LC_ALL=C ioreg -l | awk '/IOPlatformSerialNumber/{print $4}' | sed 's/"//g')

    if [ -z "$serial" ]; then
        serial=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $4}')
    fi

    echo "$serial"
}

# There is no consistent way to read the user's email from the device itself,
# so look it up in Graph by serial. Logs go to stderr; stdout is the email.
get_user_email_from_graph() {
    local serial="$1"
    local email=""

    log_info "Querying Microsoft Graph API for device serial: $serial" >&2

    local graph_url="https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?\$filter=serialNumber%20eq%20'$serial'&\$select=id,deviceName,serialNumber,userPrincipalName"

    # Token goes through a config file on stdin to keep it out of argv.
    local response
    if ! response=$(printf 'header = "Authorization: Bearer %s"\n' "$GRAPH_API_TOKEN" \
        | curl -s --config - \
            --proto '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 60 \
            -w "\n%{http_code}" -X GET \
            -H "Content-Type: application/json" \
            "$graph_url"); then
        log_error "Could not reach Microsoft Graph API"
        return 0
    fi

    local http_code body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log_error "Graph API request failed with HTTP $http_code: $(redact "$body")"
        return 0
    fi

    # Handles an optional space after the colon.
    email=$(echo "$body" | tr -d '\n' | grep -o '"userPrincipalName"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | awk -F'"' '{print $4}' || true)

    if [ -n "$email" ]; then
        echo "$email"
    fi
}

DEVICE_SERIAL=$(get_device_serial)
if [ -z "$DEVICE_SERIAL" ]; then
    log_error "Could not retrieve device serial number"
    exit 1
fi
if ! is_safe_value "$DEVICE_SERIAL"; then
    log_error "Device serial from this Mac contains unexpected characters. Refusing to use it."
    exit 1
fi

USER_EMAIL=$(get_user_email_from_graph "$DEVICE_SERIAL")
if [ -z "$USER_EMAIL" ]; then
    log_error "Could not retrieve user email from Microsoft Graph API."
    log_error "Ensure the device is enrolled in Intune and GRAPH_API_TOKEN is valid."
    exit 1
fi

IDENTITY_SOURCE="Microsoft Graph"
EMAIL_SHAPE_HINT="Check the userPrincipalName set for this device in Intune."
# @include common.sh
