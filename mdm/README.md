# Corridor MDM Provisioning Scripts

These are scripts for deploying the Corridor extension to managed devices via MDM (Mobile Device Management) solutions. 
For detailed instructions on how to run these on your MDM, refer to the [MDM Support Guide](https://app.usepylon.com/docs/4b84ff2b-3cc4-4452-a136-0297f288ebd4/articles/e3072a26-7a38-4822-8308-9de3677afae3).

## What These Scripts Do

These scripts automate the deployment of the Corridor extension to developer machines. For each managed device, they will:

1. **Detect installed editors** - Scan for Cursor, VS Code, and Windsurf
2. **Install the Corridor extension** - Use each editor's CLI to install the extension
3. **Provision API tokens** - Create per-editor API tokens for the user and store them for the extension to pick up on next launch

The scripts also download and install the Corridor CLI for the logged-in user, provision a `cli` API token, and run `corridor install --yes` to set up agent plugins (Claude Code, Factory Droid, Codex). On macOS this uses [install.sh](https://app.corridor.dev/cli/install.sh) (`curl -fsSL https://app.corridor.dev/cli/install.sh | bash`); on Windows it uses [install.ps1](https://app.corridor.dev/cli/install.ps1).

> **Windows execution context:** macOS scripts run as root and use `sudo -u "$CURRENT_USER"` to do per-user work as the signed-in user. Windows has no unprivileged equivalent — a SYSTEM-context script cannot drop to the user without their password — so `intune-windows.ps1` must be deployed with Intune's **"Run this script using the logged-on credentials = Yes"** setting so it runs in the signed-in user's context.

## Supported MDMs

| MDM | Platform | Script | Extra files |
| --- | --- | --- | --- |
| Microsoft Intune | macOS | `intune-macos.sh` | — |
| Microsoft Intune | Windows | `intune-windows.ps1` | — |
| Kandji | macOS | `kandji-macos.sh` | — |
| Jamf Pro | macOS | `jamf-macos.sh` | `dev.corridor.mdm.plist` (configuration profile) |
| Fleet | macOS | `fleet-macos.sh` | `fleet-dev.corridor.mdm.mobileconfig` (configuration profile) |

Every script needs the user's email and the device serial number to provision tokens; the scripts differ mainly in how their MDM supplies those two values.

## Available Scripts

### `intune-macos.sh` and `intune-windows.ps1`

For MacOS and Windows devices managed by **Microsoft Intune**.

**Requirements:**
- `CORRIDOR_TEAM_TOKEN` - Your team's Universal Team Token from Corridor settings
- `GRAPH_API_TOKEN` - Microsoft Graph API token with `DeviceManagementManagedDevices.Read.All` permission

The scripts retrieve the user's email from Microsoft Graph API using the device serial number.

### `kandji-macos.sh`

For MacOS devices managed by **Kandji**.

**Requirements:**
- `CORRIDOR_TEAM_TOKEN` - Your team's Universal Team Token from Corridor settings

The script uses Kandji's global variables (`$EMAIL` and `$SERIAL_NUMBER`) which are injected by Kandji through custom profiles.

### `jamf-macos.sh`

For MacOS devices managed by **Jamf Pro**, deployed as a policy script.

**Requirements:**
- `CORRIDOR_TEAM_TOKEN` - Your team's Universal Team Token from Corridor settings
- A configuration profile that pushes `dev.corridor.mdm.plist` (in this directory) to `/Library/Managed Preferences/dev.corridor.mdm.plist`, with Jamf substituting the `UserEmail` and `SerialNumber` values

The script reads the user's email and device serial from the managed plist.

### `fleet-macos.sh`

For MacOS devices managed by **Fleet** ([fleetdm.com](https://fleetdm.com)), run via Fleet scripts (manually, through the API/`fleetctl`, or as a policy automation).

**Requirements:**
- `CORRIDOR_TEAM_TOKEN` - Your team's Universal Team Token from Corridor settings, stored as a Fleet custom variable named `CORRIDOR_TEAM_TOKEN` (the script references it as `$FLEET_SECRET_CORRIDOR_TEAM_TOKEN`, which Fleet substitutes server-side and masks in its UI and API)
- `fleet-dev.corridor.mdm.mobileconfig` (in this directory) uploaded under **Controls → OS settings → Configuration profiles** (called "Custom settings" before Fleet 4.84), scoped to the fleet containing your target hosts. It pushes the user's email and device serial to `/Library/Managed Preferences/dev.corridor.mdm.plist` using Fleet's built-in variables (`$FLEET_VAR_HOST_END_USER_IDP_USERNAME` and `$FLEET_VAR_HOST_HARDWARE_SERIAL`)
- Fleet must know each host's end user (IdP integration or human-to-host mapping), and the resolved IdP username must be an email address, otherwise the profile fails to resolve the email variable
- Script execution enabled in `fleetd` (enabled by default on hosts with Fleet MDM turned on)
- An active console session on the Mac. Because Fleet policy automations run unattended, the script skips (exit 0) rather than provisioning to the wrong home directory when nobody is signed in, and the automation picks it up on a later run
- Optional: set `CORRIDOR_CLI_SHA256` in the script to pin the expected SHA-256 of the Corridor CLI installer. The script logs the observed hash when unset

The script reads the user's email and device serial from the managed plist, mirroring the Jamf Pro flow. It is hardened beyond the other MDM scripts: the team token reaches `curl` through a config file on stdin instead of argv, token files are written as the target user rather than as root, MDM-supplied values are charset-validated before use, and logged output is redacted, since Fleet stores script output verbatim.