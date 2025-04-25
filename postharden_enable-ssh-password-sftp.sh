#!/bin/bash

set -e

# Backup sshd_config
BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date -u +%Y-%m-%dT%H%M%SZ)"
echo "[+] Backing up /etc/ssh/sshd_config to $BACKUP_FILE"
sudo cp /etc/ssh/sshd_config "$BACKUP_FILE"

# Remove publickey-only enforcement and enable password authentication
sudo sed -i 's/^\s*PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^\s*AuthenticationMethods publickey/#AuthenticationMethods publickey/' /etc/ssh/sshd_config

# Fix SFTP subsystem path
sudo sed -i 's|^Subsystem sftp .*|Subsystem sftp /usr/lib/openssh/sftp-server -f AUTHPRIV -l INFO|' /etc/ssh/sshd_config

# Restart sshd
echo "[+] Restarting sshd service"
sudo systemctl restart ssh

# Validate sshd is running
if sudo systemctl is-active ssh > /dev/null; then
  echo "[✔] SSH service is active"
else
  echo "[✘] SSH service failed to start. Check your sshd_config."
  exit 1
fi

echo "[✔] SSH and SFTP are now accessible using password authentication."