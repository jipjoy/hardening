#!/bin/bash
# RHEL 9.5 CIS Level 1 Hardening Script

set -e

### === Config ===
PROFILE="xccdf_org.ssgproject.content_profile_cis_server_l1"
SSG_FILE="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
BASE_DIR="$HOME/cis-hardening"

### === Defaults ===
MODE="check"
VERBOSE=false

### === Help Message ===
show_help() {
cat << EOF
Usage: $0 [--mode check|remediate] [--verbose] [--help]

Options:
  --mode check        Run compliance scan only (default)
  --mode remediate    Run scan with auto-remediation
  --verbose           Show detailed output while running
  --help, -h          Display this help message

Examples:
  $0 --mode check
  $0 --mode remediate --verbose
EOF
exit 0
}

### === Parse CLI ===
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift 1
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "[!] Unknown parameter: $1"
            show_help
            ;;
    esac
done

### === Validate mode ===
if [[ "$MODE" != "check" && "$MODE" != "remediate" ]]; then
    echo "[!] Invalid mode: $MODE"
    show_help
fi

### === ISO Timestamp Output Directory ===
TIMESTAMP=$(date -u +"%Y-%m-%dT%H%M%SZ")
OUTDIR="$BASE_DIR/$TIMESTAMP"
mkdir -p "$OUTDIR"
cd "$OUTDIR"

log_file="$OUTDIR/run.log"
touch "$log_file"

### === Logging Helpers ===
log() {
    if $VERBOSE; then
        echo "[*] $1" | tee -a "$log_file"
    else
        echo "[*] $1" >> "$log_file"
    fi
}

error() {
    echo "[!] $1" | tee -a "$log_file" >&2
}

### === Step 1: Install Required Tools ===
log "Installing required packages (if not already installed)..."
sudo dnf install -y openscap-scanner scap-security-guide 2>&1 | sed 's/\r$//' >> "$log_file"

### === Step 2: Verify or Locate SSG File ===
if [[ ! -f "$SSG_FILE" ]]; then
  log "[!] SSG data stream file not found at: $SSG_FILE"
  FOUND=$(find /usr/share/xml/scap/ssg/ -name "ssg-rhel9-ds.xml" 2>/dev/null | head -n 1)
  if [[ -n "$FOUND" ]]; then
    log "[*] Found alternate path: $FOUND"
    SSG_FILE="$FOUND"
  else
    error "SSG data stream file could not be found. Please install scap-security-guide."
    exit 1
  fi
fi

### === Step 3: Run OpenSCAP Based on Mode ===
if [[ "$MODE" == "check" ]]; then
    log "Running CIS Level 1 compliance scan (check mode)..."
    sudo oscap xccdf eval \
        --profile "$PROFILE" \
        --results results.xml \
        --report report.html \
        "$SSG_FILE" 2>&1 | sed 's/\r$//' >> "$log_file"
    log "Scan complete. Report: $OUTDIR/report.html"

elif [[ "$MODE" == "remediate" ]]; then
    log "Running CIS Level 1 scan with remediation..."
    sudo oscap xccdf eval \
        --profile "$PROFILE" \
        --remediate \
        --results results-remediate.xml \
        --report report-remediate.html \
        "$SSG_FILE" 2>&1 | sed 's/\r$//' >> "$log_file"
    log "Remediation complete. Report: $OUTDIR/report-remediate.html"
fi

### === Step 4: Final Cleanup of ^M Carriage Returns ===
sed -i 's/\r$//' "$log_file"

### === Step 5: Export Reports for Easy Access ===
EXPORT_BASE="$HOME/public_cis_reports"
EXPORT_DIR="$EXPORT_BASE/$TIMESTAMP"
mkdir -p "$EXPORT_DIR"

# Determine the actual user running the script (for chown)
REAL_USER=$(logname)

if [[ "$MODE" == "check" ]]; then
    sudo cp "$OUTDIR/report.html" "$EXPORT_DIR/"
    sudo chown "$REAL_USER:$REAL_USER" "$EXPORT_DIR/report.html"
elif [[ "$MODE" == "remediate" ]]; then
    sudo cp "$OUTDIR/report-remediate.html" "$EXPORT_DIR/"
    sudo chown "$REAL_USER:$REAL_USER" "$EXPORT_DIR/report-remediate.html"
fi

chmod -R a+rx "$EXPORT_DIR"
log "Public export ready: $EXPORT_DIR (readable via FileZilla or SCP)"

### === Done ===
log "All output saved in: $OUTDIR"

