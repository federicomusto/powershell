# sysadmin-tools

A single-file PowerShell panel for common Windows sysadmin tasks: OpenSSH
server, firewall, network profiles, and WSL2 LAN access.

All-in-one interactive menu — no dependencies, no install, runs on Windows 10/11.

## Requirements

- Windows 10/11 (tested on Windows 11 Pro)
- Windows PowerShell 5.1+ (built in)
- Administrator rights — the script auto-elevates via UAC if run non-elevated

## Usage

Right-click → **Run with PowerShell**, or from a terminal:

```powershell
powershell -ExecutionPolicy Bypass -File .\sysadmin-tools.ps1
```

## Menu

1. **SSH Service & Firewall Control**
   - Start / stop the OpenSSH server (`sshd`)
   - Open / close TCP port 22 in the firewall (all profiles)
   - Set `sshd` startup to Automatic or Manual

2. **SSH Key Manager**
   - View, add, or delete authorized public keys (user + admin)
   - Full configuration & ACL repair (preserves existing keys)

3. **Network Profiles & PING Controls**
   - Enable / disable ICMP (ping) response
   - Force Wi-Fi/Ethernet profiles to Private or Public

4. **Diagnostics & System Info**
   - Local + public WAN IP
   - Process listening on port 22
   - `Test-NetConnection` to `localhost:22`

5. **Help & Setup Sequence Guide**

6. **Restore Windows Default Settings (Factory Reset)**

7. **WSL2 LAN Access (Mirrored Networking)**
   - Enable `networkingMode=mirrored` in `.wslconfig`
   - Toggle firewall ports open/closed (80 / 443 / 8001 / custom)
   - Restart WSL (`wsl --shutdown`)

## WSL2 LAN access

WSL2 runs behind NAT, so services inside WSL (for example a web site on port
80) are reachable via `localhost` on the Windows host but not from other PCs on
the LAN.

Menu option 7 sets WSL2 to **mirrored networking** (WSL shares the host's
network interfaces) and opens the matching firewall port. After a
`wsl --shutdown` and restart of the distro, browse from any LAN device to:

```
http://<Windows-LAN-IP>
```

## License

GPL-3.0 — see [LICENSE](LICENSE).
