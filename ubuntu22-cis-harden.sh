#!/bin/bash

set -e

# ────────── Locate Script Directory ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTDIR="$SCRIPT_DIR/cis-hardening"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H%M%SZ")
RUNDIR="$ROOTDIR/runs/$TIMESTAMP"
mkdir -p "$RUNDIR"

ROLEDIR="$ROOTDIR/roles/ubuntu22-cis"
GROUPVAR="$ROOTDIR/group_vars/all.yml"
PLAYBOOK="$ROOTDIR/playbook.yml"
LOGFILE="$RUNDIR/hardening.log"
SUMMARY_JSON="$RUNDIR/summary.json"
NEEDS_REBOOT_FLAG="$ROOTDIR/.needs_reboot"

RESET=false
DRYRUN=false
AUDITONLY=false
VERBOSE=false
NOLOG=false

# ────────── Help Output ──────────
show_help() {
  echo "Usage: ./ubuntu22-cis-harden.sh [options]"
  echo
  echo "Options:"
  echo "  --reset        Remove all configs and re-clone the role"
  echo "  --dry-run      Run Ansible in check mode (no changes)"
  echo "  --audit-only   Run only audit-tagged CIS rules"
  echo "  --verbose      Enable full Ansible debug output (-vvv)"
  echo "  --no-log       Skip writing to log file"
  echo "  --help         Show this help and exit"
  exit 0
}

# ────────── Parse CLI Options ──────────
for arg in "$@"; do
  case $arg in
    --reset) RESET=true ;;
    --dry-run) DRYRUN=true ;;
    --audit-only) AUDITONLY=true ;;
    --verbose) VERBOSE=true ;;
    --no-log) NOLOG=true ;;
    --help) show_help ;;
  esac
done

# ────────── Reset Mode ──────────
if [ "$RESET" = true ]; then
  echo "[!] --reset detected. Removing previous configuration..."
  rm -rf "$ROOTDIR/runs" "$ROLEDIR" "$GROUPVAR" "$PLAYBOOK"
fi

mkdir -p "$ROOTDIR/group_vars" "$ROOTDIR/roles"

# ────────── Logging Setup ──────────
if [ "$NOLOG" = false ]; then
  touch "$LOGFILE"
  exec > >(tee -a "$LOGFILE") 2>&1
fi

# ────────── Start Log ──────────
echo "========== $TIMESTAMP =========="
echo "[+] Starting Ubuntu 22.04 CIS Hardening"

# ────────── Pre-flight Setup ──────────
if ! command -v ansible >/dev/null 2>&1; then
  echo "[+] Installing Ansible..."
  sudo apt update
  sudo apt install -y software-properties-common
  sudo apt-add-repository --yes --update ppa:ansible/ansible
  sudo apt install -y ansible git
else
  echo "[OK] Ansible is already installed"
fi

cd "$ROOTDIR"

if [ ! -d "$ROLEDIR" ]; then
  echo "[+] Cloning Ubuntu 22.04 CIS role"
  git clone https://github.com/ansible-lockdown/UBUNTU22-CIS.git "$ROLEDIR"
else
  echo "[OK] CIS role already present"
fi

if [ ! -f "$PLAYBOOK" ]; then
  cat > "$PLAYBOOK" << 'EOF'
- name: Harden Ubuntu 22.04 LTS to CIS Level 1 (Local)
  hosts: localhost
  become: yes
  roles:
    - ubuntu22-cis
EOF
fi

if [ ! -f "$GROUPVAR" ]; then
  cat > "$GROUPVAR" << 'EOF'
benchmark_version: 'v1.0.0'
ubuntu22cis_level_1: true
ubuntu22cis_level_2: false
EOF
fi

# ────────── Run Ansible ──────────
ANSIBLE_CMD="ansible-playbook -i localhost, -c local playbook.yml"
[ "$DRYRUN" = true ] && ANSIBLE_CMD+=" --check"
[ "$AUDITONLY" = true ] && ANSIBLE_CMD+=" --tags audit"
[ "$VERBOSE" = true ] && ANSIBLE_CMD+=" -vvv"

START_TIME_RAW=$(date +%s)
HOSTNAME=$(hostname)

echo "[+] Running Ansible with:"
[ "$DRYRUN" = true ] && echo "    → Check mode"
[ "$AUDITONLY" = true ] && echo "    → Audit-only mode"
[ "$VERBOSE" = true ] && echo "    → Verbose output"
[ "$NOLOG" = true ] && echo "    → Log file disabled"
[ "$NOLOG" = false ] && echo "    → Logging to: $LOGFILE"

eval "$ANSIBLE_CMD"
RUN_STATUS=$?

# ────────── Reboot Detection ──────────
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

# ────────── JSON Summary ──────────
echo "[+] Writing summary to: $SUMMARY_JSON"

cat > "$SUMMARY_JSON" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "hostname": "$HOSTNAME",
  "mode": "$( [ "$AUDITONLY" = true ] && echo 'audit-only' || ([ "$DRYRUN" = true ] && echo 'dry-run' || echo 'full-apply'))",
  "reboot_required": $REBOOT_NEEDED,
  "status": "$( [ "$RUN_STATUS" -eq 0 ] && echo 'success' || echo 'failed')",
  "duration_seconds": $DURATION_SEC,
  "log_file": "$LOGFILE",
  "role_path": "$ROLEDIR"
}
EOF

cat "$SUMMARY_JSON"

# ────────── Symlinks to latest files ──────────
ln -sf "$SUMMARY_JSON" "$ROOTDIR/latest.json"
[ "$NOLOG" = false ] && ln -sf "$LOGFILE" "$ROOTDIR/latest.log"

# ────────── Reboot If Needed ──────────
if [ "$REBOOT_NEEDED" = true ]; then
  echo "[↻] Rebooting in 10 seconds..."
  sleep 10
  sudo reboot
fi

echo "[✔] Done — mode: $(grep mode "$SUMMARY_JSON" | cut -d '"' -f4), status: $(grep status "$SUMMARY_JSON" | cut -d '"' -f4)"
