#!/bin/bash
# Checks account selection in fleet-macos.sh. No Fleet host and no dscl required.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
START_DIR=$(pwd)

CORRIDOR_FLEET_TEST_SOURCE=1
# shellcheck source=fleet-macos.sh
source "$SCRIPT_DIR/fleet-macos.sh"
cd "$START_DIR"

FAIL=0

ok() {
    printf 'ok %s\n' "$1"
}

bad() {
    printf 'FAIL %s\n' "$1" >&2
    FAIL=1
}

assert_eq() {
    local desc="$1"
    local got="$2"
    local want="$3"
    if [ "$got" = "$want" ]; then
        ok "$desc"
    else
        bad "$desc: got '$got' want '$want'"
    fi
}

assert_human() {
    local desc="$1"
    local user="$2"
    local uid="$3"
    local want="$4"
    local rc=0
    console_user_is_human "$user" "$uid" || rc=$?
    assert_eq "$desc" "$rc" "$want"
}

choose() {
    local email="$1"
    local accounts="$2"
    CHOOSE_OUT=""
    CHOOSE_RC=0
    CHOOSE_OUT=$(printf '%s\n' "$accounts" | choose_offline_user "$email") || CHOOSE_RC=$?
}

assert_human "signed-in user" "ada" "501" "0"
assert_human "uid 500 stays signed-in" "ada" "500" "0"
assert_human "setup assistant" "_mbsetupuser" "248" "1"
assert_human "root" "root" "0" "1"
assert_human "empty console" "" "" "1"
assert_human "low uid" "nobody" "429" "1"
assert_human "unsafe name" "ada;rm" "501" "1"
assert_human "non-numeric uid" "ada" "50a" "1"

choose "ada" "ada
other"
assert_eq "email match among two" "$CHOOSE_RC:$CHOOSE_OUT" "0:ada"

choose "Ada" "ada
other"
assert_eq "email match ignores case" "$CHOOSE_RC:$CHOOSE_OUT" "0:ada"

choose "nomatch" "only"
assert_eq "only account when email does not match" "$CHOOSE_RC:$CHOOSE_OUT" "0:only"

choose "nomatch" "ada
other"
assert_eq "two accounts and no email match" "$CHOOSE_RC" "1"

choose "ada" ""
assert_eq "no accounts" "$CHOOSE_RC" "1"

choose "ada" "ada
ada"
assert_eq "two email matches" "$CHOOSE_RC" "1"

FLAT=$(printf 'NFSHomeDirectory: /Users/ada\n' | flatten_nfs_home)
assert_eq "dscl home prefix is stripped" "$FLAT" "/Users/ada"

TMP=$(mktemp -d)
mkdir -p "$TMP/ada" "$TMP/other"
ln -s "$TMP/ada" "$TMP/linked"

dscl_list_unique_ids() {
    printf '%s\n' \
        "ada 501" \
        "other 502" \
        "_mbsetupuser 248" \
        "root 0" \
        "low 499" \
        "bad name 504" \
        "linked 505" \
        "missing 506" \
        "stolen 507"
}

dscl_nfs_home() {
    case "$1" in
        ada) printf '%s\n' "$TMP/ada" ;;
        other) printf '%s\n' "$TMP/other" ;;
        linked) printf '%s\n' "$TMP/linked" ;;
        missing) printf '%s\n' "$TMP/missing" ;;
        stolen) printf '%s\n' "$TMP/ada" ;;
        *) printf '%s\n' "$TMP/missing" ;;
    esac
}

path_owner() {
    case "$1" in
        "$TMP/ada") printf '%s\n' "501" ;;
        "$TMP/other") printf '%s\n' "502" ;;
        *) printf '%s\n' "0" ;;
    esac
}

COLLECTED=$(collect_local_accounts)
assert_eq "collector keeps owned uid 501+ homes" "$COLLECTED" "ada
other"

choose "other" "$COLLECTED"
assert_eq "collector feed prefers email" "$CHOOSE_RC:$CHOOSE_OUT" "0:other"

dscl_list_unique_ids() {
    printf '%s\n' "solo 501" "_mbsetupuser 248"
}
dscl_nfs_home() {
    printf '%s\n' "$TMP/ada"
}
path_owner() {
    printf '%s\n' "501"
}
COLLECTED=$(collect_local_accounts)
choose "someoneelse" "$COLLECTED"
assert_eq "setup assistant falls back to the only account" "$CHOOSE_RC:$CHOOSE_OUT" "0:solo"

if grep -q "Skipping provisioning" "$SCRIPT_DIR/fleet-macos.sh"; then
    bad "script still skips with exit 0"
else
    ok "script no longer skips with a success exit"
fi

if nothing_was_installed "" ""; then
    ok "no CLI and no editor is a failed install"
else
    bad "no CLI and no editor is a failed install"
fi
if nothing_was_installed "" "cli"; then
    bad "CLI alone is treated as nothing installed"
else
    ok "CLI alone is an install"
fi
if nothing_was_installed "Cursor" ""; then
    bad "an editor alone is treated as nothing installed"
else
    ok "an editor alone is an install"
fi
if grep -q "Nothing was installed. The Corridor CLI did not install" "$SCRIPT_DIR/fleet-macos.sh"; then
    ok "empty install tells Fleet it failed"
else
    bad "empty install tells Fleet it failed"
fi

rm -rf "$TMP"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
printf 'all fleet account checks passed\n'
