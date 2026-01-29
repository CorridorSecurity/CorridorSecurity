# Corridor MDM Provisioning Scripts

These are scripts for deploying the Corridor extension to managed devices via MDM (Mobile Device Management) solutions. 
For detailed instructions on how to run these on your MDM, refer to the [MDM Support Guide](https://app.usepylon.com/docs/4b84ff2b-3cc4-4452-a136-0297f288ebd4/articles/e3072a26-7a38-4822-8308-9de3677afae3).

## What These Scripts Do

These scripts automate the deployment of the Corridor extension to developer machines. For each managed device, they will:

1. **Detect installed editors** - Scan for Cursor, VS Code, and Windsurf
2. **Install the Corridor extension** - Use each editor's CLI to install the extension
3. **Provision API tokens** - Create per-editor API tokens for the user and store them for the extension to pick up on next launch

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