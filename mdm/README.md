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

You need **both** files in this directory:
- `fleet-macos.sh` — the provisioning script
- `fleet-dev.corridor.mdm.mobileconfig` — the configuration profile that supplies email + serial

#### Prerequisites

- A Fleet Premium instance with MDM turned on for the test Mac (script execution is enabled automatically for MDM-enrolled hosts)
- Fleet knows the host's end user (IdP integration, or set the host's human in Fleet). Without this, the profile cannot resolve the email and will fail to deliver
- A Universal Team Token from Corridor (Settings → Team → Universal Team Token)

#### Setup (do these in order)

**1. Store the team token as a Fleet custom variable**

In Fleet, create a custom variable named exactly `CORRIDOR_TEAM_TOKEN` and set its value to your Universal Team Token.

The script references `$FLEET_SECRET_CORRIDOR_TEAM_TOKEN`. Fleet substitutes the real value when the script is sent to the host and masks it in the Fleet UI/API. Do not hardcode the token into the uploaded script.

**2. Deploy the device-info configuration profile**

1. Upload `fleet-dev.corridor.mdm.mobileconfig` under **Controls → OS settings → Custom settings**
2. Scope it to the team that contains your test host
3. Wait for Fleet to deliver the profile, then on the Mac verify:

```bash
defaults read "/Library/Managed Preferences/dev.corridor.mdm.plist"
```

You should see `UserEmail` (the host's IdP email / username) and `SerialNumber` (the hardware serial). If the profile is stuck failed in Fleet, the host has no end user assigned — fix that before continuing.

**3. Upload and run the provisioning script**

1. Upload `fleet-macos.sh` under **Controls → Scripts** (if Fleet rejects the upload as an unknown variable, Step 1's name is wrong — it must be exactly `CORRIDOR_TEAM_TOKEN`)
2. Run it on the test host:
   - **UI:** Hosts → select the host → Actions → Run script
   - **CLI:** `fleetctl run-script --script-path=fleet-macos.sh --host=<hostname>`

Fleet runs the script as root; per-user work (CLI install, extension install, token files) is done as the signed-in console user via `sudo -u`.

#### Verify the run

- In Fleet, open the host's activity / script results and look for `[Corridor MDM] SUCCESS: Corridor MDM provisioning complete!`
- On the Mac, pending tokens should exist under `~/.corridor/<platform>/pending-token` for each detected editor (`cursor`, `vscode`, `windsurf`) plus `cli` if the Corridor CLI installed
- Launch a provisioned editor once — the extension migrates the pending token into secure storage
- The device should appear under your Corridor team's MDM-synced devices

#### Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Profile stuck "failed" in Fleet | Host has no end user in Fleet, so `$FLEET_VAR_HOST_END_USER_IDP_USERNAME` cannot resolve. Connect your IdP or set the host's human. |
| `CORRIDOR_TEAM_TOKEN is not configured` | Custom variable missing or misnamed, so the secret expanded to empty. |
| `Could not retrieve user email` / `device serial` | Profile from Step 2 not delivered yet, or scoped to the wrong team. Re-check the `defaults read` command above. |
| Extension install fails behind a TLS-intercepting proxy | The script sets `NODE_USE_SYSTEM_CA=1`; ensure your proxy root CA is in the macOS System keychain. |

#### Limitations

macOS only. Fleet runs Windows scripts as SYSTEM and cannot drop to the signed-in user, which Corridor provisioning requires — use `intune-windows.ps1` for Windows.