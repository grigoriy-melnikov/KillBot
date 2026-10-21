#!/bin/bash
#
# Refresh KillBot from the main branch (default) or from a git ref / GitHub Release.
#
# Usage:
#   sudo /opt/killbot/UpdateAll.sh
#   sudo /opt/killbot/UpdateAll.sh main
#   sudo /opt/killbot/UpdateAll.sh latest
#   sudo /opt/killbot/UpdateAll.sh v3.4
#   sudo /opt/killbot/UpdateAll.sh <commit>
#
set -e

KB_GIT_REPO="${KB_GIT_REPO:-grigoriy-melnikov/KillBot}"
REF="${1:-main}"

usage() {
    echo "Usage: $0 [main|latest|TAG|BRANCH|COMMIT]"
    echo "  (no arg) / main     installer and files from the main branch"
    echo "  latest              installer from GitHub Releases latest"
    echo "  v3.4                installer from that GitHub Release"
    echo "  BRANCH / COMMIT     installer and files from that git revision"
    exit 1
}

case "$REF" in
    -h|--help) usage ;;
esac

if [[ ! "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$REF" == *..* ]]; then
    echo "ERROR: invalid ref: ${REF}"
    usage
fi

is_release_tag() {
    [[ "$1" =~ ^v?[0-9]+(\.[0-9]+)*$ ]]
}

release_tag() {
    local tag="$1"
    [[ "$tag" == v* ]] || tag="v${tag}"
    echo "$tag"
}

installer_url() {
    local ref="$1" tag
    case "$ref" in
        latest|release)
            echo "https://github.com/${KB_GIT_REPO}/releases/latest/download/kb_install.sh"
            ;;
        *)
            if is_release_tag "$ref"; then
                tag="$(release_tag "$ref")"
                echo "https://github.com/${KB_GIT_REPO}/releases/download/${tag}/kb_install.sh"
            else
                echo "https://raw.githubusercontent.com/${KB_GIT_REPO}/${ref}/kb_install.sh"
            fi
            ;;
    esac
}

install_ref() {
    local ref="$1"
    case "$ref" in
        latest|release)
            echo "main"
            ;;
        *)
            if is_release_tag "$ref"; then
                release_tag "$ref"
            else
                echo "$ref"
            fi
            ;;
    esac
}

URL="$(installer_url "$REF")"
KB_GIT_REF="$(install_ref "$REF")"

rm -f kbi.sh
rm -f kb_install.sh
echo "Downloading kb_install.sh from ${URL}"
wget -O kbi.sh "$URL"
chmod +x kbi.sh
echo "Installing with KB_GIT_REF=${KB_GIT_REF}"
yes '' | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a KB_GIT_REF="${KB_GIT_REF}" ./kbi.sh
