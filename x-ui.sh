#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

app_name="X-MILI"
repo_raw_base="${X_MILI_RAW_BASE:=https://raw.githubusercontent.com/2019563552abc/X-MILI/main}"
lang_file="${X_MILI_LANG_FILE:=/etc/x-mili/lang}"

load_language() {
    if [[ -z "$X_MILI_LANG" && -f "$lang_file" ]]; then
        X_MILI_LANG=$(cat "$lang_file")
    fi
}

is_zh() {
    [[ "$X_MILI_LANG" == "zh_CN" ]]
}

choose_language() {
    load_language
    [[ -n "$X_MILI_LANG" ]] && return
    echo -e "${green}1.${plain} English"
    echo -e "${green}2.${plain} 简体中文"
    read -rp "Please choose language / 请选择语言 [1-2]: " lang_choice
    if [[ "$lang_choice" == "2" ]]; then
        X_MILI_LANG="zh_CN"
    else
        X_MILI_LANG="en_US"
    fi
    mkdir -p "$(dirname "$lang_file")"
    echo "$X_MILI_LANG" > "$lang_file"
}

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# Port helpers: detect listener and owning process (best effort)
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltnH 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

# Simple helpers for domain/IP validation
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

load_language

# check root
if [[ $EUID -ne 0 ]]; then
    is_zh && LOGE "错误：请使用 root 运行此脚本！\n" || LOGE "ERROR: You must be root to run this script! \n"
    exit 1
fi

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    if is_zh; then
        echo "检测系统发行版失败，请联系维护者！" >&2
    else
        echo "Failed to check the system OS, please contact the author!" >&2
    fi
    exit 1
fi
is_zh && echo "系统发行版: $release" || echo "The OS release is: $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

# Declare Variables
xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
if [[ ! -x "${xui_folder}/x-ui" && -x /app/x-ui ]]; then
    xui_folder="/app"
fi
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    local default_label="Default"
    is_zh && default_label="默认"
    if [[ $# -gt 1 ]]; then
        echo && read -rp "$1 [${default_label} $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    if is_zh; then
        confirm "是否重启面板？注意：重启面板也会重启 Xray" "y"
    else
        confirm "Restart the panel, Attention: Restarting the panel will also restart xray" "y"
    fi
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    if is_zh; then
        echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read -r temp
    else
        echo && echo -n -e "${yellow}Press enter to return to the main menu: ${plain}" && read -r temp
    fi
    show_menu
}

install() {
    bash <(curl -Ls "${repo_raw_base}/install.sh")
}

update() {
    if [[ -n "${X_MILI_DEPLOY_ROOT:-}" ]]; then
        if [[ -x "${xui_folder}/deploy.sh" ]]; then
            exec "${xui_folder}/deploy.sh" --update "$@"
        fi
        LOGE "Managed deployment script is missing: ${xui_folder}/deploy.sh"
        return 1
    fi
    bash <(curl -Ls "${repo_raw_base}/update.sh") "$@"
}

update_menu() {
    if [[ -n "${X_MILI_DEPLOY_ROOT:-}" ]]; then
        if [[ -x "${xui_folder}/deploy.sh" ]]; then
            exec "${xui_folder}/deploy.sh" --update
        fi
        LOGE "Managed deployment script is missing: ${xui_folder}/deploy.sh"
        return 1
    fi
    curl -fLRo /usr/bin/ml "${repo_raw_base}/x-ui.sh"
    chmod +x /usr/bin/ml 2> /dev/null || true
    if [[ $? == 0 ]]; then
        is_zh && LOGI "$app_name 菜单更新完成。请重新运行 ml。" || LOGI "$app_name menu updated. Please rerun ml."
    else
        is_zh && LOGE "更新 $app_name 菜单失败。" || LOGE "Failed to update $app_name menu."
        return 1
    fi
}

# Function to handle the deletion of the script file
delete_script() {
    rm -f /usr/bin/ml /usr/bin/x-ui
    exit 0
}

uninstall() {
    if [[ -n "${X_MILI_DEPLOY_ROOT:-}" ]]; then
        if [[ -x "${xui_folder}/deploy.sh" ]]; then
            exec "${xui_folder}/deploy.sh" --uninstall
        fi
        LOGE "Managed deployment script is missing: ${xui_folder}/deploy.sh"
        return 1
    fi
    if is_zh; then
        confirm "确定要彻底卸载面板吗？面板数据、Xray、VPNGate/OpenVPN、证书和日志都会清理。" "n"
    else
        confirm "Fully uninstall the panel? Panel data, Xray, VPNGate/OpenVPN, certificates and logs will be removed." "n"
    fi
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    local uninstall_acme_bin="${X_MILI_ACME_BIN:-/root/.acme.sh/acme.sh}"
    local uninstall_acme_home="${X_MILI_ACME_HOME:-/root/.acme.sh}"
    if [[ -x "$uninstall_acme_bin" ]]; then
        "$uninstall_acme_bin" --home "$uninstall_acme_home" --uninstall-cronjob > /dev/null 2>&1 || true
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop 2> /dev/null || true
        rc-update del x-ui 2> /dev/null || true
        rm /etc/init.d/x-ui -f
    else
        systemctl disable --now x-mili-acme-renew.timer 2> /dev/null || true
        systemctl stop x-ui 2> /dev/null || true
        systemctl disable x-ui 2> /dev/null || true
        rm ${xui_service}/x-ui.service -f
        rm /etc/systemd/system/x-ui.service -f
        rm -f /etc/systemd/system/x-mili-acme-renew.service /etc/systemd/system/x-mili-acme-renew.timer
        systemctl daemon-reload
        systemctl reset-failed
    fi

    # Kill running panel, OpenVPN and Xray instances
    pkill -9 x-ui 2>/dev/null || true
    pkill -9 openvpn 2>/dev/null || true
    pkill -9 openvpn3 2>/dev/null || true
    pkill -9 xray 2>/dev/null || true
    pkill -9 xray-linux 2>/dev/null || true

    # Uninstall OpenVPN package installed for VPNGate
    if command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y openvpn openvpn3 >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y openvpn openvpn3 >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y openvpn openvpn3 >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk del openvpn openvpn3 >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Rns --noconfirm openvpn openvpn3 >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper -q remove -y openvpn openvpn3 >/dev/null 2>&1 || true
    fi

    rm /etc/x-ui/ -rf
    rm /etc/x-mili/ -rf
    rm /var/log/x-ui/ -rf
    rm /root/cert/ -rf
    rm /root/.acme.sh/ -rf
    case "$xui_folder" in
        /usr/local/*|/opt/*) rm -rf -- "${xui_folder:?}/" ;;
        /app) : ;; # Docker program files belong to the image and host wrapper.
        *) LOGE "Refusing to remove unsafe program directory: $xui_folder"; return 1 ;;
    esac
    rm -rf /usr/local/etc/x-ui /var/lib/x-ui /tmp/x-mili-* /tmp/vpngate-check-*.ovpn

    if [ -d "/etc/fail2ban" ]; then
        rm -f /etc/fail2ban/filter.d/3x-ipl.conf
        rm -f /etc/fail2ban/action.d/3x-ipl.conf
        rm -f /etc/fail2ban/jail.d/3x-ipl.conf
        systemctl restart fail2ban >/dev/null 2>&1 || true
    fi

    rm -f /usr/bin/ml /usr/bin/x-ui

    echo ""
    if is_zh; then
        echo -e "卸载完成。\n"
        echo "重新安装: bash <(curl -Ls ${repo_raw_base}/install.sh)"
    else
        echo -e "Uninstalled Successfully.\n"
        echo "Reinstall with: bash <(curl -Ls ${repo_raw_base}/install.sh)"
    fi
    echo ""
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    if is_zh; then
        confirm "确定要重置面板用户名和密码吗？" "n"
    else
        confirm "Are you sure to reset the username and password of the panel?" "n"
    fi
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if is_zh; then
        read -rp "请输入登录用户名 [留空则随机生成]: " config_account
    else
        read -rp "Please set the login username [default is a random username]: " config_account
    fi
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    if is_zh; then
        read -rp "请输入登录密码 [留空则随机生成]: " config_password
    else
        read -rp "Please set the login password [default is a random password]: " config_password
    fi
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    if is_zh; then
        read -rp "是否关闭当前已配置的两步验证？(y/n): " twoFactorConfirm
    else
        read -rp "Do you want to disable currently configured two-factor authentication? (y/n): " twoFactorConfirm
    fi
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor false > /dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor true > /dev/null 2>&1
        is_zh && echo -e "两步验证已关闭。" || echo -e "Two factor authentication has been disabled."
    fi

    if is_zh; then
        echo -e "面板登录用户名已重置为: ${green}${config_account}${plain}"
        echo -e "面板登录密码已重置为: ${green}${config_password}${plain}"
        echo -e "${green}请使用新的用户名和密码访问 ${app_name} 面板，并妥善保存。${plain}"
    else
        echo -e "Panel login username has been reset to: ${green} ${config_account} ${plain}"
        echo -e "Panel login password has been reset to: ${green} ${config_password} ${plain}"
        echo -e "${green} Please use the new login username and password to access the $app_name panel. Also remember them! ${plain}"
    fi
    confirm_restart
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

reset_webbasepath() {
    is_zh && echo -e "${yellow}正在重置面板访问路径${plain}" || echo -e "${yellow}Resetting Web Base Path${plain}"

    if is_zh; then
        read -rp "确定要重置面板访问路径吗？(y/n): " confirm
    else
        read -rp "Are you sure you want to reset the web base path? (y/n): " confirm
    fi
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        is_zh && echo -e "${yellow}操作已取消。${plain}" || echo -e "${yellow}Operation canceled.${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)

    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" > /dev/null 2>&1

    if is_zh; then
        echo -e "面板访问路径已重置为: ${green}/${config_webBasePath}/${plain}"
        echo -e "${green}请使用新的访问路径进入面板。${plain}"
    else
        echo -e "Web base path has been reset to: ${green}${config_webBasePath}${plain}"
        echo -e "${green}Please use the new web base path to access the panel.${plain}"
    fi
    restart
}

reset_config() {
    if is_zh; then
        confirm "确定要重置所有面板设置吗？账号数据不会丢失，用户名和密码不会改变" "n"
    else
        confirm "Are you sure you want to reset all panel settings, Account data will not be lost, Username and password will not change" "n"
    fi
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    is_zh && echo -e "所有面板设置已重置为默认值。" || echo -e "All panel settings have been reset to default."
    restart
}

check_config() {
    local info=$(${xui_folder}/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        is_zh && LOGE "获取当前设置失败，请检查日志" || LOGE "get current settings error, please check logs"
        show_menu
        return
    fi

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    local has_default_credential=$(echo "$info" | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local bootstrap_pending=$(echo "$info" | grep -Eo 'bootstrapPending: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
	local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local server_ip=$(curl -s --max-time 3 https://api.ipify.org)
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -s --max-time 3 https://4.ident.me)
    fi
    [[ -n "$server_ip" ]] || server_ip="服务器IP"
    if [[ -z "$existing_cert" && ( -z "$existing_listenIP" || "$existing_listenIP" == "127.0.0.1" || "$existing_listenIP" == "::1" || "$existing_listenIP" == "localhost" ) ]]; then
        server_ip="127.0.0.1"
    fi

    if is_zh; then
        echo -e "${green}当前面板设置:${plain}"
        echo -e "端口: ${green}${existing_port}${plain}"
        echo -e "访问路径: ${green}${existing_webBasePath}${plain}"
        if [[ "$has_default_credential" == "true" || "$bootstrap_pending" == "true" ]]; then
            echo -e "默认账号: ${red}是，请使用菜单 6 立即重置用户名和密码${plain}"
        else
            echo -e "默认账号: ${green}否${plain}"
        fi
    else
        LOGI "${info}"
    fi

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            is_zh && echo -e "${green}访问地址: https://${domain}:${existing_port}${existing_webBasePath}${plain}" || echo -e "${green}Access URL: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            is_zh && echo -e "${green}访问地址: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}" || echo -e "${green}Access URL: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
    else
        if is_zh; then
            echo -e "${yellow}访问地址: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}当前未配置 SSL。如需 HTTPS，请在菜单 19 中配置 SSL 证书。${plain}"
        else
            echo -e "${yellow}Access URL: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}No SSL certificate configured. Configure SSL via option 19 when needed.${plain}"
        fi
    fi
}

set_port() {
    if is_zh; then
        echo -n "请输入端口号 [1-65535]: "
    else
        echo -n "Enter port number[1-65535]: "
    fi
    read -r port
    if [[ -z "${port}" ]]; then
        is_zh && LOGD "已取消" || LOGD "Cancelled"
        before_show_menu
    else
        ${xui_folder}/x-ui setting -port ${port}
        if is_zh; then
            echo -e "端口已设置，请重启面板后使用新端口 ${green}${port}${plain} 访问 Web 面板"
        else
            echo -e "The port is set, Please restart the panel now, and use the new port ${green}${port}${plain} to access web panel"
        fi
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "Panel is running, No need to start again, If you need to restart, please select restart"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui Started Successfully"
        else
            LOGE "panel Failed to start, Probably because it takes longer than two seconds to start, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "Panel stopped, No need to stop again!"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "x-ui and xray stopped successfully"
        else
            LOGE "Panel stop failed, Probably because the stop time exceeds two seconds, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    local restart_rc=0
    if [[ -f /.dockerenv ]]; then
        # The image runs x-ui as PID 1. SIGHUP asks x-ui to reload both web
        # servers in-process, so an interactive docker exec session can verify
        # the new listener before returning.
        if kill -HUP 1 2> /dev/null; then
            sleep 3
            kill -0 1 2> /dev/null || restart_rc=1
        else
            restart_rc=1
        fi
    elif [[ $release == "alpine" ]] && command -v rc-service > /dev/null 2>&1; then
        rc-service x-ui restart || restart_rc=$?
    elif command -v systemctl > /dev/null 2>&1; then
        systemctl restart x-ui || restart_rc=$?
    else
        LOGE "No supported service manager was found."
        restart_rc=1
    fi

    if [[ $restart_rc -eq 0 ]]; then
        LOGI "x-ui and xray restarted successfully"
    else
        LOGE "Panel restart failed. Please check the service/container logs."
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
    return "$restart_rc"
}

xray_pid_snapshot() {
    local destination="$1" snapshot
    snapshot=$(ps -eo pid=,args= 2> /dev/null \
        | awk '$0 ~ /xray-linux/ && $0 ~ /(^|[[:space:]])-c[[:space:]]+([^[:space:]]*\/)?config\.json([[:space:]]|$)/ {printf "%s ", $1}')
    printf -v "$destination" '%s' "$snapshot"
}

restart_xray() {
    local restart_rc=1 attempt current_pids candidate_pids="" old_pid
    local old_still_running
    local old_pids="" max_attempts=8

    xray_pid_snapshot old_pids
    if systemctl reload x-ui; then
        # Reload is asynchronous. Do not accept the old child that may still be
        # alive immediately after the signal. A replacement PID must remain
        # healthy for two consecutive checks within the eight-second window.
        for ((attempt = 1; attempt <= max_attempts; attempt++)); do
            sleep 1
            current_pids=""
            if check_xray_status; then
                xray_pid_snapshot current_pids
                old_still_running=0
                for old_pid in $old_pids; do
                    if [[ " $current_pids" == *" $old_pid "* ]]; then
                        old_still_running=1
                        break
                    fi
                done
                if [[ -n "$current_pids" && $old_still_running -eq 0 ]]; then
                    if [[ "$current_pids" == "$candidate_pids" ]]; then
                        restart_rc=0
                        break
                    fi
                    candidate_pids="$current_pids"
                    continue
                fi
            fi
            candidate_pids=""
        done
    fi

    if [[ $restart_rc -eq 0 ]]; then
        LOGI "xray-core restarted successfully"
    else
        LOGE "xray-core restart failed. Inspect the service logs with: journalctl -u x-ui -e --no-pager"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
    return "$restart_rc"
}

status() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui default
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui Set to boot automatically on startup successfully"
    else
        LOGE "x-ui Failed to set Autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui Autostart Cancelled successfully"
    else
        LOGE "x-ui Failed to cancel autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -rp "Choose an option: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                grep -F 'x-ui[' /var/log/messages
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            *)
                echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
                show_log
                ;;
        esac
    else
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t2.${plain} Clear All logs"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -rp "Choose an option: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                journalctl -u x-ui -e --no-pager -f -p debug
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            2)
                sudo journalctl --rotate
                sudo journalctl --vacuum-time=1s
                echo "All Logs cleared."
                restart
                ;;
            *)
                echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
                show_log
                ;;
        esac
    fi
}

bbr_menu() {
    if is_zh; then
        echo -e "${green}\t1.${plain} 启用 BBR"
        echo -e "${green}\t2.${plain} 禁用 BBR"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice
    else
    echo -e "${green}\t1.${plain} Enable BBR"
    echo -e "${green}\t2.${plain} Disable BBR"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice
    fi
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            enable_bbr
            bbr_menu
            ;;
        2)
            disable_bbr
            bbr_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            bbr_menu
            ;;
    esac
}

disable_bbr() {

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]] || [[ ! $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        is_zh && echo -e "${yellow}当前未启用 BBR。${plain}" || echo -e "${yellow}BBR is not currently enabled.${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        old_settings=$(head -1 /etc/sysctl.d/99-bbr-x-ui.conf | tr -d '#')
        sysctl -w net.core.default_qdisc="${old_settings%:*}"
        sysctl -w net.ipv4.tcp_congestion_control="${old_settings#*:}"
        rm /etc/sysctl.d/99-bbr-x-ui.conf
        sysctl --system
    else
        # Replace BBR with CUBIC configurations
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sysctl -p
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        is_zh && echo -e "${green}BBR 已成功替换为 CUBIC。${plain}" || echo -e "${green}BBR has been replaced with CUBIC successfully.${plain}"
    else
        is_zh && echo -e "${red}无法将 BBR 替换为 CUBIC。请检查系统配置。${plain}" || echo -e "${red}Failed to replace BBR with CUBIC. Please check your system configuration.${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        is_zh && echo -e "${green}BBR 已经启用！${plain}" || echo -e "${green}BBR is already enabled!${plain}"
        before_show_menu
    fi

    # Enable BBR
    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        if [ -f "/etc/sysctl.conf" ]; then
            # Backup old settings from sysctl.conf, if any
            sed -i 's/^net.core.default_qdisc/# &/' /etc/sysctl.conf
            sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
        fi
        sysctl --system
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
        sysctl -p
    fi

    # Verify that BBR is enabled
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        is_zh && echo -e "${green}BBR 已成功启用。${plain}" || echo -e "${green}BBR has been enabled successfully.${plain}"
    else
        is_zh && echo -e "${red}启用 BBR 失败。请检查系统配置。${plain}" || echo -e "${red}Failed to enable BBR. Please check your system configuration.${plain}"
    fi
}

update_shell() {
    if [[ -n "${X_MILI_DEPLOY_ROOT:-}" ]]; then
        if [[ -x "${xui_folder}/deploy.sh" ]]; then
            exec "${xui_folder}/deploy.sh" --update
        fi
        LOGE "Managed deployment script is missing: ${xui_folder}/deploy.sh"
        return 1
    fi
    curl -fLRo /usr/bin/ml "${repo_raw_base}/x-ui.sh"
    chmod +x /usr/bin/ml 2> /dev/null || true
    is_zh && LOGI "$app_name 脚本更新完成。请重新运行 ml。" || LOGI "$app_name shell updated. Please rerun ml."
    before_show_menu
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ -f /.dockerenv && -x "${xui_folder}/x-ui" ]]; then
        kill -0 1 2> /dev/null && return 0
        return 1
    elif [[ $release == "alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        if [[ $(rc-service x-ui status | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f ${xui_service}/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ "${temp}" == "running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-update show | grep -F 'x-ui' | grep default -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ "${temp}" == "enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        is_zh && LOGE "面板已安装，请不要重复安装" || LOGE "Panel installed, Please do not reinstall"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        is_zh && LOGE "请先安装面板" || LOGE "Please install the panel first"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            if is_zh; then
                echo -e "面板状态: ${green}运行中${plain}"
            else
                echo -e "Panel state: ${green}Running${plain}"
            fi
            show_enable_status
            ;;
        1)
            if is_zh; then
                echo -e "面板状态: ${yellow}未运行${plain}"
            else
                echo -e "Panel state: ${yellow}Not Running${plain}"
            fi
            show_enable_status
            ;;
        2)
            if is_zh; then
                echo -e "面板状态: ${red}未安装${plain}"
            else
                echo -e "Panel state: ${red}Not Installed${plain}"
            fi
            ;;
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        if is_zh; then
            echo -e "开机自启: ${green}已开启${plain}"
        else
            echo -e "Start automatically: ${green}Yes${plain}"
        fi
    else
        if is_zh; then
            echo -e "开机自启: ${red}未开启${plain}"
        else
            echo -e "Start automatically: ${red}No${plain}"
        fi
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        if is_zh; then
            echo -e "Xray 状态: ${green}运行中${plain}"
        else
            echo -e "xray state: ${green}Running${plain}"
        fi
    else
        if is_zh; then
            echo -e "Xray 状态: ${red}未运行${plain}"
        else
            echo -e "xray state: ${red}Not Running${plain}"
        fi
    fi
}

firewall_require_ufw() {
    if command -v ufw > /dev/null 2>&1; then
        return 0
    fi

    if is_zh; then
        LOGE "未安装 UFW。请先选择 1 安装防火墙。"
    else
        LOGE "UFW is not installed. Select option 1 to install the firewall first."
    fi
    return 1
}

firewall_current_ssh_server_port() {
    local client_address client_port server_address server_port extra port_number
    IFS=' ' read -r client_address client_port server_address server_port extra \
        <<< "${SSH_CONNECTION:-}" || return 1
    [[ -n "$client_address" && -n "$client_port" && -n "$server_address" \
        && -z "$extra" && "$server_port" =~ ^[0-9]{1,5}$ ]] || return 1
    port_number=$((10#$server_port))
    ((port_number >= 1 && port_number <= 65535)) || return 1
    printf '%d\n' "$port_number"
}

firewall_list_rules() {
    firewall_require_ufw || return 1
    LC_ALL=C ufw status numbered
}

firewall_status() {
    firewall_require_ufw || return 1
    LC_ALL=C ufw status verbose
}

firewall_enable() {
    local ssh_port status confirmation
    firewall_require_ufw || return 1
    if ! ssh_port=$(firewall_current_ssh_server_port); then
        if is_zh; then
            LOGE "无法从 SSH_CONNECTION 检测并验证当前 SSH 服务端口；为避免断开远程连接，未启用防火墙。"
        else
            LOGE "Could not detect and validate the active SSH server port from SSH_CONNECTION; the firewall was not enabled."
        fi
        return 1
    fi

    if ! status=$(LC_ALL=C ufw status 2> /dev/null); then
        is_zh && LOGE "无法读取 UFW 状态。" || LOGE "Failed to read UFW status."
        return 1
    fi
    if grep -Eq '^Status:[[:space:]]*active[[:space:]]*$' <<< "$status"; then
        is_zh && echo "防火墙已启用。" || echo "Firewall is already active."
        return 0
    fi

    firewall_list_rules || return 1
    if is_zh; then
        echo "将自动放行当前 SSH 服务端口 ${ssh_port}/tcp，并完整保留现有 UFW 规则。"
        echo "脚本不会猜测面板、订阅或 Xray 入站端口；请确认上方规则已包含所有需要公网访问的端口。"
        read -rp "确认规则完整并继续启用？[y/N]: " confirmation
    else
        echo "The active SSH server port ${ssh_port}/tcp will be allowed and all existing UFW rules will be preserved."
        echo "Panel, subscription, and Xray inbound ports are not guessed; verify that every required public port appears above."
        read -rp "Are the rules complete, and should UFW be enabled? [y/N]: " confirmation
    fi
    case "$confirmation" in
        y|Y|yes|YES) ;;
        *)
            is_zh && echo "已取消，防火墙未启用。" || echo "Cancelled; the firewall was not enabled."
            return 1
            ;;
    esac

    if ! ufw allow "${ssh_port}/tcp"; then
        is_zh && LOGE "当前 SSH 端口放行失败，未启用防火墙。" \
            || LOGE "Failed to allow the active SSH port; the firewall was not enabled."
        return 1
    fi
    if ! ufw --force enable; then
        is_zh && LOGE "防火墙启用失败。" || LOGE "Failed to enable the firewall."
        return 1
    fi
}

firewall_disable() {
    firewall_require_ufw || return 1
    ufw disable
}

firewall_menu() {
    if is_zh; then
        echo -e "${green}\t1.${plain} ${green}安装${plain}防火墙"
        echo -e "${green}\t2.${plain} 查看端口列表"
        echo -e "${green}\t3.${plain} ${green}开放${plain}端口"
        echo -e "${green}\t4.${plain} ${red}删除${plain}端口规则"
        echo -e "${green}\t5.${plain} ${green}启用${plain}防火墙"
        echo -e "${green}\t6.${plain} ${red}停用${plain}防火墙"
        echo -e "${green}\t7.${plain} 防火墙状态"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice
    else
    echo -e "${green}\t1.${plain} ${green}Install${plain} Firewall"
    echo -e "${green}\t2.${plain} Port List [numbered]"
    echo -e "${green}\t3.${plain} ${green}Open${plain} Ports"
    echo -e "${green}\t4.${plain} ${red}Delete${plain} Ports from List"
    echo -e "${green}\t5.${plain} ${green}Enable${plain} Firewall"
    echo -e "${green}\t6.${plain} ${red}Disable${plain} Firewall"
    echo -e "${green}\t7.${plain} Firewall Status"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice
    fi
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            install_firewall
            firewall_menu
            ;;
        2)
            firewall_list_rules
            firewall_menu
            ;;
        3)
            open_ports
            firewall_menu
            ;;
        4)
            delete_ports
            firewall_menu
            ;;
        5)
            firewall_enable
            firewall_menu
            ;;
        6)
            firewall_disable
            firewall_menu
            ;;
        7)
            firewall_status
            firewall_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            firewall_menu
            ;;
    esac
}

install_firewall() {
    if command -v ufw > /dev/null 2>&1; then
        is_zh && echo "UFW 已安装。" || echo "UFW is already installed."
        return 0
    fi

    if ! command -v apt-get > /dev/null 2>&1; then
        if is_zh; then
            LOGE "安装 UFW 需要 apt-get；当前系统未检测到受支持的包管理器。"
        else
            LOGE "apt-get is required to install UFW; no supported package manager was found."
        fi
        return 1
    fi

    is_zh && echo "未安装 UFW，正在安装..." \
        || echo "UFW is not installed. Installing now..."
    if ! apt-get update || ! apt-get install -y ufw; then
        if is_zh; then
            LOGE "UFW 安装失败，未修改防火墙规则。"
        else
            LOGE "Failed to install UFW; firewall rules were not changed."
        fi
        return 1
    fi
    hash -r
    firewall_require_ufw || return 1

    if is_zh; then
        echo "UFW 安装完成但尚未启用。请先开放当前 SSH 和所需服务端口，再选择 5 启用防火墙。"
    else
        echo "UFW is installed but not enabled. Open the active SSH and service ports before selecting option 5."
    fi
}

open_ports() {
    firewall_require_ufw || return 1

    # Prompt the user to enter the ports they want to open
    read -rp "Enter the ports you want to open (e.g. 80,443,2053 or range 400-500): " ports

    # Check if the input is valid
    if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
        echo "Error: Invalid input. Please enter a comma-separated list of ports or a range of ports (e.g. 80,443,2053 or 400-500)." >&2
        return 1
    fi

    # Open the specified ports using ufw
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            # Split the range into start and end ports
            start_port=${port%%-*}
            end_port=${port##*-}
            # Open the port range
            ufw allow "${start_port}:${end_port}/tcp"
            ufw allow "${start_port}:${end_port}/udp"
        else
            # Open the single port
            ufw allow "$port"
        fi
    done

    # Confirm that the ports are opened
    echo "Opened the specified ports:"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            start_port=${port%%-*}
            end_port=${port##*-}
            # Check if the port range has been successfully opened
            (ufw status | grep -q "$start_port:$end_port") && echo "$start_port-$end_port"
        else
            # Check if the individual port has been successfully opened
            (ufw status | grep -q "$port") && echo "$port"
        fi
    done
}

delete_ports() {
    firewall_require_ufw || return 1

    # Display current rules with numbers
    echo "Current UFW rules:"
    ufw status numbered

    # Ask the user how they want to delete rules
    echo "Do you want to delete rules by:"
    echo "1) Rule numbers"
    echo "2) Ports"
    read -rp "Enter your choice (1 or 2): " choice

    if [[ $choice -eq 1 ]]; then
        # Deleting by rule numbers
        read -rp "Enter the rule numbers you want to delete (1, 2, etc.): " rule_numbers

        # Validate the input
        if ! [[ $rule_numbers =~ ^([0-9]+)(,[0-9]+)*$ ]]; then
            echo "Error: Invalid input. Please enter a comma-separated list of rule numbers." >&2
            return 1
        fi

        # Split numbers into an array
        IFS=',' read -ra RULE_NUMBERS <<< "$rule_numbers"
        for rule_number in "${RULE_NUMBERS[@]}"; do
            # Delete the rule by number
            ufw delete "$rule_number" || echo "Failed to delete rule number $rule_number"
        done

        echo "Selected rules have been deleted."

    elif [[ $choice -eq 2 ]]; then
        # Deleting by ports
        read -rp "Enter the ports you want to delete (e.g. 80,443,2053 or range 400-500): " ports

        # Validate the input
        if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
            echo "Error: Invalid input. Please enter a comma-separated list of ports or a range of ports (e.g. 80,443,2053 or 400-500)." >&2
            return 1
        fi

        # Split ports into an array
        IFS=',' read -ra PORT_LIST <<< "$ports"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                # Split the port range
                start_port=${port%%-*}
                end_port=${port##*-}
                # Delete the port range
                ufw delete allow "${start_port}:${end_port}/tcp"
                ufw delete allow "${start_port}:${end_port}/udp"
            else
                # Delete a single port
                ufw delete allow "$port"
            fi
        done

        # Confirmation of deletion
        echo "Deleted the specified ports:"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                start_port=${port%%-*}
                end_port=${port##*-}
                # Check if the port range has been deleted
                (ufw status | grep -q "$start_port:$end_port") || echo "$start_port-$end_port"
            else
                # Check if the individual port has been deleted
                (ufw status | grep -q "$port") || echo "$port"
            fi
        done
    else
        echo "${red}Error:${plain} Invalid choice. Please enter 1 or 2." >&2
        return 1
    fi
}

update_all_geofiles() {
    update_geofiles "main"
    update_geofiles "IR"
    update_geofiles "RU"
}

update_geofiles() {
    case "${1}" in
        "main")
            dat_files=(geoip geosite)
            dat_source="Loyalsoldier/v2ray-rules-dat"
            ;;
        "IR")
            dat_files=(geoip_IR geosite_IR)
            dat_source="chocolate4u/Iran-v2ray-rules"
            ;;
        "RU")
            dat_files=(geoip_RU geosite_RU)
            dat_source="runetfreedom/russia-v2ray-rules-dat"
            ;;
    esac
    for dat in "${dat_files[@]}"; do
        # Remove suffix for remote filename (e.g., geoip_IR -> geoip)
        remote_file="${dat%%_*}"
        curl -fLRo ${xui_folder}/bin/${dat}.dat -z ${xui_folder}/bin/${dat}.dat \
            https://github.com/${dat_source}/releases/latest/download/${remote_file}.dat
    done
}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} runetfreedom (geoip_RU.dat, geosite_RU.dat)"
    echo -e "${green}\t4.${plain} All"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice

    case "$choice" in
        0)
            show_menu
            ;;
        1)
            update_geofiles "main"
            echo -e "${green}Loyalsoldier datasets have been updated successfully!${plain}"
            restart
            ;;
        2)
            update_geofiles "IR"
            echo -e "${green}chocolate4u datasets have been updated successfully!${plain}"
            restart
            ;;
        3)
            update_geofiles "RU"
            echo -e "${green}runetfreedom datasets have been updated successfully!${plain}"
            restart
            ;;
        4)
            update_all_geofiles
            echo -e "${green}All geo files have been updated successfully!${plain}"
            restart
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            update_geo
            ;;
    esac

    before_show_menu
}
# X-MILI managed certificate workflow.  Keep every panel/configuration change
# transactional: a failed issue, install, restart, or TLS probe restores the
# previous certificate paths, listen address, and insecure-HTTP opt-in.
X_MILI_CERT_ROOT="${X_MILI_CERT_ROOT:-/root/cert}"
if [[ -f /.dockerenv ]]; then
    # The certificate directory is a host volume in the Docker deployment;
    # keeping acme.sh here preserves account and renewal state on recreate.
    X_MILI_ACME_HOME="${X_MILI_ACME_HOME:-${X_MILI_CERT_ROOT}/.acme.sh}"
else
    X_MILI_ACME_HOME="${X_MILI_ACME_HOME:-/root/.acme.sh}"
fi
X_MILI_ACME_BIN="${X_MILI_ACME_HOME}/acme.sh"
SSL_CERT_BACKUP=""
SSL_CERT_HAD_OLD=0
SSL_CERT_INSTALL_ACTIVE=0
SSL_ACME_BACKUP=""
SSL_ACME_HAD_RSA=0
SSL_ACME_HAD_ECC=0
SSL_ACME_HAD_ACCOUNT=0
SSL_ACME_SNAPSHOT_COMPLETE=0
SSL_ACME_DEPLOY_STAGE=""
SSL_TRANSACTION_DOMAIN=""
SSL_TRANSACTION_LOCK=""
SSL_TRANSACTION_LOCK_FD=""
SSL_TRANSACTION_LOCK_MODE=""
SSL_PANEL_ROLLBACK_ACTIVE=0
SSL_PANEL_ROLLBACK_FORBIDDEN=0
SSL_PANEL_OLD_CERT=""
SSL_PANEL_OLD_KEY=""
SSL_PANEL_OLD_LISTEN=""
SSL_PANEL_OLD_INSECURE=false
SSL_SCHEDULER_BACKUP=""
SSL_SCHEDULER_SNAPSHOT_COMPLETE=0
SSL_SCHEDULER_MODE=""
SSL_SCHEDULER_HAD_CRONTAB=0
SSL_SCHEDULER_HAD_SERVICE=0
SSL_SCHEDULER_HAD_TIMER=0
SSL_SCHEDULER_TIMER_ENABLED=0
SSL_SCHEDULER_TIMER_ACTIVE=0
SSL_SCHEDULER_CROND_ENABLED=0
SSL_SCHEDULER_CROND_ACTIVE=0
SSL_SCHEDULER_SYSTEMD_DIR=""
SSL_SCHEDULER_DOCKER_MARKER=""

ssl_lock_metadata_is_stale() {
    local modified now
    modified=$(stat -c %Y -- "$1" 2> /dev/null) || return 1
    now=$(date +%s) || return 1
    [[ "$modified" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ \
        && $((now - modified)) -gt 60 ]]
}

ssl_acquire_lock() {
    local lock pid lock_fd proc_start saved_start stale_lock
    mkdir -p "$X_MILI_CERT_ROOT" || return 1
    lock="${X_MILI_CERT_ROOT}/.x-mili-ssl.lock"

    if command -v flock > /dev/null 2>&1; then
        # Migrate the directory used by older releases without ever removing a
        # lock that can still belong to a live SSL process.
        if [[ -d "$lock" ]]; then
            pid=$(cat "${lock}/pid" 2> /dev/null || true)
            if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
                if ! ssl_lock_metadata_is_stale "$lock"; then
                    ssl_log_e "SSL 锁正在迁移或状态不完整，请稍后重试。" \
                        "The SSL lock is being migrated or is incomplete; retry shortly."
                    return 1
                fi
            fi
            if kill -0 "$pid" 2> /dev/null \
                && tr '\0' ' ' < "/proc/${pid}/cmdline" 2> /dev/null \
                    | grep -Eq '(^|[ /])(x-ui\.sh|ml)( |$)'; then
                ssl_log_e "另一个 SSL 操作正在运行（PID ${pid}）。" \
                    "Another SSL operation is already running (PID ${pid})."
                return 1
            fi
            stale_lock="${lock}.stale.$$.$RANDOM"
            mv -- "$lock" "$stale_lock" 2> /dev/null || return 1
            rm -rf -- "$stale_lock"
        fi

        exec {lock_fd}>> "$lock" || return 1
        if ! flock -n "$lock_fd"; then
            pid=$(cat "$lock" 2> /dev/null || true)
            exec {lock_fd}>&-
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                ssl_log_e "另一个 SSL 操作正在运行（PID ${pid}）。" \
                    "Another SSL operation is already running (PID ${pid})."
            else
                ssl_log_e "另一个 SSL 操作正在运行。" \
                    "Another SSL operation is already running."
            fi
            return 1
        fi
        chmod 0600 "$lock" || { exec {lock_fd}>&-; return 1; }
        printf '%s\n' "$$" > "$lock" || { exec {lock_fd}>&-; return 1; }
        SSL_TRANSACTION_LOCK="$lock"
        SSL_TRANSACTION_LOCK_FD="$lock_fd"
        SSL_TRANSACTION_LOCK_MODE=flock
        return 0
    fi

    # Portable fallback for minimal systems.  PID plus /proc start time avoids
    # treating an unrelated process that reused the PID as the lock owner.
    lock="${lock}.d"
    if ! mkdir "$lock" 2> /dev/null; then
        pid=$(cat "${lock}/pid" 2> /dev/null || true)
        saved_start=$(cat "${lock}/start" 2> /dev/null || true)
        proc_start=""
        if [[ "$pid" =~ ^[0-9]+$ && -r "/proc/${pid}/stat" ]]; then
            proc_start=$(awk '{print $22}' "/proc/${pid}/stat" 2> /dev/null || true)
        fi
        if [[ ! "$pid" =~ ^[0-9]+$ || -z "$saved_start" ]]; then
            if ! ssl_lock_metadata_is_stale "$lock"; then
                ssl_log_e "SSL 锁状态尚未完整，请稍后重试。" \
                    "The SSL lock metadata is not complete yet; retry shortly."
                return 1
            fi
        fi
        if [[ -n "$proc_start" && "$proc_start" == "$saved_start" ]] \
            && kill -0 "$pid" 2> /dev/null; then
            ssl_log_e "另一个 SSL 操作正在运行（PID ${pid}）。" \
                "Another SSL operation is already running (PID ${pid})."
            return 1
        fi
        stale_lock="${lock}.stale.$$.$RANDOM"
        mv -- "$lock" "$stale_lock" 2> /dev/null || return 1
        rm -rf -- "$stale_lock"
        mkdir "$lock" 2> /dev/null || return 1
    fi
    proc_start=$(awk '{print $22}' "/proc/$$/stat" 2> /dev/null || true)
    printf '%s\n' "$$" > "${lock}/pid" || { rm -rf -- "$lock"; return 1; }
    printf '%s\n' "$proc_start" > "${lock}/start" || { rm -rf -- "$lock"; return 1; }
    chmod 0700 "$lock" || { rm -rf -- "$lock"; return 1; }
    SSL_TRANSACTION_LOCK="$lock"
    SSL_TRANSACTION_LOCK_MODE="mkdir"
}

ssl_release_lock() {
    if [[ "$SSL_TRANSACTION_LOCK_MODE" == flock \
        && "$SSL_TRANSACTION_LOCK_FD" =~ ^[0-9]+$ ]]; then
        : > "$SSL_TRANSACTION_LOCK" 2> /dev/null || true
        exec {SSL_TRANSACTION_LOCK_FD}>&-
    elif [[ "$SSL_TRANSACTION_LOCK_MODE" == mkdir && -n "$SSL_TRANSACTION_LOCK" ]]; then
        rm -rf -- "$SSL_TRANSACTION_LOCK"
    fi
    SSL_TRANSACTION_LOCK="" SSL_TRANSACTION_LOCK_FD="" SSL_TRANSACTION_LOCK_MODE=""
}

ssl_transaction_rollback() {
    local rc=0 domain="${SSL_TRANSACTION_DOMAIN:-${SSL_SELECTED_DOMAIN:-}}"
    trap - EXIT INT TERM HUP
    ssl_cleanup_acme_deploy_stage 2> /dev/null || rc=1
    if [[ -n "$domain" && -n "$SSL_ACME_BACKUP" ]]; then
        ssl_rollback_acme_state "$domain" || rc=1
    fi
    if [[ -n "$domain" && ( "$SSL_CERT_INSTALL_ACTIVE" == "1" \
        || "$SSL_CERT_HAD_OLD" == "1" || -n "$SSL_CERT_BACKUP" ) ]]; then
        ssl_rollback_cert_install "$domain" || rc=1
    fi
    if [[ "$SSL_PANEL_ROLLBACK_ACTIVE" == "1" ]]; then
        if [[ "$SSL_PANEL_ROLLBACK_FORBIDDEN" == "1" ]]; then
            ssl_log_e "不可逆的证书操作可能已完成；为避免重新启用已吊销或已删除的证书，面板保持 HTTP 回退模式。" \
                "An irreversible certificate action may have completed; the panel remains in HTTP fallback mode rather than re-enabling a revoked or deleted certificate."
            ssl_commit_panel_state
            rc=1
        elif ssl_restore_panel_state "$SSL_PANEL_OLD_CERT" "$SSL_PANEL_OLD_KEY" \
            "$SSL_PANEL_OLD_LISTEN" "$SSL_PANEL_OLD_INSECURE"; then
            ssl_commit_panel_state
        else
            rc=1
        fi
    fi
    if [[ -n "$SSL_SCHEDULER_BACKUP" ]]; then
        ssl_rollback_scheduler_state || rc=1
    fi
    ssl_release_lock
    return "$rc"
}

ssl_transaction_signal() {
    local status="$1"
    [[ "$status" -ne 0 ]] || status=1
    ssl_transaction_rollback || true
    exit "$status"
}

ssl_with_transaction() {
    local rc=0
    ssl_acquire_lock || return 1
    SSL_TRANSACTION_DOMAIN=""
    trap 'ssl_transaction_signal $?' EXIT
    trap 'ssl_transaction_signal 130' INT
    trap 'ssl_transaction_signal 143' TERM HUP
    "$@" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ssl_transaction_rollback || rc=1
    else
        ssl_commit_transaction_state
        trap - EXIT INT TERM HUP
        ssl_release_lock
    fi
    return "$rc"
}

ssl_log_i() {
    if is_zh; then LOGI "$1"; else LOGI "$2"; fi
}

ssl_log_e() {
    if is_zh; then LOGE "$1"; else LOGE "$2"; fi
}

ssl_is_true() {
    [[ "${1,,}" == true ]]
}

ssl_is_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

ssl_normalize_domain() {
    local domain="$1"
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    domain="${domain,,}"
    domain="${domain%.}"
    printf '%s\n' "$domain"
}

ssl_valid_domain() {
    local domain="$1" tld
    (( ${#domain} >= 4 && ${#domain} <= 253 )) || return 1
    ssl_is_ipv4 "$domain" && return 1
    [[ "$domain" != \*.* ]] || return 1
    [[ "$domain" == *.* ]] || return 1
    tld="${domain##*.}"
    (( ${#tld} >= 2 )) && [[ "$tld" =~ [a-z] ]] || return 1
    [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

ssl_read_domain() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        if is_zh; then
            read -rp "请输入要绑定的完整域名（例如 panel.example.com）: " domain
        else
            read -rp "Enter the full domain to bind (for example panel.example.com): " domain
        fi
    fi
    domain="$(ssl_normalize_domain "$domain")"
    if ! ssl_valid_domain "$domain"; then
        ssl_log_e "域名格式无效：${domain:-<空>}" "Invalid domain: ${domain:-<empty>}"
        return 1
    fi
    SSL_SELECTED_DOMAIN="$domain"
}

ssl_get_public_ipv4() {
    local endpoint ip
    for endpoint in https://api.ipify.org https://4.ident.me https://ipv4.icanhazip.com; do
        ip=$(curl --noproxy '*' -4fsS --connect-timeout 3 --max-time 6 "$endpoint" 2> /dev/null | tr -d '[:space:]' || true)
        if ssl_is_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

ssl_get_public_ipv6() {
    local ip
    ip=$(curl --noproxy '*' -6fsS --connect-timeout 3 --max-time 6 https://api64.ipify.org 2> /dev/null | tr -d '[:space:]' || true)
    [[ "$ip" == *:* ]] || return 1
    printf '%s\n' "$ip"
}

ssl_resolve_ipv4() {
    local domain="$1"
    if command -v dig > /dev/null 2>&1; then
        dig +time=3 +tries=1 +short A "$domain" 2> /dev/null | while read -r ip; do
            ssl_is_ipv4 "$ip" && printf '%s\n' "$ip"
        done | sort -u
    elif command -v getent > /dev/null 2>&1; then
        getent ahostsv4 "$domain" 2> /dev/null | awk '{print $1}' | sort -u
    elif command -v nslookup > /dev/null 2>&1; then
        nslookup "$domain" 2> /dev/null | awk '/^Address: / {print $2}' | while read -r ip; do
            ssl_is_ipv4 "$ip" && printf '%s\n' "$ip"
        done | sort -u
    fi
}

ssl_resolve_ipv6() {
    local domain="$1"
    if command -v dig > /dev/null 2>&1; then
        dig +time=3 +tries=1 +short AAAA "$domain" 2> /dev/null | awk '/:/' | sort -u
    elif command -v getent > /dev/null 2>&1; then
        getent ahostsv6 "$domain" 2> /dev/null | awk '{print $1}' | sort -u
    fi
}

ssl_dns_check() {
    local domain="$1" public4 public6 resolved4 resolved6 mismatch=0 matched_family=0
    public4=$(ssl_get_public_ipv4 || true)
    public6=$(ssl_get_public_ipv6 || true)
    resolved4=$(ssl_resolve_ipv4 "$domain")
    resolved6=$(ssl_resolve_ipv6 "$domain")

    if [[ -z "$resolved4" && -z "$resolved6" ]]; then
        ssl_log_e "DNS 未找到 ${domain} 的 A/AAAA 记录。请先添加解析并等待生效。" \
            "No A/AAAA record was found for ${domain}. Add DNS records and wait for propagation."
        return 1
    fi

    is_zh && echo "DNS A 记录: ${resolved4:-无}" || echo "DNS A records: ${resolved4:-none}"
    is_zh && echo "DNS AAAA 记录: ${resolved6:-无}" || echo "DNS AAAA records: ${resolved6:-none}"
    is_zh && echo "本机公网 IPv4: ${public4:-未检测到}" || echo "Server public IPv4: ${public4:-not detected}"
    [[ -z "$public6" ]] || { is_zh && echo "本机公网 IPv6: $public6" || echo "Server public IPv6: $public6"; }

    if [[ -n "$resolved4" ]]; then
        if [[ -z "$public4" ]] || awk -v expected="$public4" 'NF && $0 != expected {bad=1} END {exit bad ? 0 : 1}' <<< "$resolved4"; then
            mismatch=1
        else
            matched_family=1
        fi
    fi
    if [[ -n "$resolved6" ]]; then
        if [[ -z "$public6" ]] || awk -v expected="$public6" 'NF && tolower($0) != tolower(expected) {bad=1} END {exit bad ? 0 : 1}' <<< "$resolved6"; then
            mismatch=1
        else
            matched_family=1
        fi
    fi
    if [[ $mismatch -eq 0 && $matched_family -eq 1 ]]; then
        ssl_log_i "所有 DNS 地址均与本机公网地址一致。" "All DNS addresses match this server's public addresses."
        return 0
    fi

    ssl_log_e "至少一个 A/AAAA 记录未指向本机；HTTP-01 可能访问错误服务器。Cloudflare 橙云请使用 DNS 验证。" \
        "At least one A/AAAA record points elsewhere, so HTTP-01 may reach the wrong server. Use DNS validation for proxied Cloudflare records."
    if is_zh; then
        confirm "仍要继续 HTTP-01 验证吗？" "n"
    else
        confirm "Continue with HTTP-01 validation anyway?" "n"
    fi
}

ssl_install_dependencies() {
    local need_socat="${1:-0}" missing=0
    local -a packages=(curl openssl ca-certificates)
    command -v curl > /dev/null 2>&1 || missing=1
    command -v openssl > /dev/null 2>&1 || missing=1
    [[ "$need_socat" != "1" ]] || command -v socat > /dev/null 2>&1 || missing=1
    [[ $missing -eq 1 ]] || return 0
    [[ "$need_socat" != "1" ]] || packages+=(socat)

    ssl_log_i "正在安装证书依赖..." "Installing certificate dependencies..."
    if command -v apt-get > /dev/null 2>&1; then
        apt-get update && env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || return 1
    elif command -v dnf > /dev/null 2>&1; then
        dnf install -y "${packages[@]}" || return 1
    elif command -v yum > /dev/null 2>&1; then
        yum install -y "${packages[@]}" || return 1
    elif command -v apk > /dev/null 2>&1; then
        apk add --no-cache "${packages[@]}" || return 1
    elif command -v pacman > /dev/null 2>&1; then
        pacman -Sy --noconfirm "${packages[@]}" || return 1
    elif command -v zypper > /dev/null 2>&1; then
        zypper -n install "${packages[@]}" || return 1
    else
        ssl_log_e "无法识别包管理器，请手动安装 curl、openssl 和 socat。" \
            "Unsupported package manager. Install curl, openssl, and socat manually."
        return 1
    fi

    command -v curl > /dev/null 2>&1 && command -v openssl > /dev/null 2>&1 || return 1
    [[ "$need_socat" != "1" ]] || command -v socat > /dev/null 2>&1
}

install_acme() {
    local installer email=""
    local -a installer_args=(--home "$X_MILI_ACME_HOME")
    if [[ -x "$X_MILI_ACME_BIN" ]]; then
        ssl_log_i "acme.sh 已安装。" "acme.sh is already installed."
        return 0
    fi
    ssl_install_dependencies 0 || return 1
    if is_zh; then
        read -rp "ACME 账户邮箱（建议填写，可留空）: " email
    else
        read -rp "ACME account email (recommended, optional): " email
    fi
    if [[ -n "$email" && ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        ssl_log_e "邮箱格式无效。" "Invalid email address."
        return 1
    fi
    installer=$(mktemp /tmp/x-mili-acme.XXXXXX) || return 1
    if ! curl -fsSL --proto '=https' --tlsv1.2 \
        https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh \
        -o "$installer"; then
        rm -f -- "$installer"
        ssl_log_e "下载 acme.sh 安装器失败。" "Failed to download the acme.sh installer."
        return 1
    fi
    [[ -z "$email" ]] || installer_args+=(--accountemail "$email")
    installer_args+=(--install-online --nocron)
    HOME=/root sh "$installer" "${installer_args[@]}"
    local rc=$?
    rm -f -- "$installer"
    if [[ $rc -ne 0 || ! -x "$X_MILI_ACME_BIN" ]]; then
        ssl_log_e "安装 acme.sh 失败。" "Failed to install acme.sh."
        return 1
    fi
    "$X_MILI_ACME_BIN" --set-default-ca --server letsencrypt > /dev/null || return 1
    "$X_MILI_ACME_BIN" --upgrade --auto-upgrade > /dev/null 2>&1 || true
    ssl_log_i "acme.sh 安装完成。" "acme.sh installed successfully."
}

ssl_service_env_file() {
    local env_file=""
    if [[ -f /.dockerenv ]]; then
        return 1
    fi
    if [[ "$release" == alpine && -f /etc/init.d/x-ui ]]; then
        printf '%s\n' /etc/conf.d/x-ui
        return 0
    fi
    if command -v systemctl > /dev/null 2>&1; then
        env_file=$(systemctl cat x-ui --no-pager 2> /dev/null \
            | sed -n 's/^[[:space:]]*EnvironmentFile=[[:space:]]*//p' | tail -n 1)
        env_file="${env_file#\"}"
        env_file="${env_file%\"}"
        env_file="${env_file#-}"
    fi
    if [[ -z "$env_file" && -n "${X_MILI_CONFIG_DIR:-}" ]]; then
        env_file="${X_MILI_CONFIG_DIR}/x-mili.env"
    fi
    [[ -n "$env_file" ]] || { [[ -f /etc/x-mili/x-mili.env ]] && env_file=/etc/x-mili/x-mili.env; }
    [[ -n "$env_file" ]] || env_file=/etc/default/x-ui
    printf '%s\n' "$env_file"
}

ssl_insecure_http_enabled() {
    local env_file value
    if [[ -f /.dockerenv ]]; then
        ssl_is_true "${XUI_ALLOW_INSECURE_HTTP:-}"
        return
    fi
    env_file=$(ssl_service_env_file) || return 1
    [[ -f "$env_file" ]] || return 1
    value=$(awk -F= '
        /^[[:space:]]*(export[[:space:]]+)?XUI_ALLOW_INSECURE_HTTP[[:space:]]*=/ {
            v=$0; sub(/^[^=]*=/, "", v); gsub(/[[:space:]"'"'"']/, "", v); last=tolower(v)
        }
        END { print last }
    ' "$env_file")
    [[ "$value" == "true" ]]
}

ssl_ensure_systemd_env_file() {
    local env_file="$1" dropin_dir dropin tmp
    [[ -f /.dockerenv || "$release" == alpine ]] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl cat x-ui --no-pager 2>/dev/null | grep -q '^[[:space:]]*EnvironmentFile='; then
        return 0
    fi
    dropin_dir=/etc/systemd/system/x-ui.service.d
    dropin="${dropin_dir}/10-x-mili-env.conf"
    mkdir -p "$dropin_dir" || return 1
    tmp=$(mktemp "${dropin}.XXXXXX") || return 1
    printf '[Service]\nEnvironmentFile=-%s\n' "$env_file" > "$tmp"
    chown root:root "$tmp" 2>/dev/null || true
    chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dropin" || return 1
    systemctl daemon-reload
}

ssl_write_docker_http_mode() {
    local enabled="$1" data_dir marker tmp
    data_dir="${XUI_DB_FOLDER:-/etc/x-ui}"
    marker="${data_dir}/.x-mili-http-mode"
    mkdir -p "$data_dir" || return 1
    tmp=$(mktemp "${marker}.XXXXXX") || return 1
    printf '%s\n' "$enabled" > "$tmp"
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$marker"
}

ssl_set_insecure_http() {
    local enabled="$1" env_file tmp parent
    if [[ -f /.dockerenv ]]; then
        # Docker cannot mutate PID 1's inherited environment.  Persist the
        # requested state in the shared DB volume; the host `ml ssl` wrapper
        # consumes it, updates Compose, and force-recreates the container.
        ssl_write_docker_http_mode "$enabled" || return 1
        if [[ "$enabled" == "true" ]] && ! ssl_insecure_http_enabled; then
            ssl_log_i "已请求宿主机重建容器以开启临时公网 HTTP。" \
                "Requested a host-side container recreate for temporary public HTTP."
        elif [[ "$enabled" != "true" ]] && ssl_insecure_http_enabled; then
            ssl_log_i "已请求宿主机重建容器并移除公网明文 HTTP 开关。" \
                "Requested a host-side container recreate with public plaintext HTTP disabled."
        fi
        return 0
    fi

    env_file=$(ssl_service_env_file) || return 1
    parent=$(dirname "$env_file")
    mkdir -p "$parent" || return 1
    tmp=$(mktemp "${env_file}.XXXXXX") || return 1
    if [[ -f "$env_file" ]]; then
        sed '/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}XUI_ALLOW_INSECURE_HTTP[[:space:]]*=/d' "$env_file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    if [[ "$enabled" == "true" ]]; then
        if [[ "$env_file" == /etc/conf.d/* ]]; then
            printf 'export XUI_ALLOW_INSECURE_HTTP=true\n' >> "$tmp"
        else
            printf 'XUI_ALLOW_INSECURE_HTTP=true\n' >> "$tmp"
        fi
    fi
    chown root:root "$tmp" 2> /dev/null || true
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$env_file" || return 1
    ssl_ensure_systemd_env_file "$env_file"
}

ssl_panel_cert() {
    "${xui_folder}/x-ui" setting -getCert true 2> /dev/null | sed -n 's/^cert:[[:space:]]*//p' | sed -n '1p'
}

ssl_panel_key() {
    "${xui_folder}/x-ui" setting -getCert true 2> /dev/null | sed -n 's/^key:[[:space:]]*//p' | sed -n '1p'
}

ssl_panel_listen() {
    "${xui_folder}/x-ui" setting -getListen true 2> /dev/null | sed -n 's/^listenIP:[[:space:]]*//p' | sed -n '1p'
}

ssl_set_panel_cert() {
    local cert="$1" key="$2"
    "${xui_folder}/x-ui" cert -webCert "$cert" -webCertKey "$key" > /dev/null 2>&1 || return 1
    [[ "$(ssl_panel_cert)" == "$cert" && "$(ssl_panel_key)" == "$key" ]]
}

ssl_set_panel_listen() {
    local listen="$1"
    "${xui_folder}/x-ui" setting -listenIP "$listen" > /dev/null 2>&1 || return 1
    [[ "$(ssl_panel_listen)" == "$listen" ]]
}

ssl_panel_setting() {
    local key="$1"
    "${xui_folder}/x-ui" setting -show true 2> /dev/null \
        | awk -v key="$key" '$1 == key ":" {print $2; exit}'
}

ssl_panel_port() {
    local port
    port=$(ssl_panel_setting port)
    [[ "$port" =~ ^[0-9]+$ ]] || port=2053
    printf '%s\n' "$port"
}

ssl_panel_path() {
    local path
    path=$(ssl_panel_setting webBasePath)
    [[ -n "$path" ]] || path=/
    [[ "$path" == /* ]] || path="/$path"
    [[ "$path" == */ ]] || path="$path/"
    printf '%s\n' "$path"
}

ssl_verify_cert_key_pair() {
    local domain="$1" cert="$2" key="$3" cert_pub key_pub
    [[ -s "$cert" && -s "$key" ]] || return 1
    openssl x509 -in "$cert" -noout > /dev/null 2>&1 || return 1
    openssl pkey -in "$key" -noout > /dev/null 2>&1 || return 1
    cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2> /dev/null \
        | openssl pkey -pubin -outform DER 2> /dev/null | openssl dgst -sha256 2> /dev/null) || return 1
    key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2> /dev/null \
        | openssl dgst -sha256 2> /dev/null) || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || return 1
    if openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
        openssl x509 -in "$cert" -noout -checkhost "$domain" > /dev/null 2>&1 || return 1
    fi
}

ssl_verify_cert_files() {
    local domain="$1" cert="$2" key="$3"
    ssl_verify_cert_key_pair "$domain" "$cert" "$key" || return 1
    openssl x509 -in "$cert" -noout -checkend 60 > /dev/null 2>&1
}

ssl_verify_local_https() {
    local domain="$1" port path i
    port=$(ssl_panel_port)
    path=$(ssl_panel_path)
    for i in {1..12}; do
        if curl --noproxy '*' -sS --output /dev/null --connect-timeout 3 --max-time 8 \
            --resolve "${domain}:${port}:127.0.0.1" "https://${domain}:${port}${path}" 2> /dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

ssl_verify_local_http() {
    local port path i
    port=$(ssl_panel_port)
    path=$(ssl_panel_path)
    for i in {1..10}; do
        curl --noproxy '*' -sS --output /dev/null --connect-timeout 2 --max-time 5 \
            "http://127.0.0.1:${port}${path}" 2> /dev/null && return 0
        sleep 1
    done
    return 1
}

ssl_public_listener_active() {
    local port="$1"
    command -v ss > /dev/null 2>&1 || return 0
    ss -ltnH 2> /dev/null | awk -v p=":${port}$" '
        $4 ~ p && ($4 ~ /^0\.0\.0\.0:/ || $4 ~ /^\[::\]:/ || $4 ~ /^\*:/) {found=1}
        END {exit !found}'
}

ssl_commit_panel_state() {
    # Clear all panel rollback metadata at one trap boundary. Call this only
    # when the enclosing certificate transaction is committed, or when an
    # irreversible action makes restoring the old TLS state unsafe.
    SSL_PANEL_ROLLBACK_ACTIVE=0 SSL_PANEL_ROLLBACK_FORBIDDEN=0 \
        SSL_PANEL_OLD_CERT="" SSL_PANEL_OLD_KEY="" SSL_PANEL_OLD_LISTEN="" \
        SSL_PANEL_OLD_INSECURE=false
}

ssl_commit_transaction_state() {
    local cert_backup="$SSL_CERT_BACKUP" acme_backup="$SSL_ACME_BACKUP"
    local scheduler_backup="$SSL_SCHEDULER_BACKUP" backup

    # This is the sole successful transaction commit point. All rollback
    # eligibility is cleared by one assignment-only simple command, which is a
    # single Bash trap boundary. Backup deletion happens only afterwards.
    SSL_CERT_BACKUP="" SSL_CERT_HAD_OLD=0 SSL_CERT_INSTALL_ACTIVE=0 \
        SSL_ACME_BACKUP="" SSL_ACME_HAD_RSA=0 SSL_ACME_HAD_ECC=0 \
        SSL_ACME_HAD_ACCOUNT=0 SSL_ACME_SNAPSHOT_COMPLETE=0 \
        SSL_PANEL_ROLLBACK_ACTIVE=0 SSL_PANEL_ROLLBACK_FORBIDDEN=0 \
        SSL_PANEL_OLD_CERT="" SSL_PANEL_OLD_KEY="" SSL_PANEL_OLD_LISTEN="" \
        SSL_PANEL_OLD_INSECURE=false SSL_SCHEDULER_BACKUP="" \
        SSL_SCHEDULER_SNAPSHOT_COMPLETE=0 SSL_SCHEDULER_MODE="" \
        SSL_SCHEDULER_HAD_CRONTAB=0 SSL_SCHEDULER_HAD_SERVICE=0 \
        SSL_SCHEDULER_HAD_TIMER=0 SSL_SCHEDULER_TIMER_ENABLED=0 \
        SSL_SCHEDULER_TIMER_ACTIVE=0 SSL_SCHEDULER_CROND_ENABLED=0 \
        SSL_SCHEDULER_CROND_ACTIVE=0 SSL_SCHEDULER_SYSTEMD_DIR="" \
        SSL_SCHEDULER_DOCKER_MARKER=""

    for backup in "$cert_backup" "$acme_backup" "$scheduler_backup"; do
        [[ -z "$backup" ]] || rm -rf -- "$backup" 2> /dev/null || true
    done
}

ssl_restore_panel_state() {
    local cert="$1" key="$2" listen="$3" insecure="$4" rc=0
    [[ -n "$listen" ]] || listen=0.0.0.0
    ssl_set_panel_cert "$cert" "$key" || rc=1
    ssl_set_panel_listen "$listen" || rc=1
    ssl_set_insecure_http "$insecure" > /dev/null 2>&1 || rc=1
    restart 0 > /dev/null 2>&1 || rc=1
    if [[ $rc -ne 0 ]]; then
        ssl_log_e "自动恢复未完全成功，请立即检查面板证书、监听地址和服务日志。" \
            "Automatic rollback was incomplete; inspect panel certificate paths, listener settings, and service logs immediately."
    fi
    return "$rc"
}

ssl_apply_panel_tls() {
    local domain="$1" cert="$2" key="$3"
    local old_cert old_key old_listen old_insecure=false port
    ssl_verify_cert_files "$domain" "$cert" "$key" || {
        ssl_log_e "证书或私钥校验失败，未修改面板。" "Certificate/key validation failed; the panel was not changed."
        return 1
    }
    port=$(ssl_panel_port)
    ssl_prepare_panel_firewall "$port" || return 1
    old_cert=$(ssl_panel_cert)
    old_key=$(ssl_panel_key)
    old_listen=$(ssl_panel_listen)
    ssl_insecure_http_enabled && old_insecure=true
    SSL_PANEL_OLD_CERT="$old_cert"
    SSL_PANEL_OLD_KEY="$old_key"
    SSL_PANEL_OLD_LISTEN="$old_listen"
    SSL_PANEL_OLD_INSECURE="$old_insecure"
    SSL_PANEL_ROLLBACK_ACTIVE=1

    # Clear the plaintext override first. A later broken certificate must never
    # fall back to a public HTTP listener.
    if ! ssl_set_insecure_http false \
        || ! ssl_set_panel_cert "$cert" "$key" \
        || ! ssl_set_panel_listen 0.0.0.0 \
        || ! restart 0 \
        || ! ssl_verify_local_https "$domain"; then
        ssl_log_e "HTTPS 启用或本机握手验证失败，正在恢复原配置。" \
            "HTTPS activation or local handshake failed; restoring the previous configuration."
        ssl_restore_panel_state "$old_cert" "$old_key" "$old_listen" "$old_insecure" \
            && ssl_commit_panel_state
        return 1
    fi

    ssl_log_i "HTTPS 已启用并通过本机 TLS 验证。" "HTTPS is enabled and passed the local TLS probe."
    echo -e "${green}https://${domain}:$(ssl_panel_port)$(ssl_panel_path)${plain}"
}

ssl_acme_mode() {
    local domain="$1"
    if [[ -d "${X_MILI_ACME_HOME}/${domain}_ecc" ]]; then
        echo ecc
    elif [[ -d "${X_MILI_ACME_HOME}/${domain}" ]]; then
        echo rsa
    else
        echo none
    fi
}

ssl_backup_acme_state() {
    local domain="$1"
    SSL_TRANSACTION_DOMAIN="$domain"
    mkdir -p "$X_MILI_CERT_ROOT" "$X_MILI_ACME_HOME" || return 1
    SSL_ACME_BACKUP="" SSL_ACME_HAD_RSA=0 SSL_ACME_HAD_ECC=0 \
        SSL_ACME_HAD_ACCOUNT=0 SSL_ACME_SNAPSHOT_COMPLETE=0
    SSL_ACME_BACKUP=$(mktemp -d "${X_MILI_CERT_ROOT}/.acme-state.${domain}.XXXXXX") || return 1
    if [[ -f "${X_MILI_ACME_HOME}/account.conf" ]]; then
        cp -a -- "${X_MILI_ACME_HOME}/account.conf" "${SSL_ACME_BACKUP}/account.conf" \
            || { ssl_commit_acme_state; return 1; }
        SSL_ACME_HAD_ACCOUNT=1
    fi
    if [[ -d "${X_MILI_ACME_HOME}/${domain}" ]]; then
        cp -a -- "${X_MILI_ACME_HOME}/${domain}" "${SSL_ACME_BACKUP}/rsa" \
            || { ssl_commit_acme_state; return 1; }
        SSL_ACME_HAD_RSA=1
    fi
    if [[ -d "${X_MILI_ACME_HOME}/${domain}_ecc" ]]; then
        cp -a -- "${X_MILI_ACME_HOME}/${domain}_ecc" "${SSL_ACME_BACKUP}/ecc" \
            || { ssl_commit_acme_state; return 1; }
        SSL_ACME_HAD_ECC=1
    fi
    # A rollback may touch live ACME state only after every expected item was
    # copied and its presence flag was recorded.
    SSL_ACME_SNAPSHOT_COMPLETE=1
}

ssl_commit_acme_state() {
    local backup="$SSL_ACME_BACKUP"
    # Clear rollback eligibility as one simple command before deleting the
    # snapshot. A signal can then leave only an orphaned backup, never make a
    # later rollback operate from a missing or partial snapshot.
    SSL_ACME_BACKUP="" SSL_ACME_HAD_RSA=0 SSL_ACME_HAD_ECC=0 \
        SSL_ACME_HAD_ACCOUNT=0 SSL_ACME_SNAPSHOT_COMPLETE=0
    [[ -z "$backup" ]] || rm -rf -- "$backup"
}

ssl_rollback_acme_state() {
    local domain="$1" rsa_stage="" ecc_stage="" account_stage=""
    [[ -n "$SSL_ACME_BACKUP" && -d "$SSL_ACME_BACKUP" ]] || return 1
    if [[ "$SSL_ACME_SNAPSHOT_COMPLETE" != "1" ]]; then
        # Snapshot creation is read-only. If it was interrupted, discard only
        # the partial snapshot and leave all live ACME files untouched.
        ssl_commit_acme_state
        return 0
    fi
    if [[ $SSL_ACME_HAD_RSA -eq 1 ]]; then
        rsa_stage="${X_MILI_ACME_HOME}/.${domain}.restore-rsa.$$"
        rm -rf -- "$rsa_stage"
        cp -a -- "${SSL_ACME_BACKUP}/rsa" "$rsa_stage" || {
            ssl_log_e "恢复旧 ACME RSA 状态失败，备份保留在 ${SSL_ACME_BACKUP}。" \
                "Failed to stage the old RSA ACME state; backup kept at ${SSL_ACME_BACKUP}."
            return 1
        }
    fi
    if [[ $SSL_ACME_HAD_ECC -eq 1 ]]; then
        ecc_stage="${X_MILI_ACME_HOME}/.${domain}.restore-ecc.$$"
        rm -rf -- "$ecc_stage"
        cp -a -- "${SSL_ACME_BACKUP}/ecc" "$ecc_stage" || {
            [[ -z "$rsa_stage" ]] || rm -rf -- "$rsa_stage"
            ssl_log_e "恢复旧 ACME ECC 状态失败，备份保留在 ${SSL_ACME_BACKUP}。" \
                "Failed to stage the old ECC ACME state; backup kept at ${SSL_ACME_BACKUP}."
            return 1
        }
    fi
    if [[ $SSL_ACME_HAD_ACCOUNT -eq 1 ]]; then
        account_stage="${X_MILI_ACME_HOME}/.account.conf.restore.$$"
        rm -f -- "$account_stage"
        cp -a -- "${SSL_ACME_BACKUP}/account.conf" "$account_stage" || {
            [[ -z "$rsa_stage" ]] || rm -rf -- "$rsa_stage"
            [[ -z "$ecc_stage" ]] || rm -rf -- "$ecc_stage"
            ssl_log_e "恢复旧 ACME account.conf 失败，备份保留在 ${SSL_ACME_BACKUP}。" \
                "Failed to stage the old ACME account.conf; backup kept at ${SSL_ACME_BACKUP}."
            return 1
        }
    fi
    rm -rf -- "${X_MILI_ACME_HOME:?}/${domain}" "${X_MILI_ACME_HOME:?}/${domain}_ecc"
    [[ -z "$rsa_stage" ]] || mv -- "$rsa_stage" "${X_MILI_ACME_HOME}/${domain}" || return 1
    [[ -z "$ecc_stage" ]] || mv -- "$ecc_stage" "${X_MILI_ACME_HOME}/${domain}_ecc" || return 1
    rm -f -- "${X_MILI_ACME_HOME}/account.conf"
    [[ -z "$account_stage" ]] || mv -- "$account_stage" "${X_MILI_ACME_HOME}/account.conf" || return 1
    ssl_commit_acme_state
}

ssl_cleanup_acme_deploy_stage() {
    [[ -z "$SSL_ACME_DEPLOY_STAGE" ]] || rm -rf -- "$SSL_ACME_DEPLOY_STAGE"
    SSL_ACME_DEPLOY_STAGE=""
}

ssl_prepare_acme_deploy_stage() {
    local domain="$1" mode conf stage tmp reload_b64
    ssl_cleanup_acme_deploy_stage
    mode=$(ssl_acme_mode "$domain")
    [[ "$mode" != none ]] || return 0
    mkdir -p "$X_MILI_CERT_ROOT" || return 1
    stage=$(mktemp -d "${X_MILI_CERT_ROOT}/.${domain}.acme-deploy.XXXXXX") || return 1
    if [[ "$mode" == ecc ]]; then
        conf="${X_MILI_ACME_HOME}/${domain}_ecc/${domain}.conf"
    else
        conf="${X_MILI_ACME_HOME}/${domain}/${domain}.conf"
    fi
    [[ -f "$conf" ]] || { rm -rf -- "$stage"; return 1; }
    reload_b64=$(printf '%s' /bin/true | openssl base64 -A 2> /dev/null) || {
        rm -rf -- "$stage"
        return 1
    }
    tmp=$(mktemp "${conf}.x-mili.XXXXXX") || { rm -rf -- "$stage"; return 1; }
    if ! sed \
        -e '/^Le_RealCertPath[[:space:]]*=/d' \
        -e '/^Le_RealCACertPath[[:space:]]*=/d' \
        -e '/^Le_RealKeyPath[[:space:]]*=/d' \
        -e '/^Le_ReloadCmd[[:space:]]*=/d' \
        -e '/^Le_RealFullChainPath[[:space:]]*=/d' \
        "$conf" > "$tmp"; then
        rm -f -- "$tmp"
        rm -rf -- "$stage"
        return 1
    fi
    {
        printf "Le_RealCertPath='%s'\n" "${stage}/cert.pem"
        printf "Le_RealCACertPath='%s'\n" "${stage}/ca.pem"
        printf "Le_RealKeyPath='%s'\n" "${stage}/privkey.pem"
        printf "Le_ReloadCmd='__ACME_BASE64__START_%s__ACME_BASE64__END_'\n" "$reload_b64"
        printf "Le_RealFullChainPath='%s'\n" "${stage}/fullchain.pem"
    } >> "$tmp"
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; rm -rf -- "$stage"; return 1; }
    if ! mv -f -- "$tmp" "$conf" \
        || [[ $(grep -Fc "$stage" "$conf" 2> /dev/null) -lt 4 ]] \
        || ! grep -Fq "Le_ReloadCmd='__ACME_BASE64__START_${reload_b64}__ACME_BASE64__END_'" "$conf"; then
        rm -f -- "$tmp"
        rm -rf -- "$stage"
        ssl_log_e "无法确认 ACME 安全部署路径，已中止。" \
            "Could not verify the safe ACME deployment paths; aborting."
        return 1
    fi
    SSL_ACME_DEPLOY_STAGE="$stage"
}

ssl_scheduler_path_is_safe() {
    # These paths are embedded in both a systemd unit and a crontab command.
    # Keep the accepted alphabet shell- and unit-safe instead of attempting to
    # compose two different escaping formats for privileged renewal jobs.
    [[ "$1" =~ ^/[A-Za-z0-9._/+:~-]+$ ]]
}

ssl_commit_scheduler_state() {
    local backup="$SSL_SCHEDULER_BACKUP"
    SSL_SCHEDULER_BACKUP="" SSL_SCHEDULER_SNAPSHOT_COMPLETE=0 \
        SSL_SCHEDULER_MODE="" SSL_SCHEDULER_HAD_CRONTAB=0 \
        SSL_SCHEDULER_HAD_SERVICE=0 SSL_SCHEDULER_HAD_TIMER=0 \
        SSL_SCHEDULER_TIMER_ENABLED=0 SSL_SCHEDULER_TIMER_ACTIVE=0 \
        SSL_SCHEDULER_CROND_ENABLED=0 SSL_SCHEDULER_CROND_ACTIVE=0 \
        SSL_SCHEDULER_SYSTEMD_DIR="" SSL_SCHEDULER_DOCKER_MARKER=""
    [[ -z "$backup" ]] || rm -rf -- "$backup"
}

ssl_backup_scheduler_state() {
    local mode="$1" backup systemd_dir service_file timer_file marker
    [[ -z "$SSL_SCHEDULER_BACKUP" ]] || return 1
    mkdir -p "$X_MILI_CERT_ROOT" || return 1
    backup=$(mktemp -d "${X_MILI_CERT_ROOT}/.scheduler-state.XXXXXX") || return 1
    SSL_SCHEDULER_BACKUP="$backup" SSL_SCHEDULER_SNAPSHOT_COMPLETE=0 \
        SSL_SCHEDULER_MODE="$mode" SSL_SCHEDULER_HAD_CRONTAB=0 \
        SSL_SCHEDULER_HAD_SERVICE=0 SSL_SCHEDULER_HAD_TIMER=0 \
        SSL_SCHEDULER_TIMER_ENABLED=0 SSL_SCHEDULER_TIMER_ACTIVE=0 \
        SSL_SCHEDULER_CROND_ENABLED=0 SSL_SCHEDULER_CROND_ACTIVE=0 \
        SSL_SCHEDULER_SYSTEMD_DIR="" SSL_SCHEDULER_DOCKER_MARKER=""

    if command -v crontab > /dev/null 2>&1 \
        && crontab -l > "${backup}/crontab" 2> /dev/null; then
        SSL_SCHEDULER_HAD_CRONTAB=1
    fi

    case "$mode" in
        systemd)
            systemd_dir="${X_MILI_SYSTEMD_DIR:-/etc/systemd/system}"
            service_file="${systemd_dir}/x-mili-acme-renew.service"
            timer_file="${systemd_dir}/x-mili-acme-renew.timer"
            SSL_SCHEDULER_SYSTEMD_DIR="$systemd_dir"
            if [[ -e "$service_file" || -L "$service_file" ]]; then
                cp -a -- "$service_file" "${backup}/service" \
                    || { ssl_commit_scheduler_state; return 1; }
                SSL_SCHEDULER_HAD_SERVICE=1
            fi
            if [[ -e "$timer_file" || -L "$timer_file" ]]; then
                cp -a -- "$timer_file" "${backup}/timer" \
                    || { ssl_commit_scheduler_state; return 1; }
                SSL_SCHEDULER_HAD_TIMER=1
            fi
            systemctl is-enabled --quiet x-mili-acme-renew.timer 2> /dev/null \
                && SSL_SCHEDULER_TIMER_ENABLED=1
            systemctl is-active --quiet x-mili-acme-renew.timer 2> /dev/null \
                && SSL_SCHEDULER_TIMER_ACTIVE=1
            ;;
        cron)
            if command -v rc-update > /dev/null 2>&1 \
                && rc-update show default 2> /dev/null \
                    | grep -Eq '(^|[[:space:]])crond([[:space:]]|$)'; then
                SSL_SCHEDULER_CROND_ENABLED=1
            fi
            if command -v rc-service > /dev/null 2>&1 \
                && rc-service crond status > /dev/null 2>&1; then
                SSL_SCHEDULER_CROND_ACTIVE=1
            fi
            ;;
        docker)
            marker="${XUI_DB_FOLDER:-/etc/x-ui}/.x-mili-acme-renewal"
            SSL_SCHEDULER_DOCKER_MARKER="$marker"
            if [[ -e "$marker" || -L "$marker" ]]; then
                cp -a -- "$marker" "${backup}/docker-marker" \
                    || { ssl_commit_scheduler_state; return 1; }
            fi
            ;;
        *)
            ssl_commit_scheduler_state
            return 1
            ;;
    esac
    SSL_SCHEDULER_SNAPSHOT_COMPLETE=1
}

ssl_restore_scheduler_crontab() {
    local backup="$SSL_SCHEDULER_BACKUP"
    command -v crontab > /dev/null 2>&1 || {
        [[ $SSL_SCHEDULER_HAD_CRONTAB -eq 0 ]]
        return
    }
    if [[ $SSL_SCHEDULER_HAD_CRONTAB -eq 1 ]]; then
        crontab "${backup}/crontab"
    else
        crontab -r > /dev/null 2>&1 || ! crontab -l > /dev/null 2>&1
    fi
}

ssl_rollback_scheduler_state() {
    local backup="$SSL_SCHEDULER_BACKUP" rc=0 systemd_dir service_file timer_file marker
    [[ -n "$backup" && -d "$backup" ]] || return 1
    if [[ "$SSL_SCHEDULER_SNAPSHOT_COMPLETE" != "1" ]]; then
        ssl_commit_scheduler_state
        return 0
    fi

    case "$SSL_SCHEDULER_MODE" in
        systemd)
            systemd_dir="$SSL_SCHEDULER_SYSTEMD_DIR"
            service_file="${systemd_dir}/x-mili-acme-renew.service"
            timer_file="${systemd_dir}/x-mili-acme-renew.timer"
            systemctl disable --now x-mili-acme-renew.timer > /dev/null 2>&1 || true
            if [[ $SSL_SCHEDULER_HAD_SERVICE -eq 1 ]]; then
                rm -f -- "$service_file" || rc=1
                cp -a -- "${backup}/service" "$service_file" || rc=1
            else
                rm -f -- "$service_file" || rc=1
            fi
            if [[ $SSL_SCHEDULER_HAD_TIMER -eq 1 ]]; then
                rm -f -- "$timer_file" || rc=1
                cp -a -- "${backup}/timer" "$timer_file" || rc=1
            else
                rm -f -- "$timer_file" || rc=1
            fi
            systemctl daemon-reload > /dev/null 2>&1 || rc=1
            if [[ $SSL_SCHEDULER_HAD_TIMER -eq 1 ]]; then
                if [[ $SSL_SCHEDULER_TIMER_ENABLED -eq 1 ]]; then
                    systemctl enable x-mili-acme-renew.timer > /dev/null 2>&1 || rc=1
                else
                    systemctl disable x-mili-acme-renew.timer > /dev/null 2>&1 || rc=1
                fi
                if [[ $SSL_SCHEDULER_TIMER_ACTIVE -eq 1 ]]; then
                    systemctl start x-mili-acme-renew.timer > /dev/null 2>&1 || rc=1
                else
                    systemctl stop x-mili-acme-renew.timer > /dev/null 2>&1 || rc=1
                fi
            fi
            ;;
        cron)
            if command -v rc-update > /dev/null 2>&1 \
                && command -v rc-service > /dev/null 2>&1; then
                if [[ $SSL_SCHEDULER_CROND_ENABLED -eq 1 ]]; then
                    rc-update add crond default > /dev/null 2>&1 || rc=1
                else
                    rc-update del crond default > /dev/null 2>&1 || true
                fi
                if [[ $SSL_SCHEDULER_CROND_ACTIVE -eq 1 ]]; then
                    rc-service crond start > /dev/null 2>&1 || rc=1
                else
                    rc-service crond stop > /dev/null 2>&1 || true
                fi
            fi
            ;;
        docker)
            marker="$SSL_SCHEDULER_DOCKER_MARKER"
            if [[ -e "${backup}/docker-marker" || -L "${backup}/docker-marker" ]]; then
                rm -f -- "$marker" || rc=1
                cp -a -- "${backup}/docker-marker" "$marker" || rc=1
            else
                rm -f -- "$marker" || rc=1
            fi
            ;;
        *) rc=1 ;;
    esac

    ssl_restore_scheduler_crontab || rc=1
    if [[ $rc -eq 0 ]]; then
        ssl_commit_scheduler_state
    else
        ssl_log_e "自动续签调度器回滚不完整，快照保留在 ${backup}。" \
            "Renewal scheduler rollback was incomplete; snapshot kept at ${backup}."
    fi
    return "$rc"
}

ssl_acme_native_cron_present() {
    command -v crontab > /dev/null 2>&1 || return 1
    crontab -l 2> /dev/null | awk -v bin="$X_MILI_ACME_BIN" -v home="$X_MILI_ACME_HOME" '
        index($0, "--cron") && (index($0, bin) || index($0, home "/acme.sh")) {found=1}
        END {exit !found}
    '
}

ssl_install_cron_renewal() {
    local cron_tmp
    command -v crontab > /dev/null 2>&1 || return 1
    cron_tmp=$(mktemp /tmp/x-mili-acme-cron.XXXXXX) || return 1
    crontab -l 2> /dev/null | sed -e '\|/usr/bin/ml ssl cron|d' > "$cron_tmp" || true
    printf '17 3 * * * X_MILI_ACME_HOME=%s X_MILI_CERT_ROOT=%s /usr/bin/ml ssl cron >/dev/null 2>&1 # X-MILI managed renewal\n' \
        "$X_MILI_ACME_HOME" "$X_MILI_CERT_ROOT" >> "$cron_tmp"
    if ! crontab "$cron_tmp"; then
        rm -f -- "$cron_tmp"
        return 1
    fi
    rm -f -- "$cron_tmp"
    crontab -l 2> /dev/null | grep -Fq '/usr/bin/ml ssl cron' || return 1
    if command -v rc-update > /dev/null 2>&1 && command -v rc-service > /dev/null 2>&1; then
        rc-update add crond default > /dev/null 2>&1 || return 1
        rc-service crond start > /dev/null 2>&1 \
            || rc-service crond status > /dev/null 2>&1 || return 1
    elif command -v pgrep > /dev/null 2>&1; then
        pgrep -x cron > /dev/null 2>&1 || pgrep -x crond > /dev/null 2>&1 || return 1
    else
        return 1
    fi
}

ssl_install_systemd_renew_timer() {
    local systemd_dir="${X_MILI_SYSTEMD_DIR:-/etc/systemd/system}"
    local service_file="${systemd_dir}/x-mili-acme-renew.service"
    local timer_file="${systemd_dir}/x-mili-acme-renew.timer"
    local service_tmp timer_tmp
    if ! ssl_scheduler_path_is_safe "$X_MILI_ACME_HOME" \
        || ! ssl_scheduler_path_is_safe "$X_MILI_CERT_ROOT"; then
        ssl_log_e "ACME 或证书目录包含不适合特权续签任务的字符。" \
            "The ACME or certificate directory contains characters unsafe for a privileged renewal job."
        return 1
    fi
    mkdir -p "$systemd_dir" || return 1
    service_tmp=$(mktemp "${service_file}.XXXXXX") || return 1
    timer_tmp=$(mktemp "${timer_file}.XXXXXX") || { rm -f -- "$service_tmp"; return 1; }
    cat > "$service_tmp" <<EOF
[Unit]
Description=X-MILI ACME certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment="X_MILI_ACME_HOME=${X_MILI_ACME_HOME}"
Environment="X_MILI_CERT_ROOT=${X_MILI_CERT_ROOT}"
UMask=0077
ExecStart=/usr/bin/ml ssl cron
EOF
    cat > "$timer_tmp" <<'EOF'
[Unit]
Description=Daily X-MILI ACME certificate renewal

[Timer]
OnActiveSec=15min
OnUnitActiveSec=24h
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
    chown root:root "$service_tmp" "$timer_tmp" 2> /dev/null || true
    chmod 0644 "$service_tmp" "$timer_tmp" \
        || { rm -f -- "$service_tmp" "$timer_tmp"; return 1; }
    mv -f -- "$service_tmp" "$service_file" \
        && mv -f -- "$timer_tmp" "$timer_file" \
        || { rm -f -- "$service_tmp" "$timer_tmp"; return 1; }
    systemctl daemon-reload \
        && systemctl enable --now x-mili-acme-renew.timer > /dev/null \
        && systemctl is-enabled --quiet x-mili-acme-renew.timer \
        && systemctl is-active --quiet x-mili-acme-renew.timer
}

ssl_write_docker_renewal_marker() {
    local data_dir marker tmp
    data_dir="${XUI_DB_FOLDER:-/etc/x-ui}"
    marker="${data_dir}/.x-mili-acme-renewal"
    mkdir -p "$data_dir" || return 1
    tmp=$(mktemp "${marker}.XXXXXX") || return 1
    printf 'true\n' > "$tmp"
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$marker"
}

ssl_configure_auto_renew() {
    local mode configured=0
    if ! ssl_scheduler_path_is_safe "$X_MILI_ACME_HOME" \
        || ! ssl_scheduler_path_is_safe "$X_MILI_CERT_ROOT"; then
        ssl_log_e "ACME 或证书目录包含不适合特权续签任务的字符。" \
            "The ACME or certificate directory contains characters unsafe for a privileged renewal job."
        return 1
    fi

    if [[ -f /.dockerenv ]]; then
        mode=docker
    elif command -v systemctl > /dev/null 2>&1 \
        && systemctl show x-ui > /dev/null 2>&1; then
        mode=systemd
    else
        command -v crontab > /dev/null 2>&1 || return 1
        mode=cron
    fi

    ssl_backup_scheduler_state "$mode" || return 1
    case "$mode" in
        docker) ssl_write_docker_renewal_marker && configured=1 ;;
        systemd) ssl_install_systemd_renew_timer && configured=1 ;;
        cron) ssl_install_cron_renewal && configured=1 ;;
    esac
    if [[ $configured -ne 1 ]]; then
        ssl_rollback_scheduler_state || true
        return 1
    fi

    # The prior native acme.sh cron remains present until the replacement has
    # been installed and verified. Docker's host-side recreate reconstructs
    # the container crontab, so it performs this handoff outside the container.
    if [[ "$mode" != docker ]] && ssl_acme_native_cron_present; then
        "$X_MILI_ACME_BIN" --home "$X_MILI_ACME_HOME" --uninstall-cronjob > /dev/null 2>&1 || true
        if ssl_acme_native_cron_present; then
            ssl_log_e "新续签调度器已安装，但无法安全移除旧 acme.sh cron；正在回滚调度器。" \
                "The replacement scheduler was installed, but the old acme.sh cron could not be removed safely; rolling the scheduler back."
            ssl_rollback_scheduler_state || true
            return 1
        fi
    fi
    if [[ "$mode" == cron ]] \
        && ! crontab -l 2> /dev/null | grep -Fq '/usr/bin/ml ssl cron'; then
        ssl_rollback_scheduler_state || true
        return 1
    fi

    case "$mode" in
        docker) SSL_RENEWAL_MODE=docker-host ;;
        systemd) SSL_RENEWAL_MODE=systemd ;;
        cron) SSL_RENEWAL_MODE=cron ;;
    esac
}

ssl_install_acme_cert() {
    local domain="$1" mode source_dir source_key source_fullchain stage dest backup="" reload_cmd
    local -a ecc_arg=()
    mode=$(ssl_acme_mode "$domain")
    [[ "$mode" != none ]] || {
        ssl_log_e "acme.sh 中没有 ${domain} 的签发记录。" "No acme.sh issuance record exists for ${domain}."
        return 1
    }
    [[ "$mode" != ecc ]] || ecc_arg=(--ecc)
    if [[ "$mode" == ecc ]]; then
        source_dir="${X_MILI_ACME_HOME}/${domain}_ecc"
    else
        source_dir="${X_MILI_ACME_HOME}/${domain}"
    fi
    source_key="${source_dir}/${domain}.key"
    source_fullchain="${source_dir}/fullchain.cer"
    if [[ ! -s "$source_key" || ! -s "$source_fullchain" ]]; then
        ssl_log_e "acme.sh 源证书或私钥不存在。" "The acme.sh source certificate or key is missing."
        return 1
    fi
    mkdir -p "$X_MILI_CERT_ROOT" || return 1
    stage=$(mktemp -d "${X_MILI_CERT_ROOT}/.${domain}.new.XXXXXX") || return 1
    dest="${X_MILI_CERT_ROOT}/${domain}"

    if ! cp -- "$source_key" "${stage}/privkey.pem" \
        || ! cp -- "$source_fullchain" "${stage}/fullchain.pem"; then
        rm -rf -- "$stage"
        ssl_log_e "无法复制 acme.sh 源证书。" "Failed to copy the acme.sh source certificate."
        return 1
    fi
    if ! ssl_verify_cert_files "$domain" "${stage}/fullchain.pem" "${stage}/privkey.pem"; then
        rm -rf -- "$stage"
        ssl_log_e "新证书校验失败，旧证书未改动。" "The new certificate failed validation; the old certificate is untouched."
        return 1
    fi
    chmod 0600 "${stage}/privkey.pem"
    chmod 0644 "${stage}/fullchain.pem"

    SSL_CERT_BACKUP="" SSL_CERT_HAD_OLD=0 SSL_CERT_INSTALL_ACTIVE=0
    if [[ -e "$dest" || -L "$dest" ]] && { [[ ! -d "$dest" ]] || [[ -L "$dest" ]]; }; then
        rm -rf -- "$stage"
        ssl_log_e "证书目标不是安全的实体目录，已中止替换。" \
            "The certificate destination is not a safe physical directory; replacement was aborted."
        return 1
    fi
    if [[ -d "$dest" ]]; then
        backup="${X_MILI_CERT_ROOT}/.${domain}.old.$(date +%s).$$"
        SSL_CERT_BACKUP="$backup" SSL_CERT_HAD_OLD=1 SSL_CERT_INSTALL_ACTIVE=1
        if ! mv -- "$dest" "$backup"; then
            SSL_CERT_BACKUP="" SSL_CERT_HAD_OLD=0 SSL_CERT_INSTALL_ACTIVE=0
            rm -rf -- "$stage"
            return 1
        fi
    else
        SSL_CERT_INSTALL_ACTIVE=1
    fi
    if ! mv -- "$stage" "$dest"; then
        ssl_rollback_cert_install "$domain" || true
        return 1
    fi

    # acme.sh must never reload the panel outside this transaction. The panel
    # is applied, restarted, and probed only after certificate validation.
    reload_cmd=/bin/true
    if ! "$X_MILI_ACME_BIN" --install-cert -d "$domain" "${ecc_arg[@]}" \
        --key-file "${dest}/privkey.pem" \
        --fullchain-file "${dest}/fullchain.pem" \
        --reloadcmd "$reload_cmd" \
        || ! ssl_verify_cert_files "$domain" "${dest}/fullchain.pem" "${dest}/privkey.pem"; then
        ssl_rollback_cert_install "$domain" || true
        ssl_log_e "安装新证书失败，已恢复旧证书。" "Failed to install the new certificate; the old certificate was restored."
        return 1
    fi
}

ssl_commit_cert_install() {
    local backup="$SSL_CERT_BACKUP"
    # Make the committed destination ineligible for rollback before removing
    # its old backup. These assignments form one trap boundary in Bash.
    SSL_CERT_BACKUP="" SSL_CERT_HAD_OLD=0 SSL_CERT_INSTALL_ACTIVE=0
    [[ -z "$backup" ]] || rm -rf -- "$backup"
}

ssl_restore_cert_snapshot() {
    local domain="$1" snapshot="$2" dest displaced
    dest="${X_MILI_CERT_ROOT}/${domain}"
    displaced="${X_MILI_CERT_ROOT}/.${domain}.restore-displaced.$(date +%s).$$"
    if [[ ! -d "$snapshot" ]] \
        || ! ssl_verify_cert_key_pair "$domain" "${snapshot}/fullchain.pem" "${snapshot}/privkey.pem"; then
        ssl_log_e "旧证书快照无效，未覆盖当前文件：${snapshot}" \
            "The old certificate snapshot is invalid; current files were not replaced: ${snapshot}"
        return 1
    fi
    if [[ -e "$dest" ]]; then
        mv -- "$dest" "$displaced" || return 1
    else
        displaced=""
    fi
    if ! mv -- "$snapshot" "$dest"; then
        [[ -z "$displaced" ]] || mv -- "$displaced" "$dest" 2> /dev/null || true
        ssl_log_e "恢复旧证书失败，快照仍保留在 ${snapshot}。" \
            "Failed to restore the old certificate; snapshot remains at ${snapshot}."
        return 1
    fi
    if ! ssl_verify_cert_key_pair "$domain" "${dest}/fullchain.pem" "${dest}/privkey.pem"; then
        mv -- "$dest" "$snapshot" 2> /dev/null || true
        [[ -z "$displaced" ]] || mv -- "$displaced" "$dest" 2> /dev/null || true
        ssl_log_e "恢复后的证书校验失败，快照保留在 ${snapshot}。" \
            "The restored certificate failed validation; snapshot kept at ${snapshot}."
        return 1
    fi
    [[ -z "$displaced" ]] || rm -rf -- "$displaced"
    ssl_commit_cert_install
}

ssl_rollback_cert_install() {
    local domain="$1" dest
    dest="${X_MILI_CERT_ROOT}/${domain}"
    if [[ "$SSL_CERT_INSTALL_ACTIVE" != "1" && "$SSL_CERT_HAD_OLD" != "1" \
        && -z "$SSL_CERT_BACKUP" ]]; then
        return 0
    fi
    if [[ $SSL_CERT_HAD_OLD -eq 1 && -n "$SSL_CERT_BACKUP" && -d "$SSL_CERT_BACKUP" ]]; then
        ssl_restore_cert_snapshot "$domain" "$SSL_CERT_BACKUP"
        return
    fi
    if [[ $SSL_CERT_HAD_OLD -eq 1 ]]; then
        # The rollback state is published immediately before the atomic move
        # of the old destination. If the move had not happened when a signal
        # arrived, the original destination is still authoritative.
        if [[ -d "$dest" && -n "$SSL_CERT_BACKUP" && ! -e "$SSL_CERT_BACKUP" ]]; then
            SSL_CERT_BACKUP="" SSL_CERT_HAD_OLD=0 SSL_CERT_INSTALL_ACTIVE=0
            return 0
        fi
        return 1
    fi
    rm -rf -- "$dest" || return 1
    SSL_CERT_BACKUP="" SSL_CERT_HAD_OLD=0 SSL_CERT_INSTALL_ACTIVE=0
}

ssl_finish_issue() {
    local domain="$1" cert key
    if ! ssl_install_acme_cert "$domain"; then
        return 1
    fi
    cert="${X_MILI_CERT_ROOT}/${domain}/fullchain.pem"
    key="${X_MILI_CERT_ROOT}/${domain}/privkey.pem"
    if ! ssl_configure_auto_renew; then
        ssl_log_e "无法安装并验证自动续签调度，正在恢复旧证书。" \
            "Could not install and verify the renewal scheduler; restoring the old certificate."
        ssl_rollback_cert_install "$domain"
        restart 0 > /dev/null 2>&1 || true
        return 1
    fi
    if ! ssl_apply_panel_tls "$domain" "$cert" "$key"; then
        ssl_rollback_cert_install "$domain"
        restart 0 > /dev/null 2>&1 || true
        return 1
    fi
    "$X_MILI_ACME_BIN" --upgrade --auto-upgrade > /dev/null 2>&1 || true
    if [[ "${SSL_RENEWAL_MODE:-}" == docker-host ]]; then
        ssl_log_i "证书已保存；宿主机将根据共享标记安装自动续签任务。" \
            "Certificate saved; the host will install renewal scheduling from the shared marker."
    else
        ssl_log_i "证书已保存到 ${X_MILI_CERT_ROOT}/${domain}，自动续签调度已验证。" \
            "Certificate saved in ${X_MILI_CERT_ROOT}/${domain}; renewal scheduling was verified."
    fi
}

ssl_show_port_owner() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltnpH 2> /dev/null | awk -v p=":${port}$" '$4 ~ p'
    elif command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2> /dev/null || true
    fi
}

ssl_ufw_port_rule_exists() {
    local port="$1" status
    status=$(LC_ALL=C ufw status 2> /dev/null) || return 1
    awk -v plain="$port" -v tcp="${port}/tcp" '
        ($1 == plain || $1 == tcp) && $2 == "ALLOW" && $3 == "Anywhere" {found=1}
        END {exit !found}
    ' <<< "$status"
}

ssl_ufw_http_rule_exists() {
    ssl_ufw_port_rule_exists 80
}

ssl_prepare_http01_firewall() {
    local ufw_status zone auto_open="${X_MILI_AUTO_OPEN_FIREWALL:-true}"
    local runtime_open=0 permanent_open=0 changed=0 active=0

    ssl_log_i "脚本只能配置主机防火墙；云平台安全组/云防火墙仍需手动放行公网 TCP 80。" \
        "Only the host firewall can be configured here; allow public TCP 80 manually in the cloud security group/firewall."

    case "${auto_open,,}" in
        1|true|yes|on) ;;
        0|false|no|off)
            ssl_log_i "已关闭自动防火墙修改；请手动确认 TCP 80。" \
                "Automatic firewall changes are disabled; verify TCP 80 manually."
            return 0
            ;;
        *)
            ssl_log_e "X_MILI_AUTO_OPEN_FIREWALL 必须是 1/true/yes/on 或 0/false/no/off；未修改防火墙。" \
                "X_MILI_AUTO_OPEN_FIREWALL must be 1/true/yes/on or 0/false/no/off; no firewall change was made."
            return 1
            ;;
    esac

    if command -v ufw > /dev/null 2>&1; then
        ufw_status=$(LC_ALL=C ufw status 2> /dev/null || true)
        if grep -Eq '^Status:[[:space:]]*active[[:space:]]*$' <<< "$ufw_status"; then
            active=1
            if ssl_ufw_http_rule_exists; then
                ssl_log_i "UFW 已放行公网 TCP 80，现有规则保持不变。" \
                    "UFW already allows public TCP 80; the existing rule is unchanged."
            else
                if ! ufw allow 80/tcp > /dev/null \
                    || ! ssl_ufw_http_rule_exists; then
                    ssl_log_e "UFW TCP 80 规则添加或验证失败，已中止 HTTP-01。" \
                        "Failed to add or verify the UFW TCP 80 rule; HTTP-01 was aborted."
                    return 1
                fi
                changed=1
                ssl_log_i "UFW 已持久放行 TCP 80，规则将保留供自动续签使用。" \
                    "UFW now allows TCP 80; the rule is kept for automatic renewal."
            fi
        fi
    fi

    if command -v firewall-cmd > /dev/null 2>&1 \
        && [[ "$(firewall-cmd --state 2> /dev/null || true)" == running ]]; then
        active=1
        zone=$(firewall-cmd --get-default-zone 2> /dev/null || true)
        if [[ ! "$zone" =~ ^[A-Za-z0-9_-]+$ ]]; then
            ssl_log_e "无法安全确定 firewalld 默认 zone，已中止 HTTP-01。" \
                "Could not safely determine the firewalld default zone; HTTP-01 was aborted."
            return 1
        fi
        if firewall-cmd --quiet --zone="$zone" --query-port=80/tcp \
            || firewall-cmd --quiet --zone="$zone" --query-service=http; then
            runtime_open=1
        fi
        if firewall-cmd --quiet --permanent --zone="$zone" --query-port=80/tcp \
            || firewall-cmd --quiet --permanent --zone="$zone" --query-service=http; then
            permanent_open=1
        fi
        if [[ $permanent_open -eq 0 ]]; then
            firewall-cmd --quiet --permanent --zone="$zone" --add-port=80/tcp || {
                ssl_log_e "firewalld 持久 TCP 80 规则添加失败，已中止 HTTP-01。" \
                    "Failed to add the permanent firewalld TCP 80 rule; HTTP-01 was aborted."
                return 1
            }
            changed=1
        fi
        if [[ $runtime_open -eq 0 ]]; then
            firewall-cmd --quiet --zone="$zone" --add-port=80/tcp || {
                ssl_log_e "firewalld 运行时 TCP 80 规则添加失败，已中止 HTTP-01。" \
                    "Failed to add the runtime firewalld TCP 80 rule; HTTP-01 was aborted."
                return 1
            }
            changed=1
        fi
        if ! { firewall-cmd --quiet --zone="$zone" --query-port=80/tcp \
                || firewall-cmd --quiet --zone="$zone" --query-service=http; } \
            || ! { firewall-cmd --quiet --permanent --zone="$zone" --query-port=80/tcp \
                || firewall-cmd --quiet --permanent --zone="$zone" --query-service=http; }; then
            ssl_log_e "firewalld TCP 80 规则验证失败，已中止 HTTP-01。" \
                "Failed to verify the firewalld TCP 80 rule; HTTP-01 was aborted."
            return 1
        fi
        if [[ $runtime_open -eq 1 && $permanent_open -eq 1 ]]; then
            ssl_log_i "firewalld zone ${zone} 已放行 TCP 80，现有规则保持不变。" \
                "firewalld zone ${zone} already allows TCP 80; existing rules are unchanged."
        else
            ssl_log_i "firewalld zone ${zone} 已放行运行时和持久 TCP 80，规则将保留供自动续签使用。" \
                "firewalld zone ${zone} now allows runtime and permanent TCP 80; the rule is kept for automatic renewal."
        fi
    fi

    if [[ $active -eq 0 ]]; then
        ssl_log_i "未检测到活动的 UFW/firewalld；未修改主机防火墙。" \
            "No active UFW/firewalld was detected; no host firewall change was made."
    elif [[ $changed -eq 0 ]]; then
        : # Existing rules were deliberately left untouched.
    fi
}

ssl_firewalld_port_rule_exists() {
    local port="$1" zone="$2" scope="${3:-runtime}"
    local -a args=(--quiet --zone="$zone")
    [[ "$scope" != permanent ]] || args=(--quiet --permanent --zone="$zone")
    firewall-cmd "${args[@]}" --query-port="${port}/tcp" \
        || { [[ "$port" == 80 ]] && firewall-cmd "${args[@]}" --query-service=http; }
}

ssl_prepare_panel_firewall() {
    local port="$1" auto_open="${X_MILI_AUTO_OPEN_FIREWALL:-true}"
    local ufw_status zone runtime_open=0 permanent_open=0
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
        ssl_log_e "面板端口无效，未修改防火墙。" \
            "The panel port is invalid; no firewall change was made."
        return 1
    }
    ssl_log_i "脚本只能配置主机防火墙；云安全组/云防火墙仍需手动放行公网 TCP ${port}。" \
        "Only the host firewall can be configured here; allow public TCP ${port} manually in the cloud security group/firewall."
    case "${auto_open,,}" in
        1|true|yes|on) ;;
        0|false|no|off)
            ssl_log_i "已关闭自动防火墙修改；请手动确认面板端口 TCP ${port}。" \
                "Automatic firewall changes are disabled; verify panel TCP ${port} manually."
            return 0
            ;;
        *)
            ssl_log_e "X_MILI_AUTO_OPEN_FIREWALL 必须是 1/true/yes/on 或 0/false/no/off；未修改防火墙。" \
                "X_MILI_AUTO_OPEN_FIREWALL must be 1/true/yes/on or 0/false/no/off; no firewall change was made."
            return 1
            ;;
    esac

    if command -v ufw > /dev/null 2>&1; then
        ufw_status=$(LC_ALL=C ufw status 2> /dev/null || true)
        if grep -Eq '^Status:[[:space:]]*active[[:space:]]*$' <<< "$ufw_status" \
            && ! ssl_ufw_port_rule_exists "$port"; then
            if ! ufw allow "${port}/tcp" > /dev/null \
                || ! ssl_ufw_port_rule_exists "$port"; then
                ssl_log_e "UFW TCP ${port} 规则添加或验证失败，未启用公网 TLS。" \
                    "Failed to add or verify the UFW TCP ${port} rule; public TLS was not enabled."
                return 1
            fi
        fi
    fi

    if command -v firewall-cmd > /dev/null 2>&1 \
        && [[ "$(firewall-cmd --state 2> /dev/null || true)" == running ]]; then
        zone=$(firewall-cmd --get-default-zone 2> /dev/null || true)
        [[ "$zone" =~ ^[A-Za-z0-9_-]+$ ]] || {
            ssl_log_e "无法安全确定 firewalld 默认 zone，未启用公网 TLS。" \
                "Could not safely determine the firewalld default zone; public TLS was not enabled."
            return 1
        }
        ssl_firewalld_port_rule_exists "$port" "$zone" runtime && runtime_open=1
        ssl_firewalld_port_rule_exists "$port" "$zone" permanent && permanent_open=1
        if [[ $permanent_open -eq 0 ]]; then
            firewall-cmd --quiet --permanent --zone="$zone" --add-port="${port}/tcp" || return 1
        fi
        if [[ $runtime_open -eq 0 ]]; then
            firewall-cmd --quiet --zone="$zone" --add-port="${port}/tcp" || return 1
        fi
        ssl_firewalld_port_rule_exists "$port" "$zone" runtime \
            && ssl_firewalld_port_rule_exists "$port" "$zone" permanent || {
            ssl_log_e "firewalld TCP ${port} 规则验证失败，未启用公网 TLS。" \
                "Failed to verify the firewalld TCP ${port} rule; public TLS was not enabled."
            return 1
        }
    fi
}

ssl_prepare_webroot() {
    local domain="$1" webroot="${2:-}" resolved challenge token body
    if [[ -z "$webroot" ]]; then
        if is_zh; then
            read -rp "请输入现有 Web 服务器的网站根目录（例如 /var/www/html）: " webroot
        else
            read -rp "Enter the existing web server document root (for example /var/www/html): " webroot
        fi
    fi
    [[ -d "$webroot" ]] || { ssl_log_e "目录不存在。" "Directory does not exist."; return 1; }
    resolved=$(cd "$webroot" 2> /dev/null && pwd -P) || return 1
    case "$resolved" in
        /|/root|/etc|/home|/usr|/var)
            ssl_log_e "拒绝把敏感系统目录作为 ACME webroot。" "Refusing to use a sensitive system directory as ACME webroot."
            return 1
            ;;
    esac
    is_port_in_use 80 || {
        ssl_log_e "Webroot 模式需要已有 Web 服务器监听 TCP 80。" "Webroot mode requires an existing web server on TCP 80."
        return 1
    }
    challenge="${resolved}/.well-known/acme-challenge"
    mkdir -p "$challenge" || return 1
    token="x-mili-$RANDOM-$$"
    printf '%s' "$token" > "${challenge}/${token}" || return 1
    body=$(curl --noproxy '*' -fsSL --connect-timeout 4 --max-time 10 "http://${domain}/.well-known/acme-challenge/${token}" 2> /dev/null || true)
    rm -f -- "${challenge}/${token}"
    if [[ "$body" != "$token" ]]; then
        ssl_log_e "公网 Webroot 自检失败；域名/80 端口/网站目录至少一项不正确。" \
            "Public webroot self-test failed; DNS, port 80, or the document root is incorrect."
        return 1
    fi
    SSL_WEBROOT="$resolved"
}

ssl_cert_issue() {
    local requested_domain="${1:-}" requested_method="${2:-}" requested_webroot="${3:-}"
    local domain method cert_keylength=ec-256
    local -a issue_args
    ssl_read_domain "$requested_domain" || return 1
    domain="$SSL_SELECTED_DOMAIN"
    ssl_install_dependencies 0 || return 1
    ssl_dns_check "$domain" || return 1
    install_acme || return 1
    ssl_backup_acme_state "$domain" || return 1
    [[ "$(ssl_acme_mode "$domain")" != rsa ]] || cert_keylength=2048

    case "${requested_method,,}" in
        standalone) method=1 ;;
        webroot) method=2 ;;
        "")
            if is_zh; then
                echo -e "${green}1.${plain} Standalone（推荐，要求 80 端口空闲）"
                echo -e "${green}2.${plain} Webroot（已有 Nginx/Caddy/Apache 占用 80）"
                read -rp "验证方式 [1]: " method
            else
                echo -e "${green}1.${plain} Standalone (recommended; port 80 must be free)"
                echo -e "${green}2.${plain} Webroot (an existing web server owns port 80)"
                read -rp "Validation method [1]: " method
            fi
            ;;
        *)
            ssl_log_e "验证方式只能是 standalone 或 webroot。" "Validation method must be standalone or webroot."
            ssl_commit_acme_state
            return 1
            ;;
    esac
    if [[ -z "$requested_method" ]]; then
        method="${method:-1}"
    fi
    case "$method" in
        1|2)
            if ! ssl_prepare_http01_firewall; then
                ssl_commit_acme_state
                return 1
            fi
            ;;
    esac
    case "$method" in
        1)
            if ! ssl_install_dependencies 1; then
                ssl_commit_acme_state
                return 1
            fi
            if is_port_in_use 80; then
                ssl_log_e "TCP 80 已被占用，脚本不会终止未知进程：" \
                    "TCP 80 is occupied; the script will not kill an unknown process:"
                ssl_show_port_owner 80
                is_zh && echo "请先安全停止占用服务，或改用 Webroot。" || echo "Stop it safely or use webroot validation."
                ssl_commit_acme_state
                return 1
            fi
            issue_args=(--issue --server letsencrypt -d "$domain" --standalone --httpport 80 --keylength "$cert_keylength" --force)
            ;;
        2)
            if ! ssl_prepare_webroot "$domain" "$requested_webroot"; then
                ssl_commit_acme_state
                return 1
            fi
            issue_args=(--issue --server letsencrypt -d "$domain" --webroot "$SSL_WEBROOT" --keylength "$cert_keylength" --force)
            ;;
        *)
            ssl_log_e "无效选项。" "Invalid option."
            ssl_commit_acme_state
            return 1
            ;;
    esac

    ssl_log_i "开始签发；主机防火墙已检查，云安全组/云防火墙仍需手动放行公网 TCP 80。" \
        "Issuing now; the host firewall was checked, but the cloud security group/firewall must still allow public TCP 80."
    if ! ssl_prepare_acme_deploy_stage "$domain"; then
        ssl_rollback_acme_state "$domain" || true
        return 1
    fi
    if ! "$X_MILI_ACME_BIN" --set-default-ca --server letsencrypt > /dev/null; then
        ssl_cleanup_acme_deploy_stage
        ssl_rollback_acme_state "$domain" || true
        return 1
    fi
    if ! "$X_MILI_ACME_BIN" "${issue_args[@]}"; then
        ssl_cleanup_acme_deploy_stage
        ssl_rollback_acme_state "$domain" || true
        ssl_log_e "签发失败。现有面板证书和监听配置未修改。" \
            "Issuance failed. Existing panel certificate and listener settings were not changed."
        return 1
    fi
    if ssl_finish_issue "$domain"; then
        ssl_cleanup_acme_deploy_stage
        return 0
    fi
    ssl_cleanup_acme_deploy_stage
    ssl_rollback_acme_state "$domain" || true
    return 1
}

ssl_cert_issue_CF() {
    local requested_domain="${1:-}" domain auth_type token account_id global_key email cert_keylength=ec-256
    local rc
    ssl_read_domain "$requested_domain" || return 1
    domain="$SSL_SELECTED_DOMAIN"
    install_acme || return 1
    ssl_backup_acme_state "$domain" || return 1
    [[ "$(ssl_acme_mode "$domain")" != rsa ]] || cert_keylength=2048
    unset CF_Token CF_Account_ID CF_Zone_ID CF_Key CF_Email
    if is_zh; then
        echo -e "${green}1.${plain} Cloudflare API Token（推荐，Zone:DNS:Edit）"
        echo -e "${green}2.${plain} Global API Key + 邮箱"
        read -rp "认证方式 [1]: " auth_type
    else
        echo -e "${green}1.${plain} Cloudflare API Token (recommended, Zone:DNS:Edit)"
        echo -e "${green}2.${plain} Global API Key + email"
        read -rp "Authentication method [1]: " auth_type
    fi
    auth_type="${auth_type:-1}"
    case "$auth_type" in
        1)
            is_zh && read -rsp "API Token: " token || read -rsp "API Token: " token
            echo
            is_zh && read -rp "Account ID（通常可留空）: " account_id || read -rp "Account ID (usually optional): " account_id
            [[ -n "$token" ]] || {
                ssl_log_e "Token 不能为空。" "Token cannot be empty."
                ssl_commit_acme_state
                return 1
            }
            export CF_Token="$token"
            [[ -z "$account_id" ]] || export CF_Account_ID="$account_id"
            ;;
        2)
            is_zh && read -rsp "Global API Key: " global_key || read -rsp "Global API Key: " global_key
            echo
            is_zh && read -rp "Cloudflare 注册邮箱: " email || read -rp "Cloudflare account email: " email
            [[ -n "$global_key" && "$email" == *@* ]] || {
                ssl_log_e "API Key 或邮箱无效。" "Invalid API key or email."
                ssl_commit_acme_state
                return 1
            }
            export CF_Key="$global_key" CF_Email="$email"
            ;;
        *)
            ssl_log_e "无效选项。" "Invalid option."
            ssl_commit_acme_state
            return 1
            ;;
    esac

    if ! ssl_prepare_acme_deploy_stage "$domain"; then
        unset CF_Token CF_Account_ID CF_Zone_ID CF_Key CF_Email token account_id global_key
        ssl_rollback_acme_state "$domain" || true
        return 1
    fi
    "$X_MILI_ACME_BIN" --set-default-ca --server letsencrypt > /dev/null || rc=$?
    if [[ ${rc:-0} -eq 0 ]]; then
        "$X_MILI_ACME_BIN" --issue --server letsencrypt --dns dns_cf \
            -d "$domain" -d "*.${domain}" --keylength "$cert_keylength" --force
        rc=$?
    fi
    unset CF_Token CF_Account_ID CF_Zone_ID CF_Key CF_Email token account_id global_key
    if [[ ${rc:-1} -ne 0 ]]; then
        ssl_cleanup_acme_deploy_stage
        ssl_rollback_acme_state "$domain" || true
        ssl_log_e "Cloudflare DNS 验证签发失败；现有配置未修改。" \
            "Cloudflare DNS issuance failed; existing settings were not changed."
        return 1
    fi
    if ssl_finish_issue "$domain"; then
        ssl_cleanup_acme_deploy_stage
        ssl_log_i "Cloudflare 凭据已由 acme.sh 保存到共享 account.conf，供自动续签使用。" \
            "Cloudflare credentials were saved by acme.sh in shared account.conf for renewal."
        return 0
    fi
    ssl_cleanup_acme_deploy_stage
    ssl_rollback_acme_state "$domain" || true
    return 1
}

ssl_list_domains() {
    local path name
    [[ -d "$X_MILI_CERT_ROOT" ]] || return 0
    for path in "$X_MILI_CERT_ROOT"/*; do
        [[ -d "$path" ]] || continue
        name=$(basename "$path")
        ssl_valid_domain "$name" && printf '%s\n' "$name"
    done | sort -u
}

ssl_select_domain() {
    local input i=1 domain
    local -a domains=()
    while IFS= read -r domain; do domains+=("$domain"); done < <(ssl_list_domains)
    if [[ ${#domains[@]} -eq 0 ]]; then
        ssl_log_e "没有已安装的域名证书。" "No installed domain certificates were found."
        return 1
    fi
    for domain in "${domains[@]}"; do echo "  $i) $domain"; ((i++)); done
    is_zh && read -rp "请输入编号或完整域名: " input || read -rp "Enter a number or full domain: " input
    if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= ${#domains[@]})); then
        SSL_SELECTED_DOMAIN="${domains[input-1]}"
        return 0
    fi
    input=$(ssl_normalize_domain "$input")
    for domain in "${domains[@]}"; do
        [[ "$input" != "$domain" ]] || { SSL_SELECTED_DOMAIN="$domain"; return 0; }
    done
    ssl_log_e "选择无效。" "Invalid selection."
    return 1
}

ssl_show_certificates() {
    local current_cert current_key listen env_file domain cert key expiry issuer
    current_cert=$(ssl_panel_cert)
    current_key=$(ssl_panel_key)
    listen=$(ssl_panel_listen)
    echo
    is_zh && echo "面板证书: ${current_cert:-未设置}" || echo "Panel certificate: ${current_cert:-not set}"
    is_zh && echo "面板私钥: ${current_key:-未设置}" || echo "Panel key: ${current_key:-not set}"
    is_zh && echo "监听地址: ${listen:-0.0.0.0}" || echo "Listen address: ${listen:-0.0.0.0}"
    if ssl_insecure_http_enabled; then
        is_zh && echo -e "公网明文 HTTP: ${red}已显式开启${plain}" || echo -e "Public plaintext HTTP: ${red}explicitly enabled${plain}"
    else
        is_zh && echo -e "公网明文 HTTP: ${green}关闭${plain}" || echo -e "Public plaintext HTTP: ${green}disabled${plain}"
    fi
    if env_file=$(ssl_service_env_file 2> /dev/null); then
        is_zh && echo "环境文件: $env_file" || echo "Environment file: $env_file"
    elif [[ -f /.dockerenv ]]; then
        is_zh && echo "环境来源: Docker Compose" || echo "Environment source: Docker Compose"
    fi
    echo
    while IFS= read -r domain; do
        cert="${X_MILI_CERT_ROOT}/${domain}/fullchain.pem"
        key="${X_MILI_CERT_ROOT}/${domain}/privkey.pem"
        if ssl_verify_cert_files "$domain" "$cert" "$key"; then
            expiry=$(openssl x509 -in "$cert" -noout -enddate 2> /dev/null | cut -d= -f2-)
            issuer=$(openssl x509 -in "$cert" -noout -issuer 2> /dev/null | sed 's/^issuer=//')
            echo "${domain}"
            echo "  cert: $cert"
            echo "  key:  $key"
            is_zh && echo "  到期: $expiry" || echo "  expires: $expiry"
            is_zh && echo "  签发者: $issuer" || echo "  issuer: $issuer"
        else
            echo -e "${red}${domain}: invalid certificate/key${plain}"
        fi
    done < <(ssl_list_domains)
}

ssl_set_existing_cert() {
    local domain cert key
    ssl_select_domain || return 1
    domain="$SSL_SELECTED_DOMAIN"
    cert="${X_MILI_CERT_ROOT}/${domain}/fullchain.pem"
    key="${X_MILI_CERT_ROOT}/${domain}/privkey.pem"
    ssl_apply_panel_tls "$domain" "$cert" "$key"
}

ssl_renew_domain() {
    local domain="$1" force="${2:-false}" mode dest prebackup active=0 rc=0
    local -a ecc_arg=()
    local -a force_arg=()
    ssl_valid_domain "$domain" || return 1
    [[ -d "${X_MILI_CERT_ROOT}/${domain}" ]] || return 1
    mode=$(ssl_acme_mode "$domain")
    [[ "$mode" != none ]] || { ssl_log_e "acme.sh 中没有续签记录。" "No acme.sh renewal record was found."; return 1; }
    [[ "$mode" != ecc ]] || ecc_arg=(--ecc)
    ssl_is_true "$force" && force_arg=(--force)
    dest="${X_MILI_CERT_ROOT}/${domain}"
    [[ "$(ssl_panel_cert)" == "${dest}/fullchain.pem" ]] && active=1
    prebackup=$(mktemp -d "${X_MILI_CERT_ROOT}/.${domain}.renew-old.XXXXXX") || return 1
    cp -a -- "${dest}/." "$prebackup/" || { rm -rf -- "$prebackup"; return 1; }
    if ! ssl_verify_cert_key_pair "$domain" "${prebackup}/fullchain.pem" "${prebackup}/privkey.pem"; then
        ssl_log_e "当前证书快照校验失败，未开始续签。" "The current certificate snapshot is invalid; renewal was not started."
        rm -rf -- "$prebackup"
        return 1
    fi
    ssl_backup_acme_state "$domain" || { rm -rf -- "$prebackup"; return 1; }
    if ! ssl_prepare_acme_deploy_stage "$domain"; then
        ssl_rollback_acme_state "$domain" || true
        rm -rf -- "$prebackup"
        return 1
    fi

    "$X_MILI_ACME_BIN" --renew -d "$domain" "${ecc_arg[@]}" "${force_arg[@]}" || rc=$?
    if [[ $rc -eq 2 && ${#force_arg[@]} -eq 0 ]]; then
        ssl_cleanup_acme_deploy_stage
        ssl_rollback_acme_state "$domain" || true
        rm -rf -- "$prebackup"
        ssl_log_i "证书尚未到续签时间，已安全跳过：${domain}" \
            "Certificate is not due yet; safely skipped: ${domain}"
        return 2
    fi
    if [[ $rc -eq 0 ]]; then
        ssl_install_acme_cert "$domain" || rc=$?
    fi
    if [[ $rc -eq 0 && $active -eq 1 ]]; then
        ssl_apply_panel_tls "$domain" "${dest}/fullchain.pem" "${dest}/privkey.pem" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        if ssl_restore_cert_snapshot "$domain" "$prebackup"; then
            [[ $active -eq 0 ]] || restart 0 > /dev/null 2>&1 || true
            ssl_log_e "续签或验证失败，已恢复旧证书。" "Renewal or verification failed; the old certificate was restored."
        else
            ssl_log_e "续签失败且自动恢复未完成，请按上方快照路径手动检查。" \
                "Renewal failed and automatic restore was incomplete; inspect the snapshot path shown above."
        fi
        ssl_cleanup_acme_deploy_stage
        ssl_rollback_acme_state "$domain" || true
        return 1
    fi
    ssl_cleanup_acme_deploy_stage
    ssl_commit_transaction_state
    rm -rf -- "$prebackup"
    ssl_log_i "证书续签完成。" "Certificate renewed successfully."
}

ssl_renew_cert() {
    ssl_select_domain || return 1
    ssl_renew_domain "$SSL_SELECTED_DOMAIN" true
}

ssl_choose_http_fallback() {
    local choice
    if is_zh; then
        echo -e "${green}1.${plain} 临时公网 IP HTTP（0.0.0.0 + 显式不安全开关）"
        echo -e "${green}2.${plain} 安全本机模式（127.0.0.1，需 SSH 隧道）"
        read -rp "关闭 TLS 后的访问方式 [2]: " choice
    else
        echo -e "${green}1.${plain} Temporary public-IP HTTP (0.0.0.0 + explicit insecure opt-in)"
        echo -e "${green}2.${plain} Safe localhost mode (127.0.0.1; use an SSH tunnel)"
        read -rp "Access mode after disabling TLS [2]: " choice
    fi
    choice="${choice:-2}"
    case "$choice" in
        1)
            if is_zh; then
                confirm "公网明文会暴露账号、密码和订阅令牌，确认仅临时开启？" "n" || return 1
            else
                confirm "Public plaintext exposes credentials and subscription tokens. Enable temporarily?" "n" || return 1
            fi
            SSL_DISABLE_MODE=public
            ;;
        2) SSL_DISABLE_MODE=local ;;
        *) return 1 ;;
    esac
}

ssl_disable_tls() {
    local mode="$1" old_cert old_key old_listen old_insecure=false listen insecure port public_ip
    old_cert=$(ssl_panel_cert)
    old_key=$(ssl_panel_key)
    old_listen=$(ssl_panel_listen)
    ssl_insecure_http_enabled && old_insecure=true
    SSL_PANEL_OLD_CERT="$old_cert"
    SSL_PANEL_OLD_KEY="$old_key"
    SSL_PANEL_OLD_LISTEN="$old_listen"
    SSL_PANEL_OLD_INSECURE="$old_insecure"
    SSL_PANEL_ROLLBACK_ACTIVE=1
    if [[ "$mode" == public ]]; then
        listen=0.0.0.0
        insecure=true
    else
        listen=127.0.0.1
        insecure=false
    fi
    if ! ssl_set_insecure_http "$insecure" \
        || ! ssl_set_panel_cert "" "" \
        || ! ssl_set_panel_listen "$listen" \
        || ! restart 0 \
        || ! ssl_verify_local_http; then
        ssl_log_e "关闭 TLS 失败，正在恢复原配置。" "Failed to disable TLS; restoring the previous configuration."
        ssl_restore_panel_state "$old_cert" "$old_key" "$old_listen" "$old_insecure" \
            && ssl_commit_panel_state
        return 1
    fi
    port=$(ssl_panel_port)
    if [[ "$mode" == public ]]; then
        if [[ ! -f /.dockerenv ]] && ! ssl_public_listener_active "$port"; then
            ssl_log_e "未检测到公网监听，正在恢复原配置。" "No public listener was detected; restoring the previous configuration."
            ssl_restore_panel_state "$old_cert" "$old_key" "$old_listen" "$old_insecure" \
                && ssl_commit_panel_state
            return 1
        fi
        public_ip=$(ssl_get_public_ipv4 || echo "SERVER_IP")
        echo -e "${yellow}http://${public_ip}:${port}$(ssl_panel_path)${plain}"
        ssl_log_i "仅作首次配置，请尽快重新绑定域名证书。" "Use only for initial setup; bind a domain certificate as soon as possible."
    else
        echo -e "${yellow}ssh -L ${port}:127.0.0.1:${port} root@SERVER_IP${plain}"
        echo -e "${green}http://127.0.0.1:${port}$(ssl_panel_path)${plain}"
    fi
}

ssl_disable_tls_menu() {
    ssl_choose_http_fallback || return 1
    ssl_disable_tls "$SSL_DISABLE_MODE"
}

ssl_revoke_delete_cert() {
    local domain mode cert_path quarantine active=0 disabled=0
    local -a ecc_arg=()
    ssl_select_domain || return 1
    domain="$SSL_SELECTED_DOMAIN"
    if is_zh; then
        confirm "确认吊销并删除 ${domain} 的证书？此操作不可撤销。" "n" || return 0
    else
        confirm "Revoke and delete ${domain}? This cannot be undone." "n" || return 0
    fi
    mode=$(ssl_acme_mode "$domain")
    if [[ "$mode" == none ]]; then
        if is_zh; then
            confirm "没有 ACME 记录，只删除本地证书文件？" "n" || return 0
        else
            confirm "No ACME record exists. Delete only the local files?" "n" || return 0
        fi
    fi
    cert_path="${X_MILI_CERT_ROOT}/${domain}"
    if [[ ! -d "$cert_path" || -L "$cert_path" ]]; then
        ssl_log_e "证书目标不是安全的实体目录，已中止删除。" \
            "The certificate target is not a safe physical directory; deletion was aborted."
        return 1
    fi
    [[ "$(ssl_panel_cert)" == "${cert_path}/fullchain.pem" ]] && active=1
    if [[ $active -eq 1 ]]; then
        ssl_choose_http_fallback || return 1
        ssl_disable_tls "$SSL_DISABLE_MODE" || return 1
        disabled=1
    fi
    if [[ "$mode" != none ]]; then
        [[ "$mode" != ecc ]] || ecc_arg=(--ecc)
        # Revocation is irreversible. From this point, an interrupt with an
        # unknown command outcome must keep the selected HTTP fallback rather
        # than risk serving a certificate that may already be revoked.
        [[ $disabled -eq 0 ]] || SSL_PANEL_ROLLBACK_FORBIDDEN=1
        if ! "$X_MILI_ACME_BIN" --revoke -d "$domain" "${ecc_arg[@]}"; then
            SSL_PANEL_ROLLBACK_FORBIDDEN=0
            ssl_log_e "吊销失败，证书文件未删除。" "Revocation failed; certificate files were not deleted."
            return 1
        fi
        [[ $disabled -eq 0 ]] || ssl_commit_panel_state
        if ! "$X_MILI_ACME_BIN" --remove -d "$domain" "${ecc_arg[@]}"; then
            [[ $disabled -eq 0 ]] || ssl_log_e \
                "证书已吊销，面板将保持所选 HTTP 回退模式，不会重新启用该证书。" \
                "The certificate is revoked; the panel remains in the selected HTTP fallback mode and will not re-enable it."
            ssl_log_e "证书已吊销，但移除 acme.sh 记录失败；本地文件暂未删除。" \
                "Certificate was revoked, but removing its acme.sh record failed; local files were kept."
            return 1
        fi
    fi
    # Rename inside CERT_ROOT first. The same-filesystem rename is atomic, so a
    # failed move leaves the live directory intact and safe to re-bind.
    if [[ "$mode" == none && $disabled -eq 1 ]]; then
        SSL_PANEL_ROLLBACK_FORBIDDEN=1
    fi
    quarantine="${X_MILI_CERT_ROOT}/.${domain}.delete.$(date +%s).$$"
    if ! mv -- "$cert_path" "$quarantine"; then
        [[ "$mode" != none || $disabled -eq 0 ]] || SSL_PANEL_ROLLBACK_FORBIDDEN=0
        ssl_log_e "无法原子隔离证书目录；原文件保持不变。" \
            "Could not atomically quarantine the certificate directory; original files are unchanged."
        return 1
    fi
    if [[ "$mode" == none && $disabled -eq 1 ]]; then
        ssl_commit_panel_state
    fi
    if ! rm -rf -- "$quarantine"; then
        ssl_log_e "证书已从活动路径隔离，但清理未完成：${quarantine}" \
            "The certificate was quarantined from its active path, but cleanup is incomplete: ${quarantine}"
        return 1
    fi
    ssl_log_i "证书已吊销并删除：${domain}" "Certificate revoked and deleted: ${domain}"
}

ssl_cert_issue_main() {
    local choice
    while true; do
        echo
        if is_zh; then
            echo -e "${green}1.${plain} 申请/替换域名证书（HTTP-01）"
            echo -e "${green}2.${plain} Cloudflare DNS 申请（支持通配符）"
            echo -e "${green}3.${plain} 查看证书与当前 TLS 状态"
            echo -e "${green}4.${plain} 强制续签证书"
            echo -e "${green}5.${plain} 将已有证书绑定到面板"
            echo -e "${green}6.${plain} 吊销并删除证书"
            echo -e "${green}7.${plain} 关闭 TLS / 选择 HTTP 回退模式"
            echo -e "${green}0.${plain} 返回"
            read -rp "请选择: " choice
        else
            echo -e "${green}1.${plain} Issue/replace a domain certificate (HTTP-01)"
            echo -e "${green}2.${plain} Issue with Cloudflare DNS (wildcard supported)"
            echo -e "${green}3.${plain} Show certificates and current TLS state"
            echo -e "${green}4.${plain} Force-renew a certificate"
            echo -e "${green}5.${plain} Bind an existing certificate to the panel"
            echo -e "${green}6.${plain} Revoke and delete a certificate"
            echo -e "${green}7.${plain} Disable TLS / choose HTTP fallback mode"
            echo -e "${green}0.${plain} Back"
            read -rp "Choose an option: " choice
        fi
        case "$choice" in
            1) ssl_with_transaction ssl_cert_issue || true ;;
            2) ssl_with_transaction ssl_cert_issue_CF || true ;;
            3) ssl_show_certificates ;;
            4) ssl_with_transaction ssl_renew_cert || true ;;
            5) ssl_with_transaction ssl_set_existing_cert || true ;;
            6) ssl_with_transaction ssl_revoke_delete_cert || true ;;
            7) ssl_with_transaction ssl_disable_tls_menu || true ;;
            0) return 0 ;;
            *) ssl_log_e "无效选项。" "Invalid option." ;;
        esac
    done
}

ssl_run_cron() {
    local domain rc failed=0 renewed=0 skipped=0
    [[ -x "$X_MILI_ACME_BIN" ]] || {
        ssl_log_e "acme.sh 尚未安装。" "acme.sh is not installed."
        return 1
    }
    while IFS= read -r domain; do
        [[ "$(ssl_acme_mode "$domain")" != none ]] || continue
        if ssl_renew_domain "$domain" false; then
            rc=0
        else
            rc=$?
        fi
        case "$rc" in
            0) ((renewed += 1)) ;;
            2) ((skipped += 1)) ;;
            *) ((failed += 1)) ;;
        esac
    done < <(ssl_list_domains)
    ssl_log_i "自动续签检查完成：续签 ${renewed}，跳过 ${skipped}，失败 ${failed}。" \
        "Renewal check complete: renewed ${renewed}, skipped ${skipped}, failed ${failed}."
    [[ $failed -eq 0 ]]
}

ssl_command() {
    local action="${1:-menu}"
    [[ $# -eq 0 ]] || shift
    case "$action" in
        menu) ssl_cert_issue_main ;;
        issue) ssl_with_transaction ssl_cert_issue "$@" ;;
        cloudflare|cf) ssl_with_transaction ssl_cert_issue_CF "$@" ;;
        show|status) ssl_show_certificates ;;
        cron) ssl_with_transaction ssl_run_cron ;;
        *)
            if is_zh; then
                echo "用法: ml ssl [menu|show|issue <域名> [standalone|webroot] [webroot目录]|cloudflare <域名>]"
            else
                echo "Usage: ml ssl [menu|show|issue <domain> [standalone|webroot] [webroot-path]|cloudflare <domain>]"
            fi
            return 2
            ;;
    esac
}

run_speedtest() {
    # Check if Speedtest is already installed
    if ! command -v speedtest &> /dev/null; then
        # If not installed, determine installation method
        if command -v snap &> /dev/null; then
            # Use snap to install Speedtest
            echo "Installing Speedtest using snap..."
            snap install speedtest
        else
            # Fallback to using package managers
            local pkg_manager=""
            local speedtest_install_script=""

            if command -v dnf &> /dev/null; then
                pkg_manager="dnf"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v yum &> /dev/null; then
                pkg_manager="yum"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v apt-get &> /dev/null; then
                pkg_manager="apt-get"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            elif command -v apt &> /dev/null; then
                pkg_manager="apt"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            fi

            if [[ -z $pkg_manager ]]; then
                echo "Error: Package manager not found. You may need to install Speedtest manually."
                return 1
            else
                echo "Installing Speedtest using $pkg_manager..."
                curl -s $speedtest_install_script | bash
                $pkg_manager install -y speedtest
            fi
        fi
    fi

    speedtest
}

ip_validation() {
    ipv6_regex="^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
    ipv4_regex="^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$"
}

iplimit_main() {
    if is_zh; then
        echo -e "\n${green}\t1.${plain} 安装 Fail2ban 并配置 IP 限制"
        echo -e "${green}\t2.${plain} 修改封禁时长"
        echo -e "${green}\t3.${plain} 解除全部封禁"
        echo -e "${green}\t4.${plain} 查看封禁日志"
        echo -e "${green}\t5.${plain} 封禁一个 IP"
        echo -e "${green}\t6.${plain} 解封一个 IP"
        echo -e "${green}\t7.${plain} 实时日志"
        echo -e "${green}\t8.${plain} 服务状态"
        echo -e "${green}\t9.${plain} 重启服务"
        echo -e "${green}\t10.${plain} 卸载 Fail2ban 和 IP 限制"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice
    else
    echo -e "\n${green}\t1.${plain} Install Fail2ban and configure IP Limit"
    echo -e "${green}\t2.${plain} Change Ban Duration"
    echo -e "${green}\t3.${plain} Unban Everyone"
    echo -e "${green}\t4.${plain} Ban Logs"
    echo -e "${green}\t5.${plain} Ban an IP Address"
    echo -e "${green}\t6.${plain} Unban an IP Address"
    echo -e "${green}\t7.${plain} Real-Time Logs"
    echo -e "${green}\t8.${plain} Service Status"
    echo -e "${green}\t9.${plain} Service Restart"
    echo -e "${green}\t10.${plain} Uninstall Fail2ban and IP Limit"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " choice
    fi
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            if is_zh; then
                confirm "确定要安装 Fail2ban & 配置 IP 限制吗？" "y"
            else
                confirm "Proceed with installation of Fail2ban & IP Limit?" "y"
            fi
            if [[ $? == 0 ]]; then
                install_iplimit
            else
                iplimit_main
            fi
            ;;
        2)
            if is_zh; then
                read -rp "请输入新的封禁时长 (分钟) [默认 30]: " NUM
            else
                read -rp "Please enter new Ban Duration in Minutes [default 30]: " NUM
            fi
            if [[ $NUM =~ ^[0-9]+$ ]]; then
                create_iplimit_jails ${NUM}
                if [[ $release == "alpine" ]]; then
                    rc-service fail2ban restart
                else
                    systemctl restart fail2ban
                fi
            else
                is_zh && echo -e "${red}${NUM} 不是一个有效的数字！请重试。${plain}" || echo -e "${red}${NUM} is not a number! Please, try again.${plain}"
            fi
            iplimit_main
            ;;
        3)
            if is_zh; then
                confirm "确定要解封所有的被限制 IP 吗？" "y"
            else
                confirm "Proceed with Unbanning everyone from IP Limit jail?" "y"
            fi
            if [[ $? == 0 ]]; then
                fail2ban-client reload --restart --unban 3x-ipl
                truncate -s 0 "${iplimit_banned_log_path}"
                is_zh && echo -e "${green}所有用户均已成功解封。${plain}" || echo -e "${green}All users Unbanned successfully.${plain}"
                iplimit_main
            else
                is_zh && echo -e "${yellow}操作已取消。${plain}" || echo -e "${yellow}Cancelled.${plain}"
            fi
            iplimit_main
            ;;
        4)
            show_banlog
            iplimit_main
            ;;
        5)
            is_zh && read -rp "请输入要封禁的 IP 地址: " ban_ip || read -rp "Enter the IP address you want to ban: " ban_ip
            ip_validation
            if [[ $ban_ip =~ $ipv4_regex || $ban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl banip "$ban_ip"
                is_zh && echo -e "${green}IP 地址 ${ban_ip} 已成功封禁。${plain}" || echo -e "${green}IP Address ${ban_ip} has been banned successfully.${plain}"
            else
                is_zh && echo -e "${red}IP 地址格式无效！请重试。${plain}" || echo -e "${red}Invalid IP address format! Please try again.${plain}"
            fi
            iplimit_main
            ;;
        6)
            is_zh && read -rp "请输入要解封的 IP 地址: " unban_ip || read -rp "Enter the IP address you want to unban: " unban_ip
            ip_validation
            if [[ $unban_ip =~ $ipv4_regex || $unban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl unbanip "$unban_ip"
                is_zh && echo -e "${green}IP 地址 ${unban_ip} 已成功解封。${plain}" || echo -e "${green}IP Address ${unban_ip} has been unbanned successfully.${plain}"
            else
                is_zh && echo -e "${red}IP 地址格式无效！请重试。${plain}" || echo -e "${red}Invalid IP address format! Please try again.${plain}"
            fi
            iplimit_main
            ;;
        7)
            tail -f /var/log/fail2ban.log
            iplimit_main
            ;;
        8)
            service fail2ban status
            iplimit_main
            ;;
        9)
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            iplimit_main
            ;;
        10)
            remove_iplimit
            iplimit_main
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            iplimit_main
            ;;
    esac
}

install_iplimit() {
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${green}Fail2ban is not installed. Installing now...!${plain}\n"

        # Install fail2ban together with nftables. Recent fail2ban packages
        # default to `banaction = nftables-multiport` in /etc/fail2ban/jail.conf,
        # but the `nftables` package isn't pulled in as a dependency on most
        # minimal server images (Debian 12+, Ubuntu 24+, fresh RHEL-family).
        # Without `nft` in PATH the default sshd jail fails to ban with
        #   stderr: '/bin/sh: 1: nft: not found'
        # even though our own 3x-ipl jail uses iptables. Bundling the binary
        # at install time prevents that confusing log spam for new installs.
        case "${release}" in
            ubuntu)
                apt-get update
                if [[ "${os_version}" -ge 24 ]]; then
                    apt-get install python3-pip -y
                    python3 -m pip install pyasynchat --break-system-packages
                fi
                apt-get install fail2ban nftables -y
                ;;
            debian)
                apt-get update
                if [ "$os_version" -ge 12 ]; then
                    apt-get install -y python3-systemd
                fi
                apt-get install -y fail2ban nftables
                ;;
            armbian)
                apt-get update && apt-get install fail2ban nftables -y
                ;;
            fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                dnf -y update && dnf -y install fail2ban nftables
                ;;
            centos)
                if [[ "${VERSION_ID}" =~ ^7 ]]; then
                    yum update -y && yum install epel-release -y
                    yum -y install fail2ban nftables
                else
                    dnf -y update && dnf -y install fail2ban nftables
                fi
                ;;
            arch | manjaro | parch)
                pacman -Syu --noconfirm fail2ban nftables
                ;;
            alpine)
                apk add fail2ban nftables
                ;;
            *)
                echo -e "${red}Unsupported operating system. Please check the script and install the necessary packages manually.${plain}\n"
                exit 1
                ;;
        esac

        if ! command -v fail2ban-client &> /dev/null; then
            echo -e "${red}Fail2ban installation failed.${plain}\n"
            exit 1
        fi

        echo -e "${green}Fail2ban installed successfully!${plain}\n"
    else
        echo -e "${yellow}Fail2ban is already installed.${plain}\n"
    fi

    echo -e "${green}Configuring IP Limit...${plain}\n"

    # make sure there's no conflict for jail files
    iplimit_remove_conflicts

    # Check if log file exists
    if ! test -f "${iplimit_banned_log_path}"; then
        touch ${iplimit_banned_log_path}
    fi

    # Check if service log file exists so fail2ban won't return error
    if ! test -f "${iplimit_log_path}"; then
        touch ${iplimit_log_path}
    fi

    # Create the iplimit jail files
    # we didn't pass the bantime here to use the default value
    create_iplimit_jails

    # Launching fail2ban
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            rc-service fail2ban start
        else
            rc-service fail2ban restart
        fi
        rc-update add fail2ban
    else
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
        else
            systemctl restart fail2ban
        fi
        systemctl enable fail2ban
    fi

    echo -e "${green}IP Limit installed and configured successfully!${plain}\n"
    before_show_menu
}

remove_iplimit() {
    echo -e "${green}\t1.${plain} Only remove IP Limit configurations"
    echo -e "${green}\t2.${plain} Uninstall Fail2ban and IP Limit"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -rp "Choose an option: " num
    case "$num" in
        1)
            rm -f /etc/fail2ban/filter.d/3x-ipl.conf
            rm -f /etc/fail2ban/action.d/3x-ipl.conf
            rm -f /etc/fail2ban/jail.d/3x-ipl.conf
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            echo -e "${green}IP Limit removed successfully!${plain}\n"
            before_show_menu
            ;;
        2)
            rm -rf /etc/fail2ban
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban stop
            else
                systemctl stop fail2ban
            fi
            case "${release}" in
                ubuntu | debian | armbian)
                    apt-get remove -y fail2ban
                    apt-get purge -y fail2ban -y
                    apt-get autoremove -y
                    ;;
                fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                    dnf remove fail2ban -y
                    dnf autoremove -y
                    ;;
                centos)
                    if [[ "${VERSION_ID}" =~ ^7 ]]; then
                        yum remove fail2ban -y
                        yum autoremove -y
                    else
                        dnf remove fail2ban -y
                        dnf autoremove -y
                    fi
                    ;;
                arch | manjaro | parch)
                    pacman -Rns --noconfirm fail2ban
                    ;;
                alpine)
                    apk del fail2ban
                    ;;
                *)
                    echo -e "${red}Unsupported operating system. Please uninstall Fail2ban manually.${plain}\n"
                    exit 1
                    ;;
            esac
            echo -e "${green}Fail2ban and IP Limit removed successfully!${plain}\n"
            before_show_menu
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            remove_iplimit
            ;;
    esac
}

show_banlog() {
    local system_log="/var/log/fail2ban.log"

    echo -e "${green}Checking ban logs...${plain}\n"

    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            echo -e "${red}Fail2ban service is not running!${plain}\n"
            return 1
        fi
    else
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${red}Fail2ban service is not running!${plain}\n"
            return 1
        fi
    fi

    if [[ -f "$system_log" ]]; then
        echo -e "${green}Recent system ban activities from fail2ban.log:${plain}"
        grep "3x-ipl" "$system_log" | grep -E "Ban|Unban" | tail -n 10 || echo -e "${yellow}No recent system ban activities found${plain}"
        echo ""
    fi

    if [[ -f "${iplimit_banned_log_path}" ]]; then
        echo -e "${green}3X-IPL ban log entries:${plain}"
        if [[ -s "${iplimit_banned_log_path}" ]]; then
            grep -v "INIT" "${iplimit_banned_log_path}" | tail -n 10 || echo -e "${yellow}No ban entries found${plain}"
        else
            echo -e "${yellow}Ban log file is empty${plain}"
        fi
    else
        echo -e "${red}Ban log file not found at: ${iplimit_banned_log_path}${plain}"
    fi

    echo -e "\n${green}Current jail status:${plain}"
    fail2ban-client status 3x-ipl || echo -e "${yellow}Unable to get jail status${plain}"
}

create_iplimit_jails() {
    # Use default bantime if not passed => 30 minutes
    local bantime="${1:-30}"

    # Uncomment 'allowipv6 = auto' in fail2ban.conf
    sed -i 's/#allowipv6 = auto/allowipv6 = auto/g' /etc/fail2ban/fail2ban.conf

    # On Debian 12+ fail2ban's default backend should be changed to systemd
    if [[ "${release}" == "debian" && ${os_version} -ge 12 ]]; then
        sed -i '0,/action =/s/backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
    fi

    cat << EOF > /etc/fail2ban/jail.d/3x-ipl.conf
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${iplimit_log_path}
maxretry=2
findtime=32
bantime=${bantime}m
EOF

    cat << EOF > /etc/fail2ban/filter.d/3x-ipl.conf
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    cat << EOF > /etc/fail2ban/action.d/3x-ipl.conf
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -p <protocol> -j f2b-<name>

actionstop = <iptables> -D <chain> -p <protocol> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> ${iplimit_banned_log_path}

actionunban = <iptables> -D f2b-<name> -s <ip> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> ${iplimit_banned_log_path}

[Init]
name = default
protocol = tcp
chain = INPUT
EOF

    echo -e "${green}Ip Limit jail files created with a bantime of ${bantime} minutes.${plain}"
}

iplimit_remove_conflicts() {
    local jail_files=(
        /etc/fail2ban/jail.conf
        /etc/fail2ban/jail.local
    )

    for file in "${jail_files[@]}"; do
        # Check for [3x-ipl] config in jail file then remove it
        if test -f "${file}" && grep -qw '3x-ipl' ${file}; then
            sed -i "/\[3x-ipl\]/,/^$/d" ${file}
            echo -e "${yellow}Removing conflicts of [3x-ipl] in jail (${file})!${plain}\n"
        fi
    done
}

SSH_port_forwarding() {
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]')
        if [[ "${http_code}" == "200" && -n "${ip_result}" ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local existing_key=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'key: .+' | awk '{print $2}')

    local config_listenIP=""
    local listen_choice=""

    if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
        is_zh && echo -e "${green}面板已使用 SSL 证书加密，非常安全。${plain}" || echo -e "${green}Panel is secure with SSL.${plain}"
        before_show_menu
    fi
    if [[ -z "$existing_cert" && -z "$existing_key" && (-z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0") ]]; then
        if is_zh; then
            echo -e "\n${red}警告：未检测到 SSL 证书和私钥！面板目前处于未加密状态。${plain}"
            echo "建议您申请 SSL 证书，或者配置 SSH 端口转发以保障安全。"
        else
            echo -e "\n${red}Warning: No Cert and Key found! The panel is not secure.${plain}"
            echo "Please obtain a certificate or set up SSH port forwarding."
        fi
    fi

    if [[ -n "$existing_listenIP" && "$existing_listenIP" != "0.0.0.0" && (-z "$existing_cert" && -z "$existing_key") ]]; then
        if is_zh; then
            echo -e "\n${green}当前 SSH 端口转发配置:${plain}"
            echo -e "标准 SSH 转发命令:"
            echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\n如果是使用 SSH 密钥连接:"
            echo -e "${yellow}ssh -i <密钥路径> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\n连接成功后，在浏览器访问本地地址打开面板:"
            echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
        else
            echo -e "\n${green}Current SSH Port Forwarding Configuration:${plain}"
            echo -e "Standard SSH command:"
            echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\nIf using SSH key:"
            echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\nAfter connecting, access the panel at:"
            echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
        fi
    fi

    if is_zh; then
        echo -e "\n请选择:"
        echo -e "${green}1.${plain} 设置监听 IP (Listen IP)"
        echo -e "${green}2.${plain} 清除监听 IP"
        echo -e "${green}0.${plain} 返回主菜单"
        read -rp "请选择: " num
    else
        echo -e "\nChoose an option:"
        echo -e "${green}1.${plain} Set listen IP"
        echo -e "${green}2.${plain} Clear listen IP"
        echo -e "${green}0.${plain} Back to Main Menu"
        read -rp "Choose an option: " num
    fi

    case "$num" in
        1)
            if [[ -z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0" ]]; then
                if is_zh; then
                    echo -e "\n未配置监听 IP。请选择:"
                    echo -e "1. 使用默认 IP (127.0.0.1)"
                    echo -e "2. 设置自定义 IP"
                    read -rp "请选择 (1 或 2): " listen_choice
                else
                    echo -e "\nNo listenIP configured. Choose an option:"
                    echo -e "1. Use default IP (127.0.0.1)"
                    echo -e "2. Set a custom IP"
                    read -rp "Select an option (1 or 2): " listen_choice
                fi

                config_listenIP="127.0.0.1"
                if [[ "$listen_choice" == "2" ]]; then
                    is_zh && read -rp "请输入自定义监听 IP: " config_listenIP || read -rp "Enter custom IP to listen on: " config_listenIP
                fi

                ${xui_folder}/x-ui setting -listenIP "${config_listenIP}" > /dev/null 2>&1
                if is_zh; then
                    echo -e "${green}监听 IP 已成功设置为 ${config_listenIP}。${plain}"
                    echo -e "\n${green}SSH 端口转发配置:${plain}"
                    echo -e "标准 SSH 转发命令:"
                    echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                    echo -e "\n如果是使用 SSH 密钥连接:"
                    echo -e "${yellow}ssh -i <密钥路径> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                    echo -e "\n连接成功后，在浏览器访问本地地址打开面板:"
                    echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                else
                    echo -e "${green}listen IP has been set to ${config_listenIP}.${plain}"
                    echo -e "\n${green}SSH Port Forwarding Configuration:${plain}"
                    echo -e "Standard SSH command:"
                    echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                    echo -e "\nIf using SSH key:"
                    echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                    echo -e "\nAfter connecting, access the panel at:"
                    echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                fi
                restart
            else
                config_listenIP="${existing_listenIP}"
                is_zh && echo -e "${green}当前监听 IP 已设置为 ${config_listenIP}。${plain}" || echo -e "${green}Current listen IP is already set to ${config_listenIP}.${plain}"
            fi
            ;;
        2)
            ${xui_folder}/x-ui setting -listenIP 0.0.0.0 > /dev/null 2>&1
            is_zh && echo -e "${green}监听 IP 已成功清除。${plain}" || echo -e "${green}Listen IP has been cleared.${plain}"
            restart
            ;;
        0)
            show_menu
            ;;
        *)
            is_zh && echo -e "${red}无效选项。请选择正确的数字。${plain}\n" || echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
            SSH_port_forwarding
            ;;
    esac
}

show_usage() {
    if is_zh; then
        echo -e "${blue}ml ssl${plain}                    - SSL 证书管理"
        echo -e "${blue}ml ssl issue <域名> standalone${plain} - 使用 HTTP-01 申请并绑定"
    else
        echo -e "${blue}ml ssl${plain}                    - SSL certificate management"
        echo -e "${blue}ml ssl issue <domain> standalone${plain} - issue and bind with HTTP-01"
    fi
    if is_zh; then
        echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}X-MILI 控制菜单用法（子命令）:${plain}                              │
│                                                                │
│  ${blue}ml${plain}                        - 管理脚本                         │
│  ${blue}ml start${plain}                  - 启动                             │
│  ${blue}ml stop${plain}                   - 停止                             │
│  ${blue}ml restart${plain}                - 重启面板                         │
│  ${blue}ml restart-xray${plain}           - 重启 Xray                        │
│  ${blue}ml status${plain}                 - 查看状态                         │
│  ${blue}ml settings${plain}               - 查看当前设置                     │
│  ${blue}ml enable${plain}                 - 开机自启                         │
│  ${blue}ml disable${plain}                - 关闭开机自启                     │
│  ${blue}ml log${plain}                    - 查看日志                         │
│  ${blue}ml banlog${plain}                 - 查看封禁日志                     │
│  ${blue}ml update${plain}                 - 更新                             │
│  ${blue}ml update-all-geofiles${plain}    - 更新 Geo 文件                    │
│  ${blue}ml install${plain}                - 安装                             │
│  ${blue}ml uninstall${plain}              - 卸载                             │
└────────────────────────────────────────────────────────────────┘"
        return
    fi
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}X-MILI control menu usages (subcommands):${plain}                     │
│                                                                │
│  ${blue}ml${plain}                        - Admin Management Script           │
│  ${blue}ml start${plain}                  - Start                             │
│  ${blue}ml stop${plain}                   - Stop                              │
│  ${blue}ml restart${plain}                - Restart                           │
|  ${blue}ml restart-xray${plain}           - Restart Xray                      │
│  ${blue}ml status${plain}                 - Current Status                    │
│  ${blue}ml settings${plain}               - Current Settings                  │
│  ${blue}ml enable${plain}                 - Enable Autostart on OS Startup    │
│  ${blue}ml disable${plain}                - Disable Autostart on OS Startup   │
│  ${blue}ml log${plain}                    - Check logs                        │
│  ${blue}ml banlog${plain}                 - Check Fail2ban ban logs           │
│  ${blue}ml update${plain}                 - Update                            │
│  ${blue}ml update-all-geofiles${plain}    - Update all geo files              │
│  ${blue}ml install${plain}                - Install                           │
│  ${blue}ml uninstall${plain}              - Uninstall                         │
└────────────────────────────────────────────────────────────────┘"
}

show_menu() {
    choose_language
    if is_zh; then
        echo -e "
╔────────────────────────────────────────────────╗
│   ${green}X-MILI 面板管理脚本${plain}                         │
│   ${green}0.${plain} 退出脚本                                 │
│────────────────────────────────────────────────│
│   ${green}1.${plain} 安装                                     │
│   ${green}2.${plain} 更新                                     │
│   ${green}3.${plain} 更新菜单                                 │
│   ${green}4.${plain} 卸载                                     │
│────────────────────────────────────────────────│
│   ${green}5.${plain} 重置用户名和密码                         │
│   ${green}6.${plain} 重置面板访问路径                         │
│   ${green}7.${plain} 重置面板设置                             │
│   ${green}8.${plain} 修改端口                                 │
│   ${green}9.${plain} 查看当前设置                             │
│────────────────────────────────────────────────│
│  ${green}10.${plain} 启动                                     │
│  ${green}11.${plain} 停止                                     │
│  ${green}12.${plain} 重启面板                                 │
|  ${green}13.${plain} 重启 Xray                                │
│  ${green}14.${plain} 查看状态                                 │
│  ${green}15.${plain} 日志管理                                 │
│────────────────────────────────────────────────│
│  ${green}16.${plain} 开启开机自启                             │
│  ${green}17.${plain} 关闭开机自启                             │
│────────────────────────────────────────────────│
│  ${green}18.${plain} SSL 证书管理                             │
│  ${green}19.${plain} Cloudflare SSL 证书                      │
│  ${green}20.${plain} IP 限制管理                              │
│  ${green}21.${plain} 防火墙管理                               │
│  ${green}22.${plain} SSH 端口转发管理                         │
│────────────────────────────────────────────────│
│  ${green}23.${plain} 启用 BBR                                 │
│  ${green}24.${plain} 更新 Geo 文件                            │
│  ${green}25.${plain} Ookla 测速                               │
╚────────────────────────────────────────────────╝
"
        show_status
        echo && read -rp "请输入选项 [0-25]: " num
    else
    echo -e "
╔────────────────────────────────────────────────╗
│   ${green}X-MILI Panel Management Script${plain}                │
│   ${green}0.${plain} Exit Script                               │
│────────────────────────────────────────────────│
│   ${green}1.${plain} Install                                   │
│   ${green}2.${plain} Update                                    │
│   ${green}3.${plain} Update Menu                               │
│   ${green}4.${plain} Uninstall                                 │
│────────────────────────────────────────────────│
│   ${green}5.${plain} Reset Username & Password                 │
│   ${green}6.${plain} Reset Web Base Path                       │
│   ${green}7.${plain} Reset Settings                            │
│   ${green}8.${plain} Change Port                               │
│   ${green}9.${plain} View Current Settings                     │
│────────────────────────────────────────────────│
│  ${green}10.${plain} Start                                     │
│  ${green}11.${plain} Stop                                      │
│  ${green}12.${plain} Restart                                   │
|  ${green}13.${plain} Restart Xray                              │
│  ${green}14.${plain} Check Status                              │
│  ${green}15.${plain} Logs Management                           │
│────────────────────────────────────────────────│
│  ${green}16.${plain} Enable Autostart                          │
│  ${green}17.${plain} Disable Autostart                         │
│────────────────────────────────────────────────│
│  ${green}18.${plain} SSL Certificate Management                │
│  ${green}19.${plain} Cloudflare SSL Certificate                │
│  ${green}20.${plain} IP Limit Management                       │
│  ${green}21.${plain} Firewall Management                       │
│  ${green}22.${plain} SSH Port Forwarding Management            │
│────────────────────────────────────────────────│
│  ${green}23.${plain} Enable BBR                                │
│  ${green}24.${plain} Update Geo Files                          │
│  ${green}25.${plain} Speedtest by Ookla                        │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "Please enter your selection [0-25]: " num
    fi

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            check_uninstall && install
            ;;
        2)
            check_install && update
            ;;
        3)
            check_install && update_menu
            ;;
        4)
            uninstall
            ;;
        5)
            check_install && reset_user
            ;;
        6)
            check_install && reset_webbasepath
            ;;
        7)
            check_install && reset_config
            ;;
        8)
            check_install && set_port
            ;;
        9)
            check_install && check_config
            ;;
        10)
            check_install && start
            ;;
        11)
            check_install && stop
            ;;
        12)
            check_install && restart
            ;;
        13)
            check_install && restart_xray
            ;;
        14)
            check_install && status
            ;;
        15)
            check_install && show_log
            ;;
        16)
            check_install && enable
            ;;
        17)
            check_install && disable
            ;;
        18)
            ssl_cert_issue_main
            ;;
        19)
            ssl_with_transaction ssl_cert_issue_CF
            ;;
        20)
            iplimit_main
            ;;
        21)
            firewall_menu
            ;;
        22)
            SSH_port_forwarding
            ;;
        23)
            bbr_menu
            ;;
        24)
            update_geo
            ;;
        25)
            run_speedtest
            ;;
        *)
            is_zh && LOGE "请输入正确的选项 [0-25]" || LOGE "Please enter the correct number [0-25]"
            ;;
    esac
}

if [[ $# -gt 0 ]]; then
    case $1 in
        "start")
            check_install 0 && start 0
            ;;
        "stop")
            check_install 0 && stop 0
            ;;
        "restart")
            check_install 0 && restart 0
            ;;
        "restart-xray")
            check_install 0 && restart_xray 0
            ;;
        "status")
            check_install 0 && status 0
            ;;
        "settings")
            check_install 0 && check_config 0
            ;;
        "ssl")
            shift
            check_install 0 && ssl_command "$@"
            ;;
        "ssl-reload")
            check_install 0 && restart 0
            ;;
        "enable")
            check_install 0 && enable 0
            ;;
        "disable")
            check_install 0 && disable 0
            ;;
        "log")
            check_install 0 && show_log 0
            ;;
        "banlog")
            check_install 0 && show_banlog 0
            ;;
        "update")
            shift
            check_install 0 && update "$@"
            ;;
        "install")
            check_uninstall 0 && install 0
            ;;
        "uninstall")
            uninstall 0
            ;;
        "update-all-geofiles")
            check_install 0 && update_all_geofiles 0 && restart 0
            ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
