#!/bin/bash
# RHEL 9.5 CIS Level 1 or 2 Hardening & Audit Script
# Supports: --level 1|2, --mode check|remediate
# Author: ChatGPT

set -e

### === Config Defaults ===
LEVEL="1"
MODE="check"
VERBOSE=false
SSG_FILE="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
BASE_DIR="$HOME/cis-hardening"

### === Help Message ===
show_help() {
cat << EOF
Usage: $0 [--level 1|2] [--mode check|remediate] [--verbose] [--help]

Options:
  --level 1            Use CIS Level 1 profile (default)
  --level 2            Use CIS Level 2 profile
  --mode check         Run compliance scan only (default)
  --mode remediate     Run scan with remediation
  --verbose            Show detailed output while running
  --help, -h           Display this help message

Examples:
  $0 --level 1 --mode check
  $0 --level 2 --mode remediate --verbose
EOF
exit 0
}

### === Parse CLI ===
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --level)
            LEVEL="$2"
            shift 2
            ;;
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

### === Validate Inputs ===
if [[ "$LEVEL" != "1" && "$LEVEL" != "2" ]]; then
    echo "[!] Invalid level: $LEVEL"
    show_help
fi

if [[ "$MODE" != "check" && "$MODE" != "remediate" ]]; then
    echo "[!] Invalid mode: $MODE"
    show_help
fi

### === Profile Mapping ===
if [[ "$LEVEL" == "1" ]]; then
    PROFILE="xccdf_org.ssgproject.content_profile_cis"
elif [[ "$LEVEL" == "2" ]]; then
    PROFILE="xccdf_org.ssgproject.content_profile_cis_level2_server"
fi

### === Timestamp and Directories ===
TIMESTAMP=$(date -u +"%Y-%m-%dT%H%M%SZ")
OUTDIR="$BASE_DIR/$TIMESTAMP"
mkdir -p "$OUTDIR"
cd "$OUTDIR"

log_file="$OUTDIR/run.log"
touch "$log_file"

### === Logging Functions ===
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

### === Step 1: Ensure Required Tools ===
log "Installing required packages..."
sudo dnf install -y openscap-scanner scap-security-guide 2>&1 | sed 's/\r$//' >> "$log_file"

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

### === Step 2: Perform Evaluation ===
RESULTS_XML="results-l${LEVEL}.xml"
REPORT_HTML="report-l${LEVEL}.html"
if [[ "$MODE" == "remediate" ]]; then
    RESULTS_XML="results-l${LEVEL}-remediate.xml"
    REPORT_HTML="report-l${LEVEL}-remediate.html"
fi

log "Running CIS Level $LEVEL scan (mode: $MODE)..."

if [[ "$MODE" == "check" ]]; then
    sudo oscap xccdf eval \
        --profile "$PROFILE" \
        --results "$RESULTS_XML" \
        "$SSG_FILE" 2>&1 | sed 's/\r$//' >> "$log_file"
elif [[ "$MODE" == "remediate" ]]; then
    sudo oscap xccdf eval \
        --profile "$PROFILE" \
        --remediate \
        --results "$RESULTS_XML" \
        "$SSG_FILE" 2>&1 | sed 's/\r$//' >> "$log_file"
fi

# Attempt to generate report
if sudo oscap xccdf generate report "$RESULTS_XML" > "$REPORT_HTML"; then
    log "Report generated: $REPORT_HTML"
else
    log "[!] Report generation failed."
fi

### === Step 3: Clean ^M Characters from Log
sed -i 's/\r$//' "$log_file"

### === Step 4: Export Files for Easy Download ===
EXPORT_BASE="$HOME/public_cis_reports"
EXPORT_DIR="$EXPORT_BASE/$TIMESTAMP"
mkdir -p "$EXPORT_DIR"
REAL_USER=$(logname)

for FILE in "$RESULTS_XML" "$REPORT_HTML"; do
    if [[ -f "$FILE" ]]; then
        sudo cp "$FILE" "$EXPORT_DIR/"
        sudo chown "$REAL_USER:$REAL_USER" "$EXPORT_DIR/$(basename "$FILE")"
        chmod a+r "$EXPORT_DIR/$(basename "$FILE")"
        log "Exported: $(basename "$FILE")"
    else
        log "[!] File not found and skipped: $FILE"
    fi
done

chmod a+rx "$EXPORT_DIR"
log "Public export ready: $EXPORT_DIR (readable via FileZilla or SCP)"
log "All output saved in: $OUTDIR"
