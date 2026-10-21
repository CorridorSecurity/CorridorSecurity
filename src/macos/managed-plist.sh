# ============================================================================
# Read device configuration from the managed plist
# ============================================================================
# Expects MANAGED_PLIST, PLIST_SERIAL_KEY, PLIST_EMAIL_KEY, IDENTITY_SOURCE and
# the hint variables used in the messages below.
# MDM writes this path as root; anything else means the identity is not
# authoritative.
if [ -L "$MANAGED_PLIST" ] || [ ! -f "$MANAGED_PLIST" ]; then
    log_error "Managed preferences file not found at $MANAGED_PLIST. $PLIST_MISSING_HINT"
    exit 1
fi

if [ "$(stat -f '%u' "$MANAGED_PLIST")" != "0" ]; then
    log_error "$MANAGED_PLIST is not owned by root. Refusing to read device identity from it."
    exit 1
fi

# plutil reads the file directly, bypassing cfprefsd's cached view.
DEVICE_SERIAL=$(plutil -extract "$PLIST_SERIAL_KEY" raw -o - "$MANAGED_PLIST" 2>/dev/null || echo "")
USER_EMAIL=$(plutil -extract "$PLIST_EMAIL_KEY" raw -o - "$MANAGED_PLIST" 2>/dev/null || echo "")

if [ -z "$DEVICE_SERIAL" ]; then
    log_error "Could not retrieve device serial number. Ensure $PLIST_PROFILE_NAME pushes $PLIST_SERIAL_KEY to $MANAGED_PLIST."
    exit 1
fi

if [ -z "$USER_EMAIL" ]; then
    log_error "Could not retrieve user email. Ensure $PLIST_PROFILE_NAME pushes $PLIST_EMAIL_KEY to $MANAGED_PLIST${PLIST_EMAIL_EMPTY_HINT:+, $PLIST_EMAIL_EMPTY_HINT}."
    exit 1
fi

