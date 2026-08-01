#!/bin/bash
# ============================================================
#  colors.sh — Shared UI Library (Clean & Professional, No Emojis)
#  Source file ini di setiap script: source /etc/vpn/lib/colors.sh
# ============================================================

# ── Warna Dasar ───────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m'

# ── Bold ───────────────────────────────────────────────────
BRED='\033[1;31m'
BGREEN='\033[1;32m'
BYELLOW='\033[1;33m'
BBLUE='\033[1;34m'
BPURPLE='\033[1;35m'
BCYAN='\033[1;36m'
BWHITE='\033[1;37m'

# ── Background ─────────────────────────────────────────────
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_BLUE='\033[44m'
BG_PURPLE='\033[45m'
BG_CYAN='\033[46m'

# ── Simbol ─────────────────────────────────────────────────
OK="[OK]"
FAIL="[FAIL]"
ARROW=">"
BULLET="-"

# ── Fungsi Output ──────────────────────────────────────────
info()    { echo -e "${CYAN}${ARROW} ${NC}${1}"; }
success() { echo -e "${BGREEN}${OK} ${NC}${1}"; }
error()   { echo -e "${BRED}${FAIL} ${NC}${1}"; }
warn()    { echo -e "${BYELLOW}[!] ${NC}${1}"; }
bold()    { echo -e "${BWHITE}${1}${NC}"; }

# ── Divider / Header ───────────────────────────────────────
divider() {
    echo -e "${CYAN}------------------------------------------------${NC}"
}

header() {
    local title="${1}"
    divider
    printf "${BG_BLUE}${BWHITE}%*s${NC}\n" $(( (${#title} + 48) / 2 )) "${title}"
    divider
}

section() {
    echo -e ""
    echo -e "${BCYAN}--- ${1} ------------------------------------------${NC}"
}

status_line() {
    local label="${1}"
    local state="${2}"
    if [[ "${state}" == "running" || "${state}" == "active" ]]; then
        printf "  ${BWHITE}%-28s${NC} ${BGREEN}[ RUNNING ]${NC}\n" "${label}"
    else
        printf "  ${BWHITE}%-28s${NC} ${BRED}[ STOPPED ]${NC}\n" "${label}"
    fi
}

press_any_key() {
    echo ""
    read -n 1 -s -r -p "$(echo -e "${YELLOW}Tekan tombol apapun untuk kembali...${NC}")"
    echo ""
}

confirm() {
    local msg="${1:-Apakah kamu yakin?}"
    echo -ne "${BYELLOW}${msg} [y/N]: ${NC}"
    read -r answer
    [[ "${answer,,}" == "y" ]]
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "Script ini harus dijalankan sebagai root!"
        exit 1
    fi
}

VPN_CONF="/etc/vpn/config.conf"
get_config() {
    local key="${1}"
    grep -i "^${key}=" "${VPN_CONF}" 2>/dev/null | cut -d'=' -f2
}

TODAY=$(date +"%Y-%m-%d")
NOW=$(date +"%Y-%m-%d %H:%M:%S")
