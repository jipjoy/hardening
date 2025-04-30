
# Post-Remediation Script for Nessus Compliance Scanning (Firewall ON, Hardened Server)

Start-Transcript -Path "C:\Nessus_PostRemediation.log" -Force

Write-Host "✅ Enabling required firewall rule groups..."
$groups = @(
  "Remote Desktop",
  "File and Printer Sharing",
  "Windows Remote Management",
  "Windows Management Instrumentation (WMI)",
  "Remote Event Log Management",
  "Remote Service Management",
  "Remote Scheduled Tasks Management",
  "Remote Volume Management"
)

foreach ($group in $groups) {
  Enable-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
}

Write-Host "✅ Adding specific inbound rules for RPC and WinRM..."
New-NetFirewallRule -DisplayName "Allow RPC Port 135" -Direction Inbound -Protocol TCP -LocalPort 135 -Action Allow -Profile Any -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Allow RPC Dynamic Ports" -Direction Inbound -Protocol TCP -LocalPort 49152-65535 -Action Allow -Profile Any -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Allow WinRM HTTP 5985" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -Profile Any -ErrorAction SilentlyContinue

Write-Host "✅ Disabling UAC remote filtering to allow local admin access to C$..."
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
  -Name "LocalAccountTokenFilterPolicy" -Value 1 -PropertyType DWord -Force

Write-Host "✅ Ensuring required services are enabled and started..."
Set-Service -Name WinRM -StartupType Automatic
Start-Service WinRM

Set-Service -Name RemoteRegistry -StartupType Automatic
Start-Service RemoteRegistry

Set-Service -Name LanmanServer -StartupType Automatic
Start-Service LanmanServer

Write-Host "✅ Post-remediation setup for Nessus credentialed scan is complete."
Stop-Transcript
