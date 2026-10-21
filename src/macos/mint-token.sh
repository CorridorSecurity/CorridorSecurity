# ============================================================================
# Mint a per-user API token
# ============================================================================
# mint_platform_token <platform>: sets API_TOKEN and API_TOKEN_ID. Returns 1
# after a warning on a non-200 so the caller can record the failure and go on.
# An unreachable API or a response that cannot be trusted exits 1.
mint_platform_token() {
    local platform="$1"
    local request_body response http_code body

    log_info "Creating API token for $platform..."

    request_body=$(printf '{"deviceSerial": "%s", "userEmail": "%s", "platform": "%s"}' \
        "$DEVICE_SERIAL" "$USER_EMAIL" "$platform")

    # Token goes through a config file on stdin to keep this team-wide credential
    # out of argv. No --retry: this call mints a token, so a retried POST would
    # leave extra live credentials behind.
    if ! response=$(printf 'header = "Authorization: Bearer %s"\n' "$CORRIDOR_TEAM_TOKEN" \
        | curl -s --config - \
            --proto '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 60 \
            -w "\n%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$request_body" \
            "$CORRIDOR_API_URL/extension-auth/mdm-sync-device"); then
        log_error "Could not reach $CORRIDOR_API_URL to provision $platform"
        exit 1
    fi

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log_warn "Failed to provision token for $platform. HTTP $http_code: $(redact "$body")"
        return 1
    fi

    API_TOKEN=$(printf '%s' "$body" | sed -n 's/.*"apiToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    API_TOKEN_ID=$(printf '%s' "$body" | sed -n 's/.*"apiTokenId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    if [ -z "$API_TOKEN" ]; then
        log_error "Could not extract API token from response for $platform"
        exit 1
    fi
    if ! is_safe_value "$API_TOKEN" || ! is_safe_value "$API_TOKEN_ID"; then
        log_error "API token response for $platform contains unexpected characters. Refusing to store it."
        exit 1
    fi
}
