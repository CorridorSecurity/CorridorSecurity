# ============================================================================
# Legacy in-script provisioning
# ============================================================================
# Used when the installed CLI predates `corridor mdm provision`
# (CORRIDOR_MIN_PROVISION_VERSION) or did not install. Remove once every
# supported CLI release has the command.
EXTENSION_INSTALL_TIMEOUT=60
EXTENSION_PHASE_TIMEOUT=150

kill_process_tree() {
    local parent_pid="$1"
    local child_pid
    for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null); do
        kill_process_tree "$child_pid"
    done
    kill -TERM "$parent_pid" 2>/dev/null || true
    kill -KILL "$parent_pid" 2>/dev/null || true
}

run_extension_install() {
    EXTENSION_OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/corridor-extension.XXXXXX")
    launchctl asuser "$CURRENT_USER_UID" sudo -u "$CURRENT_USER" \
        env NODE_USE_SYSTEM_CA=1 "$CLI_PATH" \
        --install-extension corridor.Corridor --force \
        > "$EXTENSION_OUTPUT_FILE" 2>&1 &
    local install_pid=$!
    local elapsed=0
    local phase_remaining=$((EXTENSION_PHASE_TIMEOUT - (SECONDS - EXTENSION_PHASE_START)))
    local install_timeout="$EXTENSION_INSTALL_TIMEOUT"
    if [ "$phase_remaining" -lt "$install_timeout" ]; then
        install_timeout="$phase_remaining"
    fi
    INSTALL_TIMEOUT_USED="$install_timeout"
    while kill -0 "$install_pid" 2>/dev/null; do
        if [ "$elapsed" -ge "$install_timeout" ]; then
            kill_process_tree "$install_pid"
            wait "$install_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$install_pid"
}

# ============================================================================
# Detect editors and install the Corridor extension
# ============================================================================
# bash 3.x compatible - no associative arrays.
EDITOR_NAMES="Cursor VSCode Windsurf Devin"

get_editor_app_name() {
    case "$1" in
        Cursor)   echo "Cursor.app" ;;
        VSCode)   echo "Visual Studio Code.app" ;;
        Windsurf) echo "Windsurf.app" ;;
        Devin)    echo "Devin.app" ;;
    esac
}

get_editor_platform() {
    case "$1" in
        Cursor)   echo "cursor" ;;
        VSCode)   echo "vscode" ;;
        Windsurf) echo "windsurf" ;;
        # Placeholder until Corridor adds a dedicated Devin Desktop platform.
        Devin)    echo "windsurf" ;;
    esac
}

get_editor_cli() {
    case "$1" in
        Cursor)   echo "cursor" ;;
        VSCode)   echo "code" ;;
        Windsurf) echo "windsurf" ;;
        Devin)    echo "devin-desktop" ;;
    esac
}

get_editor_app() {
    echo "/Applications/$(get_editor_app_name "$1")"
}

# VS Code in particular is often left in ~/Downloads.
get_editor_app_alternative() {
    echo "$USER_HOME/Downloads/$(get_editor_app_name "$1")"
}

get_editor_cli_path() {
    echo "/Applications/$(get_editor_app_name "$1")/Contents/Resources/app/bin/$(get_editor_cli "$1")"
}

get_editor_cli_path_alternative() {
    echo "$USER_HOME/Downloads/$(get_editor_app_name "$1")/Contents/Resources/app/bin/$(get_editor_cli "$1")"
}

get_editor_ext_dir() {
    case "$1" in
        Cursor)  echo ".cursor/extensions" ;;
        VSCode)  echo ".vscode/extensions" ;;
        Windsurf) echo ".windsurf/extensions" ;;
        Devin)   echo ".devin/extensions" ;;
    esac
}

INSTALLED_EDITORS=""
EDITOR_PATHS=""  # Track which path each editor was found at

for editor in $EDITOR_NAMES; do
    APP_PATH=$(get_editor_app "$editor")
    ALT_PATH=$(get_editor_app_alternative "$editor")

    if [ -d "$APP_PATH" ]; then
        INSTALLED_EDITORS="$INSTALLED_EDITORS $editor"
        EDITOR_PATHS="$EDITOR_PATHS $editor:standard"
        log_info "$editor detected at $APP_PATH"
    elif [ -d "$ALT_PATH" ]; then
        INSTALLED_EDITORS="$INSTALLED_EDITORS $editor"
        EDITOR_PATHS="$EDITOR_PATHS $editor:alternative"
        log_info "$editor detected at $ALT_PATH"
    fi
done

INSTALLED_EDITORS=$(echo "$INSTALLED_EDITORS" | sed 's/^ *//')

# One platform per installed editor, plus "cli" if the CLI installed.
PROVISION_PLATFORMS=""
for editor in $INSTALLED_EDITORS; do
    PLATFORM=$(get_editor_platform "$editor")
    case " $PROVISION_PLATFORMS " in
        *" $PLATFORM "*) ;;
        *) PROVISION_PLATFORMS="$PROVISION_PLATFORMS $PLATFORM" ;;
    esac
done
if [ "$CLI_INSTALLED" = "true" ]; then
    case " $PROVISION_PLATFORMS " in
        *" cli "*) ;;
        *) PROVISION_PLATFORMS="$PROVISION_PLATFORMS cli" ;;
    esac
fi
PROVISION_PLATFORMS=$(echo "$PROVISION_PLATFORMS" | sed 's/^ *//')

if [ -z "$INSTALLED_EDITORS" ]; then
    log_info "No supported editors (Cursor, VS Code, Windsurf, Devin) are installed. Skipping Corridor extension installation."
    if [ -z "$PROVISION_PLATFORMS" ]; then
        exit 0
    fi
fi

skip_remaining_editors() {
    if [ -n "$REMAINING_EDITORS" ]; then
        EXTENSION_FAILURE=1
        log_warn "Editor extension phase budget of ${EXTENSION_PHASE_TIMEOUT}s exhausted; skipping editors: $REMAINING_EDITORS. They will be retried on the next check-in."
    fi
}

EXTENSION_FAILURE=0
EXTENSION_PHASE_START=$SECONDS
REMAINING_EDITORS="$INSTALLED_EDITORS"
for editor in $INSTALLED_EDITORS; do
    [ -z "$editor" ] && continue

    if [ "$((SECONDS - EXTENSION_PHASE_START))" -ge "$EXTENSION_PHASE_TIMEOUT" ]; then
        skip_remaining_editors
        break
    fi
    REMAINING_EDITORS="${REMAINING_EDITORS#"$editor"}"
    REMAINING_EDITORS="${REMAINING_EDITORS# }"

    if echo "$EDITOR_PATHS" | grep -q "$editor:alternative"; then
        CLI_PATH=$(get_editor_cli_path_alternative "$editor")
    else
        CLI_PATH=$(get_editor_cli_path "$editor")
    fi
    EXT_DIR="$USER_HOME/$(get_editor_ext_dir "$editor")"

    if [ -z "$CLI_PATH" ]; then
        log_error "Unknown editor: $editor"
        exit 1
    fi

    if [ ! -f "$CLI_PATH" ]; then
        log_error "$editor CLI not found at $CLI_PATH"
        exit 1
    fi

    log_info "Installing Corridor extension for $editor..."

    # NODE_USE_SYSTEM_CA=1 adds the macOS System keychain to the editor's bundled
    # CA list, so installs work behind TLS-intercepting proxies (Zscaler, etc.).
    INSTALL_STATUS=0
    run_extension_install || INSTALL_STATUS=$?
    INSTALL_OUTPUT=$(cat "$EXTENSION_OUTPUT_FILE")
    rm -f "$EXTENSION_OUTPUT_FILE"
    EXTENSION_OUTPUT_FILE=""

    if [ "$INSTALL_STATUS" -eq 124 ]; then
        EXTENSION_FAILURE=1
        log_warn "Timed out installing the Corridor extension for $editor after ${INSTALL_TIMEOUT_USED}s; it will be retried on the next check-in."
        if [ "$((SECONDS - EXTENSION_PHASE_START))" -ge "$EXTENSION_PHASE_TIMEOUT" ]; then
            skip_remaining_editors
            break
        fi
        continue
    fi

    if echo "$INSTALL_OUTPUT" | grep -qi "already installed"; then
        log_info "Corridor extension is already installed for $editor"
    elif echo "$INSTALL_OUTPUT" | grep -qi "successfully installed\|was successfully installed"; then
        log_success "Corridor extension installed successfully for $editor"
    else
        if [ -n "$(find "$EXT_DIR" -maxdepth 1 -iname "*corridor*" -print -quit 2>/dev/null)" ]; then
            log_info "Corridor extension is already installed for $editor"
        else
            log_error "Failed to install Corridor extension for $editor: $(redact "$INSTALL_OUTPUT")"
            exit 1
        fi
    fi
done

# ============================================================================
# Provision an API token per platform
# ============================================================================
log_info "Provisioning user with Corridor..."
PLATFORM_FAILURE=0

for PLATFORM in $PROVISION_PLATFORMS; do
    PLATFORM_CONFIG_DIR="$CORRIDOR_CONFIG_DIR/$PLATFORM"

    if ! mint_platform_token "$PLATFORM"; then
        PLATFORM_FAILURE=1
        continue
    fi

    TOKEN_JSON=$(printf '{\n  "apiToken": "%s",\n  "apiTokenId": "%s",\n  "provisionedAt": "%s"\n}\n' \
        "$API_TOKEN" "$API_TOKEN_ID" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")")

    # Written as the target user, not root: the destination is a directory the
    # user owns, so a root-context mkdir or redirect could be aimed anywhere via
    # a symlink they planted. umask 077 covers creation, the chmods cover a
    # pre-existing directory, and the token arrives on stdin to stay out of argv.
    if ! printf '%s' "$TOKEN_JSON" | sudo -u "$CURRENT_USER" bash -c '
        umask 077
        config_dir="$1"
        platform_dir="$2"
        mkdir -p "$platform_dir" || exit 1
        chmod 700 "$config_dir" "$platform_dir" || exit 1
        cat > "$platform_dir/pending-token" || exit 1
        chmod 600 "$platform_dir/pending-token" || exit 1
    ' _ "$CORRIDOR_CONFIG_DIR" "$PLATFORM_CONFIG_DIR"; then
        log_error "Failed to store the pending token for $PLATFORM under $PLATFORM_CONFIG_DIR"
        exit 1
    fi

    log_info "Pending token for $PLATFORM stored in $PLATFORM_CONFIG_DIR/pending-token"
done

if [ "$PLATFORM_FAILURE" -eq 0 ]; then
    log_success "User provisioned successfully!"
else
    log_warn "One or more platform token provisions failed; successful platforms were processed."
fi
log_info "The Corridor extension will migrate tokens to secure storage on next launch of that editor"

# ============================================================================
# Install agent plugins (Claude Code, Factory Droid, Codex)
# ============================================================================
# `corridor install` migrates the pending CLI token into ~/.corridor/config.env
# and authenticates from it. A missing agent CLI is a non-fatal no-op.
if [ "$CLI_INSTALLED" = "true" ]; then
    log_info "Setting up Corridor agent plugins (Claude Code, etc.) for $CURRENT_USER..."
    if sudo -u "$CURRENT_USER" env HOME="$USER_HOME" \
        PATH="$USER_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        "$CORRIDOR_CONFIG_DIR/bin/corridor" install --yes; then
        log_success "Corridor agent plugins installed"
    else
        log_info "Corridor agent plugin setup skipped or incomplete (non-fatal — e.g. no claude/droid/codex in PATH, or install did not finish). See corridor output above for the cause."
    fi
fi

if [ "$EXTENSION_FAILURE" -ne 0 ] || [ "$PLATFORM_FAILURE" -ne 0 ]; then
    log_error "Corridor provisioning completed with one or more extension or platform token failures."
    exit 1
fi

log_success "Corridor MDM provisioning complete!"
exit 0
