#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="X-MILI"
DEFAULT_REPO="https://github.com/2019563552abc/X-MILI"
REPO="${X_MILI_REPO:-$DEFAULT_REPO}"
REPO_SLUG="${REPO#https://github.com/}"
REPO_SLUG="${REPO_SLUG%.git}"
API_REPO="${X_MILI_API_REPO:-https://api.github.com/repos/${REPO_SLUG}}"
RELEASE_TAG="${X_MILI_RELEASE_TAG:-latest}"
REQUESTED_HTTP_EXPOSURE="${X_MILI_ALLOW_INSECURE_HTTP-}"
AUTO_OPEN_FIREWALL="${X_MILI_AUTO_OPEN_FIREWALL:-true}"
HTTP_EXPOSURE_ACTION="preserve"
FIRST_INSTALL=0
PARTIAL_INSTALL=0
INSTALL_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
DATA_DIR="/etc/x-ui"
LANG_DIR="/etc/x-mili"
LANG_FILE="$LANG_DIR/lang"
SERVICE_ENV_FILE="/etc/default/x-ui"
CREDENTIAL_RECOVERY_FILE="${X_MILI_CREDENTIAL_RECOVERY_FILE:-${DATA_DIR}/.x-mili-initial-credentials}"
INSTALL_IN_PROGRESS_FILE="${DATA_DIR}/.x-mili-install-in-progress"
X_MILI_LANG="${X_MILI_LANG:-}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
tmp_dir=""
prepared_package_dir=""

log() { echo -e "${green}[X-MILI]${plain} $*"; }
warn() { echo -e "${yellow}[X-MILI]${plain} $*"; }
fail() { echo -e "${red}[X-MILI]${plain} $*" >&2; exit 1; }
step() { echo -e "${green}[X-MILI]${plain} ${yellow}[$1/$2]${plain} $3"; }

normalize_repository() {
    local value="${REPO%/}"
    value="${value%.git}"
    value="${value#https://github.com/}"
    [[ "$value" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || fail "X_MILI_REPO must be a GitHub owner/repository value"
    REPO_SLUG="$value"
    REPO="https://github.com/${value}"
    if [[ -z "${X_MILI_API_REPO:-}" ]]; then
        API_REPO="https://api.github.com/repos/${value}"
    fi
    [[ "$API_REPO" == https://* ]] || fail "X_MILI_API_REPO must use HTTPS"
}

choose_language() {
    [[ -f "$LANG_FILE" ]] && X_MILI_LANG=$(cat "$LANG_FILE")
    if [[ -z "$X_MILI_LANG" ]]; then
        echo -e "${green}1.${plain} English"
        echo -e "${green}2.${plain} 简体中文"
        read -rp "Please choose language / 请选择语言 [1-2]: " choice
        [[ "$choice" == "2" ]] && X_MILI_LANG="zh_CN" || X_MILI_LANG="en_US"
        mkdir -p "$LANG_DIR"
        echo "$X_MILI_LANG" > "$LANG_FILE"
    fi
}

is_zh() { [[ "$X_MILI_LANG" == "zh_CN" ]]; }

validate_install_dir() {
    local resolved
    command -v realpath >/dev/null 2>&1 || fail "Missing required command: realpath"
    [[ "$INSTALL_DIR" == /* ]] || fail "XUI_MAIN_FOLDER must be an absolute path"
    [[ "$INSTALL_DIR" != *[[:space:]]* ]] || fail "XUI_MAIN_FOLDER must not contain whitespace"
    resolved="$(realpath -m -- "$INSTALL_DIR")" || fail "Could not resolve XUI_MAIN_FOLDER: ${INSTALL_DIR}"
    case "$resolved" in
        /usr/local/*|/opt/*) ;;
        *) fail "XUI_MAIN_FOLDER must be a managed child of /usr/local or /opt: ${resolved}" ;;
    esac
    [[ "$resolved" != "$DATA_DIR" && "$resolved" != "$DATA_DIR/"* && "$DATA_DIR" != "$resolved/"* ]] \
        || fail "Program and data directories must not overlap"
    [[ ! -L "$INSTALL_DIR" ]] || fail "XUI_MAIN_FOLDER must not be a symbolic link"
    INSTALL_DIR="$resolved"
}

install_runtime_deps() {
    local command_name
    is_zh && log "正在安装运行依赖和 OpenVPN..." || log "Installing runtime dependencies and OpenVPN..."
    if command -v apt-get >/dev/null 2>&1; then
        is_zh && warn "如果系统自动更新正在运行，将等待 apt/dpkg 锁释放。" || warn "Waiting for apt/dpkg lock if unattended upgrades are running."
        apt-get -o DPkg::Lock::Timeout=1800 update
        apt-get -o DPkg::Lock::Timeout=1800 install -y ca-certificates curl tar gzip coreutils openvpn iproute2
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl tar gzip coreutils openvpn iproute
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl tar gzip coreutils openvpn iproute
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates curl tar gzip coreutils openvpn iproute2
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm ca-certificates curl tar gzip coreutils openvpn iproute2
    elif command -v zypper >/dev/null 2>&1; then
        zypper refresh
        zypper -q install -y ca-certificates curl tar gzip coreutils openvpn iproute2
    else
        fail "Unsupported package manager / 不支持的包管理器"
    fi
    for command_name in curl tar gzip sha256sum od realpath ss; do
        command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command after dependency installation: ${command_name}"
    done
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        *) fail "Unsupported architecture: $(uname -m). GitHub Releases currently provide linux-amd64 only." ;;
    esac
}

resolve_release_tag() {
    if [[ "$RELEASE_TAG" == "latest" ]]; then
        RELEASE_TAG="$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --retry 3 --connect-timeout 15 --max-time 60 "${API_REPO}/releases/latest" \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | sed -n '1p')"
    fi
    [[ "$RELEASE_TAG" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] || fail "No published version release was found in ${API_REPO}"
}

resolve_release_commit() {
    local output_file="$tmp_dir/release-commit.json"
    local commit

    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 15 --max-time 60 \
        --output "$output_file" "${API_REPO}/commits/${RELEASE_TAG}" \
        || return 1
    commit="$(sed -n 's/^[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f]\{40\}\)".*/\1/p' "$output_file" | sed -n '1p')"
    [[ "$commit" =~ ^[0-9A-Fa-f]{40}$ ]] || return 1
    printf '%s' "${commit,,}"
}

clean_old_runtime() {
    validate_install_dir
    is_zh && log "清理旧程序和安装缓存" || log "Cleaning old runtime and install cache"
    is_zh && warn "保留数据目录 ${DATA_DIR}" || warn "Keeping data directory ${DATA_DIR}"
    systemctl stop x-ui >/dev/null 2>&1 || true
    # The verified bundle for this run lives in $tmp_dir (also named
    # /tmp/x-mili-install.*), so never sweep that pattern here.
    rm -rf /tmp/x-mili-go.tar.gz /tmp/x-mili-src.*
    if [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "/" ]]; then
        rm -rf "$INSTALL_DIR"
    fi
    rm -f /usr/bin/ml /usr/bin/x-ui
    mkdir -p "$INSTALL_DIR" "$LANG_DIR"
    install -d -m 0700 "$DATA_DIR"
    chmod 0700 "$DATA_DIR"
    find "$DATA_DIR" -maxdepth 1 -type f \( -name 'x-ui.db' -o -name 'x-ui.db-journal' -o -name 'x-ui.db-wal' -o -name 'x-ui.db-shm' \) \
        -exec chmod 0600 {} + 2>/dev/null || true
}

gen_random_string() {
    local length="$1"
    local value=""
    while (( ${#value} < length )); do
        value+="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    done
    printf '%s' "${value:0:length}"
}

save_initial_credentials() {
    local temporary
    temporary="$(mktemp "${CREDENTIAL_RECOVERY_FILE}.XXXXXX")"
    {
        printf 'username: %s\n' "$panel_username"
        printf 'password: %s\n' "$panel_password"
        printf 'port: %s\n' "$panel_port"
        printf 'webBasePath: %s\n' "$panel_web_path"
    } > "$temporary"
    chown root:root "$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$CREDENTIAL_RECOVERY_FILE"
}

show_recovery_credentials() {
    [[ -f "$CREDENTIAL_RECOVERY_FILE" && ! -L "$CREDENTIAL_RECOVERY_FILE" ]] || return 1
    is_zh && echo -e "初始登录恢复信息（仅本次安装保留）:" \
        || echo -e "Initial login recovery details (kept only during installation):"
    sed 's/^/  /' "$CREDENTIAL_RECOVERY_FILE"
}

normalize_boolean() {
    case "${1,,}" in
        1|true|yes|on) printf 'true' ;;
        0|false|no|off) printf 'false' ;;
        *) return 1 ;;
    esac
}

select_http_exposure_action() {
    local fresh_install="$1"
    local requested="$2"
    local saved_action="$3"

    if [[ -n "$requested" ]]; then
        normalize_boolean "$requested"
    elif [[ "$saved_action" == "true" || "$saved_action" == "false" || "$saved_action" == "preserve" ]]; then
        printf '%s' "$saved_action"
    elif [[ "$fresh_install" == "1" ]]; then
        printf 'true'
    else
        printf 'preserve'
    fi
}

listen_ip_for_http_exposure() {
    case "$1" in
        true) printf '0.0.0.0' ;;
        false) printf '127.0.0.1' ;;
        *) return 1 ;;
    esac
}

determine_http_exposure_action() {
    local has_binary=0 has_unit=0 has_existing_state=0 fresh_install=0 saved_action=""
    [[ -x "$INSTALL_DIR/x-ui" ]] && has_binary=1
    [[ -e /etc/systemd/system/x-ui.service || -L /etc/systemd/system/x-ui.service ]] && has_unit=1
    [[ -e "$DATA_DIR/x-ui.db" || -e "$INSTALL_DIR" || "$has_unit" == "1" \
        || -e "$CREDENTIAL_RECOVERY_FILE" || -e "$INSTALL_IN_PROGRESS_FILE" ]] && has_existing_state=1
    if [[ -f "$INSTALL_IN_PROGRESS_FILE" && ! -L "$INSTALL_IN_PROGRESS_FILE" ]]; then
        saved_action="$(awk -F= '$1 == "http_exposure" { print $2; exit }' "$INSTALL_IN_PROGRESS_FILE")"
    fi
    [[ "$has_existing_state" == "1" ]] || fresh_install=1

    if [[ "$has_binary" == "1" && "$has_unit" == "1" \
        && ! -f "$CREDENTIAL_RECOVERY_FILE" && ! -f "$INSTALL_IN_PROGRESS_FILE" ]]; then
        FIRST_INSTALL=0
    else
        FIRST_INSTALL=1
        [[ "$has_existing_state" == "0" ]] || PARTIAL_INSTALL=1
    fi

    HTTP_EXPOSURE_ACTION="$(select_http_exposure_action "$fresh_install" "$REQUESTED_HTTP_EXPOSURE" "$saved_action")" \
        || fail "X_MILI_ALLOW_INSECURE_HTTP must be true or false"
}

mark_install_in_progress() {
    local temporary
    install -d -m 0700 "$DATA_DIR"
    chmod 0700 "$DATA_DIR"
    temporary="$(mktemp "${INSTALL_IN_PROGRESS_FILE}.XXXXXX")"
    printf 'pid=%s\nstarted=%s\nhttp_exposure=%s\n' \
        "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HTTP_EXPOSURE_ACTION" > "$temporary"
    chown root:root "$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$INSTALL_IN_PROGRESS_FILE"
}

configure_http_exposure() {
    local temporary_env listen_ip

    install -d -m 0755 "$(dirname "$SERVICE_ENV_FILE")"
    [[ ! -L "$SERVICE_ENV_FILE" ]] || fail "Refusing to replace symbolic link: ${SERVICE_ENV_FILE}"
    if [[ -e "$SERVICE_ENV_FILE" && ! -f "$SERVICE_ENV_FILE" ]]; then
        fail "Service environment path is not a regular file: ${SERVICE_ENV_FILE}"
    fi
    temporary_env="$(mktemp "${SERVICE_ENV_FILE}.XXXXXX")"

    if [[ -f "$SERVICE_ENV_FILE" ]]; then
        if [[ "$HTTP_EXPOSURE_ACTION" == "preserve" ]]; then
            cp -- "$SERVICE_ENV_FILE" "$temporary_env"
        else
            sed '/^[[:space:]]*XUI_ALLOW_INSECURE_HTTP[[:space:]]*=/d' "$SERVICE_ENV_FILE" > "$temporary_env"
        fi
    fi

    case "$HTTP_EXPOSURE_ACTION" in
        true)
            printf 'XUI_ALLOW_INSECURE_HTTP=true\n' >> "$temporary_env"
            listen_ip="$(listen_ip_for_http_exposure true)"
            "${INSTALL_DIR}/x-ui" setting -listenIP "$listen_ip" >/dev/null
            ;;
        false)
            printf 'XUI_ALLOW_INSECURE_HTTP=false\n' >> "$temporary_env"
            listen_ip="$(listen_ip_for_http_exposure false)"
            "${INSTALL_DIR}/x-ui" setting -listenIP "$listen_ip" >/dev/null
            ;;
        preserve)
            ;;
        *)
            rm -f -- "$temporary_env"
            fail "Internal error: invalid HTTP exposure action"
            ;;
    esac

    chown root:root "$temporary_env"
    chmod 0600 "$temporary_env"
    mv -f -- "$temporary_env" "$SERVICE_ENV_FILE"
}

open_panel_firewall_port() {
    local port="$1" auto_open opened=0
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) \
        || fail "Invalid panel port for firewall rule: ${port}"
    auto_open="$(normalize_boolean "$AUTO_OPEN_FIREWALL")" \
        || fail "X_MILI_AUTO_OPEN_FIREWALL must be true or false"
    [[ "$auto_open" == "true" ]] || return 0

    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ufw allow "${port}/tcp" >/dev/null; then
            opened=1
            is_zh && log "已在 UFW 中放行 ${port}/TCP" || log "Allowed ${port}/TCP in UFW"
        else
            is_zh && warn "UFW 未能放行 ${port}/TCP，请手动检查。" || warn "UFW could not allow ${port}/TCP; check it manually."
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --quiet --permanent --query-port="${port}/tcp"; then
            opened=1
        elif firewall-cmd --quiet --permanent --add-port="${port}/tcp" && firewall-cmd --quiet --reload; then
            opened=1
            is_zh && log "已在 firewalld 中放行 ${port}/TCP" || log "Allowed ${port}/TCP in firewalld"
        else
            is_zh && warn "firewalld 未能放行 ${port}/TCP，请手动检查。" || warn "firewalld could not allow ${port}/TCP; check it manually."
        fi
    fi

    if [[ "$opened" == "0" ]]; then
        is_zh && warn "未检测到已启用的 UFW/firewalld；没有修改主机防火墙。云安全组仍需在服务商控制台放行 ${port}/TCP。" \
            || warn "No active UFW/firewalld was detected; the host firewall was not changed. Allow ${port}/TCP in the cloud firewall/security group."
    fi
}

insecure_http_opted_in() {
    local line key value effective="false"

    [[ -f "$SERVICE_ENV_FILE" && ! -L "$SERVICE_ENV_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        key="${key//[[:space:]]/}"
        [[ "$key" == "XUI_ALLOW_INSECURE_HTTP" ]] || continue
        value="${line#*=}"
        value="${value//[[:space:]\"\']/}"
        effective="${value,,}"
    done < "$SERVICE_ENV_FILE"
    [[ "$effective" == "true" || "$effective" == "1" || "$effective" == "yes" || "$effective" == "on" ]]
}

is_valid_ipv4() {
    local candidate="$1" octet
    local -a octets
    [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a octets <<< "$candidate"
    [[ "${#octets[@]}" -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ ${#octet} -le 3 ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_valid_ipv6() {
    local candidate="$1" remainder group compressed=0 group_count=0
    local -a groups

    [[ "$candidate" == *:* && "$candidate" != ":" && "$candidate" =~ ^[0-9A-Fa-f:]+$ && ${#candidate} -le 39 && "$candidate" != *:::* ]] || return 1
    if [[ "$candidate" == *::* ]]; then
        compressed=1
        remainder="${candidate#*::}"
        [[ "$remainder" != *::* ]] || return 1
    fi
    IFS=':' read -r -a groups <<< "$candidate"
    for group in "${groups[@]}"; do
        [[ -z "$group" ]] && continue
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        ((group_count += 1))
    done
    if [[ "$compressed" == "1" ]]; then
        (( group_count < 8 ))
    else
        (( group_count == 8 ))
    fi
}

fetch_public_address() {
    local family="$1" validator="$2" endpoint candidate
    shift 2
    for endpoint in "$@"; do
        candidate="$(curl "-$family" --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 3 --max-time 6 "$endpoint" 2>/dev/null || true)"
        candidate="${candidate//$'\r'/}"
        candidate="${candidate//$'\n'/}"
        candidate="${candidate//[[:space:]]/}"
        if "$validator" "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

get_public_ipv4() {
    fetch_public_address 4 is_valid_ipv4 \
        https://api.ipify.org https://ipv4.icanhazip.com https://v4.ident.me
}

get_public_ipv6() {
    fetch_public_address 6 is_valid_ipv6 \
        https://api6.ipify.org https://ipv6.icanhazip.com https://6.ident.me
}

format_url_host() {
    local ipv4="$1" ipv6="$2"
    if [[ -n "$ipv4" ]]; then
        printf '%s' "$ipv4"
    elif [[ -n "$ipv6" ]]; then
        printf '[%s]' "$ipv6"
    else
        printf 'SERVER_PUBLIC_IP'
    fi
}

normalize_web_path() {
    local path="$1"
    [[ -n "$path" ]] || path="/"
    [[ "$path" == /* ]] || path="/${path}"
    [[ "$path" == */ ]] || path="${path}/"
    echo "$path"
}

extract_setting() {
    local info="$1"
    local key="$2"
    echo "$info" | awk -v k="${key}:" '$1 == k {print $2; exit}'
}

read_panel_port() {
    local current_port="${1:-2053}"
    while true; do
        if is_zh; then
            read -rp "请设置登录面板的端口 [默认 ${current_port}]: " panel_port
        else
            read -rp "Panel port [default ${current_port}]: " panel_port
        fi
        panel_port="${panel_port:-$current_port}"
        if [[ "$panel_port" =~ ^[0-9]{1,5}$ ]] && ((10#$panel_port >= 1 && 10#$panel_port <= 65535)); then
            return
        fi
        is_zh && warn "端口必须是 1-65535" || warn "Port must be 1-65535"
    done
}

read_initial_panel_settings() {
    local info current_port
    info=$("${INSTALL_DIR}/x-ui" setting -show true 2>/dev/null || true)
    current_port=$(extract_setting "$info" "port")
    current_port="${current_port:-2053}"

    panel_username="${X_MILI_USERNAME:-}"
    panel_password="${X_MILI_PASSWORD:-}"
    panel_web_path="${X_MILI_WEB_BASE_PATH:-}"
    panel_port="${X_MILI_PANEL_PORT:-}"

    if [[ -t 0 ]]; then
        echo ""
        if is_zh; then
            echo -e "${green}首次安装向导：请设置面板登录信息。直接回车将随机生成，更安全。${plain}"
            read -rp "请设置登录面板的账号 [随机]: " panel_username
            read -rsp "请设置登录面板的密码 [随机]: " panel_password
            echo
            if [[ -z "${X_MILI_PANEL_PORT:-}" ]]; then
                read_panel_port "$current_port"
            fi
            read -rp "请设置登录面板的安全后缀 [随机，例如 /$(gen_random_string 8)/]: " panel_web_path
        else
            echo -e "${green}First-time setup: configure panel login. Press Enter to generate secure random values.${plain}"
            read -rp "Panel username [random]: " panel_username
            read -rsp "Panel password [random]: " panel_password
            echo
            if [[ -z "${X_MILI_PANEL_PORT:-}" ]]; then
                read_panel_port "$current_port"
            fi
            read -rp "Panel secure URL suffix [random, e.g. /$(gen_random_string 8)/]: " panel_web_path
        fi
    fi

    panel_username="${panel_username:-$(gen_random_string 10)}"
    panel_password="${panel_password:-$(gen_random_string 18)}"
    panel_web_path="${panel_web_path:-$(gen_random_string 18)}"
    panel_web_path=$(normalize_web_path "$panel_web_path")
    panel_port="${panel_port:-$current_port}"

    [[ "$panel_username" =~ ^[A-Za-z0-9._-]{3,64}$ ]] \
        || fail "Initial username must contain 3-64 letters, numbers, dots, underscores or hyphens"
    [[ "$panel_password" =~ ^[^[:space:]]{12,128}$ ]] \
        || fail "Initial password must be 12-128 non-space characters"
    [[ "$panel_port" =~ ^[0-9]{1,5}$ ]] && ((10#$panel_port >= 1 && 10#$panel_port <= 65535)) \
        || fail "Initial panel port must be 1-65535"
    [[ "$panel_web_path" == /* && "$panel_web_path" != *[[:space:]]* ]] \
        || fail "Initial web path must start with / and contain no whitespace"
}

panel_needs_initialization() {
    local info
    info=$("${INSTALL_DIR}/x-ui" setting -show true 2>/dev/null) || return 2
    if echo "$info" | grep -Eq "bootstrapPending: true|hasDefaultCredential: true"; then
        return 0
    fi
    if echo "$info" | grep -Eq "bootstrapPending: false|hasDefaultCredential: false"; then
        return 1
    fi
    return 2
}

init_panel_settings() {
    local bootstrap_status password_file
    panel_credentials_initialized=0
    if panel_needs_initialization; then
        :
    else
        bootstrap_status=$?
        if [[ "$bootstrap_status" == "1" ]]; then
            is_zh && log "检测到已有非默认面板账号，保留现有登录信息" || log "Existing non-default panel account detected, keeping current login"
            return 0
        fi
        fail "无法确定面板初始化状态，拒绝重置现有凭据 / Could not determine bootstrap state; refusing to change credentials"
    fi

    read_initial_panel_settings
    save_initial_credentials
    password_file=$(mktemp "${tmp_dir}/panel-password.XXXXXX")
    chmod 0600 "$password_file"
    printf '%s' "$panel_password" > "$password_file"
    if ! "${INSTALL_DIR}/x-ui" setting \
        -username "$panel_username" \
        -password-file "$password_file" \
        -port "$panel_port" \
        -resetTwoFactor true >/dev/null 2>&1; then
        rm -f -- "$password_file"
        return 1
    fi
    rm -f -- "$password_file"
    "${INSTALL_DIR}/x-ui" setting -webBasePath "$panel_web_path" >/dev/null 2>&1
    panel_credentials_initialized=1
    is_zh && log "已设置初始面板账号、密码、端口和访问路径" || log "Initial panel username, password, port and web path configured"
}

print_install_guide() {
    local info port web_path cert protocol listen_ip public_http=0 direct_public=0
    local public_ipv4 public_ipv6 url_host check_host panel_url
    info=$("${INSTALL_DIR}/x-ui" setting -show true 2>/dev/null || true)
    port=$(extract_setting "$info" "port")
    web_path=$(extract_setting "$info" "webBasePath")
    port="${port:-2053}"
    web_path=$(normalize_web_path "$web_path")
    public_ipv4="$(get_public_ipv4 || true)"
    public_ipv6="$(get_public_ipv6 || true)"
    cert=$("${INSTALL_DIR}/x-ui" setting -getCert true 2>/dev/null | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]' || true)
    listen_ip=$("${INSTALL_DIR}/x-ui" setting -getListen true 2>/dev/null | awk -F': ' '/^listenIP:/ {print $2; exit}' | tr -d '[:space:]' || true)
    [[ -n "$cert" ]] && protocol="https" || protocol="http"
    if insecure_http_opted_in; then
        public_http=1
    fi
    if [[ "$listen_ip" == "0.0.0.0" || "$listen_ip" == "::" || "$listen_ip" == "[::]" ]]; then
        if [[ -n "$cert" || "$public_http" == "1" ]]; then
            direct_public=1
        fi
    fi
    if [[ "$direct_public" == "1" ]]; then
        if [[ "$listen_ip" == "0.0.0.0" ]]; then
            url_host="${public_ipv4:-SERVER_PUBLIC_IPV4}"
        else
            url_host="$(format_url_host "$public_ipv4" "$public_ipv6")"
        fi
    else
        url_host="127.0.0.1"
    fi
    panel_url="${protocol}://${url_host}:${port}${web_path}"
    if [[ "$listen_ip" == "0.0.0.0" ]]; then
        check_host="${public_ipv4:-SERVER_PUBLIC_IPV4}"
    else
        check_host="${public_ipv4:-${public_ipv6:-SERVER_PUBLIC_IP}}"
    fi

    echo ""
    if is_zh; then
        echo -e "${green}================ X-MILI 安装完成 ================${plain}"
        echo -e "管理命令: ${green}ml${plain}"
        echo -e "面板地址: ${green}${panel_url}${plain}"
        [[ -n "$public_ipv4" ]] && echo -e "公网 IPv4: ${green}${public_ipv4}${plain}"
        [[ -n "$public_ipv6" ]] && echo -e "公网 IPv6: ${green}${public_ipv6}${plain}"
        [[ -n "$public_ipv6" && "$listen_ip" == "0.0.0.0" ]] && echo -e "${yellow}检测到 IPv6，但当前 0.0.0.0 监听只用于 IPv4 公网入口。${plain}"
        if [[ "$panel_credentials_initialized" == "1" ]]; then
            echo -e "登录账号: ${green}${panel_username}${plain}"
            echo -e "登录密码: ${green}${panel_password}${plain}"
            echo -e "安全后缀: ${green}${web_path}${plain}"
        else
            if ! show_recovery_credentials; then
                echo -e "登录信息: ${yellow}已保留现有账号和密码${plain}"
            fi
        fi
        echo -e "数据目录: ${yellow}${DATA_DIR}${plain}"
        echo -e "监听地址: ${yellow}${listen_ip:-未知}:${port}${plain}"
        if [[ "$direct_public" != "1" ]]; then
            echo -e "${yellow}面板仅监听本机地址。请配置 TLS 后公网访问，或通过 SSH 隧道访问：ssh -L ${port}:127.0.0.1:${port} root@服务器IP${plain}"
        elif [[ -z "$cert" ]]; then
            echo -e "${red}安全警告：当前已允许公网明文 HTTP，账号、密码和订阅内容可能被窃听。请登录后立即绑定域名并配置 TLS。${plain}"
        fi
        echo -e "${yellow}端口用途：${port}/TCP=当前面板（HTTP 与绑定证书后的 HTTPS 都使用此端口）；80/TCP=域名证书 HTTP-01 验证；443/TCP 仅在另配反向代理或把面板改到 443 时使用。${plain}"
        echo -e "${yellow}注意：http://域名 默认访问 80 端口，不等于当前面板地址；请保留 :${port}${web_path}。${plain}"
        echo -e "服务器监听自检: ss -ltnp | grep -E ':(${port}|80)[[:space:]]'"
        echo -e "外部自检（必须在另一台机器/手机网络运行）: curl -v --connect-timeout 5 '${panel_url}' -o /dev/null"
        echo -e "外部端口自检: nc -vz ${check_host} 80 ; nc -vz ${check_host} ${port}"
        echo -e "${yellow}若服务器本机可访问但外部失败，请检查云安全组、主机防火墙、NAT 端口映射，以及域名 A/AAAA 记录。仅运行 python http.server 不能证明公网已放行。${plain}"
        echo -e "${green}=================================================${plain}"
    else
        echo -e "${green}================ X-MILI Installed ================${plain}"
        echo -e "Command: ${green}ml${plain}"
        echo -e "URL: ${green}${panel_url}${plain}"
        [[ -n "$public_ipv4" ]] && echo -e "Public IPv4: ${green}${public_ipv4}${plain}"
        [[ -n "$public_ipv6" ]] && echo -e "Public IPv6: ${green}${public_ipv6}${plain}"
        [[ -n "$public_ipv6" && "$listen_ip" == "0.0.0.0" ]] && echo -e "${yellow}IPv6 was detected, but the current 0.0.0.0 listener is the IPv4 public entry point.${plain}"
        if [[ "$panel_credentials_initialized" == "1" ]]; then
            echo -e "Username: ${green}${panel_username}${plain}"
            echo -e "Password: ${green}${panel_password}${plain}"
            echo -e "Secure suffix: ${green}${web_path}${plain}"
        else
            if ! show_recovery_credentials; then
                echo -e "Login: ${yellow}existing username and password preserved${plain}"
            fi
        fi
        echo -e "Data directory: ${yellow}${DATA_DIR}${plain}"
        echo -e "Listen address: ${yellow}${listen_ip:-unknown}:${port}${plain}"
        if [[ "$direct_public" != "1" ]]; then
            echo -e "${yellow}The panel is bound to localhost only. Configure TLS for public access, or use: ssh -L ${port}:127.0.0.1:${port} root@server-ip${plain}"
        elif [[ -z "$cert" ]]; then
            echo -e "${red}SECURITY WARNING: public plaintext HTTP is enabled. Credentials and subscriptions can be intercepted. Bind a domain and configure TLS immediately.${plain}"
        fi
        echo -e "${yellow}Ports: ${port}/TCP=current panel for both HTTP and domain-bound HTTPS; 80/TCP=ACME HTTP-01; 443/TCP is needed only for a separate reverse proxy or if the panel is moved to 443.${plain}"
        echo -e "${yellow}Note: http://domain uses port 80 and is not the current panel URL; keep :${port}${web_path}.${plain}"
        echo -e "Server listener check: ss -ltnp | grep -E ':(${port}|80)[[:space:]]'"
        echo -e "External check (run from another host/mobile network): curl -v --connect-timeout 5 '${panel_url}' -o /dev/null"
        echo -e "External port check: nc -vz ${check_host} 80 ; nc -vz ${check_host} ${port}"
        echo -e "${yellow}If local access works but external access fails, check the cloud firewall/security group, host firewall, NAT forwarding and DNS A/AAAA records. A local python http.server test does not prove Internet reachability.${plain}"
        echo -e "${green}==================================================${plain}"
    fi
    echo ""
}

install_service() {
    cat > /etc/systemd/system/x-ui.service <<EOF
[Unit]
Description=X-MILI Service
After=network.target
Wants=network.target

[Service]
EnvironmentFile=/etc/default/x-ui
Environment="XRAY_VMESS_AEAD_FORCED=false"
UMask=0077
Type=simple
WorkingDirectory=${INSTALL_DIR}/
ExecStart=${INSTALL_DIR}/x-ui
ExecReload=kill -USR1 \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now x-ui
}

verify_native_service() {
    local checks_left=5 settings port listener_checks=10
    while ((checks_left-- > 0)); do
        systemctl is-active --quiet x-ui || return 1
        sleep 1
    done
    settings=$("${INSTALL_DIR}/x-ui" setting -show true 2>/dev/null) || return 1
    port=$(extract_setting "$settings" port)
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    while ((listener_checks-- > 0)); do
        if ss -ltnH 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit !found}'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

prepare_prebuilt_bundle() {
    local arch asset url checksums_url package_dir expected actual
    local archive_details
    local bundle_commit remote_commit
    arch=$(detect_arch)
    asset="x-mili-linux-${arch}.tar.gz"
    url="${REPO}/releases/download/${RELEASE_TAG}/${asset}"
    checksums_url="${REPO}/releases/download/${RELEASE_TAG}/SHA256SUMS"
    package_dir="$tmp_dir/package"

    is_zh && log "尝试下载预编译一体包: ${url}" || log "Trying prebuilt bundle: ${url}"
    mkdir -p "$package_dir"
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 "$url" -o "$tmp_dir/$asset"; then
        return 1
    fi
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 "$checksums_url" -o "$tmp_dir/SHA256SUMS"; then
        is_zh && warn "无法下载发布校验文件 SHA256SUMS" || warn "Could not download release checksum file SHA256SUMS"
        return 1
    fi
    expected="$(awk -v asset="$asset" '
        $2 == asset { checksum=$1; count++ }
        END { if (count == 1) print checksum; else exit 1 }
    ' "$tmp_dir/SHA256SUMS")" \
        || fail "SHA256SUMS must contain exactly one entry for ${asset}"
    [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || fail "SHA256SUMS does not contain a valid checksum for ${asset}"
    actual="$(sha256sum "$tmp_dir/$asset" | awk '{ print $1 }')"
    [[ "$actual" == "$expected" ]] || fail "Checksum verification failed for ${asset}"

    tar -tzf "$tmp_dir/$asset" > "$tmp_dir/archive-paths"
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$tmp_dir/archive-paths"; then
        fail "Release archive contains an unsafe path"
    fi
    archive_details="$tmp_dir/archive-details"
    LC_ALL=C tar -tvzf "$tmp_dir/$asset" > "$archive_details" \
        || fail "Release archive metadata is invalid"
    if awk '{ type=substr($1,1,1); if (type != "-" && type != "d") bad=1 } END { exit bad ? 0 : 1 }' "$archive_details"; then
        fail "Release archive contains a link, device, or another unsupported entry type"
    fi
    if ! tar --no-same-owner --no-same-permissions -xzf "$tmp_dir/$asset" -C "$package_dir"; then
        is_zh && warn "预编译包解压失败" || warn "Failed to extract prebuilt bundle"
        return 1
    fi
    if find "$package_dir" -mindepth 1 ! -type f ! -type d -print -quit | grep -q .; then
        fail "Extracted release contains an unsupported filesystem object"
    fi
    if [[ -L "$package_dir/x-ui" || -L "$package_dir/x-ui.sh" || -L "$package_dir/bin/xray-linux-${arch}" || -L "$package_dir/.x-mili-commit" ]]; then
        fail "Release bundle contains an unexpected symbolic link"
    fi
    if [[ ! -x "$package_dir/x-ui" || ! -f "$package_dir/x-ui.sh" || ! -x "$package_dir/bin/xray-linux-${arch}" || ! -f "$package_dir/.x-mili-commit" ]]; then
        is_zh && warn "预编译包不完整：缺少 x-ui、x-ui.sh 或 bin/" || warn "Incomplete prebuilt bundle: missing x-ui, x-ui.sh or bin/"
        return 1
    fi
    bundle_commit="$(tr -d '[:space:]' < "$package_dir/.x-mili-commit")"
    [[ "$bundle_commit" =~ ^[0-9A-Fa-f]{40}$ ]] \
        || fail "Release bundle has an invalid commit marker"
    remote_commit="$(resolve_release_commit)" \
        || fail "Could not resolve the GitHub commit for release tag ${RELEASE_TAG}"
    [[ "${bundle_commit,,}" == "$remote_commit" ]] \
        || fail "Release bundle commit does not match GitHub tag ${RELEASE_TAG}"

    prepared_package_dir="$package_dir"
    return 0
}

install_program_files() {
    [[ -n "$prepared_package_dir" && -x "$prepared_package_dir/x-ui" && -f "$prepared_package_dir/x-ui.sh" ]] \
        || fail "Verified release bundle is unavailable"
    cp -a "$prepared_package_dir"/. "$INSTALL_DIR/"
    install -m 755 "$prepared_package_dir/x-ui.sh" /usr/bin/ml
    chmod +x "$INSTALL_DIR/x-ui" "$INSTALL_DIR"/bin/xray-linux-* 2>/dev/null || true
    is_zh && log "已使用经过校验的预编译一体包，服务器不进行编译。" || log "Verified prebuilt bundle installed. No server-side build."
    echo "$X_MILI_LANG" > "$LANG_FILE"
}

update_existing_install() {
    local updater settings firewall_port
    updater="$(mktemp -t x-mili-update-launcher.XXXXXX)"
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "https://raw.githubusercontent.com/${REPO_SLUG}/${RELEASE_TAG}/update.sh" -o "$updater"; then
        rm -f -- "$updater"
        fail "无法下载事务更新器 / Could not download the transactional updater"
    fi
    chmod 0700 "$updater"
    if ! X_MILI_REPO="$REPO" X_MILI_API_REPO="$API_REPO" X_MILI_RELEASE_TAG="$RELEASE_TAG" bash "$updater"; then
        rm -f -- "$updater"
        fail "更新失败，旧版本已由事务更新器恢复 / Update failed; the transactional updater restored the previous version"
    fi
    rm -f -- "$updater"

    if [[ "$HTTP_EXPOSURE_ACTION" == "true" ]]; then
        settings=$("${INSTALL_DIR}/x-ui" setting -show true 2>/dev/null || true)
        firewall_port=$(extract_setting "$settings" "port")
        open_panel_firewall_port "${firewall_port:-2053}"
    fi
    panel_credentials_initialized=0
    print_install_guide
    rm -f -- "$CREDENTIAL_RECOVERY_FILE"
}

main() {
    local firewall_port settings
    [[ $EUID -eq 0 ]] || fail "请使用 root 运行 / Please run as root"
    normalize_repository
    choose_language
    is_zh && log "开始安装/更新 ${APP_NAME}" || log "Installing/updating ${APP_NAME}"

    command -v systemctl >/dev/null 2>&1 || fail "需要 systemd / systemd is required"
    determine_http_exposure_action
    if [[ "$FIRST_INSTALL" == "0" ]]; then
        [[ -x "$INSTALL_DIR/x-ui" ]] \
            || fail "检测到不完整的旧安装，拒绝覆盖；请先备份 ${DATA_DIR} 并检查服务 / Incomplete existing installation detected; refusing to overwrite it"
        install_runtime_deps
        validate_install_dir
        resolve_release_tag
        is_zh && log "检测到现有安装，使用事务更新器保留旧版本和数据" \
            || log "Existing installation detected; using the transactional updater"
        update_existing_install
        return 0
    fi
    if [[ "$PARTIAL_INSTALL" == "1" ]]; then
        is_zh && warn "检测到未完成或损坏的安装；将保留 ${DATA_DIR} 并重建程序与服务。" \
            || warn "An incomplete installation was detected; ${DATA_DIR} will be kept while program files and the service are rebuilt."
    fi
    mark_install_in_progress
    is_zh && step 1 6 "安装运行依赖和 OpenVPN" || step 1 6 "Installing runtime dependencies and OpenVPN"
    install_runtime_deps
    validate_install_dir
    resolve_release_tag
    tmp_dir=$(mktemp -d -t x-mili-install.XXXXXX)
    trap 'rm -rf -- "$tmp_dir"' EXIT
    is_zh && step 2 6 "下载并校验 GitHub Release" || step 2 6 "Downloading and verifying the GitHub Release"
    if ! prepare_prebuilt_bundle; then
        fail "未找到或无法验证当前架构的一体包 / Release bundle is unavailable or could not be verified"
    fi
    is_zh && step 3 6 "清理旧程序文件，保留面板数据" || step 3 6 "Cleaning old runtime files, keeping panel data"
    clean_old_runtime

    is_zh && step 4 6 "安装 X-MILI 程序文件" || step 4 6 "Installing X-MILI program files"
    install_program_files

    is_zh && step 5 6 "配置面板账号、端口和安全后缀" || step 5 6 "Configuring panel login, port and secure suffix"
    init_panel_settings
    configure_http_exposure
    if [[ "$HTTP_EXPOSURE_ACTION" == "true" ]]; then
        settings=$("${INSTALL_DIR}/x-ui" setting -show true 2>/dev/null || true)
        firewall_port=$(extract_setting "$settings" "port")
    fi
    is_zh && step 6 6 "安装并启动系统服务" || step 6 6 "Installing and starting system service"
    install_service
    verify_native_service \
        || fail "面板服务未能持续运行或监听配置端口；恢复凭据和安装标记已保留 / Panel health verification failed; recovery files were kept"
    if [[ "$HTTP_EXPOSURE_ACTION" == "true" ]]; then
        open_panel_firewall_port "${firewall_port:-2053}"
    fi
    print_install_guide
    rm -f -- "$CREDENTIAL_RECOVERY_FILE"
    rm -f -- "$INSTALL_IN_PROGRESS_FILE"

    is_zh && log "安装完成。命令：ml" || log "Done. Command: ml"
    is_zh && warn "默认数据目录仍为 ${DATA_DIR}，用于兼容旧数据。" || warn "Data directory remains ${DATA_DIR} for compatibility."

    if [[ "$panel_credentials_initialized" == "1" ]]; then
        # Actively open the menu for the first installation
        /usr/bin/ml
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
