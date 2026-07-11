#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$repo_dir/x-ui.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "restart_xray test failed: $*" >&2
    exit 1
}

extract_function() {
    local name="$1"
    awk -v name="$name" '
        $0 ~ "^" name "\\(\\) \\{" { capturing=1 }
        capturing { print }
        capturing && /^}$/ { found=1; exit }
        END { if (!found) exit 1 }
    ' "$source_file"
}

library="$tmp_dir/restart-xray-function.sh"
{
    extract_function xray_pid_snapshot \
        || fail "missing xray_pid_snapshot in x-ui.sh"
    extract_function restart_xray \
        || fail "missing restart_xray in x-ui.sh"
} > "$library"

# shellcheck source=/dev/null
source "$library"

ps() {
    cat <<'EOF'
100 bin/xray-linux-amd64 -c bin/config.json
101 bin/xray-linux-amd64 -c bin/xray_test_123.json
102 /usr/local/bin/not-xray --config config.json
EOF
}
main_xray_pids=""
xray_pid_snapshot main_xray_pids
[[ "$main_xray_pids" == "100 " ]] \
    || fail "main Xray PID filter included a test or unrelated process: $main_xray_pids"
unset -f ps

info_log="$tmp_dir/info.log"
error_log="$tmp_dir/error.log"
systemctl_log="$tmp_dir/systemctl.log"
sleep_log="$tmp_dir/sleep.log"

LOGI() { printf '%s\n' "$*" >> "$info_log"; }
LOGE() { printf '%s\n' "$*" >> "$error_log"; }
systemctl() {
    printf '%s\n' "$*" >> "$systemctl_log"
    return "$systemctl_rc"
}
sleep() { printf '%s\n' "$1" >> "$sleep_log"; }
before_show_menu() {
    menu_calls=$((menu_calls + 1))
    return 0
}
check_xray_status() {
    status_calls=$((status_calls + 1))
    ((status_calls >= healthy_on_call))
}
xray_pid_snapshot() {
    local destination="$1" value
    snapshot_calls=$((snapshot_calls + 1))
    if ((snapshot_calls == 1)); then
        value='100 '
    else
        case "$snapshot_mode" in
            stable) value='200 ' ;;
            old_then_new)
                if ((snapshot_calls <= 3)); then
                    value='100 '
                else
                    value='200 '
                fi
                ;;
            churn) value="$((snapshot_calls + 100)) " ;;
            overlap) value='100 200 ' ;;
            same) value='100 ' ;;
            *) fail "unknown snapshot mode: $snapshot_mode" ;;
        esac
    fi
    printf -v "$destination" '%s' "$value"
}

reset_mocks() {
    : > "$info_log"
    : > "$error_log"
    : > "$systemctl_log"
    : > "$sleep_log"
    systemctl_rc=0
    status_calls=0
    healthy_on_call=1
    menu_calls=0
    snapshot_calls=0
    snapshot_mode=stable
}

run_restart() {
    local with_menu="$1"
    set +e
    if [[ $with_menu == yes ]]; then
        restart_xray
    else
        restart_xray 0
    fi
    restart_status=$?
    set -e
}

reset_mocks
run_restart no
[[ $restart_status -eq 0 ]] || fail "healthy xray was reported as a failure"
[[ $status_calls -eq 2 ]] || fail "replacement xray was not checked for stability"
[[ $(wc -l < "$sleep_log") -eq 2 ]] || fail "replacement xray skipped the post-reload wait"
[[ $(<"$systemctl_log") == "reload x-ui" ]] \
    || fail "restart_xray issued the wrong systemctl command"
grep -q "restarted successfully" "$info_log" \
    || fail "successful restart was not reported"
[[ ! -s "$error_log" ]] || fail "successful restart emitted an error"

reset_mocks
healthy_on_call=4
run_restart no
[[ $restart_status -eq 0 ]] || fail "delayed xray startup was reported as a failure"
[[ $status_calls -eq 5 ]] || fail "delayed replacement was not checked for stability"
[[ $(wc -l < "$sleep_log") -eq 5 ]] || fail "restart used the wrong delayed-start wait"

reset_mocks
snapshot_mode=old_then_new
run_restart no
[[ $restart_status -eq 0 ]] || fail "replacement after a lingering old process was rejected"
[[ $status_calls -eq 4 ]] \
    || fail "restart accepted the old xray process before the replacement was stable"

reset_mocks
healthy_on_call=999
run_restart yes
[[ $restart_status -ne 0 ]] || fail "xray timeout was reported as successful"
[[ $status_calls -eq 8 ]] || fail "restart did not use the bounded eight checks"
[[ $(wc -l < "$sleep_log") -eq 8 ]] || fail "restart wait was not bounded at eight seconds"
[[ $menu_calls -eq 1 ]] || fail "interactive failure did not return to the menu"
grep -q "journalctl -u x-ui" "$error_log" \
    || fail "timeout did not point the user to journalctl"
[[ ! -s "$info_log" ]] || fail "timeout emitted a success message"

reset_mocks
snapshot_mode=churn
run_restart no
[[ $restart_status -ne 0 ]] || fail "a crash loop was reported as a stable restart"
[[ $status_calls -eq 8 ]] || fail "crash-loop verification was not bounded"

reset_mocks
snapshot_mode=overlap
run_restart no
[[ $restart_status -ne 0 ]] \
    || fail "restart succeeded while the old xray process was still present"

reset_mocks
systemctl_rc=5
run_restart no
[[ $restart_status -ne 0 ]] || fail "failed systemctl reload was reported as successful"
[[ $status_calls -eq 0 ]] || fail "xray was polled after reload command failure"
[[ ! -s "$sleep_log" ]] || fail "reload command failure incurred a pointless wait"
grep -q "journalctl -u x-ui" "$error_log" \
    || fail "reload failure did not point the user to journalctl"

echo "restart_xray tests passed"
