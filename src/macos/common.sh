# ============================================================================
# Validate device identity
# ============================================================================
# IDENTITY_SOURCE names where the values came from, for error messages.
if ! is_safe_value "$DEVICE_SERIAL"; then
    log_error "Device serial from $IDENTITY_SOURCE contains unexpected characters. Refusing to use it."
    exit 1
fi
log_info "Device Serial: $DEVICE_SERIAL"

if ! is_safe_value "$USER_EMAIL"; then
    log_error "User email from $IDENTITY_SOURCE contains unexpected characters. Refusing to use it."
    exit 1
fi
case "$USER_EMAIL" in
    *@*.*) ;;
    *)
        log_error "User email '$USER_EMAIL' from $IDENTITY_SOURCE is not an email address.${EMAIL_SHAPE_HINT:+ $EMAIL_SHAPE_HINT}"
        exit 1
        ;;
esac
log_info "User email: $USER_EMAIL"

# ============================================================================
# Resolve the target user
# ============================================================================
# Console owner only. A "most recent GUI user" fallback would provision the
# MDM-assigned user's token into whichever account last logged in.
CURRENT_USER=$(stat -f "%Su" /dev/console)

case "$CURRENT_USER" in
    ""|root|_*)
        log_error "No user is signed in at the console (console owner: '${CURRENT_USER:-unknown}'). Corridor installs per user, so run this script while the developer is signed in. Exiting 1 so the MDM records a failure and retries on a later check-in."
        exit 1
        ;;
esac

if ! is_safe_username "$CURRENT_USER"; then
    log_error "Console user name '$CURRENT_USER' contains unexpected characters. Refusing to provision."
    exit 1
fi

CURRENT_USER_UID=$(id -u "$CURRENT_USER" 2>/dev/null || echo "")
case "$CURRENT_USER_UID" in
    ""|*[!0-9]*)
        log_error "Could not resolve a numeric UID for console user '$CURRENT_USER'."
        exit 1
        ;;
esac
if [ "$CURRENT_USER_UID" -lt 500 ]; then
    log_error "Console user '$CURRENT_USER' is a system account (UID $CURRENT_USER_UID). Refusing to provision."
    exit 1
fi

# dscl wraps long values onto a second line, so flatten before stripping the key.
USER_HOME=$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory 2>/dev/null \
    | tr '\n' ' ' | sed 's/^NFSHomeDirectory: *//; s/ *$//')
if [ -z "$USER_HOME" ] || [ -L "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    log_error "Could not resolve a home directory for '$CURRENT_USER'."
    exit 1
fi
if [ "$(stat -f '%u' "$USER_HOME")" != "$CURRENT_USER_UID" ]; then
    log_error "Home directory $USER_HOME is not owned by '$CURRENT_USER'. Refusing to provision."
    exit 1
fi
log_info "Current User: $CURRENT_USER ($USER_HOME)"

EMAIL_LOCAL_PART="${USER_EMAIL%%@*}"
if [ "$CURRENT_USER" != "$EMAIL_LOCAL_PART" ]; then
    log_warn "Console user '$CURRENT_USER' does not match the MDM-assigned user '$USER_EMAIL'. Tokens for $USER_EMAIL will be written to $USER_HOME - confirm this device is assigned to the person using it."
fi

CORRIDOR_CONFIG_DIR="$USER_HOME/.corridor"

# ============================================================================
# Install the Corridor CLI
# ============================================================================
# Runs as the interactive user so HOME resolves to their ~/.corridor. CI=1 skips
# the interactive plugin setup; CORRIDOR_MDM=1 marks this a persistent managed
# device. Downloaded to a file rather than piped to bash so a truncated download
# cannot partially execute and the bytes can be checksummed first.
log_info "Installing the Corridor CLI for $CURRENT_USER..."

CLI_INSTALLED="false"

if ! CLI_INSTALLER=$(sudo -u "$CURRENT_USER" mktemp /tmp/corridor-cli-install.XXXXXX); then
    CLI_INSTALLER=""
    log_error "Could not create a temporary file to download the Corridor CLI installer (continuing with extension provisioning)"
elif ! sudo -u "$CURRENT_USER" curl -fsSL \
    --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 120 \
    --retry 2 --retry-connrefused \
    -o "$CLI_INSTALLER" "$CORRIDOR_CLI_INSTALL_URL"; then
    log_error "Failed to download the Corridor CLI installer (continuing with extension provisioning)"
elif [ ! -s "$CLI_INSTALLER" ]; then
    log_error "Downloaded Corridor CLI installer is empty (continuing with extension provisioning)"
else
    INSTALLER_SHA256=$(sudo -u "$CURRENT_USER" shasum -a 256 "$CLI_INSTALLER" | awk '{print $1}')
    if [ -n "$CORRIDOR_CLI_SHA256" ] && [ "$INSTALLER_SHA256" != "$CORRIDOR_CLI_SHA256" ]; then
        log_error "Corridor CLI installer checksum mismatch (expected $CORRIDOR_CLI_SHA256, got $INSTALLER_SHA256). Refusing to run it."
    else
        if [ -z "$CORRIDOR_CLI_SHA256" ]; then
            log_info "Corridor CLI installer SHA-256 is $INSTALLER_SHA256 (not verified - set CORRIDOR_CLI_SHA256 to pin it)"
        fi
        if sudo -u "$CURRENT_USER" env HOME="$USER_HOME" CI=1 CORRIDOR_MDM=1 \
            bash "$CLI_INSTALLER"; then
            log_success "Corridor CLI installed successfully"
            CLI_INSTALLED="true"
        else
            log_error "Failed to install the Corridor CLI (continuing with extension provisioning)"
        fi
    fi
fi

rm -f "$CLI_INSTALLER"
CLI_INSTALLER=""

# ============================================================================
# Provision through the Corridor CLI
# ============================================================================
CORRIDOR_BIN="$CORRIDOR_CONFIG_DIR/bin/corridor"

# version_at_least <version> <minimum>: numeric x.y.z compare. Anything that is
# not plain digits (a dev build, a prerelease tag) fails, so it takes the
# legacy path.
version_at_least() {
    local have want i
    IFS=. read -r -a have <<< "$1"
    IFS=. read -r -a want <<< "$2"
    for i in 0 1 2; do
        case "${have[$i]:-}" in ""|*[!0-9]*) return 1 ;; esac
        [ "${have[$i]}" -gt "${want[$i]}" ] && return 0
        [ "${have[$i]}" -lt "${want[$i]}" ] && return 1
    done
    return 0
}

CLI_VERSION=""
if [ "$CLI_INSTALLED" = "true" ] && [ -x "$CORRIDOR_BIN" ]; then
    CLI_VERSION=$(sudo -u "$CURRENT_USER" env HOME="$USER_HOME" "$CORRIDOR_BIN" --version 2>/dev/null \
        | awk 'NR == 1 { print $NF }' || echo "")
fi

if version_at_least "$CLI_VERSION" "$CORRIDOR_MIN_PROVISION_VERSION"; then
    log_info "Provisioning $CURRENT_USER with corridor $CLI_VERSION..."
    # The team token goes on stdin to stay out of argv. launchctl asuser puts the
    # editor CLIs in the user's GUI session, as running them from Terminal would.
    if printf '%s\n' "$CORRIDOR_TEAM_TOKEN" \
        | launchctl asuser "$CURRENT_USER_UID" sudo -u "$CURRENT_USER" env HOME="$USER_HOME" \
            "$CORRIDOR_BIN" mdm provision \
            --email "$USER_EMAIL" --serial "$DEVICE_SERIAL" --api-url "$CORRIDOR_API_URL"; then
        exit 0
    fi
    log_error "corridor mdm provision failed. See its output above; the MDM will retry on a later check-in."
    exit 1
fi

if [ "$CLI_INSTALLED" = "true" ]; then
    log_info "Corridor CLI version '${CLI_VERSION:-unknown}' is older than $CORRIDOR_MIN_PROVISION_VERSION; using in-script provisioning."
fi

# @include legacy-provision.sh
