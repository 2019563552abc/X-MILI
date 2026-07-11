#!/usr/bin/env bash
set -euo pipefail

APP_NAME="X-MILI"
DEFAULT_REPO="https://github.com/2019563552abc/X-MILI"
REPO="${X_MILI_REPO:-$DEFAULT_REPO}"
REPO_SLUG="${REPO#https://github.com/}"
REPO_SLUG="${REPO_SLUG%.git}"
SOURCE_REF="${X_MILI_DOCKER_REF:-main}"
RAW_BASE="${X_MILI_RAW_BASE:-https://raw.githubusercontent.com/${REPO_SLUG}/${SOURCE_REF}}"
INSTALL_ROOT="${X_MILI_DOCKER_ROOT:-/opt/x-mili-docker}"
SRC_DIR="${X_MILI_DOCKER_SOURCE_DIR:-${INSTALL_ROOT}/src}"
DATA_DIR="${X_MILI_DOCKER_DATA_DIR:-/etc/x-ui}"
CERT_DIR="${X_MILI_DOCKER_CERT_DIR:-/root/cert}"
ACME_DIR="${X_MILI_DOCKER_ACME_DIR:-${INSTALL_ROOT}/acme}"
CONTAINER_NAME="${X_MILI_DOCKER_CONTAINER:-ml_app}"
IMAGE_NAME="${X_MILI_DOCKER_IMAGE:-x-mili:latest}"
COMPOSE_FILE="${INSTALL_ROOT}/docker-compose.yml"
LANG_DIR="/etc/x-mili"
LANG_FILE="${LANG_DIR}/lang"
PUBLIC_HTTP_ENABLED=""
PUBLIC_HTTP_EXPLICIT=0
AUTO_OPEN_FIREWALL=""
DOCKER_FIREWALL_PORT=""
DOCKER_UFW_RULE_ADDED=0
DOCKER_FIREWALLD_RULE_ADDED=0
DOCKER_INSTALL_MARKER="${DATA_DIR}/.x-mili-docker-install-in-progress"
PANEL_PASSWORD_FILE=""
DOCKER_MANAGED_INSTALL=0
DOCKER_EXISTING_UPDATE=0
DOCKER_PROTECT_EXISTING_DATA=0
DOCKER_UPDATE_TRANSACTION_ACTIVE=0
DOCKER_ROLLBACK_DIR=""
DOCKER_TX_COMPOSE_EXISTED=0
DOCKER_TX_COMPOSE_BACKED_UP=0
DOCKER_TX_SOURCE_EXISTED=0
DOCKER_TX_SOURCE_MOVE_COMPLETE=0
DOCKER_TX_MENU_EXISTED=0
DOCKER_TX_MENU_BACKED_UP=0
DOCKER_TX_INSTALLER_EXISTED=0
DOCKER_TX_INSTALLER_BACKED_UP=0
DOCKER_TX_INSTALL_MARKER_EXISTED=0
DOCKER_TX_INSTALL_MARKER_BACKED_UP=0
DOCKER_TX_CREDENTIALS_EXISTED=0
DOCKER_TX_CREDENTIALS_BACKED_UP=0
DOCKER_TX_DATA_BACKUP_COMPLETE=0
DOCKER_TX_DB_EXISTED=0
DOCKER_TX_DB_WAL_EXISTED=0
DOCKER_TX_DB_SHM_EXISTED=0
DOCKER_TX_DB_JOURNAL_EXISTED=0
DOCKER_TX_OLD_CONTAINER_EXISTED=0
DOCKER_TX_OLD_CONTAINER_RUNNING=0
DOCKER_TX_OLD_CONTAINER_ID=""
DOCKER_TX_OLD_CONTAINER_IMAGE_ID=""
DOCKER_TX_OLD_IMAGE_ID=""
DOCKER_TX_CONTAINER_IMAGE_PIN=""
DOCKER_TX_IMAGE_PIN=""
DOCKER_INSTALL_MARKER_TEMP=""
DOCKER_INSTALL_LOCK=""
DOCKER_COMPOSE_WRITE_TEMP=""
DOCKER_HOST_MENU_TEMP=""
DOCKER_INSTALLER_WRITE_TEMP=""

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

log() { echo -e "${green}[X-MILI Docker]${plain} $*"; }
warn() { echo -e "${yellow}[X-MILI Docker]${plain} $*"; }
fail() { echo -e "${red}[X-MILI Docker]${plain} $*" >&2; exit 1; }
step() { echo -e "${green}[X-MILI Docker]${plain} ${yellow}[$1/$2]${plain} $3"; }

[[ ${EUID} -ne 0 ]] && fail "请使用 root 运行 / Please run as root"

choose_language() {
    [[ -f "${LANG_FILE}" ]] && X_MILI_LANG=$(cat "${LANG_FILE}")
    if [[ -z "${X_MILI_LANG:-}" ]]; then
        echo -e "${green}1.${plain} English"
        echo -e "${green}2.${plain} 简体中文"
        read -rp "Please choose language / 请选择语言 [1-2]: " choice
        [[ "${choice}" == "2" ]] && X_MILI_LANG="zh_CN" || X_MILI_LANG="en_US"
        mkdir -p "${LANG_DIR}"
        echo "${X_MILI_LANG}" > "${LANG_FILE}"
    fi
}

is_zh() { [[ "${X_MILI_LANG}" == "zh_CN" ]]; }

cleanup_panel_password_file() {
    if [[ -n "${PANEL_PASSWORD_FILE}" \
        && "${PANEL_PASSWORD_FILE}" == "${DATA_DIR}/.x-mili-password."* ]]; then
        rm -f -- "${PANEL_PASSWORD_FILE}" 2>/dev/null || true
    fi
    PANEL_PASSWORD_FILE=""
}

cleanup_install_marker_temp() {
    if [[ -n "${DOCKER_INSTALL_MARKER_TEMP}" \
        && "${DOCKER_INSTALL_MARKER_TEMP}" == "${DOCKER_INSTALL_MARKER}."* ]]; then
        rm -f -- "${DOCKER_INSTALL_MARKER_TEMP}" 2>/dev/null || true
    fi
    DOCKER_INSTALL_MARKER_TEMP=""
}

cleanup_docker_write_temps() {
    if [[ -n "${DOCKER_COMPOSE_WRITE_TEMP}" \
        && "${DOCKER_COMPOSE_WRITE_TEMP}" == "${INSTALL_ROOT}/.docker-compose."* ]]; then
        rm -f -- "${DOCKER_COMPOSE_WRITE_TEMP}" 2>/dev/null || true
    fi
    if [[ -n "${DOCKER_INSTALLER_WRITE_TEMP}" \
        && "${DOCKER_INSTALLER_WRITE_TEMP}" == "${INSTALL_ROOT}/.install-docker."* ]]; then
        rm -f -- "${DOCKER_INSTALLER_WRITE_TEMP}" 2>/dev/null || true
    fi
    if [[ -n "${DOCKER_HOST_MENU_TEMP}" \
        && "${DOCKER_HOST_MENU_TEMP}" == /usr/bin/.x-mili-ml.* ]]; then
        rm -f -- "${DOCKER_HOST_MENU_TEMP}" 2>/dev/null || true
    fi
    DOCKER_COMPOSE_WRITE_TEMP=""
    DOCKER_INSTALLER_WRITE_TEMP=""
    DOCKER_HOST_MENU_TEMP=""
}

cleanup_docker_install_lock() {
    local owner=""
    [[ -n "${DOCKER_INSTALL_LOCK}" && -L "${DOCKER_INSTALL_LOCK}" ]] || return 0
    owner=$(readlink -- "${DOCKER_INSTALL_LOCK}" 2>/dev/null || true)
    if [[ "${owner}" == "$$" ]]; then
        rm -f -- "${DOCKER_INSTALL_LOCK}" 2>/dev/null || true
    fi
}

acquire_docker_install_lock() {
    local owner=""
    DOCKER_INSTALL_LOCK="${INSTALL_ROOT}/.x-mili-docker-install.lock"
    mkdir -p "${INSTALL_ROOT}"
    if ln -s "$$" "${DOCKER_INSTALL_LOCK}" 2>/dev/null; then
        return 0
    fi
    if [[ ! -L "${DOCKER_INSTALL_LOCK}" ]]; then
        fail "Docker install lock exists but is not a symbolic lock: ${DOCKER_INSTALL_LOCK}"
    fi
    owner=$(readlink -- "${DOCKER_INSTALL_LOCK}" 2>/dev/null || true)
    if [[ "${owner}" =~ ^[0-9]+$ ]] && kill -0 "${owner}" 2>/dev/null; then
        fail "Another X-MILI Docker install/update is already running (PID ${owner})."
    fi
    rm -f -- "${DOCKER_INSTALL_LOCK}"
    ln -s "$$" "${DOCKER_INSTALL_LOCK}" \
        || fail "Could not acquire the X-MILI Docker install lock."
}

is_managed_docker_compose() {
    [[ -f "${COMPOSE_FILE}" && ! -L "${COMPOSE_FILE}" ]] || return 1
    grep -Eq '^[[:space:]]*services:[[:space:]]*$' "${COMPOSE_FILE}" \
        && grep -Eq '^[[:space:]]+ml:[[:space:]]*$' "${COMPOSE_FILE}" \
        && grep -Fq "container_name: ${CONTAINER_NAME}" "${COMPOSE_FILE}" \
        && grep -Fq -- "- ${DATA_DIR}:/etc/x-ui" "${COMPOSE_FILE}" \
        && grep -Eq '^[[:space:]]*network_mode:[[:space:]]*host[[:space:]]*$' "${COMPOSE_FILE}"
}

is_managed_docker_wrapper() {
    [[ -f /usr/bin/ml && ! -L /usr/bin/ml ]] || return 1
    grep -Fq "ROOT=\"${INSTALL_ROOT}\"" /usr/bin/ml \
        && grep -Fq "CONTAINER=\"${CONTAINER_NAME}\"" /usr/bin/ml \
        && grep -Fq 'COMPOSE_FILE="${ROOT}/docker-compose.yml"' /usr/bin/ml \
        && grep -Fq 'docker compose -f "${COMPOSE_FILE}"' /usr/bin/ml \
        && grep -Fq '/app/x-ui' /usr/bin/ml
}

detect_docker_install_state() {
    if [[ -e "${COMPOSE_FILE}" || -L "${COMPOSE_FILE}" ]]; then
        is_managed_docker_compose \
            || fail "Existing Compose file is not a recognized X-MILI Docker install: ${COMPOSE_FILE}"
        DOCKER_MANAGED_INSTALL=1
        if [[ ! -f "${DOCKER_INSTALL_MARKER}" ]]; then
            DOCKER_EXISTING_UPDATE=1
        fi
    fi
}

check_docker_install_conflicts() {
    local native_command=""

    if [[ -e /usr/bin/ml || -L /usr/bin/ml ]]; then
        if [[ "${DOCKER_MANAGED_INSTALL}" != "1" ]] || ! is_managed_docker_wrapper; then
            fail "Refusing to overwrite /usr/bin/ml because it is not the wrapper for this X-MILI Docker install."
        fi
    fi

    # A recognized Docker install may be updated or repaired in place. For a
    # fresh Docker install, native x-ui would share the host network, menu, and
    # usually the panel port, so require the operator to choose one deployment.
    [[ "${DOCKER_MANAGED_INSTALL}" != "1" ]] || return 0
    if [[ -d /usr/local/x-ui \
        || -e /etc/systemd/system/x-ui.service \
        || -e /lib/systemd/system/x-ui.service \
        || -e /usr/lib/systemd/system/x-ui.service \
        || -e /etc/init.d/x-ui ]]; then
        fail "Native x-ui/X-MILI installation detected. Uninstall or stop using the native deployment before installing the Docker edition."
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl cat x-ui.service >/dev/null 2>&1; then
        fail "Native x-ui.service detected. Remove the native deployment before installing the Docker edition."
    fi
    native_command=$(command -v x-ui 2>/dev/null || true)
    if [[ -n "${native_command}" ]]; then
        fail "Native x-ui command detected at ${native_command}. Remove the native deployment before installing the Docker edition."
    fi
}

detect_existing_database_state() {
    local name path
    for name in x-ui.db x-ui.db-wal x-ui.db-shm x-ui.db-journal; do
        path="${DATA_DIR}/${name}"
        if [[ -L "${path}" ]]; then
            fail "Refusing to use a symbolic-link database file: ${path}"
        fi
        if [[ -e "${path}" ]]; then
            [[ -f "${path}" ]] || fail "Docker database path is not a regular file: ${path}"
            DOCKER_PROTECT_EXISTING_DATA=1
        fi
    done
}

check_docker_runtime_conflicts() {
    [[ "${DOCKER_MANAGED_INSTALL}" != "1" ]] || return 0
    if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        fail "Container ${CONTAINER_NAME} already exists but is not tied to a recognized X-MILI Docker install."
    fi
}

remove_docker_transaction_pins() {
    local pin
    for pin in "${DOCKER_TX_CONTAINER_IMAGE_PIN}" "${DOCKER_TX_IMAGE_PIN}"; do
        [[ -n "${pin}" ]] || continue
        docker image rm --force "${pin}" >/dev/null 2>&1 || true
    done
}

remove_docker_rollback_dir() {
    [[ -n "${DOCKER_ROLLBACK_DIR}" ]] || return 0
    if [[ "${DOCKER_ROLLBACK_DIR}" == "${INSTALL_ROOT}/.x-mili-docker-rollback."* ]]; then
        rm -rf -- "${DOCKER_ROLLBACK_DIR}"
    else
        warn "Refusing to remove an unexpected Docker rollback path: ${DOCKER_ROLLBACK_DIR}"
        return 1
    fi
}

begin_docker_update_transaction() {
    local transaction_id credentials_file="${DATA_DIR}/.x-mili-initial-credentials"
    if [[ "${DOCKER_EXISTING_UPDATE}" != "1" && "${DOCKER_PROTECT_EXISTING_DATA}" != "1" ]]; then
        return 0
    fi

    mkdir -p "${INSTALL_ROOT}"
    DOCKER_ROLLBACK_DIR=$(mktemp -d "${INSTALL_ROOT}/.x-mili-docker-rollback.XXXXXX")
    chmod 0700 "${DOCKER_ROLLBACK_DIR}"

    if [[ -e "${COMPOSE_FILE}" || -L "${COMPOSE_FILE}" ]]; then
        [[ -f "${COMPOSE_FILE}" && ! -L "${COMPOSE_FILE}" ]] \
            || fail "Docker Compose path is not a regular file: ${COMPOSE_FILE}"
        DOCKER_TX_COMPOSE_EXISTED=1
    fi
    if [[ -e "${SRC_DIR}" || -L "${SRC_DIR}" ]]; then
        [[ -d "${SRC_DIR}" && ! -L "${SRC_DIR}" ]] \
            || fail "Existing Docker source path is not a regular directory: ${SRC_DIR}"
        DOCKER_TX_SOURCE_EXISTED=1
    fi
    if [[ -e /usr/bin/ml || -L /usr/bin/ml ]]; then
        DOCKER_TX_MENU_EXISTED=1
    fi
    if [[ -e "${INSTALL_ROOT}/install-docker.sh" || -L "${INSTALL_ROOT}/install-docker.sh" ]]; then
        DOCKER_TX_INSTALLER_EXISTED=1
    fi
    if [[ -e "${DOCKER_INSTALL_MARKER}" || -L "${DOCKER_INSTALL_MARKER}" ]]; then
        [[ -f "${DOCKER_INSTALL_MARKER}" && ! -L "${DOCKER_INSTALL_MARKER}" ]] \
            || fail "Docker install marker is not a regular file: ${DOCKER_INSTALL_MARKER}"
        DOCKER_TX_INSTALL_MARKER_EXISTED=1
    fi
    if [[ -e "${credentials_file}" || -L "${credentials_file}" ]]; then
        [[ -f "${credentials_file}" && ! -L "${credentials_file}" ]] \
            || fail "Docker credentials recovery path is not a regular file: ${credentials_file}"
        DOCKER_TX_CREDENTIALS_EXISTED=1
    fi
    if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        DOCKER_TX_OLD_CONTAINER_EXISTED=1
        DOCKER_TX_OLD_CONTAINER_ID=$(docker inspect -f '{{.Id}}' "${CONTAINER_NAME}")
        DOCKER_TX_OLD_CONTAINER_IMAGE_ID=$(docker inspect -f '{{.Image}}' "${CONTAINER_NAME}")
        if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}")" == "true" ]]; then
            DOCKER_TX_OLD_CONTAINER_RUNNING=1
        fi
    fi
    DOCKER_TX_OLD_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "${IMAGE_NAME}" 2>/dev/null || true)

    # From this point forward every mutation has enough pre-state recorded for
    # the EXIT/signal handler to make a conservative recovery decision.
    DOCKER_UPDATE_TRANSACTION_ACTIVE=1
    if [[ "${DOCKER_TX_COMPOSE_EXISTED}" == "1" ]]; then
        cp -a -- "${COMPOSE_FILE}" "${DOCKER_ROLLBACK_DIR}/docker-compose.yml"
        DOCKER_TX_COMPOSE_BACKED_UP=1
    fi
    if [[ "${DOCKER_TX_SOURCE_EXISTED}" == "1" ]]; then
        mv -- "${SRC_DIR}" "${DOCKER_ROLLBACK_DIR}/source"
        DOCKER_TX_SOURCE_MOVE_COMPLETE=1
    fi
    if [[ "${DOCKER_TX_MENU_EXISTED}" == "1" ]]; then
        cp -a -- /usr/bin/ml "${DOCKER_ROLLBACK_DIR}/ml"
        DOCKER_TX_MENU_BACKED_UP=1
    fi
    if [[ "${DOCKER_TX_INSTALLER_EXISTED}" == "1" ]]; then
        cp -a -- "${INSTALL_ROOT}/install-docker.sh" "${DOCKER_ROLLBACK_DIR}/install-docker.sh"
        DOCKER_TX_INSTALLER_BACKED_UP=1
    fi
    if [[ "${DOCKER_TX_INSTALL_MARKER_EXISTED}" == "1" ]]; then
        cp -a -- "${DOCKER_INSTALL_MARKER}" "${DOCKER_ROLLBACK_DIR}/install-marker"
        DOCKER_TX_INSTALL_MARKER_BACKED_UP=1
    fi
    if [[ "${DOCKER_TX_CREDENTIALS_EXISTED}" == "1" ]]; then
        cp -a -- "${credentials_file}" "${DOCKER_ROLLBACK_DIR}/initial-credentials"
        DOCKER_TX_CREDENTIALS_BACKED_UP=1
    fi

    transaction_id="$$-$(date +%s)"
    if [[ -n "${DOCKER_TX_OLD_CONTAINER_IMAGE_ID}" ]]; then
        DOCKER_TX_CONTAINER_IMAGE_PIN="x-mili-rollback:${transaction_id}-container"
        docker image tag "${DOCKER_TX_OLD_CONTAINER_IMAGE_ID}" "${DOCKER_TX_CONTAINER_IMAGE_PIN}"
    fi
    if [[ -n "${DOCKER_TX_OLD_IMAGE_ID}" ]]; then
        DOCKER_TX_IMAGE_PIN="x-mili-rollback:${transaction_id}-image"
        docker image tag "${DOCKER_TX_OLD_IMAGE_ID}" "${DOCKER_TX_IMAGE_PIN}"
    fi
}

restore_docker_transaction_files() {
    local credentials_file="${DATA_DIR}/.x-mili-initial-credentials"
    local failed=0 compose_failed=0 source_failed=0 menu_failed=0 installer_failed=0
    local marker_failed=0 credentials_failed=0

    if [[ "${DOCKER_TX_COMPOSE_BACKED_UP}" == "1" ]]; then
        rm -f -- "${COMPOSE_FILE}" || compose_failed=1
        if [[ "${compose_failed}" == "0" ]]; then
            cp -a -- "${DOCKER_ROLLBACK_DIR}/docker-compose.yml" "${COMPOSE_FILE}" || compose_failed=1
        fi
    elif [[ "${DOCKER_TX_COMPOSE_EXISTED}" == "0" ]]; then
        rm -f -- "${COMPOSE_FILE}" || compose_failed=1
    fi
    [[ "${compose_failed}" == "0" ]] || failed=1

    if [[ "${DOCKER_TX_SOURCE_EXISTED}" == "1" ]]; then
        if [[ -e "${DOCKER_ROLLBACK_DIR}/source" ]]; then
            rm -rf -- "${SRC_DIR}" || source_failed=1
            if [[ "${source_failed}" == "0" ]]; then
                mv -- "${DOCKER_ROLLBACK_DIR}/source" "${SRC_DIR}" || source_failed=1
            fi
        elif [[ "${DOCKER_TX_SOURCE_MOVE_COMPLETE}" == "1" \
            || ! -d "${SRC_DIR}" || -L "${SRC_DIR}" ]]; then
            warn "Docker source rollback copy is missing and the original source is unavailable."
            source_failed=1
        fi
        if [[ "${source_failed}" != "0" ]]; then
            failed=1
        fi
    else
        rm -rf -- "${SRC_DIR}" || failed=1
    fi

    if [[ "${DOCKER_TX_MENU_BACKED_UP}" == "1" ]]; then
        rm -f -- /usr/bin/ml || menu_failed=1
        if [[ "${menu_failed}" == "0" ]]; then
            cp -a -- "${DOCKER_ROLLBACK_DIR}/ml" /usr/bin/ml || menu_failed=1
        fi
    elif [[ "${DOCKER_TX_MENU_EXISTED}" == "0" ]]; then
        rm -f -- /usr/bin/ml || menu_failed=1
    fi
    [[ "${menu_failed}" == "0" ]] || failed=1

    if [[ "${DOCKER_TX_INSTALLER_BACKED_UP}" == "1" ]]; then
        rm -f -- "${INSTALL_ROOT}/install-docker.sh" || installer_failed=1
        if [[ "${installer_failed}" == "0" ]]; then
            cp -a -- "${DOCKER_ROLLBACK_DIR}/install-docker.sh" "${INSTALL_ROOT}/install-docker.sh" \
                || installer_failed=1
        fi
    elif [[ "${DOCKER_TX_INSTALLER_EXISTED}" == "0" ]]; then
        rm -f -- "${INSTALL_ROOT}/install-docker.sh" || installer_failed=1
    fi
    [[ "${installer_failed}" == "0" ]] || failed=1

    if [[ "${DOCKER_TX_INSTALL_MARKER_BACKED_UP}" == "1" ]]; then
        rm -f -- "${DOCKER_INSTALL_MARKER}" || marker_failed=1
        if [[ "${marker_failed}" == "0" ]]; then
            cp -a -- "${DOCKER_ROLLBACK_DIR}/install-marker" "${DOCKER_INSTALL_MARKER}" \
                || marker_failed=1
        fi
    elif [[ "${DOCKER_TX_INSTALL_MARKER_EXISTED}" == "0" ]]; then
        rm -f -- "${DOCKER_INSTALL_MARKER}" || marker_failed=1
    fi

    if [[ "${DOCKER_TX_CREDENTIALS_BACKED_UP}" == "1" ]]; then
        rm -f -- "${credentials_file}" || credentials_failed=1
        if [[ "${credentials_failed}" == "0" ]]; then
            cp -a -- "${DOCKER_ROLLBACK_DIR}/initial-credentials" "${credentials_file}" \
                || credentials_failed=1
        fi
    elif [[ "${DOCKER_TX_CREDENTIALS_EXISTED}" == "0" ]]; then
        rm -f -- "${credentials_file}" || credentials_failed=1
    fi
    [[ "${marker_failed}" == "0" && "${credentials_failed}" == "0" ]] || failed=1

    return "${failed}"
}

wait_for_container_running_state() {
    local expected="$1" state _
    for _ in {1..15}; do
        state=$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)
        [[ "${state}" == "${expected}" ]] && return 0
        sleep 1
    done
    return 1
}

backup_docker_database_for_update() {
    local current_container_id name source
    [[ "${DOCKER_UPDATE_TRANSACTION_ACTIVE}" == "1" ]] || return 0

    current_container_id=$(docker inspect -f '{{.Id}}' "${CONTAINER_NAME}" 2>/dev/null || true)
    if [[ "${DOCKER_TX_OLD_CONTAINER_EXISTED}" == "1" ]]; then
        [[ "${current_container_id}" == "${DOCKER_TX_OLD_CONTAINER_ID}" ]] \
            || fail "Docker container changed during the update; refusing an inconsistent database backup."
        if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]; then
            docker stop --time 30 "${CONTAINER_NAME}" >/dev/null
        fi
        wait_for_container_running_state false \
            || fail "Could not stop the existing Docker container for a consistent database backup."
    elif [[ -n "${current_container_id}" ]]; then
        fail "A Docker container appeared during the update; refusing an inconsistent database backup."
    fi

    mkdir -p "${DOCKER_ROLLBACK_DIR}/data"
    chmod 0700 "${DOCKER_ROLLBACK_DIR}/data"
    for name in x-ui.db x-ui.db-wal x-ui.db-shm x-ui.db-journal; do
        source="${DATA_DIR}/${name}"
        [[ ! -L "${source}" ]] \
            || fail "Refusing to back up a symbolic-link database file: ${source}"
        if [[ -e "${source}" && ! -f "${source}" ]]; then
            fail "Docker database path is not a regular file: ${source}"
        fi
    done

    if [[ -f "${DATA_DIR}/x-ui.db" ]]; then
        DOCKER_TX_DB_EXISTED=1
        cp -a -- "${DATA_DIR}/x-ui.db" "${DOCKER_ROLLBACK_DIR}/data/x-ui.db"
    fi
    if [[ -f "${DATA_DIR}/x-ui.db-wal" ]]; then
        DOCKER_TX_DB_WAL_EXISTED=1
        cp -a -- "${DATA_DIR}/x-ui.db-wal" "${DOCKER_ROLLBACK_DIR}/data/x-ui.db-wal"
    fi
    if [[ -f "${DATA_DIR}/x-ui.db-shm" ]]; then
        DOCKER_TX_DB_SHM_EXISTED=1
        cp -a -- "${DATA_DIR}/x-ui.db-shm" "${DOCKER_ROLLBACK_DIR}/data/x-ui.db-shm"
    fi
    if [[ -f "${DATA_DIR}/x-ui.db-journal" ]]; then
        DOCKER_TX_DB_JOURNAL_EXISTED=1
        cp -a -- "${DATA_DIR}/x-ui.db-journal" "${DOCKER_ROLLBACK_DIR}/data/x-ui.db-journal"
    fi
    DOCKER_TX_DATA_BACKUP_COMPLETE=1
}

restore_docker_transaction_data() {
    local name expected failed=0
    [[ "${DOCKER_TX_DATA_BACKUP_COMPLETE}" == "1" ]] || return 0

    if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]; then
            docker stop --time 30 "${CONTAINER_NAME}" >/dev/null 2>&1 || return 1
        fi
        wait_for_container_running_state false || return 1
    fi

    for name in x-ui.db x-ui.db-wal x-ui.db-shm x-ui.db-journal; do
        [[ ! -L "${DATA_DIR}/${name}" ]] || return 1
    done
    rm -f -- \
        "${DATA_DIR}/x-ui.db" \
        "${DATA_DIR}/x-ui.db-wal" \
        "${DATA_DIR}/x-ui.db-shm" \
        "${DATA_DIR}/x-ui.db-journal" \
        || return 1

    for name in x-ui.db x-ui.db-wal x-ui.db-shm x-ui.db-journal; do
        case "${name}" in
            x-ui.db) expected="${DOCKER_TX_DB_EXISTED}" ;;
            x-ui.db-wal) expected="${DOCKER_TX_DB_WAL_EXISTED}" ;;
            x-ui.db-shm) expected="${DOCKER_TX_DB_SHM_EXISTED}" ;;
            x-ui.db-journal) expected="${DOCKER_TX_DB_JOURNAL_EXISTED}" ;;
        esac
        if [[ "${expected}" == "1" ]]; then
            cp -a -- "${DOCKER_ROLLBACK_DIR}/data/${name}" "${DATA_DIR}/${name}" || failed=1
        fi
    done
    return "${failed}"
}

restore_docker_transaction_container() {
    local current_container_id current_image_id current_tag_image_id failed=0 recreate_ready=1
    current_container_id=$(docker inspect -f '{{.Id}}' "${CONTAINER_NAME}" 2>/dev/null || true)

    if [[ "${DOCKER_TX_OLD_CONTAINER_EXISTED}" == "1" ]]; then
        if [[ "${current_container_id}" != "${DOCKER_TX_OLD_CONTAINER_ID}" ]]; then
            if [[ -z "${DOCKER_TX_CONTAINER_IMAGE_PIN}" ]] \
                || ! docker image inspect "${DOCKER_TX_CONTAINER_IMAGE_PIN}" >/dev/null 2>&1; then
                recreate_ready=0
                failed=1
            elif ! docker image tag "${DOCKER_TX_CONTAINER_IMAGE_PIN}" "${IMAGE_NAME}"; then
                recreate_ready=0
                failed=1
            fi
            if [[ "${recreate_ready}" == "1" ]]; then
                if [[ "${DOCKER_TX_OLD_CONTAINER_RUNNING}" == "1" ]]; then
                    compose up -d --force-recreate --no-build || failed=1
                else
                    compose create --force-recreate --no-build || failed=1
                fi
            fi
        fi

        if [[ "${DOCKER_TX_OLD_CONTAINER_RUNNING}" == "1" ]]; then
            docker start "${CONTAINER_NAME}" >/dev/null 2>&1 || failed=1
            wait_for_container_running_state true || failed=1
        else
            docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || failed=1
            wait_for_container_running_state false || failed=1
        fi
        current_image_id=$(docker inspect -f '{{.Image}}' "${CONTAINER_NAME}" 2>/dev/null || true)
        [[ "${current_image_id}" == "${DOCKER_TX_OLD_CONTAINER_IMAGE_ID}" ]] || failed=1
    else
        if [[ -n "${current_container_id}" ]]; then
            docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || failed=1
        fi
    fi

    if [[ -n "${DOCKER_TX_OLD_IMAGE_ID}" ]]; then
        current_tag_image_id=$(docker image inspect -f '{{.Id}}' "${IMAGE_NAME}" 2>/dev/null || true)
        if [[ "${current_tag_image_id}" == "${DOCKER_TX_OLD_IMAGE_ID}" ]]; then
            :
        elif [[ -n "${DOCKER_TX_IMAGE_PIN}" ]] \
            && docker image inspect "${DOCKER_TX_IMAGE_PIN}" >/dev/null 2>&1; then
            docker image tag "${DOCKER_TX_IMAGE_PIN}" "${IMAGE_NAME}" || failed=1
        else
            failed=1
        fi
    elif docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
        docker image rm --force "${IMAGE_NAME}" >/dev/null 2>&1 || failed=1
    fi

    return "${failed}"
}

rollback_docker_update_transaction() {
    local failed=0 files_restored=1 data_restored=1
    [[ "${DOCKER_UPDATE_TRANSACTION_ACTIVE}" == "1" ]] || return 0

    warn "Docker installation/update failed; restoring the previous files, database, image, and container state."
    cleanup_panel_password_file
    if ! restore_docker_transaction_files; then
        files_restored=0
        failed=1
    fi
    if ! restore_docker_transaction_data; then
        data_restored=0
        failed=1
    fi
    if [[ "${files_restored}" == "1" && "${data_restored}" == "1" ]]; then
        restore_docker_transaction_container || failed=1
    else
        warn "Container recovery was skipped because files or database state could not be restored safely."
    fi
    DOCKER_UPDATE_TRANSACTION_ACTIVE=0
    if [[ "${failed}" == "0" ]]; then
        remove_docker_transaction_pins
        remove_docker_rollback_dir || failed=1
    fi

    if [[ "${failed}" != "0" ]]; then
        warn "Docker rollback was incomplete. Recovery files and pinned images were kept at: ${DOCKER_ROLLBACK_DIR}"
        return 1
    fi
    log "Previous Docker state restored successfully."
}

commit_docker_update_transaction() {
    [[ "${DOCKER_UPDATE_TRANSACTION_ACTIVE}" == "1" ]] || return 0

    # Mark the transaction committed before cleanup so a signal can only leave
    # harmless backup artifacts, never roll back a verified deployment.
    DOCKER_UPDATE_TRANSACTION_ACTIVE=0
    remove_docker_transaction_pins
    remove_docker_rollback_dir \
        || warn "Update succeeded, but the rollback directory could not be removed: ${DOCKER_ROLLBACK_DIR}"
}

docker_installer_on_exit() {
    local rc="${1:-1}" rollback_rc=0
    trap - EXIT INT TERM HUP QUIT
    set +e
    cleanup_panel_password_file
    cleanup_install_marker_temp
    cleanup_docker_write_temps
    rollback_docker_firewall_changes
    if [[ "${DOCKER_UPDATE_TRANSACTION_ACTIVE}" == "1" ]]; then
        rollback_docker_update_transaction
        rollback_rc=$?
        [[ "${rc}" != "0" ]] || rc=1
    fi
    if [[ "${rollback_rc}" != "0" ]]; then
        warn "Automatic Docker rollback needs manual recovery."
    fi
    cleanup_docker_install_lock
    exit "${rc}"
}

paths_overlap() {
    local left="$1" right="$2"
    [[ "$left" == "$right" || "$left" == "$right/"* || "$right" == "$left/"* ]]
}

validate_docker_paths() {
    local root source data cert acme path
    command -v realpath >/dev/null 2>&1 || fail "Missing required command: realpath"
    [[ "$REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || fail "X_MILI_REPO must be a GitHub owner/repository URL"
    REPO="https://github.com/${REPO_SLUG}"
    [[ "$SOURCE_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$SOURCE_REF" != *..* ]] \
        || fail "X_MILI_DOCKER_REF contains unsafe characters"
    for path in "$INSTALL_ROOT" "$SRC_DIR" "$DATA_DIR" "$CERT_DIR" "$ACME_DIR"; do
        [[ "$path" == /* ]] || fail "Docker paths must be absolute: ${path}"
        [[ "$path" != *[[:space:]:#]* ]] || fail "Docker paths must not contain whitespace, colon, or #: ${path}"
        [[ ! -L "$path" ]] || fail "Docker managed paths must not be symbolic links: ${path}"
    done
    root=$(realpath -m -- "$INSTALL_ROOT")
    source=$(realpath -m -- "$SRC_DIR")
    data=$(realpath -m -- "$DATA_DIR")
    cert=$(realpath -m -- "$CERT_DIR")
    acme=$(realpath -m -- "$ACME_DIR")

    [[ "$root" == /opt/x-mili || "$root" == /opt/x-mili-* ]] \
        || fail "X_MILI_DOCKER_ROOT must be /opt/x-mili or an /opt/x-mili-* managed directory"
    [[ "$source" == "$root/"* ]] || fail "Docker source directory must be inside ${root}"
    case "$data" in /etc/*|/var/lib/*|/srv/*) ;; *) fail "Docker data directory must be under /etc, /var/lib, or /srv" ;; esac
    case "$cert" in /root/*|/etc/*|/var/lib/*|/srv/*) ;; *) fail "Docker certificate directory is outside the allowed roots" ;; esac
    case "$acme" in "$root"/*|/root/*|/var/lib/*) ;; *) fail "Docker ACME directory is outside the allowed roots" ;; esac

    paths_overlap "$root" "$data" && fail "Docker root and data directory must not overlap"
    paths_overlap "$root" "$cert" && fail "Docker root and certificate directory must not overlap"
    paths_overlap "$data" "$cert" && fail "Docker data and certificate directories must not overlap"
    paths_overlap "$data" "$acme" && fail "Docker data and ACME directories must not overlap"
    paths_overlap "$cert" "$acme" && fail "Docker certificate and ACME directories must not overlap"
    paths_overlap "$source" "$acme" && fail "Docker source and ACME directories must not overlap"

    INSTALL_ROOT="$root"
    SRC_DIR="$source"
    DATA_DIR="$data"
    CERT_DIR="$cert"
    ACME_DIR="$acme"
    COMPOSE_FILE="${INSTALL_ROOT}/docker-compose.yml"
    [[ ! -L "${COMPOSE_FILE}" ]] \
        || fail "Docker Compose file must not be a symbolic link: ${COMPOSE_FILE}"
}

parse_boolean() {
    case "${1,,}" in
        1 | true | yes | y | on) echo "true" ;;
        0 | false | no | n | off) echo "false" ;;
        *) return 1 ;;
    esac
}

valid_panel_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#${port} >= 1 && 10#${port} <= 65535))
}

resolve_firewall_policy() {
    local requested="${X_MILI_AUTO_OPEN_FIREWALL:-}" existing=""
    if [[ -n "${requested}" ]]; then
        AUTO_OPEN_FIREWALL=$(parse_boolean "${requested}") \
            || fail "X_MILI_AUTO_OPEN_FIREWALL must be true or false / 必须为 true 或 false"
        return 0
    fi
    if [[ -f "${COMPOSE_FILE}" ]]; then
        existing=$(awk -F':' '/^[[:space:]]*x-x-mili-auto-open-firewall:/ {gsub(/["[:space:]]/, "", $2); print tolower($2); exit}' "${COMPOSE_FILE}")
        if [[ "${existing}" == "true" || "${existing}" == "false" ]]; then
            AUTO_OPEN_FIREWALL="${existing}"
            return 0
        fi
    fi
    AUTO_OPEN_FIREWALL="true"
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 \
        && LC_ALL=C ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'
}

ufw_rule_is_allowed() {
    local port="$1"
    LC_ALL=C ufw status 2>/dev/null \
        | awk -v rule="${port}/tcp" '$1 == rule && $2 == "ALLOW" {found=1} END {exit !found}'
}

firewalld_is_active() {
    command -v firewall-cmd >/dev/null 2>&1 \
        && [[ "$(firewall-cmd --state 2>/dev/null || true)" == "running" ]]
}

rollback_docker_firewall_changes() {
    local failed=0
    [[ -n "${DOCKER_FIREWALL_PORT}" ]] || return 0
    if [[ "${DOCKER_UFW_RULE_ADDED}" == "1" ]]; then
        if ufw_rule_is_allowed "${DOCKER_FIREWALL_PORT}"; then
            ufw --force delete allow "${DOCKER_FIREWALL_PORT}/tcp" >/dev/null 2>&1 || failed=1
        fi
    fi
    if [[ "${DOCKER_FIREWALLD_RULE_ADDED}" == "1" ]]; then
        if firewall-cmd --permanent --query-port="${DOCKER_FIREWALL_PORT}/tcp" >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="${DOCKER_FIREWALL_PORT}/tcp" >/dev/null 2>&1 || failed=1
            firewall-cmd --reload >/dev/null 2>&1 || failed=1
        fi
    fi
    DOCKER_UFW_RULE_ADDED=0
    DOCKER_FIREWALLD_RULE_ADDED=0
    DOCKER_FIREWALL_PORT=""
    if [[ "${failed}" != "0" ]]; then
        warn "Could not fully restore host firewall rules; inspect UFW/firewalld manually."
        return 1
    fi
}

commit_docker_firewall_changes() {
    DOCKER_UFW_RULE_ADDED=0
    DOCKER_FIREWALLD_RULE_ADDED=0
    DOCKER_FIREWALL_PORT=""
}

configure_host_firewall() {
    local info port cert listen_ip ufw_preexisting=0 firewalld_preexisting=0 active_firewalls=0
    [[ "${PUBLIC_HTTP_ENABLED}" == "true" ]] || return 0

    info=$(container_setting -show true) || return 1
    port=$(extract_setting "${info}" "port")
    valid_panel_port "${port}" || fail "Invalid panel port returned by the container: ${port:-empty}"
    cert=$(container_setting -getCert true | awk -F': ' '/^cert:/ {print $2; exit}' | tr -d '[:space:]')
    listen_ip=$(container_setting -getListen true | awk -F': ' '/^listenIP:/ {print $2; exit}' | tr -d '[:space:]')
    [[ -z "${cert}" ]] || return 0
    [[ "${listen_ip}" == "0.0.0.0" || "${listen_ip}" == "::" || "${listen_ip}" == "[::]" ]] || return 0

    DOCKER_FIREWALL_PORT="${port}"
    if [[ "${AUTO_OPEN_FIREWALL}" == "true" ]]; then
        if ufw_is_active; then
            active_firewalls=1
            ufw_rule_is_allowed "${port}" && ufw_preexisting=1
            if [[ "${ufw_preexisting}" != "1" ]]; then
                DOCKER_UFW_RULE_ADDED=1
                if ! ufw allow "${port}/tcp" >/dev/null; then
                    return 1
                fi
            fi
            is_zh && log "已放行 UFW TCP ${port}" || log "Allowed TCP ${port} in UFW"
        fi
        if firewalld_is_active; then
            active_firewalls=1
            if firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1; then
                firewalld_preexisting=1
            fi
            if [[ "${firewalld_preexisting}" != "1" ]]; then
                DOCKER_FIREWALLD_RULE_ADDED=1
                firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
                firewall-cmd --reload >/dev/null
            fi
            is_zh && log "已放行 firewalld TCP ${port}" || log "Allowed TCP ${port} in firewalld"
        fi
        if [[ "${active_firewalls}" == "0" ]]; then
            is_zh && log "未检测到启用中的 UFW/firewalld，无需修改主机防火墙" \
                || log "No active UFW/firewalld detected; no host firewall change was needed"
        fi
    else
        is_zh && warn "已按 X_MILI_AUTO_OPEN_FIREWALL=false 跳过主机防火墙；请手动放行 TCP ${port}" \
            || warn "Host firewall unchanged by X_MILI_AUTO_OPEN_FIREWALL=false; allow TCP ${port} manually"
    fi
    is_zh && warn "如云厂商启用了安全组/云防火墙，还需手动放行 TCP ${port}" \
        || warn "If your provider uses a security group/cloud firewall, allow TCP ${port} there manually"
}

finalize_docker_installation() {
    trap '' INT TERM HUP QUIT
    commit_docker_update_transaction
    commit_docker_firewall_changes
    cleanup_docker_install_lock
    trap - INT TERM HUP QUIT
}

resolve_http_exposure() {
    local requested="${X_MILI_ALLOW_INSECURE_HTTP:-}"
    local existing=""

    if [[ -n "${requested}" ]]; then
        PUBLIC_HTTP_ENABLED=$(parse_boolean "${requested}") \
            || fail "X_MILI_ALLOW_INSECURE_HTTP must be true or false / 必须为 true 或 false"
        PUBLIC_HTTP_EXPLICIT=1
        return
    fi

    if [[ -f "${COMPOSE_FILE}" ]]; then
        existing=$(awk -F':' '/^[[:space:]]*XUI_ALLOW_INSECURE_HTTP:/ {gsub(/["[:space:]]/, "", $2); print tolower($2); exit}' "${COMPOSE_FILE}")
        if [[ "${existing}" == "true" || "${existing}" == "false" ]]; then
            PUBLIC_HTTP_ENABLED="${existing}"
        else
            # Existing Docker installs predate this setting and were loopback-only.
            PUBLIC_HTTP_ENABLED="false"
        fi
        return
    fi

    # A fresh install is reachable by public IP until the operator binds TLS.
    PUBLIC_HTTP_ENABLED="true"
}

install_base_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=1800 update
        apt-get -o DPkg::Lock::Timeout=1800 install -y ca-certificates coreutils curl git
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates coreutils curl git
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates coreutils curl git
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates coreutils curl git
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm ca-certificates coreutils curl git
    elif command -v zypper >/dev/null 2>&1; then
        zypper refresh
        zypper -q install -y ca-certificates coreutils curl git
    else
        fail "Unsupported package manager / 不支持的包管理器"
    fi
}

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        is_zh && log "正在安装 Docker" || log "Installing Docker"
        curl -fsSL https://get.docker.com -o /tmp/x-mili-get-docker.sh
        sh /tmp/x-mili-get-docker.sh
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
    fi
    docker info >/dev/null 2>&1 || fail "Docker daemon is not running / Docker 服务未运行"
    docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is missing / 缺少 docker compose 插件"
}

prepare_tun() {
    mkdir -p /dev/net
    if [[ ! -c /dev/net/tun ]]; then
        mknod /dev/net/tun c 10 200
    fi
    chmod 600 /dev/net/tun
}

prepare_source() {
    mkdir -p "${INSTALL_ROOT}" "${CERT_DIR}" "${ACME_DIR}"
    install -d -m 0700 "${DATA_DIR}"
    chmod 0700 "${DATA_DIR}"
    find "${DATA_DIR}" -maxdepth 1 -type f \
        \( -name 'x-ui.db' -o -name 'x-ui.db-wal' -o -name 'x-ui.db-shm' -o -name 'x-ui.db-journal' \) \
        -exec chmod 0600 {} + 2>/dev/null || true
    chmod 0700 "${ACME_DIR}"
    if [[ -d "${SRC_DIR}/.git" ]]; then
        git -C "${SRC_DIR}" remote set-url origin "${REPO}"
        git -C "${SRC_DIR}" fetch --depth=1 origin "${SOURCE_REF}"
        git -C "${SRC_DIR}" reset --hard FETCH_HEAD
    else
        rm -rf "${SRC_DIR}"
        git clone --depth=1 --branch "${SOURCE_REF}" --single-branch "${REPO}" "${SRC_DIR}"
    fi
}

write_compose() {
    DOCKER_COMPOSE_WRITE_TEMP=$(mktemp "${INSTALL_ROOT}/.docker-compose.XXXXXX")
    cat > "${DOCKER_COMPOSE_WRITE_TEMP}" <<EOF
x-x-mili-auto-open-firewall: "${AUTO_OPEN_FIREWALL}"

services:
  ml:
    build:
      context: ${SRC_DIR}
      dockerfile: Dockerfile
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    volumes:
      - ${DATA_DIR}:/etc/x-ui
      - ${CERT_DIR}:/root/cert
      - ${ACME_DIR}:/root/.acme.sh
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
      XUI_ENABLE_FAIL2BAN: "false"
      XUI_ALLOW_INSECURE_HTTP: "${PUBLIC_HTTP_ENABLED}"
      XUI_MAIN_FOLDER: "/app"
      XUI_DB_FOLDER: "/etc/x-ui"
      X_MILI_ACME_HOME: "/root/.acme.sh"
      X_MILI_LANG: "${X_MILI_LANG}"
    tty: true
    # Xray/WARP/VPNGate need host networking and /dev/net/tun; this intentionally trades container isolation for VPN routing.
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    restart: unless-stopped
EOF
    chmod 0600 "${DOCKER_COMPOSE_WRITE_TEMP}"
    mv -f -- "${DOCKER_COMPOSE_WRITE_TEMP}" "${COMPOSE_FILE}"
    DOCKER_COMPOSE_WRITE_TEMP=""
}

compose() {
    docker compose -f "${COMPOSE_FILE}" "$@"
}

exec_container() {
    if [[ -t 0 ]]; then
        docker exec -it "${CONTAINER_NAME}" "$@"
    else
        docker exec "${CONTAINER_NAME}" "$@"
    fi
}

gen_random_string() {
    local length="$1"
    local value=""
    while (( ${#value} < length )); do
        value+=$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    done
    printf '%s' "${value:0:length}"
}

save_initial_credentials() {
    local recovery_file="${DATA_DIR}/.x-mili-initial-credentials" temporary
    temporary=$(mktemp "${recovery_file}.XXXXXX")
    {
        printf 'username: %s\n' "${panel_username}"
        printf 'password: %s\n' "${panel_password}"
        printf 'port: %s\n' "${panel_port}"
        printf 'webBasePath: %s\n' "${panel_web_path}"
    } > "${temporary}"
    chown root:root "${temporary}"
    chmod 0600 "${temporary}"
    mv -f -- "${temporary}" "${recovery_file}"
}

show_recovery_credentials() {
    local recovery_file="${DATA_DIR}/.x-mili-initial-credentials"
    [[ -f "${recovery_file}" && ! -L "${recovery_file}" ]] || return 1
    echo -e "初始登录恢复信息（仅本次安装保留）:"
    sed 's/^/  /' "${recovery_file}"
}

normalize_web_path() {
    local path="$1"
    [[ -n "${path}" ]] || path="/"
    [[ "${path}" == /* ]] || path="/${path}"
    [[ "${path}" == */ ]] || path="${path}/"
    echo "${path}"
}

validate_initial_credentials() {
    [[ "${panel_username}" =~ ^[A-Za-z0-9._-]{3,64}$ ]] \
        || fail "Panel username must be 3-64 characters using A-Z, a-z, 0-9, dot, underscore, or hyphen / 面板账号须为 3-64 位字母、数字、点、下划线或连字符"
    (( ${#panel_password} >= 12 && ${#panel_password} <= 128 )) \
        || fail "Panel password must be 12-128 characters / 面板密码须为 12-128 位"
    [[ "${panel_password}" != *[[:space:]]* ]] \
        || fail "Panel password must not contain whitespace / 面板密码不能包含空白字符"
    [[ "${panel_web_path}" == /* && "${panel_web_path}" != *[[:space:]]* ]] \
        || fail "Panel web path must start with / and contain no whitespace / 面板路径必须以 / 开头且不能包含空白字符"
}

extract_setting() {
    local info="$1"
    local key="$2"
    echo "${info}" | awk -v k="${key}:" '$1 == k {print $2; exit}'
}

container_setting() {
    docker exec "${CONTAINER_NAME}" /app/x-ui setting "$@" 2>/dev/null
}

panel_needs_initialization() {
    local info
    info=$(container_setting -show true) || return 2
    if echo "${info}" | grep -Eq "bootstrapPending: true|hasDefaultCredential: true"; then
        return 0
    fi
    if echo "${info}" | grep -Eq "bootstrapPending: false|hasDefaultCredential: false"; then
        return 1
    fi
    return 2
}

wait_for_panel_cli() {
    local checks_left=30
    while ((checks_left-- > 0)); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]] \
            && container_setting -show true >/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

verify_docker_panel() {
    local checks_left=5 info port
    info=$(container_setting -show true) || return 1
    port=$(extract_setting "${info}" "port")
    valid_panel_port "${port}" || return 1
    while ((checks_left-- > 0)); do
        [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]] || return 1
        docker exec "${CONTAINER_NAME}" ss -ltnH 2>/dev/null \
            | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit !found}' \
            || return 1
        sleep 1
    done
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
        if valid_panel_port "${panel_port}"; then
            return
        fi
        is_zh && warn "端口必须是 1-65535" || warn "Port must be 1-65535"
    done
}

init_panel_settings() {
    local bootstrap_status container_password_file
    panel_credentials_initialized=0
    if panel_needs_initialization; then
        :
    else
        bootstrap_status=$?
        if [[ "${bootstrap_status}" == "1" ]]; then
            is_zh && log "检测到已有非默认面板账号，保留现有登录信息" || log "Existing non-default panel account detected, keeping current login"
            return 0
        fi
        fail "无法读取面板初始化状态，拒绝修改现有凭据 / Could not determine bootstrap state; refusing to change credentials"
    fi

    local info current_port
    info=$(container_setting -show true)
    current_port=$(extract_setting "${info}" "port")
    current_port="${current_port:-2053}"

    panel_username="${X_MILI_USERNAME:-}"
    panel_password="${X_MILI_PASSWORD:-}"
    panel_web_path="${X_MILI_WEB_BASE_PATH:-}"
    panel_port="${X_MILI_PANEL_PORT:-}"

    if [[ -t 0 ]]; then
        echo ""
        if is_zh; then
            echo -e "${green}Docker 首次安装向导：直接回车将随机生成，更安全。${plain}"
            read -rp "请设置登录面板的账号 [随机]: " panel_username
            read -rsp "请设置登录面板的密码 [随机]: " panel_password
            echo
            [[ -n "${X_MILI_PANEL_PORT:-}" ]] || read_panel_port "${current_port}"
            read -rp "请设置登录面板的安全后缀 [随机，例如 /$(gen_random_string 8)/]: " panel_web_path
        else
            echo -e "${green}Docker first-time setup: press Enter to generate secure random values.${plain}"
            read -rp "Panel username [random]: " panel_username
            read -rsp "Panel password [random]: " panel_password
            echo
            [[ -n "${X_MILI_PANEL_PORT:-}" ]] || read_panel_port "${current_port}"
            read -rp "Panel secure URL suffix [random, e.g. /$(gen_random_string 8)/]: " panel_web_path
        fi
    fi

    panel_username="${panel_username:-$(gen_random_string 10)}"
    panel_password="${panel_password:-$(gen_random_string 18)}"
    panel_web_path="${panel_web_path:-$(gen_random_string 18)}"
    panel_web_path=$(normalize_web_path "${panel_web_path}")
    panel_port="${panel_port:-$current_port}"
    valid_panel_port "${panel_port}" \
        || fail "Panel port must be between 1 and 65535 / 面板端口必须为 1-65535"
    validate_initial_credentials
    save_initial_credentials

    PANEL_PASSWORD_FILE=$(mktemp "${DATA_DIR}/.x-mili-password.XXXXXX")
    chown root:root "${PANEL_PASSWORD_FILE}"
    chmod 0600 "${PANEL_PASSWORD_FILE}"
    printf '%s' "${panel_password}" > "${PANEL_PASSWORD_FILE}"
    container_password_file="/etc/x-ui/$(basename "${PANEL_PASSWORD_FILE}")"
    if ! docker exec "${CONTAINER_NAME}" /app/x-ui setting \
        -username "${panel_username}" \
        -password-file "${container_password_file}" \
        -port "${panel_port}" \
        -resetTwoFactor true >/dev/null; then
        cleanup_panel_password_file
        return 1
    fi
    cleanup_panel_password_file
    docker exec "${CONTAINER_NAME}" /app/x-ui setting -webBasePath "${panel_web_path}" >/dev/null
    docker restart "${CONTAINER_NAME}" >/dev/null
    panel_credentials_initialized=1
}

configure_panel_exposure() {
    local cert listen_target

    cert=$(container_setting -getCert true | awk -F': ' '/^cert:/ {print $2; exit}' | tr -d '[:space:]')
    [[ -z "${cert}" ]] || return 0

    # Existing installs are not changed unless the operator supplied an override.
    if [[ "${panel_credentials_initialized:-0}" != "1" && "${PUBLIC_HTTP_EXPLICIT}" != "1" ]]; then
        return 0
    fi

    if [[ "${PUBLIC_HTTP_ENABLED}" == "true" ]]; then
        listen_target="0.0.0.0"
    else
        listen_target="127.0.0.1"
    fi

    docker exec "${CONTAINER_NAME}" /app/x-ui setting -listenIP "${listen_target}" >/dev/null
    docker restart "${CONTAINER_NAME}" >/dev/null
}

is_ipv4() {
    local ip="$1" octet
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "${ip}"
    for octet in "${octets[@]}"; do
        ((10#${octet} <= 255)) || return 1
    done
}

get_server_ip() {
    local endpoint ip
    for endpoint in https://api.ipify.org https://4.ident.me https://ipv4.icanhazip.com; do
        ip=$(curl -4fsS --max-time 4 "${endpoint}" 2>/dev/null | tr -d '[:space:]' || true)
        if is_ipv4 "${ip}"; then
            echo "${ip}"
            return 0
        fi
    done
    echo "服务器公网IP"
}

write_host_menu() {
    DOCKER_HOST_MENU_TEMP=$(mktemp /usr/bin/.x-mili-ml.XXXXXX)
    cat > "${DOCKER_HOST_MENU_TEMP}" <<'EOF'
#!/usr/bin/env bash
# X-MILI Docker management wrapper (generated; do not repurpose this path).
set -euo pipefail

ROOT="/opt/x-mili-docker"
SOURCE_DIR="/opt/x-mili-docker/src"
SOURCE_REF="main"
COMPOSE_FILE="${ROOT}/docker-compose.yml"
CONTAINER="ml_app"
DATA_DIR="/etc/x-ui"
CERT_DIR="/root/cert"
ACME_DIR="/opt/x-mili-docker/acme"
IMAGE_NAME="x-mili:latest"
REPO="https://github.com/2019563552abc/X-MILI"
RAW_BASE="https://raw.githubusercontent.com/2019563552abc/X-MILI/main"
RAW_INSTALL="${X_MILI_RAW_BASE:-${RAW_BASE}}/install-docker.sh"

green='\033[0;32m'
yellow='\033[0;33m'
red='\033[0;31m'
plain='\033[0m'

compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }

exec_container() {
    if [[ -t 0 ]]; then
        docker exec -it "${CONTAINER}" "$@"
    else
        docker exec "${CONTAINER}" "$@"
    fi
}

need_compose() {
    [[ -f "${COMPOSE_FILE}" ]] || { echo -e "${red}Docker 版 X-MILI 未安装。${plain}"; exit 1; }
}

safe_remove_root() {
    local resolved
    [[ ! -L "${ROOT}" ]] || { echo -e "${red}拒绝删除符号链接目录：${ROOT}${plain}" >&2; return 1; }
    resolved=$(realpath -m -- "${ROOT}") || return 1
    [[ "${resolved}" == /opt/x-mili || "${resolved}" == /opt/x-mili-* ]] \
        || { echo -e "${red}拒绝删除非 X-MILI 受管目录：${resolved}${plain}" >&2; return 1; }
    rm -rf -- "${resolved}"
}

sync_http_mode() {
    local http_marker="${DATA_DIR}/.x-mili-http-mode"
    local renewal_marker="${DATA_DIR}/.x-mili-acme-renewal"
    local mode renewal temporary attempt needs_recreate=0 renewal_ready=0

    if [[ -f "${http_marker}" ]]; then
        mode=$(tr -d '[:space:]' < "${http_marker}")
        [[ "${mode}" == "true" || "${mode}" == "false" ]] \
            || { echo -e "${red}无效的 HTTP 模式标记：${mode}${plain}" >&2; return 1; }
        grep -q '^[[:space:]]*XUI_ALLOW_INSECURE_HTTP:' "${COMPOSE_FILE}" \
            || { echo -e "${red}Compose 缺少 XUI_ALLOW_INSECURE_HTTP。${plain}" >&2; return 1; }
        temporary=$(mktemp "${COMPOSE_FILE}.XXXXXX")
        awk -v mode="${mode}" '
            /^[[:space:]]*XUI_ALLOW_INSECURE_HTTP:/ {
                sub(/:.*/, ": \"" mode "\"")
            }
            { print }
        ' "${COMPOSE_FILE}" > "${temporary}"
        chmod --reference="${COMPOSE_FILE}" "${temporary}" 2>/dev/null || chmod 0600 "${temporary}"
        chown --reference="${COMPOSE_FILE}" "${temporary}" 2>/dev/null || true
        mv -f -- "${temporary}" "${COMPOSE_FILE}"
        needs_recreate=1
    fi

    if [[ -f "${renewal_marker}" ]]; then
        renewal=$(tr -d '[:space:]' < "${renewal_marker}")
        [[ "${renewal}" == "true" ]] \
            || { echo -e "${red}无效的续签调度标记：${renewal}${plain}" >&2; return 1; }
        needs_recreate=1
    fi
    [[ "${needs_recreate}" == "1" ]] || return 0

    compose up -d --force-recreate
    if [[ -f "${renewal_marker}" ]]; then
        for attempt in {1..10}; do
            if docker exec "${CONTAINER}" sh -c \
                'test -x "$X_MILI_ACME_HOME/acme.sh" && test -s /var/spool/cron/crontabs/root && ps | grep -q "[c]rond"' 2>/dev/null; then
                renewal_ready=1
                break
            fi
            sleep 1
        done
        [[ "${renewal_ready}" == "1" ]] \
            || { echo -e "${red}容器 ACME 自动续签任务未能启动；状态标记已保留。${plain}" >&2; return 1; }
        rm -f -- "${renewal_marker}"
    fi
    rm -f -- "${http_marker}"
}

update_install() {
    local updater raw_base rc=0
    updater=$(mktemp /tmp/x-mili-docker-update.XXXXXX)
    if ! curl -fsSL "${RAW_INSTALL}" -o "${updater}"; then
        rm -f -- "${updater}"
        return 1
    fi
    raw_base="${RAW_INSTALL%/install-docker.sh}"
    if env \
        X_MILI_REPO="${REPO}" \
        X_MILI_RAW_BASE="${raw_base}" \
        X_MILI_DOCKER_ROOT="${ROOT}" \
        X_MILI_DOCKER_SOURCE_DIR="${SOURCE_DIR}" \
        X_MILI_DOCKER_REF="${SOURCE_REF}" \
        X_MILI_DOCKER_DATA_DIR="${DATA_DIR}" \
        X_MILI_DOCKER_CERT_DIR="${CERT_DIR}" \
        X_MILI_DOCKER_ACME_DIR="${ACME_DIR}" \
        X_MILI_DOCKER_CONTAINER="${CONTAINER}" \
        X_MILI_DOCKER_IMAGE="${IMAGE_NAME}" \
        bash "${updater}"; then
        rc=0
    else
        rc=$?
    fi
    rm -f -- "${updater}"
    return "${rc}"
}

show_menu() {
    while true; do
        echo -e "
╔──────────────────────────────────────────────╗
│   ${green}X-MILI Docker 管理菜单${plain}                    │
│   ${green}1.${plain} 启动容器                               │
│   ${green}2.${plain} 停止容器                               │
│   ${green}3.${plain} 重启面板                               │
│   ${green}4.${plain} 重启 Xray                              │
│   ${green}5.${plain} 查看状态                               │
│   ${green}6.${plain} 查看面板设置                           │
│   ${green}7.${plain} 查看日志                               │
│   ${green}8.${plain} 进入容器 Shell                         │
│   ${green}9.${plain} 更新 Docker 版                         │
│  ${green}10.${plain} 卸载 Docker 版                         │
│  ${green}11.${plain} SSL 证书管理                           │
│   ${green}0.${plain} 退出                                   │
╚──────────────────────────────────────────────╝"
        read -rp "请输入选项 [0-11]: " num
        case "${num}" in
            1) ml start ;;
            2) ml stop ;;
            3) ml restart ;;
            4) ml restart-xray ;;
            5) ml status ;;
            6) ml settings ;;
            7) ml log ;;
            8) ml shell ;;
            9) ml update ;;
            10) ml uninstall ;;
            11) ml ssl ;;
            0) exit 0 ;;
            *) echo -e "${red}无效选项${plain}" ;;
        esac
    done
}

if [[ -f "${COMPOSE_FILE}" ]] \
    && [[ -f "${DATA_DIR}/.x-mili-http-mode" || -f "${DATA_DIR}/.x-mili-acme-renewal" ]]; then
    sync_http_mode
fi

case "${1:-menu}" in
    menu)
        need_compose
        show_menu
        ;;
    start)
        need_compose
        compose up -d
        ;;
    stop)
        need_compose
        compose stop
        ;;
    restart)
        need_compose
        compose restart
        ;;
    restart-xray)
        docker kill -s USR1 "${CONTAINER}" >/dev/null
        echo "Xray restart signal sent."
        ;;
    status)
        need_compose
        compose ps
        docker exec "${CONTAINER}" /app/x-ui setting -show true 2>/dev/null || true
        ;;
    settings)
        exec_container /app/x-ui setting -show true
        ;;
    log|logs)
        docker logs -f --tail=200 "${CONTAINER}"
        ;;
    shell)
        exec_container sh
        ;;
    exec)
        shift
        exec_container "$@"
        ;;
    update)
        update_install
        ;;
    ssl)
        need_compose
        shift
        ssl_rc=0
        trap 'sync_http_mode || true' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM HUP
        exec_container /usr/bin/ml ssl "$@" || ssl_rc=$?
        sync_http_mode
        trap - EXIT INT TERM HUP
        exit "${ssl_rc}"
        ;;
    uninstall)
        need_compose
        read -rp "确定卸载 Docker 版 X-MILI？数据目录 /etc/x-ui 会保留 [y/N]: " yn
        [[ "${yn}" == "y" || "${yn}" == "Y" ]] || exit 0
        compose down
        safe_remove_root
        rm -f /usr/bin/ml
        echo "已卸载 Docker 版 X-MILI，数据目录 /etc/x-ui 已保留。"
        ;;
    *)
        exec_container /app/x-ui "$@"
        ;;
esac
EOF
    chmod 0755 "${DOCKER_HOST_MENU_TEMP}"
    sed -i \
        -e "s|ROOT=\"/opt/x-mili-docker\"|ROOT=\"${INSTALL_ROOT}\"|" \
        -e "s|SOURCE_DIR=\"/opt/x-mili-docker/src\"|SOURCE_DIR=\"${SRC_DIR}\"|" \
        -e "s|SOURCE_REF=\"main\"|SOURCE_REF=\"${SOURCE_REF}\"|" \
        -e "s|CONTAINER=\"ml_app\"|CONTAINER=\"${CONTAINER_NAME}\"|" \
        -e "s|DATA_DIR=\"/etc/x-ui\"|DATA_DIR=\"${DATA_DIR}\"|" \
        -e "s|CERT_DIR=\"/root/cert\"|CERT_DIR=\"${CERT_DIR}\"|" \
        -e "s|ACME_DIR=\"/opt/x-mili-docker/acme\"|ACME_DIR=\"${ACME_DIR}\"|" \
        -e "s|IMAGE_NAME=\"x-mili:latest\"|IMAGE_NAME=\"${IMAGE_NAME}\"|" \
        -e "s|REPO=\"https://github.com/2019563552abc/X-MILI\"|REPO=\"${REPO}\"|" \
        -e "s|RAW_BASE=\"https://raw.githubusercontent.com/2019563552abc/X-MILI/main\"|RAW_BASE=\"${RAW_BASE}\"|" \
        -e "s|数据目录 /etc/x-ui 会保留|数据目录 ${DATA_DIR} 会保留|" \
        -e "s|数据目录 /etc/x-ui 已保留|数据目录 ${DATA_DIR} 已保留|" \
        "${DOCKER_HOST_MENU_TEMP}"
    mv -f -- "${DOCKER_HOST_MENU_TEMP}" /usr/bin/ml
    DOCKER_HOST_MENU_TEMP=""
}

save_installer_copy() {
    local invocation_name target="${INSTALL_ROOT}/install-docker.sh"
    invocation_name=$(basename "$0")

    if [[ -f "$0" && ! -L "$0" \
        && ( "${invocation_name}" == "install-docker.sh" \
            || "${invocation_name}" == x-mili-docker-update.* ) \
        && "$(realpath -m -- "$0")" == "$(realpath -m -- "${target}")" ]]; then
        chmod 0755 "${target}"
        return 0
    fi

    DOCKER_INSTALLER_WRITE_TEMP=$(mktemp "${INSTALL_ROOT}/.install-docker.XXXXXX")
    if [[ -f "$0" && ! -L "$0" \
        && ( "${invocation_name}" == "install-docker.sh" \
            || "${invocation_name}" == x-mili-docker-update.* ) ]]; then
        install -m 0755 "$0" "${DOCKER_INSTALLER_WRITE_TEMP}"
    else
        curl -fsSL "${RAW_BASE}/install-docker.sh" -o "${DOCKER_INSTALLER_WRITE_TEMP}"
        chmod 0755 "${DOCKER_INSTALLER_WRITE_TEMP}"
    fi
    mv -f -- "${DOCKER_INSTALLER_WRITE_TEMP}" "${target}"
    DOCKER_INSTALLER_WRITE_TEMP=""
}

print_guide() {
    local info port web_path server_ip cert protocol listen_ip public_http=0 direct_public=0
    info=$(container_setting -show true)
    port=$(extract_setting "${info}" "port")
    web_path=$(extract_setting "${info}" "webBasePath")
    port="${port:-2053}"
    web_path=$(normalize_web_path "${web_path}")
    server_ip=$(get_server_ip)
    cert=$(container_setting -getCert true | awk -F': ' '/^cert:/ {print $2; exit}' | tr -d '[:space:]')
    listen_ip=$(container_setting -getListen true | awk -F': ' '/^listenIP:/ {print $2; exit}' | tr -d '[:space:]')
    [[ -n "${cert}" ]] && protocol="https" || protocol="http"
    [[ "${PUBLIC_HTTP_ENABLED}" == "true" ]] && public_http=1
    if [[ "${listen_ip}" == "0.0.0.0" || "${listen_ip}" == "::" || "${listen_ip}" == "[::]" ]]; then
        [[ -n "${cert}" || "${public_http}" == "1" ]] && direct_public=1
    fi
    if [[ "${direct_public}" != "1" ]]; then
        server_ip="127.0.0.1"
    fi

    echo ""
    echo -e "${green}================ X-MILI Docker 安装完成 ================${plain}"
    echo -e "管理命令: ${green}ml${plain}"
    echo -e "面板地址: ${green}${protocol}://${server_ip}:${port}${web_path}${plain}"
    if [[ "${panel_credentials_initialized:-0}" == "1" ]]; then
        echo -e "登录账号: ${green}${panel_username}${plain}"
        echo -e "登录密码: ${green}${panel_password}${plain}"
        echo -e "安全后缀: ${green}${web_path}${plain}"
    else
        if ! show_recovery_credentials; then
            echo -e "登录信息: ${yellow}已保留现有账号和密码${plain}"
        fi
    fi
    echo -e "数据目录: ${yellow}${DATA_DIR}${plain}"
    echo -e "容器名称: ${yellow}${CONTAINER_NAME}${plain}"
    if [[ -z "${cert}" && "${direct_public}" == "1" ]]; then
        echo -e "${red}当前为公网明文 HTTP，仅用于首次配置；请放行 TCP ${port} 后尽快运行 ml ssl 绑定域名证书。${plain}"
    elif [[ -z "${cert}" ]]; then
        echo -e "${yellow}面板当前仅限本机访问。可运行 ml ssl 配置证书，或显式设置 X_MILI_ALLOW_INSECURE_HTTP=true 后更新。${plain}"
    fi
    echo -e "${green}=========================================================${plain}"
    echo ""
}

trap 'docker_installer_on_exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT

choose_language
is_zh && log "开始安装/更新 Docker 版 ${APP_NAME}" || log "Installing/updating Docker ${APP_NAME}"
is_zh && step 1 6 "安装基础依赖" || step 1 6 "Installing base dependencies"
install_base_deps
validate_docker_paths
acquire_docker_install_lock
DOCKER_INSTALL_MARKER="${DATA_DIR}/.x-mili-docker-install-in-progress"
detect_docker_install_state
check_docker_install_conflicts
detect_existing_database_state
resolve_http_exposure
resolve_firewall_policy
is_zh && step 2 6 "安装并检查 Docker" || step 2 6 "Installing/checking Docker"
install_docker
check_docker_runtime_conflicts
begin_docker_update_transaction
install -d -m 0700 "${DATA_DIR}"
chown root:root "${DATA_DIR}"
DOCKER_INSTALL_MARKER_TEMP=$(mktemp "${DOCKER_INSTALL_MARKER}.XXXXXX")
printf 'pid=%s\nstarted=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${DOCKER_INSTALL_MARKER_TEMP}"
chmod 0600 "${DOCKER_INSTALL_MARKER_TEMP}"
mv -f -- "${DOCKER_INSTALL_MARKER_TEMP}" "${DOCKER_INSTALL_MARKER}"
DOCKER_INSTALL_MARKER_TEMP=""
is_zh && step 3 6 "准备 TUN 设备和项目源码" || step 3 6 "Preparing TUN device and source"
prepare_tun
prepare_source
is_zh && step 4 6 "写入 Docker Compose 配置" || step 4 6 "Writing Docker Compose config"
write_compose
save_installer_copy
is_zh && step 5 6 "构建并启动容器" || step 5 6 "Building and starting container"
is_zh && warn "Docker 版会使用 host 网络和 TUN 设备，以支持 Xray/WARP/VPNGate 路由" || warn "Docker uses host network and TUN for Xray/WARP/VPNGate routing"
compose build
backup_docker_database_for_update
compose up -d --no-build
wait_for_panel_cli \
    || fail "容器未能启动面板 CLI；安装标记和初始凭据恢复文件已保留 / Container panel startup failed; recovery state was kept"
is_zh && step 6 6 "写入主机 ml 菜单并初始化面板" || step 6 6 "Writing host ml menu and initializing panel"
write_host_menu
init_panel_settings
configure_panel_exposure
verify_docker_panel \
    || fail "容器面板未能持续运行或监听配置端口；恢复状态已保留 / Docker panel health verification failed; recovery state was kept"
configure_host_firewall
print_guide
rm -f -- "${DATA_DIR}/.x-mili-initial-credentials"
rm -f -- "${DOCKER_INSTALL_MARKER}"
finalize_docker_installation

if [[ "${panel_credentials_initialized:-0}" == "1" && -t 0 ]]; then
    /usr/bin/ml
fi
