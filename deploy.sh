#!/usr/bin/env bash
# X-MILI GitHub Release deployment helper.
#
# This installer deliberately downloads a prebuilt, checksummed release instead
# of building application code on the target server.  It is intended for Linux
# hosts using systemd and is safe to run again for upgrades.

set -euo pipefail

APP_NAME="X-MILI"
SERVICE_NAME="x-ui"
DEFAULT_DEPLOY_ROOT="/opt/x-mili"
DEFAULT_CONFIG_DIR="/etc/x-mili"
DEFAULT_DATA_DIR="/var/lib/x-mili"
DEFAULT_LOG_DIR="/var/log/x-mili"
MODE="install"
REQUESTED_REPO=""
REQUESTED_REF=""
REQUESTED_RELEASE_TAG=""
ENV_REPO="${X_MILI_REPO:-}"
ENV_REF="${X_MILI_REF:-}"
ENV_RELEASE_TAG="${X_MILI_RELEASE_TAG:-}"

say() {
    printf '[%s] %s\n' "$APP_NAME" "$*"
}

fail() {
    printf '[%s] Error: %s\n' "$APP_NAME" "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
X-MILI GitHub Release deployment helper

Usage:
  X_MILI_REPO=owner/repo X_MILI_REF=v1.0.0 bash deploy.sh
  deploy.sh --update
  deploy.sh --uninstall

For an update to a newer immutable release:
  deploy.sh --update --ref v1.0.1

Required for a first install:
  X_MILI_REPO   GitHub repository containing this release (owner/repo).
  X_MILI_REF    Immutable release tag, such as v1.0.0.

Optional variables:
  X_MILI_RELEASE_TAG     Release tag to download (must match X_MILI_REF).
  X_MILI_DEPLOY_ROOT     Release directory (default: /opt/x-mili).
  X_MILI_CONFIG_DIR      Configuration directory (default: /etc/x-mili).
  XUI_DB_FOLDER          Persistent data directory (default: /var/lib/x-mili).
  XUI_LOG_FOLDER         Log directory (default: /var/log/x-mili).
  X_MILI_USERNAME        Initial panel username when initialization is pending.
  X_MILI_PASSWORD        Initial panel password when initialization is pending.
  X_MILI_PANEL_PORT      Initial local panel port (default: 2053).
  X_MILI_WEB_BASE_PATH   Initial panel base path (default: /).
  X_MILI_ASSUME_YES=1    Skip the uninstall confirmation prompt.
  X_MILI_PURGE_DATA=1    Also remove persistent data and logs during uninstall.

Arguments:
  --repo owner/repo       Override the repository (normally only for migration).
  --ref vX.Y.Z           Select the immutable source revision and release tag.
  --release-tag vX.Y.Z   Select a release tag explicitly (must match --ref).

The installer accepts only version-like release tags (for example v1.0.0). Use
a protected tag created by the repository's release workflow so that the shell
script, release archive and SHA256SUMS originate from the same revision.
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || fail "run this command as root (for example: sudo bash deploy.sh)"
}

require_systemd_linux() {
    [[ "$(uname -s)" == "Linux" ]] || fail "this deployment helper supports Linux hosts only"
    command -v systemctl >/dev/null 2>&1 || fail "systemd/systemctl is required"
}

normalize_repo() {
    local repo="$1"
    repo="${repo%/}"
    repo="${repo%.git}"
    repo="${repo#https://github.com/}"
    repo="${repo#http://github.com/}"

    if [[ ! "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        return 1
    fi

    printf '%s' "$repo"
}

validate_release_ref() {
    local ref="$1"
    [[ "$ref" =~ ^v[0-9][A-Za-z0-9._-]*$ ]]
}

set_mode() {
    local requested_mode="$1"
    [[ "$MODE" == "install" || "$MODE" == "$requested_mode" ]] \
        || fail "--update and --uninstall cannot be used together"
    MODE="$requested_mode"
}

validate_path() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ && "$value" != "/" && "$value" != *"/../"* && "$value" != */.. && "$value" != *"/./"* && "$value" != */. ]] \
        || fail "$name must be an absolute path without spaces or parent-directory components"
}

validate_managed_path() {
    local name="$1"
    local value="$2"
    local parent="$3"

    validate_path "$name" "$value"
    [[ "$value" == "$parent/x-mili" || "$value" == "$parent/x-mili-"* ]] \
        || fail "$name must be ${parent}/x-mili or a ${parent}/x-mili-* managed directory"
}

load_existing_config() {
    local config_dir="${X_MILI_CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
    local env_file="$config_dir/x-mili.env"
    local line key value
    local required_key

    validate_managed_path "X_MILI_CONFIG_DIR" "$config_dir" "/etc"
    [[ ! -L "$config_dir" ]] || fail "configuration directory must not be a symbolic link: $config_dir"

    if [[ ! -e "$env_file" && ! -L "$env_file" ]]; then
        return
    fi
    [[ ! -L "$env_file" && -f "$env_file" ]] || fail "deployment environment file must be a regular file"
    command -v stat >/dev/null 2>&1 || fail "stat is required to validate the deployment environment file"
    [[ "$(stat -c '%u' -- "$env_file")" == "0" ]] || fail "deployment environment file must be owned by root"
    local mode
    mode="$(stat -c '%a' -- "$env_file")"
    (( (8#$mode & 8#022) == 0 )) || fail "deployment environment file must not be writable by group or other users"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || fail "invalid deployment environment entry"
        key="${line%%=*}"
        value="${line#*=}"
        [[ -n "$value" ]] || fail "deployment environment value is empty: $key"
        case "$key" in
            XUI_MAIN_FOLDER|XUI_DB_FOLDER|XUI_LOG_FOLDER|XUI_BIN_FOLDER|X_MILI_DEPLOY_ROOT|X_MILI_CONFIG_DIR|X_MILI_REPO|X_MILI_REF|X_MILI_RELEASE_TAG|X_MILI_RAW_BASE)
                printf -v "$key" '%s' "$value"
                export "$key"
                ;;
            *)
                fail "unsupported deployment environment key: $key"
                ;;
        esac
    done < "$env_file"

    for required_key in XUI_MAIN_FOLDER XUI_DB_FOLDER XUI_LOG_FOLDER XUI_BIN_FOLDER X_MILI_DEPLOY_ROOT X_MILI_CONFIG_DIR X_MILI_REPO X_MILI_REF X_MILI_RELEASE_TAG X_MILI_RAW_BASE; do
        [[ -n "${!required_key:-}" ]] || fail "deployment environment is missing $required_key"
    done

    [[ "$X_MILI_CONFIG_DIR" == "$config_dir" ]] || fail "deployment environment config directory does not match its location"
    validate_managed_path "X_MILI_DEPLOY_ROOT" "$X_MILI_DEPLOY_ROOT" "/opt"
    validate_managed_path "XUI_DB_FOLDER" "$XUI_DB_FOLDER" "/var/lib"
    validate_managed_path "XUI_LOG_FOLDER" "$XUI_LOG_FOLDER" "/var/log"
    [[ "$XUI_MAIN_FOLDER" == "$X_MILI_DEPLOY_ROOT/current" ]] || fail "deployment environment has an invalid main folder"
    [[ "$XUI_BIN_FOLDER" == "$X_MILI_DEPLOY_ROOT/current/bin" ]] || fail "deployment environment has an invalid binary folder"
}

detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'amd64'
            ;;
        *)
            fail "unsupported architecture: $(uname -m). GitHub releases currently provide linux-amd64 only"
            ;;
    esac
}

install_runtime_dependencies() {
    local missing=0
    local command_name
    for command_name in curl tar gzip sha256sum openvpn ip ping ps od tr realpath; do
        command -v "$command_name" >/dev/null 2>&1 || missing=1
    done

    [[ "$missing" -eq 0 ]] && return

    say "Installing runtime dependencies (no Go compiler or source build is needed)..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar gzip openvpn iproute2 iputils-ping procps
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl tar gzip coreutils openvpn iproute iputils procps-ng
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl tar gzip coreutils openvpn iproute iputils procps-ng
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates curl tar gzip coreutils openvpn iproute2 iputils procps
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm ca-certificates curl tar gzip coreutils openvpn iproute2 iputils procps-ng
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install ca-certificates curl tar gzip coreutils openvpn iproute2 iputils procps
    else
        fail "could not find a supported package manager; install curl, tar, gzip, coreutils, openvpn, iproute2, iputils and procps manually"
    fi
}

download_release() {
    local repo="$1"
    local tag="$2"
    local arch="$3"
    local temp_dir="$4"
    local asset="x-mili-linux-${arch}.tar.gz"
    local release_url="https://github.com/${repo}/releases/download/${tag}"
    local expected

    say "Downloading ${asset} from GitHub Release ${tag}..." >&2
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 \
        --output "$temp_dir/$asset" "$release_url/$asset"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 \
        --output "$temp_dir/SHA256SUMS" "$release_url/SHA256SUMS"

    expected="$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$temp_dir/SHA256SUMS")"
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || fail "SHA256SUMS does not contain a valid checksum for ${asset}"
    printf '%s  %s\n' "$expected" "$asset" > "$temp_dir/asset.sha256"
    (
        cd "$temp_dir"
        sha256sum --check asset.sha256
    )

    tar -tzf "$temp_dir/$asset" > "$temp_dir/archive-paths"
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$temp_dir/archive-paths"; then
        fail "release archive contains an unsafe path"
    fi
    mkdir -p "$temp_dir/extract"
    tar --no-same-owner --no-same-permissions -xzf "$temp_dir/$asset" -C "$temp_dir/extract"
    printf '%s' "$temp_dir/extract"
}

validate_release_bundle() {
    local release_dir="$1"
    local arch="$2"
    local commit

    [[ ! -L "$release_dir/x-ui" && ! -L "$release_dir/x-ui.sh" && ! -L "$release_dir/deploy.sh" && ! -L "$release_dir/bin/xray-linux-${arch}" && ! -L "$release_dir/.x-mili-commit" ]] \
        || fail "release bundle contains an unexpected symbolic link"
    [[ -x "$release_dir/x-ui" ]] || fail "release bundle is missing an executable x-ui binary"
    [[ -x "$release_dir/x-ui.sh" ]] || fail "release bundle is missing x-ui.sh"
    [[ -x "$release_dir/deploy.sh" ]] || fail "release bundle is missing deploy.sh"
    [[ -x "$release_dir/bin/xray-linux-${arch}" ]] || fail "release bundle is missing xray-linux-${arch}"
    [[ -f "$release_dir/.x-mili-commit" ]] || fail "release bundle is missing .x-mili-commit"

    commit="$(tr -d '[:space:]' < "$release_dir/.x-mili-commit")"
    [[ "$commit" =~ ^[A-Fa-f0-9]{40}$ ]] || fail "release bundle has an invalid commit marker"
    printf '%s' "$commit"
}

write_runtime_environment() {
    local env_file="$1"
    local deploy_root="$2"
    local data_dir="$3"
    local log_dir="$4"
    local repo="$5"
    local ref="$6"
    local tag="$7"
    local config_dir
    local temporary_env

    config_dir="$(dirname "$env_file")"
    [[ ! -L "$config_dir" ]] || fail "configuration directory must not be a symbolic link: $config_dir"
    install -d -m 0750 "$config_dir"
    chown root:root "$config_dir"
    chmod 0750 "$config_dir"
    temporary_env="$(mktemp "${config_dir}/.x-mili.env.XXXXXX")"
    cat > "$temporary_env" <<EOF
# Generated by ${APP_NAME} deploy.sh. Edit repository/ref values by redeploying.
XUI_MAIN_FOLDER=${deploy_root}/current
XUI_DB_FOLDER=${data_dir}
XUI_LOG_FOLDER=${log_dir}
XUI_BIN_FOLDER=${deploy_root}/current/bin
X_MILI_DEPLOY_ROOT=${deploy_root}
X_MILI_CONFIG_DIR=$(dirname "$env_file")
X_MILI_REPO=${repo}
X_MILI_REF=${ref}
X_MILI_RELEASE_TAG=${tag}
X_MILI_RAW_BASE=https://raw.githubusercontent.com/${repo}/${ref}
EOF
    chown root:root "$temporary_env"
    chmod 0600 "$temporary_env"
    mv -Tf "$temporary_env" "$env_file"
}

write_systemd_service() {
    local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
    local env_file="$1"
    local deploy_root="$2"
    local temporary_unit

    temporary_unit="$(mktemp "/etc/systemd/system/.${SERVICE_NAME}.service.XXXXXX")"
    cat > "$temporary_unit" <<EOF
# Managed by ${APP_NAME} deploy.sh
[Unit]
Description=${APP_NAME} Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${env_file}
WorkingDirectory=${deploy_root}/current
ExecStart=${deploy_root}/current/x-ui
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=on-failure
RestartSec=5s
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
    chown root:root "$temporary_unit"
    chmod 0644 "$temporary_unit"
    mv -Tf "$temporary_unit" "$unit_file"
}

write_command_wrappers() {
    local deploy_root="$1"
    local data_dir="$2"
    local log_dir="$3"
    local config_dir="$4"
    local repo="$5"
    local ref="$6"
    local tag="$7"
    local command
    local target
    local temporary_wrapper

    for command in ml x-ui; do
        if [[ "$command" == "ml" ]]; then
            target="x-ui.sh"
        else
            target="x-ui"
        fi
        temporary_wrapper="$(mktemp "/usr/bin/.${command}.x-mili.XXXXXX")"
        cat > "$temporary_wrapper" <<EOF
#!/usr/bin/env bash
# Managed by ${APP_NAME} deploy.sh
set -euo pipefail
export XUI_MAIN_FOLDER=${deploy_root}/current
export XUI_DB_FOLDER=${data_dir}
export XUI_LOG_FOLDER=${log_dir}
export XUI_BIN_FOLDER=${deploy_root}/current/bin
export X_MILI_DEPLOY_ROOT=${deploy_root}
export X_MILI_CONFIG_DIR=${config_dir}
export X_MILI_REPO=${repo}
export X_MILI_REF=${ref}
export X_MILI_RELEASE_TAG=${tag}
export X_MILI_RAW_BASE=https://raw.githubusercontent.com/${repo}/${ref}
exec "${deploy_root}/current/${target}" "\$@"
EOF
        chown root:root "$temporary_wrapper"
        chmod 0755 "$temporary_wrapper"
        mv -Tf "$temporary_wrapper" "/usr/bin/$command"
    done
}

random_string() {
    local length="$1"
    local value=""
    while (( ${#value} < length )); do
        value+="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    done
    printf '%s' "${value:0:length}"
}

pending_bootstrap() {
    local binary="$1"
    local settings
    if ! settings="$("$binary" setting -show true 2>&1)"; then
        printf '%s\n' "$settings" >&2
        return 2
    fi
    if [[ "$settings" == *"bootstrapPending: true"* ]]; then
        return 0
    fi
    if [[ "$settings" == *"bootstrapPending: false"* ]]; then
        return 1
    fi
    printf '[%s] Error: could not determine the bootstrap credential state\n' "$APP_NAME" >&2
    return 2
}

initialize_panel_credentials() {
    local binary="$1"
    local temporary_dir="$2"
    local username="${X_MILI_USERNAME:-}"
    local password="${X_MILI_PASSWORD:-}"
    local port="${X_MILI_PANEL_PORT:-2053}"
    local web_base_path="${X_MILI_WEB_BASE_PATH:-/}"
    local generated=0
    local status
    local password_file

    if pending_bootstrap "$binary"; then
        :
    else
        status=$?
        [[ "$status" -eq 1 ]] && return 0
        return "$status"
    fi

    if [[ -z "$username" && -t 0 ]]; then
        read -r -p "Initial panel username [admin]: " username
    fi
    username="${username:-admin}"

    if [[ -z "$password" && -t 0 ]]; then
        read -r -s -p "Initial panel password (leave empty to generate): " password
        printf '\n'
    fi
    if [[ -z "$password" ]]; then
        password="$(random_string 32)"
        generated=1
    fi

    [[ "$username" =~ ^[A-Za-z0-9._-]{3,64}$ ]] || fail "initial username must contain 3-64 letters, numbers, dots, underscores or hyphens"
    [[ "$password" =~ ^[^[:space:]]{12,128}$ ]] || fail "initial password must be 12-128 non-space characters"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || fail "initial panel port is invalid"
    [[ "$web_base_path" == /* && "$web_base_path" != *' '* ]] || fail "initial web base path must start with / and contain no spaces"

    say "Configuring initial panel credentials..."
    password_file="$(mktemp "${temporary_dir}/panel-password.XXXXXX")" || return 1
    chmod 0600 "$password_file"
    printf '%s' "$password" > "$password_file"
    if ! "$binary" setting -username "$username" -password-file "$password_file" -port "$port" -webBasePath "$web_base_path" -resetTwoFactor true; then
        rm -f -- "$password_file"
        return 1
    fi
    rm -f -- "$password_file"

    if pending_bootstrap "$binary"; then
        printf '[%s] Error: panel credentials were not initialized\n' "$APP_NAME" >&2
        return 1
    else
        status=$?
        [[ "$status" -eq 1 ]] || return "$status"
    fi

    if [[ "$generated" -eq 1 ]]; then
        printf '\nSave this generated panel password now (it will not be shown again):\n%s\n\n' "$username : $password"
    fi
    unset X_MILI_PASSWORD password
}

switch_current_release() {
    local target="$1"
    local current="$2"

    ln -s "$target" "${current}.next"
    mv -Tf "${current}.next" "$current"
}

prepare_current_switch() {
    local current="$1"
    local next_link="${current}.next"

    if [[ -L "$next_link" ]]; then
        rm -f -- "$next_link"
    fi
    [[ ! -e "$next_link" && ! -L "$next_link" ]] \
        || fail "refusing to replace an unexpected current-release temporary path: $next_link"
}

restore_previous_release() {
    local old_target="$1"
    local current="$2"

    if [[ -n "$old_target" && -d "$old_target" ]]; then
        say "Restoring the previous release after a failed deployment..."
        prepare_current_switch "$current"
        switch_current_release "$old_target" "$current"
    else
        rm -f "$current"
    fi
}

ensure_managed_directory() {
    local directory="$1"
    local mode="$2"

    [[ ! -L "$directory" ]] || fail "managed directory must not be a symbolic link: $directory"
    install -d -m "$mode" "$directory"
    [[ -d "$directory" && ! -L "$directory" ]] || fail "managed path is not a directory: $directory"
    chown root:root "$directory"
    chmod "$mode" "$directory"
}

is_managed_unit() {
    local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
    [[ -f "$unit_file" && ! -L "$unit_file" ]] && grep -Fqx "# Managed by ${APP_NAME} deploy.sh" "$unit_file"
}

is_managed_wrapper() {
    local wrapper="$1"
    [[ -f "$wrapper" && ! -L "$wrapper" ]] && grep -Fqx "# Managed by ${APP_NAME} deploy.sh" "$wrapper"
}

assert_managed_installation() {
    local deploy_root="$1"
    local current="$2"
    local releases_dir="$3"
    local env_file="$4"
    local data_dir="$5"
    local current_target
    local unit_path

    if [[ -e "$current" || -L "$current" ]]; then
        [[ -L "$current" ]] || fail "managed current-release path must be a symbolic link: $current"
        current_target="$(readlink -f "$current" 2>/dev/null || true)"
        [[ -n "$current_target" && "$current_target" == "$releases_dir/"* && -x "$current_target/deploy.sh" ]] \
            || fail "current release is not managed by this deployment helper"
        [[ -f "$env_file" && ! -L "$env_file" ]] || fail "managed installation is missing its environment file"
        is_managed_unit || fail "x-ui service is not managed by this deployment helper"
        is_managed_wrapper /usr/bin/ml || fail "ml command is not managed by this deployment helper"
        is_managed_wrapper /usr/bin/x-ui || fail "x-ui command is not managed by this deployment helper"
        return
    fi

    unit_path="$(systemctl show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null || true)"
    if [[ -n "$unit_path" || -e "/etc/systemd/system/${SERVICE_NAME}.service" || -L "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
        fail "an existing x-ui service was found; this installer will not overwrite a legacy installation"
    fi
    if [[ -e /etc/x-ui/x-ui.db || -e /usr/local/x-ui/x-ui || -e /usr/bin/ml || -L /usr/bin/ml || -e /usr/bin/x-ui || -L /usr/bin/x-ui ]]; then
        fail "a legacy x-ui installation was found; migrate or remove it before using deploy.sh"
    fi
    if [[ -e "$env_file" || -L "$env_file" ]]; then
        fail "a deployment environment file exists without a managed release; inspect it before retrying"
    fi
    if [[ -e "$data_dir/x-ui.db" || -e "$data_dir/x-ui.db-wal" || -e "$data_dir/x-ui.db-shm" ]]; then
        fail "a panel database exists without a managed release; inspect it before retrying"
    fi
}

backup_path() {
    local source="$1"
    local backup="$2"

    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$backup"
        printf '1'
    else
        printf '0'
    fi
}

restore_path() {
    local destination="$1"
    local backup="$2"
    local existed="$3"

    rm -f -- "$destination"
    if [[ "$existed" == "1" ]]; then
        cp -a -- "$backup" "$destination"
    fi
}

backup_database() {
    local data_dir="$1"
    local backup_dir="$2"
    local database_file
    local found=0

    install -d -m 0700 "$backup_dir"
    for database_file in "$data_dir/x-ui.db" "$data_dir/x-ui.db-wal" "$data_dir/x-ui.db-shm"; do
        if [[ -e "$database_file" ]]; then
            [[ ! -L "$database_file" ]] || fail "database files must not be symbolic links"
            cp -a -- "$database_file" "$backup_dir/"
            found=1
        fi
    done
    printf '%s' "$found"
}

restore_database() {
    local data_dir="$1"
    local backup_dir="$2"
    local existed="$3"

    rm -f -- "$data_dir/x-ui.db" "$data_dir/x-ui.db-wal" "$data_dir/x-ui.db-shm"
    if [[ "$existed" == "1" ]]; then
        cp -a -- "$backup_dir/." "$data_dir/"
    fi
}

rollback_deployment() {
    local old_target="$1"
    local current="$2"
    local service_was_active="$3"
    local env_file="$4"
    local env_backup="$5"
    local had_env="$6"
    local unit_file="$7"
    local unit_backup="$8"
    local had_unit="$9"
    local ml_backup="${10}"
    local had_ml="${11}"
    local xui_backup="${12}"
    local had_xui="${13}"
    local data_dir="${14}"
    local database_backup="${15}"
    local had_database="${16}"

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    restore_previous_release "$old_target" "$current" || true
    restore_database "$data_dir" "$database_backup" "$had_database" || true
    restore_path "$env_file" "$env_backup" "$had_env" || true
    restore_path "$unit_file" "$unit_backup" "$had_unit" || true
    restore_path /usr/bin/ml "$ml_backup" "$had_ml" || true
    restore_path /usr/bin/x-ui "$xui_backup" "$had_xui" || true
    systemctl daemon-reload || true

    if [[ -n "$old_target" && "$service_was_active" == "1" ]]; then
        systemctl restart "$SERVICE_NAME" || true
    elif [[ -z "$old_target" ]]; then
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    fi
}

safe_remove_directory() {
    local target="$1"
    local resolved

    resolved="$(realpath -m "$target")" || fail "could not resolve removal target: $target"
    [[ "$resolved" == "$target" ]] || fail "refusing to remove a path that resolves elsewhere: $target"
    case "$resolved" in
        /|/etc|/var|/opt|/usr|/usr/bin|/etc/systemd)
            fail "refusing to remove a protected directory: $resolved"
            ;;
    esac
    rm -rf -- "$resolved"
}

apply_requested_configuration() {
    local repo="${REQUESTED_REPO:-$ENV_REPO}"
    local ref="${REQUESTED_REF:-$ENV_REF}"
    local tag=""

    if [[ -n "$repo" ]]; then
        X_MILI_REPO="$repo"
        export X_MILI_REPO
    fi
    if [[ -n "$ref" ]]; then
        X_MILI_REF="$ref"
        export X_MILI_REF
    fi
    if [[ -n "$REQUESTED_RELEASE_TAG" ]]; then
        tag="$REQUESTED_RELEASE_TAG"
    elif [[ -n "$REQUESTED_REF" ]]; then
        tag="$REQUESTED_REF"
    elif [[ -n "$ENV_RELEASE_TAG" ]]; then
        tag="$ENV_RELEASE_TAG"
    elif [[ -n "$ENV_REF" ]]; then
        tag="$ENV_REF"
    fi

    if [[ -n "$tag" ]]; then
        X_MILI_RELEASE_TAG="$tag"
        export X_MILI_RELEASE_TAG
    elif [[ -n "$ref" ]]; then
        # A newly requested source revision implies the release of the same
        # immutable tag unless the caller explicitly chose a different asset.
        X_MILI_RELEASE_TAG="$ref"
        export X_MILI_RELEASE_TAG
    fi
}

deploy_release() {
    local deploy_root config_dir env_file data_dir log_dir repo ref tag arch temp_dir extracted_dir commit releases_dir target current old_target
    local unit_file env_backup unit_backup ml_backup xui_backup database_backup
    local had_env had_unit had_ml had_xui had_database service_was_active=0

    config_dir="${X_MILI_CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
    deploy_root="${X_MILI_DEPLOY_ROOT:-$DEFAULT_DEPLOY_ROOT}"
    data_dir="${XUI_DB_FOLDER:-$DEFAULT_DATA_DIR}"
    log_dir="${XUI_LOG_FOLDER:-$DEFAULT_LOG_DIR}"
    env_file="$config_dir/x-mili.env"
    current="$deploy_root/current"
    releases_dir="$deploy_root/releases"

    validate_managed_path "X_MILI_CONFIG_DIR" "$config_dir" "/etc"
    validate_managed_path "X_MILI_DEPLOY_ROOT" "$deploy_root" "/opt"
    validate_managed_path "XUI_DB_FOLDER" "$data_dir" "/var/lib"
    validate_managed_path "XUI_LOG_FOLDER" "$log_dir" "/var/log"
    assert_managed_installation "$deploy_root" "$current" "$releases_dir" "$env_file" "$data_dir"

    repo="$(normalize_repo "${X_MILI_REPO:-}")" || fail "X_MILI_REPO must be a GitHub owner/repository value"
    ref="${X_MILI_REF:-${X_MILI_RELEASE_TAG:-}}"
    tag="${X_MILI_RELEASE_TAG:-$ref}"
    validate_release_ref "$ref" || fail "X_MILI_REF must be an immutable version tag (for example v1.0.0)"
    validate_release_ref "$tag" || fail "X_MILI_RELEASE_TAG must be an immutable version tag"
    [[ "$ref" == "$tag" ]] || fail "X_MILI_REF and X_MILI_RELEASE_TAG must match so the launcher and archive come from one immutable revision"

    arch="$(detect_architecture)"
    install_runtime_dependencies
    temp_dir="$(mktemp -d)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    extracted_dir="$(download_release "$repo" "$tag" "$arch" "$temp_dir")"
    commit="$(validate_release_bundle "$extracted_dir" "$arch")"

    ensure_managed_directory "$deploy_root" 0755
    ensure_managed_directory "$releases_dir" 0755
    ensure_managed_directory "$data_dir" 0750
    ensure_managed_directory "$log_dir" 0750
    target="$releases_dir/$commit"
    [[ ! -L "$target" ]] || fail "release target must not be a symbolic link: $target"
    if [[ ! -e "$target" ]]; then
        install -d -m 0755 "$target"
        cp -a "$extracted_dir/." "$target/"
    fi
    validate_release_bundle "$target" "$arch" >/dev/null

    old_target="$(readlink -f "$current" 2>/dev/null || true)"
    if [[ -n "$old_target" && "$old_target" != "$releases_dir/"* ]]; then
        fail "current release points outside the managed releases directory: $old_target"
    fi
    prepare_current_switch "$current"

    unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
    env_backup="$temp_dir/previous-env"
    unit_backup="$temp_dir/previous-unit"
    ml_backup="$temp_dir/previous-ml"
    xui_backup="$temp_dir/previous-x-ui"
    database_backup="$temp_dir/previous-database"
    had_env="$(backup_path "$env_file" "$env_backup")"
    had_unit="$(backup_path "$unit_file" "$unit_backup")"
    had_ml="$(backup_path /usr/bin/ml "$ml_backup")"
    had_xui="$(backup_path /usr/bin/x-ui "$xui_backup")"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        service_was_active=1
    fi
    if ! had_database="$(backup_database "$data_dir" "$database_backup")"; then
        if [[ -n "$old_target" && "$service_was_active" == "1" ]]; then
            systemctl restart "$SERVICE_NAME" || true
        fi
        fail "could not back up the SQLite database before deployment"
    fi

    if ! switch_current_release "$target" "$current"; then
        rollback_deployment "$old_target" "$current" "$service_was_active" "$env_file" "$env_backup" "$had_env" "$unit_file" "$unit_backup" "$had_unit" "$ml_backup" "$had_ml" "$xui_backup" "$had_xui" "$data_dir" "$database_backup" "$had_database"
        fail "could not activate the new release"
    fi
    if ! write_runtime_environment "$env_file" "$deploy_root" "$data_dir" "$log_dir" "$repo" "$ref" "$tag"; then
        rollback_deployment "$old_target" "$current" "$service_was_active" "$env_file" "$env_backup" "$had_env" "$unit_file" "$unit_backup" "$had_unit" "$ml_backup" "$had_ml" "$xui_backup" "$had_xui" "$data_dir" "$database_backup" "$had_database"
        fail "could not write the deployment environment"
    fi
    if ! write_systemd_service "$env_file" "$deploy_root"; then
        rollback_deployment "$old_target" "$current" "$service_was_active" "$env_file" "$env_backup" "$had_env" "$unit_file" "$unit_backup" "$had_unit" "$ml_backup" "$had_ml" "$xui_backup" "$had_xui" "$data_dir" "$database_backup" "$had_database"
        fail "could not write the systemd service"
    fi
    if ! write_command_wrappers "$deploy_root" "$data_dir" "$log_dir" "$config_dir" "$repo" "$ref" "$tag"; then
        rollback_deployment "$old_target" "$current" "$service_was_active" "$env_file" "$env_backup" "$had_env" "$unit_file" "$unit_backup" "$had_unit" "$ml_backup" "$had_ml" "$xui_backup" "$had_xui" "$data_dir" "$database_backup" "$had_database"
        fail "could not write management command wrappers"
    fi

    export XUI_MAIN_FOLDER="$current"
    export XUI_DB_FOLDER="$data_dir"
    export XUI_LOG_FOLDER="$log_dir"
    export XUI_BIN_FOLDER="$current/bin"
    export X_MILI_DEPLOY_ROOT="$deploy_root"
    export X_MILI_CONFIG_DIR="$config_dir"
    export X_MILI_REPO="$repo"
    export X_MILI_REF="$ref"
    export X_MILI_RELEASE_TAG="$tag"
    export X_MILI_RAW_BASE="https://raw.githubusercontent.com/${repo}/${ref}"

    if [[ -z "$old_target" ]] && ! initialize_panel_credentials "$current/x-ui" "$temp_dir"; then
        rollback_deployment "$old_target" "$current" "$service_was_active" "$env_file" "$env_backup" "$had_env" "$unit_file" "$unit_backup" "$had_unit" "$ml_backup" "$had_ml" "$xui_backup" "$had_xui" "$data_dir" "$database_backup" "$had_database"
        fail "initial panel configuration failed"
    fi

    if ! systemctl daemon-reload; then
        rollback_deployment "$old_target" "$current" "$service_was_active" "$env_file" "$env_backup" "$had_env" "$unit_file" "$unit_backup" "$had_unit" "$ml_backup" "$had_ml" "$xui_backup" "$had_xui" "$data_dir" "$database_backup" "$had_database"
        fail "could not reload systemd"
    fi
    if ! systemctl enable --now "$SERVICE_NAME"; then
        rollback_deployment "$old_target" "$current" "$service_was_active" "$env_file" "$env_backup" "$had_env" "$unit_file" "$unit_backup" "$had_unit" "$ml_backup" "$had_ml" "$xui_backup" "$had_xui" "$data_dir" "$database_backup" "$had_database"
        fail "could not start ${SERVICE_NAME}; the previous release was restored when available"
    fi
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        rollback_deployment "$old_target" "$current" "$service_was_active" "$env_file" "$env_backup" "$had_env" "$unit_file" "$unit_backup" "$had_unit" "$ml_backup" "$had_ml" "$xui_backup" "$had_xui" "$data_dir" "$database_backup" "$had_database"
        fail "${SERVICE_NAME} did not remain active; the previous release was restored when available"
    fi

    # Keep old release directories so a failed later update can roll back
    # without downloading an older package again.
    trap - EXIT
    rm -rf -- "$temp_dir"

    say "Deployment completed. The panel is bound to localhost by default."
    say "Put a TLS-enabled reverse proxy in front of it before exposing it to the Internet."
    say "Use 'ml' for the management menu and 'ml update' for future release updates."
}

uninstall() {
    local config_dir="${X_MILI_CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
    local deploy_root="${X_MILI_DEPLOY_ROOT:-$DEFAULT_DEPLOY_ROOT}"
    local data_dir="${XUI_DB_FOLDER:-$DEFAULT_DATA_DIR}"
    local log_dir="${XUI_LOG_FOLDER:-$DEFAULT_LOG_DIR}"
    local env_file="$config_dir/x-mili.env"

    validate_managed_path "X_MILI_CONFIG_DIR" "$config_dir" "/etc"
    validate_managed_path "X_MILI_DEPLOY_ROOT" "$deploy_root" "/opt"
    validate_managed_path "XUI_DB_FOLDER" "$data_dir" "/var/lib"
    validate_managed_path "XUI_LOG_FOLDER" "$log_dir" "/var/log"
    assert_managed_installation "$deploy_root" "$deploy_root/current" "$deploy_root/releases" "$env_file" "$data_dir"
    [[ ! -L "$deploy_root" && ! -L "$data_dir" && ! -L "$log_dir" ]] \
        || fail "managed deployment, data and log directories must not be symbolic links"

    if [[ "${X_MILI_ASSUME_YES:-}" != "1" ]]; then
        read -r -p "Remove ${APP_NAME} program files and service? Persistent data will be kept [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || {
            say "Uninstall cancelled."
            return
        }
    fi

    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service" /usr/bin/ml /usr/bin/x-ui
    systemctl daemon-reload
    safe_remove_directory "$deploy_root"
    safe_remove_directory "$config_dir"

    if [[ "${X_MILI_PURGE_DATA:-}" == "1" ]]; then
        safe_remove_directory "$data_dir"
        safe_remove_directory "$log_dir"
        say "Program files, configuration, persistent data and logs were removed."
    else
        say "Program files and configuration were removed. Persistent data remains in ${data_dir}; logs remain in ${log_dir}."
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)
            set_mode "update"
            shift
            ;;
        --uninstall)
            set_mode "uninstall"
            shift
            ;;
        --repo)
            [[ $# -ge 2 ]] || fail "--repo requires an owner/repository value"
            REQUESTED_REPO="$2"
            shift 2
            ;;
        --ref)
            [[ $# -ge 2 ]] || fail "--ref requires a version tag"
            REQUESTED_REF="$2"
            shift 2
            ;;
        --release-tag)
            [[ $# -ge 2 ]] || fail "--release-tag requires a version tag"
            REQUESTED_RELEASE_TAG="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1 (try --help)"
            ;;
    esac
done

require_root
require_systemd_linux

if [[ "$MODE" != "install" ]]; then
    load_existing_config
fi
apply_requested_configuration

if [[ "$MODE" == "uninstall" ]]; then
    uninstall
    exit 0
fi

deploy_release
