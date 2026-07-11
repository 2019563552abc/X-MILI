#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$repo_dir/x-ui.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "firewall menu test failed: $*" >&2
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

functions=(
    firewall_require_ufw
    firewall_current_ssh_server_port
    firewall_list_rules
    firewall_status
    firewall_enable
    firewall_disable
    install_firewall
    open_ports
    delete_ports
    firewall_menu
)

library="$tmp_dir/firewall-functions.sh"
{
    cat <<'EOF'
red=''
green=''
plain=''
X_MILI_LANG='en_US'
is_zh() { [[ "$X_MILI_LANG" == "zh_CN" ]]; }
LOGE() { echo "[ERR] $*" >&2; }
show_menu() { :; }
EOF
    for function_name in "${functions[@]}"; do
        extract_function "$function_name" \
            || fail "missing function $function_name in x-ui.sh"
    done
} > "$library"

# shellcheck source=/dev/null
source "$library"

empty_path="$tmp_dir/empty-path"
mkdir -p "$empty_path"

assert_missing_ufw_is_safe() {
    local function_name="$1" output status
    set +e
    output=$(PATH="$empty_path" "$function_name" 2>&1)
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail "$function_name unexpectedly succeeded without ufw"
    [[ "$output" == *"UFW is not installed"* ]] \
        || fail "$function_name did not explain that ufw is missing: $output"
    [[ "$output" != *"command not found"* ]] \
        || fail "$function_name attempted to execute a missing command: $output"
}

for function_name in \
    firewall_list_rules firewall_status firewall_enable firewall_disable \
    open_ports delete_ports; do
    assert_missing_ufw_is_safe "$function_name"
done

# Reproduce the reported path and every other UFW-backed menu action. Each
# operation must fail before prompting for additional input or mutating state.
for menu_choice in 2 3 4 5 6 7; do
    set +e
    menu_output=$(PATH="$empty_path" firewall_menu <<< "$menu_choice"$'\n0\n' 2>&1)
    menu_status=$?
    set -e
    [[ $menu_status -eq 0 ]] \
        || fail "firewall menu did not return after missing-ufw option $menu_choice"
    [[ "$menu_output" == *"UFW is not installed"* ]] \
        || fail "menu option $menu_choice did not explain that ufw is missing"
    [[ "$menu_output" != *"command not found"* ]] \
        || fail "menu option $menu_choice called ufw directly"
done

# Choosing Install is the only missing-dependency path allowed to invoke a package manager.
set +e
install_output=$(PATH="$empty_path" install_firewall 2>&1)
install_status=$?
set -e
[[ $install_status -ne 0 ]] || fail "install_firewall succeeded without ufw or apt-get"
[[ "$install_output" == *"apt-get is required"* ]] \
    || fail "install_firewall did not report the missing package manager"

mock_bin="$tmp_dir/mock-bin"
mkdir -p "$mock_bin"
ufw_log="$tmp_dir/ufw.log"
cat > "$mock_bin/ufw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UFW_LOG"
if [[ ${1:-} == status ]]; then
    echo 'Status: inactive'
    echo '443 ALLOW Anywhere'
fi
EOF
chmod +x "$mock_bin/ufw"
export UFW_LOG="$ufw_log"

# Installing an already-present package must not silently add rules or enable UFW.
: > "$ufw_log"
PATH="$mock_bin:$PATH" install_firewall > /dev/null
[[ ! -s "$ufw_log" ]] \
    || fail "install_firewall changed UFW state even though Enable is a separate menu option"

for valid_port in 1 2222 65535; do
    detected_port=$(SSH_CONNECTION="198.51.100.10 50123 203.0.113.20 $valid_port" \
        firewall_current_ssh_server_port)
    [[ "$detected_port" == "$valid_port" ]] \
        || fail "failed to detect valid SSH server port $valid_port"
done

# Enabling must fail before changing UFW unless the active SSH server port is
# present and valid. In particular, assuming the `ssh` service means port 22
# would disconnect administrators using a custom port.
for ssh_connection in '' \
    '198.51.100.10 50123 203.0.113.20 0' \
    '198.51.100.10 50123 203.0.113.20 65536' \
    '198.51.100.10 50123 203.0.113.20 invalid' \
    '198.51.100.10 50123 203.0.113.20 2222 extra'; do
    : > "$ufw_log"
    set +e
    SSH_CONNECTION="$ssh_connection" PATH="$mock_bin:$PATH" \
        firewall_enable <<< 'y' > /dev/null 2>&1
    enable_status=$?
    set -e
    [[ $enable_status -ne 0 ]] \
        || fail "firewall_enable accepted invalid SSH_CONNECTION: $ssh_connection"
    [[ ! -s "$ufw_log" ]] \
        || fail "firewall_enable changed UFW before validating SSH_CONNECTION"
done

: > "$ufw_log"
PATH="$mock_bin:$PATH" firewall_list_rules > /dev/null
PATH="$mock_bin:$PATH" firewall_status > /dev/null
SSH_CONNECTION='198.51.100.10 50123 203.0.113.20 2222' \
    PATH="$mock_bin:$PATH" firewall_enable <<< 'y' > /dev/null
PATH="$mock_bin:$PATH" firewall_disable > /dev/null
PATH="$mock_bin:$PATH" open_ports <<< '443' > /dev/null
PATH="$mock_bin:$PATH" delete_ports <<< $'2\n443\n' > /dev/null

expected_calls=(
    'status numbered'
    'status verbose'
    'status'
    'status numbered'
    'allow 2222/tcp'
    '--force enable'
    'disable'
    'allow 443'
    'status'
    'status numbered'
    'delete allow 443'
    'status'
)
mapfile -t actual_calls < "$ufw_log"
[[ ${#actual_calls[@]} -eq ${#expected_calls[@]} ]] \
    || fail "unexpected ufw call count: ${actual_calls[*]}"
for index in "${!expected_calls[@]}"; do
    [[ "${actual_calls[$index]}" == "${expected_calls[$index]}" ]] \
        || fail "unexpected ufw call $index: ${actual_calls[$index]}"
done

echo "firewall menu tests passed"
