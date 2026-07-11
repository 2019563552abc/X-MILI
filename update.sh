#!/usr/bin/env bash
# Update a legacy /usr/local/x-ui installation from one immutable GitHub Release.

set -Eeuo pipefail
umask 022

APP_NAME="X-MILI"
SERVICE_NAME="x-ui"
DEFAULT_REPO="https://github.com/2019563552abc/X-MILI"
REPO="${X_MILI_REPO:-$DEFAULT_REPO}"
RELEASE_TAG="${X_MILI_RELEASE_TAG:-latest}"
REQUESTED_HTTP_EXPOSURE="${X_MILI_ALLOW_INSECURE_HTTP-}"
INSTALL_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
DATA_DIR="${XUI_DB_FOLDER:-/etc/x-ui}"
SERVICE_ENV_FILE="/etc/default/x-ui"
UNIT_FILE="/etc/systemd/system/x-ui.service"
ML_PATH="/usr/bin/ml"
ARCH="amd64"
ASSET="x-mili-linux-${ARCH}.tar.gz"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

log() { echo -e "${green}[${APP_NAME}]${plain} $*"; }
warn() { echo -e "${yellow}[${APP_NAME}]${plain} $*" >&2; }
fail() { echo -e "${red}[${APP_NAME}]${plain} $*" >&2; exit 1; }

tmp_dir=""
backup_dir=""
staged_dir=""
old_install_dir=""
ml_tmp=""
transaction_started=0
update_succeeded=0
runtime_stopped=0
service_was_active=0
old_install_moved=0
rollback_incomplete=0
had_data=0
had_service_env=0
had_unit=0
had_ml=0

restore_optional_path() {
    local destination="$1"
    local backup="$2"
    local existed="$3"

    rm -rf -- "$destination" || return 1
    if [[ "$existed" == "1" ]]; then
        cp -a -- "$backup" "$destination" || return 1
    fi
}

rollback_update() {
    local rollback_failed=0
    local stop_checks=10

    warn "Update failed; restoring the previous installation and configuration..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    while ((stop_checks-- > 0)); do
        service_is_live || break
        sleep 1
    done
    if service_is_live; then
        warn "Automatic rollback was stopped because ${SERVICE_NAME} is still active; rollback did not touch program or database files."
        return 1
    fi

    # Derive the move state from the filesystem as well as the flag. A signal
    # can arrive between the atomic mv and the following shell assignment.
    if [[ -n "$old_install_dir" && -d "$old_install_dir" && ! -L "$old_install_dir" ]]; then
        if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
            rm -rf -- "$INSTALL_DIR" || rollback_failed=1
        fi
        if [[ ! -e "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] \
            && mv -- "$old_install_dir" "$INSTALL_DIR"; then
            old_install_moved=0
        else
            rollback_failed=1
        fi
    elif [[ "$old_install_moved" == "1" && ! -e "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]]; then
        warn "Rollback copy of the previous installation is missing: ${old_install_dir}"
        rollback_failed=1
    else
        # The interrupt happened before the old installation was moved.
        old_install_moved=0
    fi

    restore_optional_path "$DATA_DIR" "$backup_dir/data" "$had_data" || rollback_failed=1
    restore_optional_path "$SERVICE_ENV_FILE" "$backup_dir/service-env" "$had_service_env" || rollback_failed=1
    restore_optional_path "$UNIT_FILE" "$backup_dir/unit" "$had_unit" || rollback_failed=1
    restore_optional_path "$ML_PATH" "$backup_dir/ml" "$had_ml" || rollback_failed=1
    systemctl daemon-reload >/dev/null 2>&1 || rollback_failed=1

    if [[ "$rollback_failed" == "0" && "$service_was_active" == "1" ]]; then
        if ! systemctl start "$SERVICE_NAME" >/dev/null 2>&1; then
            warn "The previous files were restored, but ${SERVICE_NAME} could not be restarted."
            rollback_failed=1
        fi
    fi
    runtime_stopped=0

    if [[ "$rollback_failed" == "0" ]]; then
        warn "Rollback completed. The previous release and panel data are active again."
    else
        warn "Rollback was incomplete and the service was left stopped. Inspect ${INSTALL_DIR}, ${DATA_DIR}, and journalctl -u ${SERVICE_NAME}."
    fi
    return "$rollback_failed"
}

cleanup() {
    local status=$?
    trap - EXIT
    trap '' INT TERM HUP
    set +e

    if [[ "$transaction_started" == "1" && "$update_succeeded" != "1" ]]; then
        if ! rollback_update; then
            rollback_incomplete=1
            status=1
        fi
    elif [[ "$runtime_stopped" == "1" && "$service_was_active" == "1" ]]; then
        systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || {
            warn "The update stopped before replacement, and ${SERVICE_NAME} could not be restarted."
            status=1
        }
    fi

    [[ -n "$ml_tmp" ]] && rm -f -- "$ml_tmp"
    [[ -n "$staged_dir" ]] && rm -rf -- "$staged_dir"
    if [[ "$update_succeeded" == "1" && -n "$old_install_dir" && -d "$old_install_dir" ]]; then
        rm -rf -- "$old_install_dir"
    fi
    if [[ "$rollback_incomplete" == "1" ]]; then
        warn "Rollback recovery files were preserved at: ${tmp_dir}"
        [[ -n "$old_install_dir" && -d "$old_install_dir" ]] \
            && warn "Previous program files were preserved at: ${old_install_dir}"
        warn "Do not delete that directory until ${INSTALL_DIR} and ${DATA_DIR} are verified."
    elif [[ -n "$tmp_dir" ]]; then
        rm -rf -- "$tmp_dir"
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

require_commands() {
    local command_name
    for command_name in awk basename chmod cmp cp curl dirname find grep head install mkdir mktemp mv realpath rm rmdir sed sha256sum sleep ss systemctl tar tr uname; do
        command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: ${command_name}"
    done
}

service_is_live() {
    local state
    if ! state="$(systemctl show -p ActiveState --value "$SERVICE_NAME" 2>/dev/null)"; then
        [[ -e "$UNIT_FILE" || -L "$UNIT_FILE" ]]
        return $?
    fi
    case "$state" in
        active|activating|reloading|deactivating) return 0 ;;
        inactive|failed) return 1 ;;
        *)
            [[ -e "$UNIT_FILE" || -L "$UNIT_FILE" ]]
            ;;
    esac
}

normalize_repo_slug() {
    local value="$1"
    value="${value%.git}"
    value="${value#https://github.com/}"
    [[ "$value" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s' "$value"
}

normalize_boolean() {
    case "${1,,}" in
        1|true|yes|on) printf 'true' ;;
        0|false|no|off) printf 'false' ;;
        *) return 1 ;;
    esac
}

write_http_exposure_environment() {
    local value="$1"
    local parent temporary

    parent="$(dirname "$SERVICE_ENV_FILE")"
    install -d -m 0755 "$parent" || return 1
    temporary="$(mktemp "${SERVICE_ENV_FILE}.XXXXXX")" || return 1
    if [[ -f "$SERVICE_ENV_FILE" ]]; then
        sed '/^[[:space:]]*XUI_ALLOW_INSECURE_HTTP[[:space:]]*=/d' "$SERVICE_ENV_FILE" > "$temporary" \
            || { rm -f -- "$temporary"; return 1; }
    fi
    printf 'XUI_ALLOW_INSECURE_HTTP=%s\n' "$value" >> "$temporary" \
        || { rm -f -- "$temporary"; return 1; }
    chmod 0600 "$temporary" \
        || { rm -f -- "$temporary"; return 1; }
    mv -Tf -- "$temporary" "$SERVICE_ENV_FILE" \
        || { rm -f -- "$temporary"; return 1; }
}

normalize_absolute_path() {
    local label="$1"
    local value="$2"
    local resolved

    [[ "$value" == /* ]] || fail "${label} must be an absolute path: ${value}"
    resolved="$(realpath -m -- "$value")" || fail "Could not resolve ${label}: ${value}"
    case "$resolved" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/bin|/usr/local|/var|/var/lib)
            fail "Refusing to use protected ${label}: ${resolved}"
            ;;
    esac
    printf '%s' "$resolved"
}

secure_download() {
    local url="$1"
    local output="$2"
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --connect-timeout 15 \
        --output "$output" "$url"
}

resolve_release_tag() {
    local release_json="$tmp_dir/latest-release.json"

    if [[ "$RELEASE_TAG" == "latest" ]]; then
        log "Resolving the latest published GitHub Release..."
        secure_download "${API_REPO}/releases/latest" "$release_json" \
            || fail "Could not query the latest published release from ${API_REPO}"
        RELEASE_TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$release_json" | sed -n '1p')"
    fi

    [[ "$RELEASE_TAG" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] \
        || fail "Release tag must be version-like (for example v1.0.4): ${RELEASE_TAG}"
}

resolve_release_commit() {
    local commit_json="$tmp_dir/release-commit.json"
    local commit

    secure_download "${API_REPO}/commits/${RELEASE_TAG}" "$commit_json" \
        || fail "Could not resolve commit for release tag ${RELEASE_TAG}"
    commit="$(sed -n 's/^[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f]\{40\}\)".*/\1/p' "$commit_json" | sed -n '1p')"
    [[ "$commit" =~ ^[0-9A-Fa-f]{40}$ ]] \
        || fail "GitHub did not return a valid commit for release tag ${RELEASE_TAG}"
    printf '%s' "${commit,,}"
}

validate_archive() {
    local archive="$1"
    local path_listing="$tmp_dir/archive-paths"
    local detail_listing="$tmp_dir/archive-details"

    tar -tzf "$archive" > "$path_listing" || fail "Release archive could not be listed"
    [[ -s "$path_listing" ]] || fail "Release archive is empty"
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$path_listing"; then
        fail "Release archive contains an unsafe path"
    fi

    LC_ALL=C tar -tvzf "$archive" > "$detail_listing" || fail "Release archive metadata is invalid"
    if awk '{ type=substr($1,1,1); if (type != "-" && type != "d") bad=1 } END { exit bad ? 0 : 1 }' "$detail_listing"; then
        fail "Release archive contains a link, device, or another unsupported entry type"
    fi
}

validate_release_bundle() {
    local bundle_dir="$1"
    local expected_commit="$2"
    local bundle_commit

    [[ -d "$bundle_dir/bin" && ! -L "$bundle_dir/bin" ]] \
        || fail "Release bundle is missing a regular bin directory"
    [[ -f "$bundle_dir/x-ui" && ! -L "$bundle_dir/x-ui" && -x "$bundle_dir/x-ui" ]] \
        || fail "Release bundle is missing an executable x-ui binary"
    [[ -f "$bundle_dir/x-ui.sh" && ! -L "$bundle_dir/x-ui.sh" && -x "$bundle_dir/x-ui.sh" ]] \
        || fail "Release bundle is missing executable x-ui.sh"
    [[ -f "$bundle_dir/deploy.sh" && ! -L "$bundle_dir/deploy.sh" && -x "$bundle_dir/deploy.sh" ]] \
        || fail "Release bundle is missing executable deploy.sh"
    [[ -f "$bundle_dir/bin/xray-linux-amd64" && ! -L "$bundle_dir/bin/xray-linux-amd64" && -x "$bundle_dir/bin/xray-linux-amd64" ]] \
        || fail "Release bundle is missing executable xray-linux-amd64"
    [[ -f "$bundle_dir/.x-mili-commit" && ! -L "$bundle_dir/.x-mili-commit" ]] \
        || fail "Release bundle is missing its commit marker"

    bundle_commit="$(<"$bundle_dir/.x-mili-commit")"
    [[ "$bundle_commit" =~ ^[0-9A-Fa-f]{40}$ ]] \
        || fail "Release bundle has an invalid commit marker"
    [[ "${bundle_commit,,}" == "$expected_commit" ]] \
        || fail "Release bundle commit does not match tag ${RELEASE_TAG}"
}

download_and_extract_release() {
    local release_url="${REPO}/releases/download/${RELEASE_TAG}"
    local archive="$tmp_dir/$ASSET"
    local checksums="$tmp_dir/SHA256SUMS"
    local selected_checksum="$tmp_dir/asset.sha256"
    local expected

    log "Downloading ${ASSET} and SHA256SUMS from Release ${RELEASE_TAG}..."
    secure_download "${release_url}/${ASSET}" "$archive" \
        || fail "Release ${RELEASE_TAG} does not provide ${ASSET}. Only linux-amd64 is currently published."
    secure_download "${release_url}/SHA256SUMS" "$checksums" \
        || fail "Release ${RELEASE_TAG} does not provide SHA256SUMS"

    expected="$(awk -v asset="$ASSET" '
        $2 == asset { checksum=$1; count++ }
        END { if (count == 1) print checksum; else exit 1 }
    ' "$checksums")" || fail "SHA256SUMS must contain exactly one entry for ${ASSET}"
    [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] \
        || fail "SHA256SUMS contains an invalid checksum for ${ASSET}"
    printf '%s  %s\n' "${expected,,}" "$ASSET" > "$selected_checksum"
    (
        cd "$tmp_dir"
        sha256sum --check "$(basename "$selected_checksum")" >/dev/null
    ) || fail "Checksum verification failed for ${ASSET}"

    validate_archive "$archive"
    mkdir -p "$tmp_dir/extract"
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$tmp_dir/extract" \
        || fail "Release archive extraction failed"
    if find "$tmp_dir/extract" -mindepth 1 ! -type f ! -type d -print -quit | grep -q .; then
        fail "Extracted release contains an unsupported filesystem object"
    fi
    chmod -R a-s "$tmp_dir/extract"
    validate_release_bundle "$tmp_dir/extract" "$remote_commit"
}

extract_output_value() {
    local output="$1"
    local key="$2"
    awk -v key="$key" '
        index($0, key ":") == 1 {
            value=substr($0, length(key) + 2)
            sub(/^[[:space:]]*/, "", value)
            print value
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' <<< "$output"
}

capture_panel_configuration() {
    local binary="$1"
    local output_file="$2"
    local settings certificates listener
    local key value

    settings="$("$binary" setting -show true 2>&1)" \
        || fail "Could not read the existing panel settings with ${binary}"
    certificates="$("$binary" setting -getCert true 2>&1)" \
        || fail "Could not read the existing TLS settings with ${binary}"
    listener="$("$binary" setting -getListen true 2>&1)" \
        || fail "Could not read the existing listen address with ${binary}"

    : > "$output_file"
    for key in hasDefaultCredential bootstrapPending port webBasePath; do
        value="$(extract_output_value "$settings" "$key")" \
            || fail "Existing panel did not report setting: ${key}"
        printf '%s=%s\n' "$key" "$value" >> "$output_file"
    done
    for key in cert key; do
        value="$(extract_output_value "$certificates" "$key")" \
            || fail "Existing panel did not report TLS setting: ${key}"
        printf '%s=%s\n' "$key" "$value" >> "$output_file"
    done
    value="$(extract_output_value "$listener" listenIP)" \
        || fail "Existing panel did not report its listen address"
    printf 'listenIP=%s\n' "$value" >> "$output_file"
}

backup_optional_path() {
    local source="$1"
    local destination="$2"

    if [[ -e "$source" || -L "$source" ]]; then
        cp -a -- "$source" "$destination" || return 1
        printf '1'
    else
        printf '0'
    fi
}

stop_runtime() {
    local initial_state
    initial_state="$(systemctl show -p ActiveState --value "$SERVICE_NAME" 2>/dev/null || true)"
    case "$initial_state" in
        active|activating|reloading) service_was_active=1 ;;
    esac

    log "Stopping ${SERVICE_NAME} for a consistent data backup..."
    runtime_stopped=1
    systemctl stop "$SERVICE_NAME" || fail "Could not stop ${SERVICE_NAME}"
    local attempts_left=10
    while ((attempts_left-- > 0)); do
        service_is_live || return 0
        sleep 1
    done
    fail "${SERVICE_NAME} did not stop cleanly; no files were replaced"
}

wait_for_service() {
    local checks_left=5
    while ((checks_left-- > 0)); do
        systemctl is-active --quiet "$SERVICE_NAME" || return 1
        sleep 1
    done
}

wait_for_panel_listener() {
    local binary="$1" settings port checks_left=10
    settings="$("$binary" setting -show true 2>/dev/null)" || return 1
    port="$(extract_output_value "$settings" port)" || return 1
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    while ((checks_left-- > 0)); do
        if ss -ltnH 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit !found}'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

[[ $EUID -eq 0 ]] || fail "Please run this updater as root"
[[ -z "${X_MILI_DEPLOY_ROOT:-}" ]] \
    || fail "This is a managed deployment. Use ${INSTALL_DIR}/deploy.sh --update instead."
require_commands

case "$(uname -m)" in
    x86_64|amd64) ;;
    *) fail "Unsupported architecture: $(uname -m). GitHub Releases currently provide linux-amd64 only." ;;
esac

REPO_SLUG="$(normalize_repo_slug "$REPO")" \
    || fail "X_MILI_REPO must be a GitHub owner/repository value or https://github.com/owner/repository URL"
REPO="https://github.com/${REPO_SLUG}"
API_REPO="${X_MILI_API_REPO:-https://api.github.com/repos/${REPO_SLUG}}"
[[ "$API_REPO" == https://* ]] || fail "X_MILI_API_REPO must use HTTPS"
if [[ -n "$REQUESTED_HTTP_EXPOSURE" ]]; then
    REQUESTED_HTTP_EXPOSURE="$(normalize_boolean "$REQUESTED_HTTP_EXPOSURE")" \
        || fail "X_MILI_ALLOW_INSECURE_HTTP must be true or false"
fi

[[ ! -L "$INSTALL_DIR" ]] || fail "Refusing to update a symbolic-link installation directory: ${INSTALL_DIR}"
[[ ! -L "$DATA_DIR" ]] || fail "Refusing to update with a symbolic-link data directory: ${DATA_DIR}"
INSTALL_DIR="$(normalize_absolute_path "installation directory" "$INSTALL_DIR")"
DATA_DIR="$(normalize_absolute_path "data directory" "$DATA_DIR")"
[[ "$DATA_DIR" != "$INSTALL_DIR" && "$DATA_DIR" != "$INSTALL_DIR/"* && "$INSTALL_DIR" != "$DATA_DIR/"* ]] \
    || fail "Installation and data directories must not overlap"
[[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" && -x "$INSTALL_DIR/x-ui" ]] \
    || fail "Existing legacy installation was not found at ${INSTALL_DIR}"
[[ ! -e "$DATA_DIR" || ( -d "$DATA_DIR" && ! -L "$DATA_DIR" ) ]] \
    || fail "Panel data path must be a regular directory: ${DATA_DIR}"
[[ ! -e "$SERVICE_ENV_FILE" || ( -f "$SERVICE_ENV_FILE" && ! -L "$SERVICE_ENV_FILE" ) ]] \
    || fail "Service environment path must be a regular file: ${SERVICE_ENV_FILE}"
[[ ! -e "$UNIT_FILE" || ( -f "$UNIT_FILE" && ! -L "$UNIT_FILE" ) ]] \
    || fail "Systemd unit path must be a regular file: ${UNIT_FILE}"
systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || fail "Systemd service ${SERVICE_NAME} is not installed"

COMMIT_FILE="${INSTALL_DIR}/.x-mili-commit"
tmp_dir="$(mktemp -d -t x-mili-update.XXXXXX)"
backup_dir="$tmp_dir/backup"
mkdir -m 0700 "$backup_dir"

resolve_release_tag
remote_commit="$(resolve_release_commit)"
local_commit="$(tr -d '[:space:]' < "$COMMIT_FILE" 2>/dev/null || true)"
if [[ -n "$local_commit" && ! "$local_commit" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    warn "Ignoring invalid local commit marker: ${COMMIT_FILE}"
    local_commit=""
fi
local_commit="${local_commit,,}"

if [[ "$local_commit" == "$remote_commit" && "${X_MILI_FORCE_UPDATE:-0}" != "1" \
    && -z "$REQUESTED_HTTP_EXPOSURE" ]]; then
    log "Already on Release ${RELEASE_TAG} (${remote_commit:0:12}); no update is needed."
    exit 0
fi

download_and_extract_release

install_parent="$(dirname "$INSTALL_DIR")"
[[ -d "$install_parent" && ! -L "$install_parent" ]] \
    || fail "Installation parent directory is invalid: ${install_parent}"
staged_dir="$(mktemp -d "${install_parent}/.x-mili-stage.XXXXXX")"
cp -a -- "$tmp_dir/extract/." "$staged_dir/"
validate_release_bundle "$staged_dir" "$remote_commit"

stop_runtime
capture_panel_configuration "$INSTALL_DIR/x-ui" "$tmp_dir/panel-before"
cp -- "$tmp_dir/panel-before" "$tmp_dir/panel-expected"

had_data="$(backup_optional_path "$DATA_DIR" "$backup_dir/data")" \
    || fail "Could not back up panel data from ${DATA_DIR}"
had_service_env="$(backup_optional_path "$SERVICE_ENV_FILE" "$backup_dir/service-env")" \
    || fail "Could not back up ${SERVICE_ENV_FILE}"
had_unit="$(backup_optional_path "$UNIT_FILE" "$backup_dir/unit")" \
    || fail "Could not back up ${UNIT_FILE}"
had_ml="$(backup_optional_path "$ML_PATH" "$backup_dir/ml")" \
    || fail "Could not back up ${ML_PATH}"

old_install_dir="$(mktemp -d "${install_parent}/.x-mili-old.XXXXXX")"
rmdir -- "$old_install_dir"
transaction_started=1

old_install_moved=1
mv -- "$INSTALL_DIR" "$old_install_dir" || {
    old_install_moved=0
    fail "Could not move the previous installation into the rollback slot"
}
mv -- "$staged_dir" "$INSTALL_DIR"
staged_dir=""

ml_tmp="$(mktemp "$(dirname "$ML_PATH")/.x-mili-ml.XXXXXX")"
install -m 0755 "$INSTALL_DIR/x-ui.sh" "$ml_tmp"
mv -Tf -- "$ml_tmp" "$ML_PATH"
ml_tmp=""

validate_release_bundle "$INSTALL_DIR" "$remote_commit"

if [[ -n "$REQUESTED_HTTP_EXPOSURE" ]]; then
    if [[ "$REQUESTED_HTTP_EXPOSURE" == "true" ]]; then
        desired_listen_ip="0.0.0.0"
    else
        desired_listen_ip="127.0.0.1"
    fi
    "$INSTALL_DIR/x-ui" setting -listenIP "$desired_listen_ip" >/dev/null \
        || fail "Could not apply the requested panel listen address"
    sed "s|^listenIP=.*$|listenIP=${desired_listen_ip}|" \
        "$tmp_dir/panel-before" > "$tmp_dir/panel-expected"
    write_http_exposure_environment "$REQUESTED_HTTP_EXPOSURE" \
        || fail "Could not persist the requested HTTP exposure mode"
    cp -- "$SERVICE_ENV_FILE" "$tmp_dir/service-env-expected"
fi

if [[ "$service_was_active" == "1" ]]; then
    log "Starting ${SERVICE_NAME} with Release ${RELEASE_TAG}..."
    systemctl start "$SERVICE_NAME" || fail "The updated service could not be started"
    wait_for_service || fail "The updated service did not remain active"
    wait_for_panel_listener "$INSTALL_DIR/x-ui" || fail "The updated panel did not open its configured listener"
else
    log "${SERVICE_NAME} was inactive before the update and will remain inactive."
fi
runtime_stopped=0

capture_panel_configuration "$INSTALL_DIR/x-ui" "$tmp_dir/panel-after"
cmp -s "$tmp_dir/panel-expected" "$tmp_dir/panel-after" \
    || fail "HTTP/TLS/listen or account bootstrap settings changed unexpectedly"

if [[ -n "$REQUESTED_HTTP_EXPOSURE" ]]; then
    cmp -s "$SERVICE_ENV_FILE" "$tmp_dir/service-env-expected" \
        || fail "The requested HTTP exposure environment was not preserved"
elif [[ "$had_service_env" == "1" ]]; then
    cmp -s "$SERVICE_ENV_FILE" "$backup_dir/service-env" \
        || fail "The HTTP exposure environment changed unexpectedly"
else
    [[ ! -e "$SERVICE_ENV_FILE" && ! -L "$SERVICE_ENV_FILE" ]] \
        || fail "The update unexpectedly created a service environment file"
fi
if [[ "$had_unit" == "1" ]]; then
    cmp -s "$UNIT_FILE" "$backup_dir/unit" \
        || fail "The systemd service definition changed unexpectedly"
fi
if [[ "$service_was_active" == "1" ]] && ! systemctl is-active --quiet "$SERVICE_NAME"; then
    fail "The updated service exited during post-update validation"
fi

update_succeeded=1
log "Updated to Release ${RELEASE_TAG} (${remote_commit:0:12})."
if [[ -n "$REQUESTED_HTTP_EXPOSURE" ]]; then
    log "Panel data, account credentials, and TLS settings were preserved; HTTP exposure is now ${REQUESTED_HTTP_EXPOSURE}."
else
    log "Panel data, account credentials, HTTP/TLS settings, listen address, and service environment were preserved."
fi
