#Requires -Version 5.1

<#
.SYNOPSIS
    Corridor MDM Provisioning Script for Intune Windows Devices

.DESCRIPTION
    This script is designed to be deployed via Microsoft Intune.
    It detects if supported editors (Cursor, VS Code, Windsurf) are installed,
    installs the Corridor extension on all detected editors, and provisions
    the user with an API token for authentication.

.NOTES
    Configuration:
      CORRIDOR_TEAM_TOKEN - Your team's Universal Team Token (required)
      GRAPH_API_TOKEN - Microsoft Graph API token with Read.All permission on DeviceManagement.ManagedDevices (required)

    Device Information:
      Device serial is retrieved from WMI Win32_BIOS
      User email is retrieved from Microsoft Graph API using device serial

    Usage:
      1. Get a Universal Team Token from your Corridor team settings
      2. Replace the CORRIDOR_TEAM_TOKEN value below with your token
      3. Get a Microsoft Graph API token with DeviceManagementManagedDevices.Read.All permission
      4. Replace the GRAPH_API_TOKEN value below with your token
      5. Deploy this script via Intune as a Windows 10+ script
#>

# ============================================================================
# CONFIGURATION - Replace with your actual values
# ============================================================================
$CORRIDOR_TEAM_TOKEN = "cor-team_..."
$GRAPH_API_TOKEN = "YOUR_GRAPH_API_TOKEN_HERE"

# ============================================================================
# SCRIPT LOGIC - Do not modify below this line
# ============================================================================

$ErrorActionPreference = "Stop"
$LOG_PREFIX = "[Corridor MDM]"
$CORRIDOR_API_URL = "https://app.corridor.dev/api"

# Force TLS 1.2+ (PowerShell 5.1 defaults to TLS 1.0/1.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp $LOG_PREFIX $Level : $Message"

    switch ($Level) {
        "ERROR" { Write-Error $logMessage }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage }
    }
}

function Get-DeviceSerial {
    <#
    .SYNOPSIS
        Gets the device serial number from WMI
    #>
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        return $bios.SerialNumber
    }
    catch {
        Write-Log "Failed to get device serial: $_" -Level ERROR
        return $null
    }
}

function Get-UserEmailFromGraph {
    <#
    .SYNOPSIS
        Gets the user's email/UPN from Microsoft Graph API using device serial
    .DESCRIPTION
        Queries Microsoft Graph API to find the device by serial number
        and returns the userPrincipalName associated with the device.
        This works in SYSTEM context when deployed via Intune.
    #>
    param([string]$DeviceSerial)

    try {
        Write-Log "Querying Microsoft Graph API for device serial: $DeviceSerial"

        # Build Graph API URL with filter
        $graphUrl = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$DeviceSerial'&`$select=id,deviceName,serialNumber,userPrincipalName"

        $headers = @{
            "Authorization" = "Bearer $GRAPH_API_TOKEN"
            "Content-Type" = "application/json"
        }

        $response = Invoke-RestMethod -Uri $graphUrl -Method Get -Headers $headers -ErrorAction Stop

        if ($response.value -and $response.value.Count -gt 0) {
            $email = $response.value[0].userPrincipalName
            if ($email) {
                return $email
            }
        }

        Write-Log "No device found in Graph API response for serial: $DeviceSerial" -Level ERROR
        return $null
    }
    catch {
        Write-Log "Failed to get user email from Graph API: $($_.Exception.GetType().Name) - $_" -Level ERROR
        return $null
    }
}

function Get-LoggedInUser {
    <#
    .SYNOPSIS
        Gets the currently logged-in user
    #>
    try {
        # Get the currently logged-in user (excluding system accounts)
        $loggedInUser = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty UserName

        if ($loggedInUser) {
            # Extract just the username: its usually in DOMAIN\User or AzureAD\User format
            if ($loggedInUser -like "*\*") {
                return $loggedInUser.Split("\")[-1]
            }
            return $loggedInUser
        }

        # Fallback: query explorer.exe owner
        $explorerProcess = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
        if ($explorerProcess) {
            $owner = Invoke-CimMethod -InputObject $explorerProcess -MethodName GetOwner
            return $owner.User
        }

        return $null
    }
    catch {
        Write-Log "Failed to get logged-in user: $_" -Level ERROR
        return $null
    }
}

function Get-UserProfilePath {
    param([string]$Username)

    # Try to get the user's profile path
    try {
        $userProfile = Get-CimInstance -ClassName Win32_UserProfile |
            Where-Object { $_.LocalPath -like "*$Username*" -and -not $_.Special } |
            Select-Object -First 1 -ExpandProperty LocalPath

        if ($userProfile) {
            return $userProfile
        }
    }
    catch {
        # Fallback to standard path
    }

    return "C:\Users\$Username"
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Log "Starting Corridor MDM provisioning..."

# Check if configuration is set
if ($CORRIDOR_TEAM_TOKEN -eq "YOUR_TEAM_TOKEN_HERE" -or [string]::IsNullOrEmpty($CORRIDOR_TEAM_TOKEN)) {
    Write-Log "CORRIDOR_TEAM_TOKEN is not configured. Please set your team token." -Level ERROR
    exit 1
}

if ($GRAPH_API_TOKEN -eq "YOUR_GRAPH_API_TOKEN_HERE" -or [string]::IsNullOrEmpty($GRAPH_API_TOKEN)) {
    Write-Log "GRAPH_API_TOKEN is not configured. Please set your Microsoft Graph API token." -Level ERROR
    exit 1
}

# Get device serial number
$DeviceSerial = Get-DeviceSerial
if ([string]::IsNullOrEmpty($DeviceSerial)) {
    Write-Log "Could not retrieve device serial number" -Level ERROR
    exit 1
}
Write-Log "Device Serial: $DeviceSerial"

# Get user email from Microsoft Graph API using device serial
$UserEmail = Get-UserEmailFromGraph -DeviceSerial $DeviceSerial
if ([string]::IsNullOrEmpty($UserEmail)) {
    Write-Log "Could not retrieve user email from Microsoft Graph API." -Level ERROR
    Write-Log "Ensure the device is enrolled in Intune and GRAPH_API_TOKEN is valid."
    exit 1
}
Write-Log "User Email: $UserEmail"

# Get the logged-in user
$CurrentUser = Get-LoggedInUser
if ([string]::IsNullOrEmpty($CurrentUser)) {
    Write-Log "Could not retrieve logged-in username" -Level ERROR
    exit 1
}
Write-Log "Current User: $CurrentUser"

# Get user profile path
$UserProfilePath = Get-UserProfilePath -Username $CurrentUser
Write-Log "User Profile Path: $UserProfilePath"

# Define supported editors
$Editors = @{
    "Cursor" = @{
        Platform = "cursor"
        Exe = Join-Path $UserProfilePath "AppData\Local\Programs\cursor\Cursor.exe"
        Cli = Join-Path $UserProfilePath "AppData\Local\Programs\cursor\resources\app\bin\cursor.cmd"
    }
    "VSCode" = @{
        Platform = "vscode"
        Exe = Join-Path $UserProfilePath "AppData\Local\Programs\Microsoft VS Code\Code.exe"
        Cli = Join-Path $UserProfilePath "AppData\Local\Programs\Microsoft VS Code\bin\code.cmd"
    }
    "Windsurf" = @{
        Platform = "windsurf"
        Exe = Join-Path $UserProfilePath "AppData\Local\Programs\Windsurf\Windsurf.exe"
        Cli = Join-Path $UserProfilePath "AppData\Local\Programs\Windsurf\bin\windsurf.cmd"
    }
}

# Check which editors are installed
$InstalledEditors = @()

foreach ($editorName in $Editors.Keys) {
    $editor = $Editors[$editorName]
    if (Test-Path $editor.Exe) {
        if (Test-Path $editor.Cli) {
            Write-Log "$editorName detected at $($editor.Exe)"
            $InstalledEditors += $editorName
        } else {
            Write-Log "$editorName found but CLI not available at $($editor.Cli)" -Level ERROR
        }
    }
}

if ($InstalledEditors.Count -eq 0) {
    Write-Log "No supported editors (VS Code, Cursor, Windsurf) are installed. Skipping Corridor extension installation."
    exit 0
}

Write-Log "Found $($InstalledEditors.Count) installed editor(s): $($InstalledEditors -join ', ')"

# Install Corridor extension for each detected editor
foreach ($editorName in $InstalledEditors) {
    $editor = $Editors[$editorName]
    Write-Log "Installing Corridor extension for $editorName..."

    try {
        $installResult = & $editor.Cli --install-extension corridor.Corridor --force 2>&1
        Write-Log "Extension install output for $editorName`: $installResult"
        Write-Log "Corridor extension installed successfully for $editorName" -Level SUCCESS
    }
    catch {
        Write-Log "Failed to install Corridor extension for $editorName`: $_" -Level ERROR
        exit 1
    }
}

# Provision each installed editor with a separate API token
foreach ($editorName in $InstalledEditors) {
    $editor = $Editors[$editorName]
    $platform = $editor.Platform

    Write-Log "Provisioning $editorName with Corridor..."

    $body = @{
        deviceSerial = $DeviceSerial
        userEmail = $UserEmail
        platform = $platform
    } | ConvertTo-Json

    try {
        $uri = "$CORRIDOR_API_URL/extension-auth/mdm-sync-device"
        Write-Log "Making POST request to $uri for $editorName"

        # Write body to temp file -- this is necessary to avoid Windows curl escaping issues
        # Otherwise the curl command will fail due to the bad JSON parsing of Windows
        # The usual Invoke-RestMethod also fails because it makes a GET request even if you specify method: POST
        $bodyFile = Join-Path $env:TEMP "corridor-mdm-body.json"
        Set-Content -Path $bodyFile -Encoding ascii -NoNewline -Value $body

        # Call curl with --data-binary @file (use array to avoid PowerShell parsing issues)
        $authHeader = "Authorization: Bearer $CORRIDOR_TEAM_TOKEN"

        $curlArgs = @(
            '-s',
            '-w', "`n%{http_code}",
            '-X', 'POST',
            '-H', $authHeader,
            '-H', 'Content-Type: application/json',
            '--data-binary', "@$bodyFile",
            $uri
        )
        $curlOutput = & curl.exe $curlArgs 2>&1

        # Clean up temp file
        Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue

        # Split response body and status code
        $outputStr = $curlOutput -join "`n"
        $lines = $outputStr -split "`n"
        $httpCode = $lines[-1].Trim()
        $responseBody = ($lines[0..($lines.Length-2)]) -join "`n"

        if ($httpCode -ne "200") {
            Write-Log "Failed to provision $editorName. HTTP $httpCode" -Level ERROR
            exit 1
        }

        $response = $responseBody | ConvertFrom-Json
        Write-Log "$editorName provisioned successfully" -Level SUCCESS
    }
    catch {
        Write-Log "Failed to provision $editorName`: $($_.Exception.Message)" -Level ERROR
        exit 1
    }

    # Extract API token and token ID from response
    $ApiToken = $response.apiToken
    $ApiTokenId = $response.apiTokenId

    if ([string]::IsNullOrEmpty($ApiToken)) {
        Write-Log "Could not extract API token from response for $editorName" -Level ERROR
        exit 1
    }

    # ApiTokenId is optional - don't fail if not present

    # Store the API token in a pending file for the extension to migrate to secure storage
    # Each editor gets its own subdirectory: .corridor/cursor/, .corridor/vscode/, .corridor/windsurf/
    $CorridorConfigDir = Join-Path $UserProfilePath ".corridor"
    $EditorConfigDir = Join-Path $CorridorConfigDir $platform
    $CorridorPendingTokenFile = Join-Path $EditorConfigDir "pending-token"

    # Create config directory if it doesn't exist
    if (-not (Test-Path $EditorConfigDir)) {
        New-Item -ItemType Directory -Path $EditorConfigDir -Force | Out-Null
        Write-Log "Created config directory: $EditorConfigDir"
    }

    # Write pending token file
    $tokenData = @{
        apiToken = $ApiToken
        apiTokenId = $ApiTokenId
        provisionedAt = (Get-Date -Format "o")
    } | ConvertTo-Json

    Set-Content -Path $CorridorPendingTokenFile -Value $tokenData -Force

    Write-Log "Pending token stored in $CorridorPendingTokenFile" -Level SUCCESS
    Write-Log "The Corridor extension for $editorName will migrate this to secure storage on next launch"
}

Write-Log "Corridor MDM provisioning complete!" -Level SUCCESS
exit 0