# Publishing notes — Fleet MDM Support Guide

## Mintlify source (canonical)

- GitHub: `corridorsecurity/corridor` (private)
- Branch: `main`
- Content directory: `public-docs/`
- Likely path: `public-docs/administration/mdm-support.mdx` (confirm extension/frontmatter against the live file)
- Live: https://docs.corridor.dev/administration/mdm-support

This cloud agent only has GitHub App access to `CorridorSecurity/CorridorSecurity`,
not the private Mintlify repo. Copy
`mdm/mintlify/administration/mdm-support.mdx` into the corridor monorepo (keeping
the existing frontmatter if it differs), then remove this staging directory so
the scripts repo does not become a second source of truth.

## Canonical vs Pylon

`docs.corridor.dev` (Mintlify) is canonical. The Pylon article at
`app.usepylon.com/...` requires sign-in and is a stale copy. `mdm/README.md`
now links to the Mintlify guide.

## Before publishing to customers

* Fleet navigation labels move between releases: 4.84 renamed "Custom settings"
  to "Configuration profiles"; 4.82 renamed "teams" to "fleets". This guide
  uses 4.84+ labels with older names in parentheses. Re-verify against
  fleetdm.com/guides/scripts, /guides/fleet-variables, and
  /guides/secrets-in-scripts-and-configuration-profiles.
* The two-file requirement is a Fleet limitation (fleetdm/fleet#46837, targeted
  for 4.91; latest release 4.89.2). The guide has a short "coming soon" Note —
  update or remove it when 4.91 ships.
* Unlike the other MDMs, customers must not paste the team token into the Fleet
  script. `$FLEET_SECRET_CORRIDOR_TEAM_TOKEN` is deliberate and keeps the token
  masked in Fleet.
* Profile delivery has not been verified against a Fleet instance with valid
  public TLS. Confirm on a real instance before publishing.
* The `curl .../refs/heads/main/mdm/fleet-*` URLs require the Fleet files on
  `main` (see CorridorSecurity PR #15).
* TODOs left in the MDX: reference policy query; dashboard screenshot.
