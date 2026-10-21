if [ -z "$CORRIDOR_TEAM_TOKEN" ] || [ "$CORRIDOR_TEAM_TOKEN" = "cor-team_..." ]; then
    log_error "CORRIDOR_TEAM_TOKEN is not configured. Set your team token in the configuration section at the top of this script."
    exit 1
fi

if ! is_safe_value "$CORRIDOR_TEAM_TOKEN"; then
    log_error "CORRIDOR_TEAM_TOKEN contains unexpected characters. Re-copy the Universal Team Token without surrounding quotes or whitespace."
    exit 1
fi

