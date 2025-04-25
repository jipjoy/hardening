#!/bin/bash

set -e

# Locate script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTDIR="$SCRIPT_DIR/cis-hardening"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H%M%SZ")
RUNDIR="$ROOTDIR/runs/$TIMESTAMP"
mkdir -p "$RUNDIR"

ROLEDIR="$ROOTDIR/roles/UBUNTU22-CIS"
GROUPVAR="$ROOTDIR/group_vars/all.yml"
PLAYBOOK="$ROOTDIR/playbook.yml"
LOGFILE="$RUNDIR/hardening.log"
SUMMARY_JSON="$RUNDIR/summary.json"
NEEDS_REBOOT_FLAG="$ROOTDIR/.needs_reboot"
BACKUP_DIR="$RUNDIR/backups"
mkdir -p "$BACKUP_DIR"

RESET=false
DRYRUN=false
AUDITONLY=false
VERBOSE=false
NOLOG=false
LEVEL="1"
RESTORE=false
ENABLE_PASSWORD_SSH=false

show_help() {
  echo "Usage: ./ubuntu22-cis-harden.sh [options]"
  echo
  echo "Options:"
  echo "  --reset               Remove all config, previous runs, and role"
  echo "  --dry-run             Run Ansible in check mode"
  echo "  --audit-only          Run only audit-tagged tasks"
  echo "  --verbose             Enable Ansible debug output (-vvv)"
  echo "  --no-log              Don’t save output to log file"
  echo "  --level [1|2]         Set CIS level to apply (default: 1)"
  echo "  --restore             Restore backed-up configs (latest run only)"
  echo "  --enable-password-ssh Enable SSH password login and SFTP pre-fix"
  echo "  --help                Show this help and exit"
  exit 0
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --reset) RESET=true ;;
    --dry-run) DRYRUN=true ;;
    --audit-only) AUDITONLY=true ;;
    --verbose) VERBOSE=true ;;
    --no-log) NOLOG=true ;;
    --restore) RESTORE=true ;;
    --enable-password-ssh) ENABLE_PASSWORD_SSH=true ;;
    --help) show_help ;;
    --level)
      shift
      if [ -n "$1" ] && [[ "$1" =~ ^[12]$ ]]; then
        LEVEL="$1"
      else
        echo "[!] Error: --level requires 1 or 2"
        exit 1
      fi ;;
    *) echo "[!] Unknown option: $1"; show_help ;;
  esac
  shift
done

if [ "$RESTORE" = true ]; then
  echo "[!] Restoring backed-up configs from latest run..."
  LATEST_BACKUP=$(find "$ROOTDIR/runs" -type d -name backups | sort | tail -n1)
  if [ -d "$LATEST_BACKUP" ]; then
    for file in "$LATEST_BACKUP"/*.bak; do
      [ -f "$file" ] && sudo cp "$file" "/etc/ssh/$(basename "${file%.bak}")" && echo "[✔] Restored: $(basename "$file")"
    done
    sudo systemctl restart sshd
    echo "[✔] SSH service restarted."
  else
    echo "[!] No backup found to restore."
  fi
  exit 0
fi

if [ "$RESET" = true ]; then
  echo "[!] --reset: Removing previous setup..."
  rm -rf "$ROOTDIR/runs" "$ROLEDIR" "$GROUPVAR" "$PLAYBOOK"
fi

mkdir -p "$ROOTDIR/group_vars" "$ROOTDIR/roles"

if [ "$NOLOG" = false ]; then
  touch "$LOGFILE"
  exec > >(tee -a "$LOGFILE") 2>&1
fi

echo "========== $TIMESTAMP =========="
echo "[+] Starting CIS 2.0.0 Hardening (Ansible Lockdown) - Level $LEVEL"

# Check network reachability for apt update logic
APT_REACHABLE=false
if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
  APT_REACHABLE=true
fi

if ! command -v ansible >/dev/null 2>&1; then
  if [ "$APT_REACHABLE" = true ]; then
    echo "[+] Installing Ansible..."
    sudo apt update
    sudo apt install -y software-properties-common
    sudo apt-add-repository --yes --update ppa:ansible/ansible
    sudo apt install -y ansible git
  else
    echo "[!] Cannot reach internet to install Ansible. Aborting."
    exit 1
  fi
else
  echo "[OK] Ansible already installed"
fi

cd "$ROOTDIR"

if [ ! -d "$ROLEDIR" ]; then
  echo "[+] Cloning Ansible Lockdown UBUNTU22-CIS v2.0.0..."
  git clone --branch 2.0.0 https://github.com/ansible-lockdown/UBUNTU22-CIS.git "$ROLEDIR"
else
  echo "[OK] UBUNTU22-CIS v2.0.0 role already present"
fi

if [ ! -f "$PLAYBOOK" ]; then
  cat > "$PLAYBOOK" << 'EOF'
- name: Harden Ubuntu 22.04 CIS v2.0.0
  hosts: localhost
  become: yes
  roles:
    - UBUNTU22-CIS
EOF
fi

cat > "$GROUPVAR" <<EOF
ubuntu22cis_level_1: $( [ "$LEVEL" = "1" ] && echo true || echo false )
ubuntu22cis_level_2: $( [ "$LEVEL" = "2" ] && echo true || echo false )
ubuntu22cis_skip_package_update: true
EOF

for f in /etc/ssh/sshd_config; do
  [ -f "$f" ] && sudo cp "$f" "$BACKUP_DIR/$(basename "$f").bak"
  echo "[+] Backed up: $f"
done

SSH_PATCH_APPLIED=false
if [ "$ENABLE_PASSWORD_SSH" = true ]; then
  echo "[+] Enabling SSH password authentication and SFTP"
  BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date -u +%Y-%m-%dT%H%M%SZ)"
  sudo cp /etc/ssh/sshd_config "$BACKUP_FILE"
  sudo sed -i 's/^\s*PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
  sudo sed -i '/^#.*PasswordAuthentication/ s/^#//' /etc/ssh/sshd_config
  grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo "PasswordAuthentication yes" | sudo tee -a /etc/ssh/sshd_config
  sudo sed -i 's/^\s*AuthenticationMethods publickey/#AuthenticationMethods publickey/' /etc/ssh/sshd_config
  sudo sed -i 's|^Subsystem sftp .*|Subsystem sftp /usr/lib/openssh/sftp-server -f AUTHPRIV -l INFO|' /etc/ssh/sshd_config
  sudo systemctl restart ssh || { echo '[!] Failed to restart sshd'; exit 1; }
  SSH_PATCH_APPLIED=true
fi

sudo sed -i 's|^Subsystem sftp .*|Subsystem sftp /usr/lib/openssh/sftp-server -f AUTHPRIV -l INFO|' /etc/ssh/sshd_config
sudo systemctl restart sshd

ANSIBLE_CMD="ansible-playbook -i localhost, -c local $PLAYBOOK"
[ "$DRYRUN" = true ] && ANSIBLE_CMD+=" --check"
[ "$AUDITONLY" = true ] && ANSIBLE_CMD+=" --tags audit"
[ "$VERBOSE" = true ] && ANSIBLE_CMD+=" -vvv"

START_TIME_RAW=$(date +%s)
HOSTNAME=$(hostname)

echo "[+] Running: $ANSIBLE_CMD"

RUN_STATUS=0
if ! sudo bash -c "$ANSIBLE_CMD"; then
  echo "[!] Ansible run failed"
  RUN_STATUS=1
fi

REBOOT_NEEDED=false
if [ "$AUDITONLY" = false ] && [ "$DRYRUN" = false ]; then
  if [ -f /var/run/reboot-required ]; then
    echo "[!] Reboot required"
    REBOOT_NEEDED=true
    touch "$NEEDS_REBOOT_FLAG"
  fi
fi

END_TIME_RAW=$(date +%s)
DURATION_SEC=$((END_TIME_RAW - START_TIME_RAW))

S1=0; S2=0
ssh -q -o BatchMode=yes localhost "exit" || S1=$?
sftp -q -oBatchMode=yes localhost <<< "exit" || S2=$?

mkdir -p "$(dirname "$SUMMARY_JSON")"
cat > "$SUMMARY_JSON" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "hostname": "$HOSTNAME",
  "mode": "$( [ "$AUDITONLY" = true ] && echo 'audit-only' || ([ "$DRYRUN" = true ] && echo 'dry-run' || echo 'full-apply'))",
  "cis_level": "$LEVEL",
  "reboot_required": $REBOOT_NEEDED,
  "ssh_patch_applied": $SSH_PATCH_APPLIED,
  "apt_reachable": $APT_REACHABLE,
  "status": "$( [ "$RUN_STATUS" -eq 0 ] && echo 'success' || echo 'failed')",
  "ssh_check": $S1,
  "sftp_check": $S2,
  "duration_seconds": $DURATION_SEC,
  "log_file": "$LOGFILE",
  "role_path": "$ROLEDIR"
}
EOF

cat "$SUMMARY_JSON"

ln -sf "$SUMMARY_JSON" "$ROOTDIR/latest.json"
[ "$NOLOG" = false ] && ln -sf "$LOGFILE" "$ROOTDIR/latest.log"

if [ "$REBOOT_NEEDED" = true ]; then
  echo "[↻] Rebooting in 10 seconds..."
  sleep 10
  sudo reboot
fi

echo "[✔] Done — mode: $(grep mode "$SUMMARY_JSON" | cut -d '"' -f4), status: $(grep status "$SUMMARY_JSON" | cut -d '"' -f4), level: $LEVEL"
