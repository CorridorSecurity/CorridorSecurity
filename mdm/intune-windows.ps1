#Requires -Version 5.1

<#
.SYNOPSIS
    Corridor MDM Provisioning Script for Intune Windows Devices

.DESCRIPTION
    This script is designed to be deployed via Microsoft Intune.
    It detects if supported editors (Cursor, VS Code, Windsurf) are installed,
    installs the Corridor extension on all detected editors, installs the
    Corridor CLI, and provisions the user with per-platform API tokens for
    authentication. It is the Windows counterpart to intune-macos.sh and aims to
    be behaviorally equivalent.

.NOTES
    Configuration:
      CORRIDOR_TEAM_TOKEN - Your team's Universal Team Token (required)
      GRAPH_API_TOKEN - Microsoft Graph API token with Read.All permission on DeviceManagement.ManagedDevices (required)

    Device Information:
      Device serial is retrieved from WMI Win32_BIOS
      User email is retrieved from Microsoft Graph API using device serial

    Execution context (Windows-specific):
      The macOS script runs as root and uses `sudo -u "$CURRENT_USER"` to perform
      per-user work (CLI install, extension install, PATH update, agent plugin
      setup) as the signed-in user. Windows has no unprivileged equivalent: a
      SYSTEM-context script cannot drop to the user without their password. So
      this script must be deployed with Intune's "Run this script using the
      logged-on credentials = Yes" setting, which runs it in the signed-in user's
      context. That is how it acts "as the logged-in user" everywhere below.

    Usage:
      1. Get a Universal Team Token from your Corridor team settings
      2. Replace the CORRIDOR_TEAM_TOKEN value below with your token
      3. Get a Microsoft Graph API token with DeviceManagementManagedDevices.Read.All permission
      4. Replace the GRAPH_API_TOKEN value below with your token
      5. Deploy this script via Intune as a Windows 10+ script with
         "Run this script using the logged-on credentials = Yes"
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
$CLI_INSTALL_URL = "https://app.corridor.dev/cli/install.ps1"

# Force TLS 1.2 (Windows PowerShell 5.1 defaults to TLS 1.0/1.1). Enable TLS 1.3
# only when the runtime actually defines it — the [Net.SecurityProtocolType]::Tls13
# literal does not exist on most 5.1 installs and referencing it directly throws.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains "Tls13") {
        $tls13 = [enum]::Parse([Net.SecurityProtocolType], "Tls13")
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor $tls13
    }
}
catch {
    # Non-fatal: keep whatever protocols the runtime negotiates by default.
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp $LOG_PREFIX $Level : $Message"

    switch ($Level) {
        # Use the error stream directly rather than Write-Error: with
        # $ErrorActionPreference = "Stop", Write-Error raises a terminating error,
        # so logging a recoverable problem would abort the whole script. The macOS
        # script just echoes to stderr; [Console]::Error.WriteLine mirrors that
        # without terminating.
        "ERROR" { [Console]::Error.WriteLine($logMessage) }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage }
    }
}

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Run a native executable, returning its combined output and exit code.
    .DESCRIPTION
        Captures stdout+stderr and the process exit code. Temporarily relaxes
        $ErrorActionPreference so a native command writing to stderr cannot raise
        a terminating "NativeCommandError" under the script's Stop preference.
        Arguments are passed as an array (never string-interpolated into a command
        line) to avoid quoting/command-injection issues.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $global:LASTEXITCODE = 0
        $output = & $FilePath @Arguments 2>&1 | Out-String
        return [pscustomobject]@{
            Output   = $output
            ExitCode = $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Set-UserOnlyAcl {
    <#
    .SYNOPSIS
        Best-effort restriction of a path to a single user (Windows analogue of
        chmod 600/700).
    .DESCRIPTION
        Removes inherited ACEs and grants the provisioned user full control via
        icacls. This is best-effort ("where practical"): if the identity cannot be
        resolved or icacls fails (e.g. an Azure AD principal that does not resolve
        locally), it is logged but never aborts provisioning.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Identity,
        [switch]$Container
    )

    if ([string]::IsNullOrEmpty($Identity)) {
        Write-Log "No user identity resolved; leaving default ACL on $Path" -Level ERROR
        return
    }

    # (OI)(CI) makes the grant inheritable so files created in the directory are
    # born restricted; a plain file just needs (F).
    $grant = if ($Container) { "${Identity}:(OI)(CI)F" } else { "${Identity}:F" }
    $result = Invoke-NativeCommand -FilePath "icacls.exe" -Arguments @(
        $Path, "/inheritance:r", "/grant:r", $grant
    )
    if ($result.ExitCode -ne 0) {
        Write-Log "Could not tighten ACL on $Path (icacls exit $($result.ExitCode)). Continuing." -Level ERROR
    }
}

function Get-DeviceSerial {
    <#
    .SYNOPSIS
        Gets the device serial number from WMI
    #>
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        if ($bios.SerialNumber) {
            return $bios.SerialNumber.Trim()
        }
        return $null
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
        Queries Microsoft Graph API to find the device by serial number and
        returns the userPrincipalName associated with the device. The OData
        $filter/$select query parameters are URL-encoded so the serial number
        (untrusted device input) cannot break out of the query string.
    #>
    param([string]$DeviceSerial)

    try {
        Write-Log "Querying Microsoft Graph API for device serial: $DeviceSerial"

        $filter = [uri]::EscapeDataString("serialNumber eq '$DeviceSerial'")
        $select = [uri]::EscapeDataString("id,deviceName,serialNumber,userPrincipalName")
        # The leading `$ in `$filter/`$select are literal OData parameter names,
        # not PowerShell variables, so they are backtick-escaped.
        $graphUrl = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$filter&`$select=$select"

        $headers = @{
            "Authorization" = "Bearer $GRAPH_API_TOKEN"
            "Content-Type"  = "application/json"
        }

        $response = Invoke-RestMethod -Uri $graphUrl -Method Get -Headers $headers -UseBasicParsing -ErrorAction Stop

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
        Gets the currently logged-in user as a full principal (DOMAIN\User or
        AzureAD\User), suitable both for deriving the short username and for
        icacls ACL grants.
    #>
    try {
        $loggedInUser = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty UserName
        if ($loggedInUser) {
            return $loggedInUser
        }

        # Fallback: query the owner of explorer.exe.
        $explorerProcess = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
        if ($explorerProcess) {
            $owner = Invoke-CimMethod -InputObject $explorerProcess -MethodName GetOwner
            if ($owner.Domain) {
                return "$($owner.Domain)\$($owner.User)"
            }
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

    try {
        $userProfile = Get-CimInstance -ClassName Win32_UserProfile |
            Where-Object { $_.LocalPath -like "*$Username*" -and -not $_.Special } |
            Select-Object -First 1 -ExpandProperty LocalPath

        if ($userProfile) {
            return $userProfile
        }
    }
    catch {
        # Fallback to the standard path below.
    }

    return "C:\Users\$Username"
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Log "Starting Corridor MDM provisioning..."

# Check if configuration is set
if ($CORRIDOR_TEAM_TOKEN -eq "cor-team_..." -or [string]::IsNullOrEmpty($CORRIDOR_TEAM_TOKEN)) {
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

# Get the logged-in user (full principal) and derive the short username
$LoggedInUser = Get-LoggedInUser
if ([string]::IsNullOrEmpty($LoggedInUser)) {
    Write-Log "Could not retrieve logged-in username" -Level ERROR
    exit 1
}
if ($LoggedInUser -like "*\*") {
    $CurrentUser = $LoggedInUser.Split("\")[-1]
}
else {
    $CurrentUser = $LoggedInUser
}
Write-Log "Current User: $CurrentUser"

# Resolve the user's profile path and align %USERPROFILE% to it. When the script
# runs as the logged-on user (the required Intune setting) these already match;
# aligning them keeps per-user installs correct even if the process environment
# differs.
$UserProfilePath = Get-UserProfilePath -Username $CurrentUser
$env:USERPROFILE = $UserProfilePath
Write-Log "User Profile Path: $UserProfilePath"

# Get user email from Microsoft Graph API using device serial
$UserEmail = Get-UserEmailFromGraph -DeviceSerial $DeviceSerial
if ([string]::IsNullOrEmpty($UserEmail)) {
    Write-Log "Could not retrieve user email from Microsoft Graph API." -Level ERROR
    Write-Log "Ensure the device is enrolled in Intune and GRAPH_API_TOKEN is valid."
    exit 1
}
Write-Log "User Email: $UserEmail"

# ============================================================================
# Install the Corridor CLI
# ============================================================================
# Download and run the Windows CLI installer for the logged-in user. CI=1 keeps
# it non-interactive (no SSO prompt); CORRIDOR_MDM=1 tells it this is a managed
# device so it still updates the user PATH and defers agent-plugin setup to the
# `corridor install --yes` call this script makes after provisioning. The
# installer is run in a child PowerShell so its `exit` on failure cannot abort
# this script — CLI install is non-fatal, matching macOS.
$CorridorConfigDir = Join-Path $UserProfilePath ".corridor"
$CorridorCliExe = Join-Path $CorridorConfigDir "bin\corridor.exe"
$CliInstalled = $false

$env:CI = "1"
$env:CORRIDOR_MDM = "1"

Write-Log "Installing the Corridor CLI for $CurrentUser..."
try {
    $installerPath = Join-Path $env:TEMP "corridor-cli-install.ps1"
    Invoke-WebRequest -Uri $CLI_INSTALL_URL -OutFile $installerPath -UseBasicParsing -ErrorAction Stop

    $cliResult = Invoke-NativeCommand -FilePath "powershell.exe" -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installerPath
    )
    if ($cliResult.Output) {
        Write-Log "Corridor CLI installer output:`n$($cliResult.Output.TrimEnd())"
    }

    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

    if ($cliResult.ExitCode -eq 0) {
        $CliInstalled = $true
        Write-Log "Corridor CLI installed successfully" -Level SUCCESS
    }
    else {
        Write-Log "Corridor CLI installer exited with code $($cliResult.ExitCode) (continuing with extension provisioning)" -Level ERROR
    }
}
catch {
    Write-Log "Failed to install the Corridor CLI: $_ (continuing with extension provisioning)" -Level ERROR
}

# ============================================================================
# Detect installed editors
# ============================================================================
# Each editor lists candidate (Exe, Cli) pairs covering per-user and machine-wide
# installs; the first candidate whose Exe and Cli both exist is used.
$Editors = @(
    [pscustomobject]@{
        Name       = "Cursor"
        Platform   = "cursor"
        ExtDir     = ".cursor\extensions"
        Candidates = @(
            @{ Exe = (Join-Path $UserProfilePath "AppData\Local\Programs\cursor\Cursor.exe"); Cli = (Join-Path $UserProfilePath "AppData\Local\Programs\cursor\resources\app\bin\cursor.cmd") },
            @{ Exe = "C:\Program Files\cursor\Cursor.exe"; Cli = "C:\Program Files\cursor\resources\app\bin\cursor.cmd" }
        )
    },
    [pscustomobject]@{
        Name       = "VSCode"
        Platform   = "vscode"
        ExtDir     = ".vscode\extensions"
        Candidates = @(
            @{ Exe = (Join-Path $UserProfilePath "AppData\Local\Programs\Microsoft VS Code\Code.exe"); Cli = (Join-Path $UserProfilePath "AppData\Local\Programs\Microsoft VS Code\bin\code.cmd") },
            @{ Exe = "C:\Program Files\Microsoft VS Code\Code.exe"; Cli = "C:\Program Files\Microsoft VS Code\bin\code.cmd" },
            @{ Exe = "C:\Program Files (x86)\Microsoft VS Code\Code.exe"; Cli = "C:\Program Files (x86)\Microsoft VS Code\bin\code.cmd" }
        )
    },
    [pscustomobject]@{
        Name       = "Windsurf"
        Platform   = "windsurf"
        ExtDir     = ".windsurf\extensions"
        Candidates = @(
            @{ Exe = (Join-Path $UserProfilePath "AppData\Local\Programs\Windsurf\Windsurf.exe"); Cli = (Join-Path $UserProfilePath "AppData\Local\Programs\Windsurf\bin\windsurf.cmd") },
            @{ Exe = "C:\Program Files\Windsurf\Windsurf.exe"; Cli = "C:\Program Files\Windsurf\bin\windsurf.cmd" }
        )
    }
)

$InstalledEditors = @()
foreach ($editor in $Editors) {
    $found = $null
    foreach ($candidate in $editor.Candidates) {
        if (Test-Path -LiteralPath $candidate.Exe) {
            if (Test-Path -LiteralPath $candidate.Cli) {
                $found = $candidate
                break
            }
            else {
                Write-Log "$($editor.Name) found at $($candidate.Exe) but CLI not available at $($candidate.Cli)" -Level ERROR
            }
        }
    }

    if ($found) {
        Write-Log "$($editor.Name) detected at $($found.Exe)"
        $InstalledEditors += [pscustomobject]@{
            Name     = $editor.Name
            Platform = $editor.Platform
            ExtDir   = $editor.ExtDir
            Exe      = $found.Exe
            Cli      = $found.Cli
        }
    }
}

# Build the list of platforms to provision: each installed editor plus "cli" if
# the Corridor CLI installed successfully.
$ProvisionPlatforms = @()
foreach ($editor in $InstalledEditors) {
    $ProvisionPlatforms += $editor.Platform
}
if ($CliInstalled) {
    $ProvisionPlatforms += "cli"
}

# Nothing to do if there are no editors and the CLI did not install.
if ($InstalledEditors.Count -eq 0) {
    Write-Log "No supported editors (Cursor, VS Code, Windsurf) are installed. Skipping Corridor extension installation."
    if ($ProvisionPlatforms.Count -eq 0) {
        Write-Log "Corridor CLI not installed and no editors found; nothing to provision."
        exit 0
    }
}
else {
    Write-Log "Found $($InstalledEditors.Count) installed editor(s): $(($InstalledEditors | ForEach-Object { $_.Name }) -join ', ')"
}

# ============================================================================
# Install the Corridor extension for each detected editor
# ============================================================================
foreach ($editor in $InstalledEditors) {
    Write-Log "Installing Corridor extension for $($editor.Name)..."

    $install = Invoke-NativeCommand -FilePath $editor.Cli -Arguments @(
        "--install-extension", "corridor.Corridor", "--force"
    )
    $output = $install.Output

    if ($output -match "(?i)already installed") {
        Write-Log "Corridor extension is already installed for $($editor.Name)"
    }
    elseif ($install.ExitCode -eq 0) {
        Write-Log "Corridor extension installed successfully for $($editor.Name)" -Level SUCCESS
    }
    else {
        # Fallback: the install command failed; check the extensions directory.
        $extDir = Join-Path $UserProfilePath $editor.ExtDir
        $extInstalled = $false
        if (Test-Path -LiteralPath $extDir) {
            $corridorExt = Get-ChildItem -LiteralPath $extDir -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "(?i)corridor" }
            if ($corridorExt) {
                $extInstalled = $true
            }
        }

        if ($extInstalled) {
            Write-Log "Corridor extension is already installed for $($editor.Name)"
        }
        else {
            Write-Log "Failed to install Corridor extension for $($editor.Name) (exit $($install.ExitCode)): $output" -Level ERROR
            exit 1
        }
    }
}

# ============================================================================
# Provision user and create a separate API token for each platform
# ============================================================================
Write-Log "Provisioning user with Corridor..."
$mdmSyncUri = "$CORRIDOR_API_URL/extension-auth/mdm-sync-device"

foreach ($platform in $ProvisionPlatforms) {
    Write-Log "Creating API token for $platform..."

    $body = @{
        deviceSerial = $DeviceSerial
        userEmail    = $UserEmail
        platform     = $platform
    } | ConvertTo-Json -Compress

    # Write the body to a temp file and POST it with curl --data-binary. This
    # sidesteps Windows curl JSON-escaping issues, and Invoke-RestMethod's habit
    # of downgrading to GET on some 5.1 builds.
    $bodyFile = Join-Path $env:TEMP "corridor-mdm-body.json"
    Set-Content -Path $bodyFile -Encoding ascii -NoNewline -Value $body

    $curlArgs = @(
        "-s",
        "-S",
        "-w", "`n%{http_code}",
        "-X", "POST",
        "-H", "Authorization: Bearer $CORRIDOR_TEAM_TOKEN",
        "-H", "Content-Type: application/json",
        "--data-binary", "@$bodyFile",
        $mdmSyncUri
    )
    $curl = Invoke-NativeCommand -FilePath "curl.exe" -Arguments $curlArgs

    Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue

    if ($curl.ExitCode -ne 0) {
        Write-Log "Failed to connect to Corridor API for $platform (curl exit code: $($curl.ExitCode))" -Level ERROR
        exit 1
    }

    # Split the trailing status code (curl -w "`n%{http_code}") from the body.
    $trimmed = $curl.Output.TrimEnd("`r", "`n")
    $newlineIndex = $trimmed.LastIndexOf("`n")
    if ($newlineIndex -ge 0) {
        $httpCode = $trimmed.Substring($newlineIndex + 1).Trim()
        $responseBody = $trimmed.Substring(0, $newlineIndex)
    }
    else {
        $httpCode = $trimmed.Trim()
        $responseBody = ""
    }

    if ($httpCode -ne "200") {
        Write-Log "Failed to provision token for $platform. HTTP $httpCode" -Level ERROR
        # A non-200 body is an error message (never contains an API token).
        Write-Log "Response body: $responseBody" -Level ERROR
        exit 1
    }

    try {
        $response = $responseBody | ConvertFrom-Json
    }
    catch {
        Write-Log "Could not parse Corridor API response for $platform" -Level ERROR
        exit 1
    }

    $apiToken = $response.apiToken
    $apiTokenId = $response.apiTokenId

    if ([string]::IsNullOrEmpty($apiToken)) {
        Write-Log "Could not extract API token from response for $platform" -Level ERROR
        exit 1
    }

    # Each platform gets its own subdirectory: .corridor/cursor, .corridor/vscode,
    # .corridor/windsurf, .corridor/cli. The IDE extensions and CLI read
    # %USERPROFILE%\.corridor\<platform>\pending-token.
    $platformConfigDir = Join-Path $CorridorConfigDir $platform
    $pendingTokenFile = Join-Path $platformConfigDir "pending-token"

    if (-not (Test-Path -LiteralPath $platformConfigDir)) {
        New-Item -ItemType Directory -Path $platformConfigDir -Force | Out-Null
    }

    # Tighten the directory ACL before writing the token so the file is born
    # restricted (Windows analogue of macOS umask 077 / chmod 700).
    Set-UserOnlyAcl -Path $platformConfigDir -Identity $LoggedInUser -Container

    $tokenData = @{
        apiToken      = $apiToken
        apiTokenId    = $apiTokenId
        provisionedAt = (Get-Date -Format "o")
    } | ConvertTo-Json

    Set-Content -Path $pendingTokenFile -Encoding ascii -Value $tokenData -Force

    # Belt-and-suspenders: restrict the token file itself too (chmod 600).
    Set-UserOnlyAcl -Path $pendingTokenFile -Identity $LoggedInUser

    Write-Log "Pending token for $platform stored in $pendingTokenFile" -Level SUCCESS
}

Write-Log "User provisioned successfully!" -Level SUCCESS
Write-Log "The Corridor extension will migrate tokens for each editor to secure storage on next launch of that editor"

# ============================================================================
# Install agent plugins (Claude Code, Factory Droid, Codex)
# ============================================================================
# With the CLI installed and its "cli" token provisioned above, configure the
# agent plugins. `corridor install --yes` migrates the pending CLI token into the
# user's config at startup, authenticates from it non-interactively, and detects
# which agent CLIs (claude, droid, codex) are present in PATH. A missing agent CLI
# or incomplete plugin setup is non-fatal, matching macOS.
if ($CliInstalled) {
    Write-Log "Setting up Corridor agent plugins (Claude Code, etc.) for $CurrentUser..."
    if (Test-Path -LiteralPath $CorridorCliExe) {
        $pluginResult = Invoke-NativeCommand -FilePath $CorridorCliExe -Arguments @("install", "--yes")
        if ($pluginResult.Output) {
            Write-Log "corridor install output:`n$($pluginResult.Output.TrimEnd())"
        }
        if ($pluginResult.ExitCode -eq 0) {
            Write-Log "Corridor agent plugins installed" -Level SUCCESS
        }
        else {
            Write-Log "Corridor agent plugin setup skipped or incomplete (non-fatal, e.g. no claude/droid/codex in PATH, or install did not finish; exit $($pluginResult.ExitCode)). See corridor output above for the cause." -Level ERROR
        }
    }
    else {
        Write-Log "Corridor CLI not found at $CorridorCliExe; skipping agent plugin setup (non-fatal)." -Level ERROR
    }
}

Write-Log "Corridor MDM provisioning complete!" -Level SUCCESS
exit 0
