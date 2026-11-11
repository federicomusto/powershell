# Auto-elevate privileges to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-File `"$PSCommandPath`""
    exit
}

# Global Variables
$ScriptVersion = "v2.5.2-EN"
$RuleName = "SSH Port 22 Manual"
$DefaultMacKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK/o0JIat4+Ep6Fl1sGWGjSAbmPgc0U37H16n+yQP6Jp federico@doghunter.org"
$UserKeysFile = "C:\Users\feder\.ssh\authorized_keys"
$AdminKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
$AmtTunnelMac = "fox@192.168.97.94"
$AmtTunnelKey = "C:\Users\feder\.ssh\id_ed25519-git"
$AmtTunnelPidFile = "C:\Users\feder\.amt-tunnel.pid"
$SshPath = "C:\Windows\System32\OpenSSH\ssh.exe"
$AmtTunnelLog = "C:\Users\feder\.amt-tunnel.log"

# --- Status Functions ---
function Get-SshdStatus {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) { return "$($svc.Status) (Startup: $($svc.StartType))" } else { return "Not Installed" }
}

function Get-Port22ListenStatus {
    $listen = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    if ($listen) { return "LISTENING (OK)" } else { return "INACTIVE" }
}

function Get-FirewallSshStatus {
    $rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if (-not $rule) { $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue }
    if ($rule -and $rule.Enabled -eq "True") { return "OPEN (All profiles)" } else { return "CLOSED / BLOCKED" }
}

function Get-FirewallPingStatus {
    $rule = Get-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq "True") { return "ENABLED" } else { return "BLOCKED" }
}

function Get-LocalIPs {
    $ips = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }).IPAddress
    if ($ips) { return ($ips -join ", ") } else { return "N/A" }
}

function Get-PublicIP {
    try {
        $ip = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 2 -ErrorAction Stop).ToString().Trim()
        return $ip
    } catch {
        return "Offline / N/A"
    }
}

function Get-NetworkProfileStatus {
    $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
    if ($profiles) {
        $list = foreach ($p in $profiles) { "$($p.InterfaceAlias): $($p.NetworkCategory)" }
        return ($list -join " | ")
    } else { return "N/A" }
}

function Draw-Header {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "     SYSADMIN PANEL: SSH, FIREWALL & WSL2 ($ScriptVersion) " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " Local IP(s):          $(Get-LocalIPs)" -ForegroundColor White
    Write-Host " Public IP (WAN):      $(Get-PublicIP)" -ForegroundColor White
    Write-Host " Network Profile:      $(Get-NetworkProfileStatus)" -ForegroundColor White
    Write-Host " SSHD Service:         $(Get-SshdStatus)" -ForegroundColor Yellow
    Write-Host " Port 22 Listening:    $(Get-Port22ListenStatus)" -ForegroundColor Yellow
    Write-Host " Firewall Port 22:     $(Get-FirewallSshStatus)" -ForegroundColor Yellow
    Write-Host " PING Response (ICMP): $(Get-FirewallPingStatus)" -ForegroundColor Yellow
    Write-Host " WSL Mirrored Network: $(Get-WslMirroredStatus)" -ForegroundColor Yellow
    Write-Host " AMT Tunnel (via Mac): $(Get-AmtTunnelStatus)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------"
}

# --- Actions ---
function Repair-PrivateKeyAcls {
    # Ensure SSH private key files retain correct ACLs after directory-level changes.
    # OpenSSH on Windows rejects private keys that have overly permissive or missing ACLs.
    $userDir = "C:\Users\feder\.ssh"
    if (-not (Test-Path $userDir)) { return }

    $privateKeys = Get-ChildItem -Path $userDir -Filter "id_*" -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -ne ".pub" -and $_.Name -notlike "*.pub" }

    foreach ($key in $privateKeys) {
        icacls $key.FullName /inheritance:r /grant "feder:(R)" 2>$null | Out-Null
    }
}

function Apply-AclFix {
    $config = "C:\ProgramData\ssh\sshd_config"
    if (Test-Path $config) {
        $content = Get-Content $config -Raw
        $content = $content -replace '(?m)^Match Group administrators', '#Match Group administrators'
        $content = $content -replace '(?m)^\s*AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys', '#AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
        [System.IO.File]::WriteAllText($config, $content, [System.Text.Encoding]::UTF8)
    }

    $userDir = "C:\Users\feder\.ssh"
    if (!(Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }
    
    $existingKeys = @()
    if (Test-Path $UserKeysFile) {
        $existingKeys = @(Get-Content $UserKeysFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($existingKeys.Count -eq 0) {
        $existingKeys = @($DefaultMacKey)
    }

    $keysContent = ($existingKeys -join "`n") + "`n"

    [System.IO.File]::WriteAllText($UserKeysFile, $keysContent, [System.Text.Encoding]::UTF8)
    icacls $userDir /inheritance:r /grant "feder:F" /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null
    icacls $UserKeysFile /inheritance:r /grant "feder:F" /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null

    # Repair private key ACLs after directory-level inheritance removal
    Repair-PrivateKeyAcls

    [System.IO.File]::WriteAllText($AdminKeysFile, $keysContent, [System.Text.Encoding]::UTF8)
    icacls $AdminKeysFile /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null

    Restart-Service sshd
}

function Remove-SshKey {
    if (-not (Test-Path $UserKeysFile)) {
        Write-Host "`nNo authorized_keys file found." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $keys = @(Get-Content $UserKeysFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($keys.Count -eq 0) {
        Write-Host "`nNo keys available to delete." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host "`n--- SELECT A KEY TO DELETE ---" -ForegroundColor Yellow
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $keyText = $keys[$i].ToString()
        $displayKey = if ($keyText.Length -gt 65) { $keyText.Substring(0, 65) + "..." } else { $keyText }
        Write-Host " [$($i + 1)] $displayKey"
    }

    $selection = Read-Host "`nEnter key number to delete (1-$($keys.Count), or press Enter to cancel)"
    if ($selection -match "^\d+$" -and [int]$selection -ge 1 -and [int]$selection -le $keys.Count) {
        $idxToDelete = [int]$selection - 1
        $keyToDelete = $keys[$idxToDelete]
        $remainingKeys = @($keys | Where-Object { $_ -ne $keyToDelete })

        $newContent = if ($remainingKeys.Count -gt 0) { ($remainingKeys -join "`n") + "`n" } else { "" }

        [System.IO.File]::WriteAllText($UserKeysFile, $newContent, [System.Text.Encoding]::UTF8)
        icacls $UserKeysFile /inheritance:r /grant "feder:F" /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null

        if (Test-Path $AdminKeysFile) {
            [System.IO.File]::WriteAllText($AdminKeysFile, $newContent, [System.Text.Encoding]::UTF8)
            icacls $AdminKeysFile /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null
        }

        Restart-Service sshd
        Write-Host "`nKey removed successfully!" -ForegroundColor Green
        Start-Sleep -Seconds 2
    } else {
        Write-Host "`nOperation cancelled." -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
}

function Restore-FactoryDefaults {
    Write-Host "`n[!] WARNING: This will reset OpenSSH, Firewall, and SSH keys to default Windows states." -ForegroundColor Red
    $confirm = Read-Host "Are you sure you want to proceed? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    Write-Host "`nRestoring factory default settings..." -ForegroundColor Yellow

    Stop-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType Manual -ErrorAction SilentlyContinue

    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    Disable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    Disable-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -ErrorAction SilentlyContinue

    $config = "C:\ProgramData\ssh\sshd_config"
    if (Test-Path $config) {
        $content = Get-Content $config -Raw
        $content = $content -replace '(?m)^#Match Group administrators', 'Match Group administrators'
        $content = $content -replace '(?m)^\s*#AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys', '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
        [System.IO.File]::WriteAllText($config, $content, [System.Text.Encoding]::UTF8)
    }

    if (Test-Path $UserKeysFile) { Remove-Item -Path $UserKeysFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $AdminKeysFile) { Remove-Item -Path $AdminKeysFile -Force -ErrorAction SilentlyContinue }

    # Repair private key ACLs (factory reset may strip inheritance from .ssh dir)
    Repair-PrivateKeyAcls

    Write-Host "Factory Defaults Restored Successfully!" -ForegroundColor Green
    Write-Host "Note: Refer to Help Guide (Option 5) for setup steps." -ForegroundColor Cyan
    Start-Sleep -Seconds 3
}

# --- Submenus ---
function Show-SubMenu-Service {
    do {
        Draw-Header
        Write-Host " --- SUBMENU: SSH SERVICE & FIREWALL CONTROL ---" -ForegroundColor Green
        Write-Host " 1. Start SSHD service"
        Write-Host " 2. Stop SSHD service"
        Write-Host " 3. OPEN Port 22 Globally (All Network Profiles)"
        Write-Host " 4. CLOSE Port 22 in Firewall"
        Write-Host " 5. Set SSHD Startup to AUTOMATIC (On Boot)"
        Write-Host " 6. Set SSHD Startup to MANUAL"
        Write-Host " 0. Back to Main Menu"
        Write-Host "--------------------------------------------------"
        $subChoice = Read-Host "Select an option (0-6)"

        switch ($subChoice) {
            '1' { Start-Service sshd -ErrorAction SilentlyContinue; Write-Host "SSHD Started." -ForegroundColor Green; Start-Sleep -Seconds 1 }
            '2' { Stop-Service sshd -ErrorAction SilentlyContinue; Write-Host "SSHD Stopped." -ForegroundColor Red; Start-Sleep -Seconds 1 }
            '3' {
                Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
                New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -Profile Any | Out-Null
                Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
                Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -Profile Any -ErrorAction SilentlyContinue
                Write-Host "Port 22 Opened Globally." -ForegroundColor Green; Start-Sleep -Seconds 1
            }
            '4' {
                Disable-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
                Disable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
                Write-Host "Port 22 Closed in Firewall." -ForegroundColor Red; Start-Sleep -Seconds 1
            }
            '5' { Set-Service -Name sshd -StartupType Automatic; Write-Host "SSHD set to Automatic." -ForegroundColor Green; Start-Sleep -Seconds 1 }
            '6' { Set-Service -Name sshd -StartupType Manual; Write-Host "SSHD set to Manual." -ForegroundColor Green; Start-Sleep -Seconds 1 }
        }
    } while ($subChoice -ne '0' -and $subChoice -ne '')
}

function Show-SubMenu-Keys {
    do {
        Draw-Header
        Write-Host " --- SUBMENU: SSH KEY MANAGER ---" -ForegroundColor Green
        Write-Host " 1. View Authorized Keys"
        Write-Host " 2. Add a New Public Key"
        Write-Host " 3. Delete an Existing Key"
        Write-Host " 4. Run Full Configuration & ACL Repair (Preserves All Keys)"
        Write-Host " 0. Back to Main Menu"
        Write-Host "--------------------------------------------------"
        $subChoice = Read-Host "Select an option (0-4)"

        switch ($subChoice) {
            '1' {
                Write-Host "`n--- USER AUTHORIZED KEYS ($UserKeysFile) ---" -ForegroundColor Yellow
                if (Test-Path $UserKeysFile) { Get-Content $UserKeysFile } else { Write-Host "File not found." -ForegroundColor Red }
                Write-Host "`n--- ADMIN AUTHORIZED KEYS ($AdminKeysFile) ---" -ForegroundColor Yellow
                if (Test-Path $AdminKeysFile) { Get-Content $AdminKeysFile } else { Write-Host "File not found." -ForegroundColor Red }
                Read-Host "`nPress Enter to return..."
            }
            '2' {
                $newKey = Read-Host "`nPaste the NEW SSH public key (Mac, Linux, Windows)"
                if (-not [string]::IsNullOrWhiteSpace($newKey)) {
                    Add-Content -Path $UserKeysFile -Value $newKey.Trim() -Encoding UTF8
                    icacls $UserKeysFile /inheritance:r /grant "feder:F" /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null
                    Add-Content -Path $AdminKeysFile -Value $newKey.Trim() -Encoding UTF8
                    icacls $AdminKeysFile /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null
                    Restart-Service sshd
                    Write-Host "Key added and permissions updated." -ForegroundColor Green
                    Start-Sleep -Seconds 2
                }
            }
            '3' { Remove-SshKey }
            '4' {
                Apply-AclFix
                Write-Host "ACL Repair and configuration applied for ALL existing keys." -ForegroundColor Green
                Start-Sleep -Seconds 2
            }
        }
    } while ($subChoice -ne '0' -and $subChoice -ne '')
}

function Show-SubMenu-Network {
    do {
        Draw-Header
        Write-Host " --- SUBMENU: NETWORK & SECURITY PROFILES ---" -ForegroundColor Green
        Write-Host " 1. ENABLE PING Response (ICMP)"
        Write-Host " 2. DISABLE PING Response (ICMP)"
        Write-Host " 3. Force Network Profiles (Wi-Fi/Ethernet) to PRIVATE"
        Write-Host " 4. Force Network Profiles (Wi-Fi/Ethernet) to PUBLIC"
        Write-Host " 0. Back to Main Menu"
        Write-Host "--------------------------------------------------"
        $subChoice = Read-Host "Select an option (0-4)"

        switch ($subChoice) {
            '1' { Enable-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -ErrorAction SilentlyContinue; Write-Host "PING Enabled." -ForegroundColor Green; Start-Sleep -Seconds 1 }
            '2' { Disable-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -ErrorAction SilentlyContinue; Write-Host "PING Disabled." -ForegroundColor Red; Start-Sleep -Seconds 1 }
            '3' {
                Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
                    Set-NetConnectionProfile -InterfaceAlias $_.InterfaceAlias -NetworkCategory Private -ErrorAction SilentlyContinue
                }
                Write-Host "Network profiles forced to PRIVATE." -ForegroundColor Green; Start-Sleep -Seconds 1
            }
            '4' {
                Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
                    Set-NetConnectionProfile -InterfaceAlias $_.InterfaceAlias -NetworkCategory Public -ErrorAction SilentlyContinue
                }
                Write-Host "Network profiles forced to PUBLIC." -ForegroundColor Red; Start-Sleep -Seconds 1
            }
        }
    } while ($subChoice -ne '0' -and $subChoice -ne '')
}

function Show-SubMenu-Diagnostics {
    do {
        Draw-Header
        Write-Host " --- SUBMENU: DIAGNOSTICS & SYSTEM INFO ---" -ForegroundColor Green
        Write-Host " 1. Fetch Local & Public WAN IP Addresses"
        Write-Host " 2. Inspect Listening Process on Port 22 (PID)"
        Write-Host " 3. Run Test-NetConnection (localhost -Port 22)"
        Write-Host " 0. Back to Main Menu"
        Write-Host "--------------------------------------------------"
        $subChoice = Read-Host "Select an option (0-3)"

        switch ($subChoice) {
            '1' {
                Write-Host "`n--- ACTIVE LOCAL IP ADDRESSES ---" -ForegroundColor Yellow
                Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Wi-Fi*", "Ethernet*" -ErrorAction SilentlyContinue | 
                    Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize
                
                Write-Host "--- PUBLIC WAN IP ADDRESS ---" -ForegroundColor Yellow
                Write-Host " Public IP: $(Get-PublicIP)" -ForegroundColor Green
                Read-Host "`nPress Enter to return..."
            }
            '2' {
                Write-Host "`n--- PROCESS LISTENING ON PORT 22 ---" -ForegroundColor Yellow
                $conns = Get-NetTCPConnection -LocalPort 22 -ErrorAction SilentlyContinue
                if ($conns) { $conns | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess | Format-Table -AutoSize }
                else { Write-Host "No active process found on Port 22." -ForegroundColor Red }
                Read-Host "Press Enter to return..."
            }
            '3' {
                Write-Host "`n--- TEST-NETCONNECTION (LOCALHOST) ---" -ForegroundColor Yellow
                Test-NetConnection -ComputerName localhost -Port 22
                Read-Host "`nPress Enter to return..."
            }
        }
    } while ($subChoice -ne '0' -and $subChoice -ne '')
}


function Get-WslMirroredStatus {
    $cfg = "$env:USERPROFILE\.wslconfig"
    if (Test-Path $cfg) {
        $content = Get-Content $cfg -Raw
        if ($content -match '(?m)^\s*networkingMode\s*=\s*mirrored') { return "MIRRORED (enabled)" }
        elseif ($content -match '(?m)^\s*networkingMode\s*=') { return "Configured (other mode)" }
        else { return "Not configured" }
    } else { return "Not configured (no .wslconfig)" }
}

function Set-WslMirroredNetworking {
    $cfg = "$env:USERPROFILE\.wslconfig"
    $lines = @()
    if (Test-Path $cfg) { $lines = @(Get-Content $cfg) }

    $sectionPattern = '^\s*\[wsl2\]\s*$'
    $modePattern = '^\s*networkingMode\s*='

    $out = New-Object System.Collections.Generic.List[string]
    $sectionIndex = -1
    $modeFound = $false

    foreach ($line in $lines) {
        if ($line -match $sectionPattern) {
            $sectionIndex = $out.Count
            $out.Add($line)
        }
        elseif ($line -match $modePattern) {
            $out.Add("networkingMode=mirrored")
            $modeFound = $true
        }
        else {
            $out.Add($line)
        }
    }

    if (-not $modeFound) {
        if ($sectionIndex -ge 0) {
            $out.Insert($sectionIndex + 1, "networkingMode=mirrored")
        }
        else {
            $out.Add("[wsl2]")
            $out.Add("networkingMode=mirrored")
        }
    }

    [System.IO.File]::WriteAllText($cfg, (($out.ToArray() -join "`n") + "`n"), [System.Text.Encoding]::UTF8)
    Write-Host ".wslconfig updated: networkingMode=mirrored" -ForegroundColor Green
    Write-Host "Restart WSL (wsl --shutdown) to apply." -ForegroundColor Yellow
}

function Get-WslLanPortStatus {
    param([int]$Port)
    $ruleName = "WSL LAN Port $Port (Inbound)"
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq "True") { return "OPEN" } else { return "CLOSED" }
}

function Open-WslLanPort {
    param([int]$Port = 80)
    $ruleName = "WSL LAN Port $Port (Inbound)"
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any | Out-Null
    Write-Host "Firewall port $Port opened for LAN access." -ForegroundColor Green
}

function Close-WslLanPort {
    param([int]$Port)
    $ruleName = "WSL LAN Port $Port (Inbound)"
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    Write-Host "Firewall port $Port CLOSED for LAN access." -ForegroundColor Red
}

function Toggle-WslLanPort {
    param([int]$Port)
    if ((Get-WslLanPortStatus -Port $Port) -eq "OPEN") {
        Close-WslLanPort -Port $Port
    } else {
        Open-WslLanPort -Port $Port
    }
}

function Restart-Wsl {
    Write-Host "Shutting down WSL (stops all distros and containers)..." -ForegroundColor Yellow
    wsl.exe --shutdown
    Write-Host "WSL shut down." -ForegroundColor Cyan
    Write-Host "Start your distro again (e.g. 'wsl -d Ubuntu-24.04'), then 'docker compose up -d'." -ForegroundColor Cyan
    Write-Host "From another LAN PC, browse to http://<Windows-LAN-IP>" -ForegroundColor Green
}

function Show-SubMenu-WslLan {
    do {
        Draw-Header
        Write-Host " --- SUBMENU: WSL2 LAN ACCESS (MIRRORED NETWORKING) ---" -ForegroundColor Green
        Write-Host " Firewall Port 80:   $(Get-WslLanPortStatus -Port 80)" -ForegroundColor Yellow
        Write-Host " Firewall Port 443:  $(Get-WslLanPortStatus -Port 443)" -ForegroundColor Yellow
        Write-Host " Firewall Port 8001: $(Get-WslLanPortStatus -Port 8001)" -ForegroundColor Yellow
        Write-Host "--------------------------------------------------"
        Write-Host " 1. Enable Mirrored Networking (.wslconfig)"
        Write-Host " 2. Toggle Firewall Port 80 (HTTP - web site)"
        Write-Host " 3. Toggle Firewall Port 443 (HTTPS)"
        Write-Host " 4. Toggle Firewall Port 8001 (Backend API)"
        Write-Host " 5. Toggle a Custom Port"
        Write-Host " 6. Restart WSL (wsl --shutdown)"
        Write-Host " 0. Back to Main Menu"
        Write-Host "--------------------------------------------------"
        $subChoice = Read-Host "Select an option (0-6)"

        switch ($subChoice) {
            '1' { Set-WslMirroredNetworking; Start-Sleep -Seconds 2 }
            '2' { Toggle-WslLanPort -Port 80; Start-Sleep -Seconds 1 }
            '3' { Toggle-WslLanPort -Port 443; Start-Sleep -Seconds 1 }
            '4' { Toggle-WslLanPort -Port 8001; Start-Sleep -Seconds 1 }
            '5' {
                $port = Read-Host "Enter the port number to toggle"
                if ($port -match '^\d+$' -and [int]$port -ge 1 -and [int]$port -le 65535) {
                    Toggle-WslLanPort -Port ([int]$port)
                } else {
                    Write-Host "Invalid port." -ForegroundColor Red
                }
                Start-Sleep -Seconds 1
            }
            '6' { Restart-Wsl }
        }
    } while ($subChoice -ne '0' -and $subChoice -ne '')
}

function Get-AmtTunnelStatus {
    if (Test-Path $AmtTunnelPidFile) {
        $tunnelPid = (Get-Content $AmtTunnelPidFile -ErrorAction SilentlyContinue).Trim()
        if ($tunnelPid -match "^\d+$" -and (Get-Process -Id ([int]$tunnelPid) -ErrorAction SilentlyContinue)) {
            return "ACTIVE (PID $tunnelPid)"
        }
    }
    return "INACTIVE"
}

function Start-AmtTunnel {
    if ((Get-AmtTunnelStatus) -like "ACTIVE*") {
        Write-Host "AMT tunnel already active." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }
    $sshArgs = @(
        "-N",
        "-i", $AmtTunnelKey,
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=60",
        "-L", "16993:192.168.99.147:16993",
        "-L", "16995:192.168.99.147:16995",
        "-L", "17993:192.168.99.153:16993",
        "-L", "17995:192.168.99.153:16995",
        $AmtTunnelMac
    )
    $proc = Start-Process $SshPath -ArgumentList $sshArgs -PassThru -WindowStyle Hidden -RedirectStandardError $AmtTunnelLog
    Start-Sleep -Seconds 3
    if ($proc -and -not $proc.HasExited) {
        $proc.Id | Out-File -FilePath $AmtTunnelPidFile -Encoding ascii
        Write-Host "AMT tunnel started (PID $($proc.Id))." -ForegroundColor Green
        Write-Host "Set amt-cli config to 127.0.0.1 (fribourg 16993/16995, ms02ultra 17993/17995)." -ForegroundColor Cyan
    } else {
        $err = if (Test-Path $AmtTunnelLog) { ((Get-Content $AmtTunnelLog -Tail 3) -join " | ") } else { "ssh exited (no log)" }
        Write-Host "AMT tunnel failed: $err" -ForegroundColor Red
        Start-Sleep -Seconds 3
    }
}
function Stop-AmtTunnel {
    if (Test-Path $AmtTunnelPidFile) {
        $tunnelPid = (Get-Content $AmtTunnelPidFile -ErrorAction SilentlyContinue).Trim()
        if ($tunnelPid -match "^\d+$") { Stop-Process -Id ([int]$tunnelPid) -Force -ErrorAction SilentlyContinue }
        Remove-Item $AmtTunnelPidFile -Force -ErrorAction SilentlyContinue
        Write-Host "AMT tunnel stopped." -ForegroundColor Red
    } else {
        Write-Host "AMT tunnel not running." -ForegroundColor Yellow
    }
}

function Show-SubMenu-AmtTunnel {
    do {
        Draw-Header
        Write-Host " --- SUBMENU: AMT TUNNEL (VIA MAC $AmtTunnelMac) ---" -ForegroundColor Green
        Write-Host " Status: $(Get-AmtTunnelStatus)" -ForegroundColor Yellow
        Write-Host " 1. Enable AMT Tunnel"
        Write-Host " 2. Disable AMT Tunnel"
        Write-Host " 0. Back to Main Menu"
        Write-Host "--------------------------------------------------"
        $subChoice = Read-Host "Select an option (0-2)"
        switch ($subChoice) {
            '1' { Start-AmtTunnel; Start-Sleep -Seconds 1 }
            '2' { Stop-AmtTunnel; Start-Sleep -Seconds 1 }
        }
    } while ($subChoice -ne "0" -and $subChoice -ne "")
}

function Show-HelpGuide {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "            SYSADMIN PANEL HELP GUIDE             " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    
    Write-Host "--- QUICKSTART: SETUP SSH FROM FACTORY DEFAULT ---" -ForegroundColor Green
    Write-Host "To enable working SSH access starting from Factory Reset, follow this path:"
    Write-Host "  Step 1: Menu [2] -> Option [4] (Run Full Configuration & ACL Repair)"
    Write-Host "          Protects ALL existing keys (Mac/Linux/Win), enforces UTF-8,"
    Write-Host "          resets ACL file permissions, and patches 'sshd_config'."
    Write-Host "  Step 2: Menu [1] -> Option [3] (OPEN Port 22 Globally)"
    Write-Host "          Allows incoming TCP port 22 traffic through Windows Firewall."
    Write-Host "  Step 3: Menu [1] -> Option [1] (Start SSHD Service)"
    Write-Host "          Starts the OpenSSH server daemon."
    Write-Host "  Step 4: Menu [3] -> Option [3] (Optional: Force Network to PRIVATE)"
    Write-Host "          Ensures local Wi-Fi profiles aren't blocked by Public Firewall rules."
    Write-Host "  Step 5: Connect from any terminal using: ssh feder@<Windows-IP>"

    Write-Host "`n--- FEATURE OVERVIEW ---" -ForegroundColor Yellow
    Write-Host " 1. Service & Firewall: Controls 'sshd' state, Firewall Port 22, and boot options."
    Write-Host " 2. SSH Key Manager: View, add, or delete public keys and fix permissions."
    Write-Host " 3. Network Profiles: Manages PING replies and forces Private/Public network profiles."
    Write-Host " 4. Diagnostics: Displays Local IPs, Public WAN IP, listening processes, and connectivity."
    Write-Host " 6. Factory Reset: Restores stock Windows settings, closes Port 22, and wipes keys."
    Write-Host " 7. WSL2 LAN Access: Enables mirrored networking and opens firewall ports so"
    Write-Host "    services inside WSL2 (e.g. a web site on port 80) are reachable from the LAN."

    Read-Host "`nPress Enter to return to Main Menu..."
}

# --- Main Program Loop ---
do {
    Draw-Header
    Write-Host " 1. SSH Service & Firewall Control"
    Write-Host " 2. SSH Key Manager (View, Add, Remove, Repair)"
    Write-Host " 3. Network Profiles & PING Controls"
    Write-Host " 4. Diagnostics & System Info"
    Write-Host " 5. Help & Setup Sequence Guide"
    Write-Host " 6. Restore Windows Default Settings (Factory Reset)"
    Write-Host " 7. WSL2 LAN Access (Mirrored Networking)"
    Write-Host " 8. AMT Tunnel (via Mac)"
    Write-Host " 0. Exit (or press Enter)"
    Write-Host "--------------------------------------------------"
    
    $mainChoice = Read-Host "Select a menu (0-7)"

    switch ($mainChoice) {
        '1' { Show-SubMenu-Service }
        '2' { Show-SubMenu-Keys }
        '3' { Show-SubMenu-Network }
        '4' { Show-SubMenu-Diagnostics }
        '5' { Show-HelpGuide }
        '6' { Restore-FactoryDefaults }
        '7' { Show-SubMenu-WslLan }
        '8' { Show-SubMenu-AmtTunnel }
        '0' { Write-Host "Exiting..." -ForegroundColor Gray; break }
        ''  { Write-Host "Exiting..." -ForegroundColor Gray; break }
        default { Write-Host "Invalid Option!" -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
} while ($mainChoice -ne '0' -and $mainChoice -ne '')