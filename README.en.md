# NtpManager 1.4

**Portable monitoring and management tool for the Windows Time service (w32time): an NTP server for the local network plus an NTP client that takes its time from a GPS time server.**

[![PowerShell 2.0+](https://img.shields.io/badge/PowerShell-2.0%2B-blue.svg)](#requirements)
[![Windows 7+ / Server 2008 R2+](https://img.shields.io/badge/Windows-7%2B%20%2F%20Server%202008%20R2%2B-blue.svg)](#supported-windows-versions)
[![No installation](https://img.shields.io/badge/installation-not%20required-success.svg)](#installation)
[![License MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Syntax check](https://github.com/dn1984/NtpManager/actions/workflows/syntax-check.yml/badge.svg)](https://github.com/dn1984/NtpManager/actions/workflows/syntax-check.yml)

[Русский](README.md) · **English**

---

## Table of contents

- [What it is](#what-it-is)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Using the GUI](#using-the-gui)
- [Using the command line](#using-the-command-line)
- [Exit codes](#exit-codes)
- [Scheduled monitoring](#scheduled-monitoring)
- [What is changed on the system](#what-is-changed-on-the-system)
- [What the tool checks](#what-the-tool-checks)
- [Configuring LAN clients](#configuring-lan-clients)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Backup and rollback](#backup-and-rollback)
- [Limitations](#limitations)
- [Security](#security)
- [Verified and not verified](#verified-and-not-verified)
- [Repository layout](#repository-layout)
- [License](#license)

## What it is

The Windows Time service (`w32time`) can both **serve time** to local network clients and **obtain
time** from an external source. Doing that without a domain, without internet access and without
third-party software is inconvenient: the settings are scattered across the registry, the state is
invisible, and problems surface only when users complain.

NtpManager is a single PowerShell script with a GUI that solves exactly this task:

```
   ┌──────────────────┐        NTP          ┌────────────────────────┐      NTP      ┌──────────────┐
   │ GPS time server  │  ───────────────▶   │ This server            │ ───────────▶  │ Local        │
   │ (stratum 1)      │  (UDP 123)          │ NTP client + NTP server│  (UDP 123)    │ network      │
   │ 192.168.1.50     │                     │ Windows Server 2008 R2  │              │ clients      │
   └──────────────────┘                     └────────────────────────┘              └──────────────┘
     no internet required: time comes from the local network
```

No installation is required: it is `NtpManager.ps1` plus two `.cmd` launchers. Copy the folder to the
server (or to a USB stick) and double-click.

## Features

**Monitoring**

- 17 status rows: the service and its startup type, the NtpServer/NtpClient providers, time source type,
  poll interval, `AnnounceFlags`, who actually listens on UDP 123, firewall rule state, conflicts with
  third-party NTP services, latest Windows Time events;
- a real check performed by a built-in SNTP client: stratum, reference ID, clock offset and round-trip
  delay (plus a 5-sample stability mode);
- group policy detection: shows whether the settings are enforced by policy (policy wins over the registry);
- a lightweight auto-refresh (~50 ms: service and registry) and a full check on demand or every 10 minutes;
- tray icon and balloon notifications when the service state changes;
- activity log with rotation.

**Management**

- start, stop, restart the service and change its startup type;
- configure the NTP server and client with a **change preview** and an **automatic registry backup**
  before every write;
- automatically appends the `,0x9` flag to the server address (an IP address alone is enough);
- firewall rule for inbound UDP 123: create / show / delete;
- **service recovery** with one button (`w32tm /register`) when the service is missing from the service list;
- group policy mode: write the parameters to the policy branch as well, or delete that branch
  (with a backup);
- command line for deployment and monitoring: `-Report`, `-Apply`, `-RestoreService`, `-Help`.

## Requirements

| Component | Requirement |
|---|---|
| Operating system | Windows 7 / Windows Server 2008 R2 or newer — see [Supported Windows versions](#supported-windows-versions) |
| PowerShell | 2.0 (ships with the OS) — nothing extra to install |
| .NET Framework | 2.0 / 3.5 (included in Windows Server 2008 R2) |
| Privileges | administrator — for changes only; viewing, reports and diagnostics work as a regular user |

## Supported Windows versions

The tool drives the **Windows Time service** (`w32time`); its registry layout and the `w32tm` command are
identical in every version from Vista / Server 2008 onwards. There are no version-specific code paths:
the tool detects which PowerShell engine and which event source are available.

| Family | Versions | State |
|---|---|---|
| Windows Server | 2008 R2, 2012, 2012 R2, 2016, 2019, 2022, 2025 | the primary target is 2008 R2; Server Core has no `gpedit.msc` (the tool says so) |
| Windows client | 7, 8, 8.1, 10, 11 | actually verified on Windows 10 Pro under both PowerShell engines |
| Not supported | Windows XP / Server 2003 | no `w32tm /query` command and a different registry layout (no `TimeProviders` branch) |

What the tool does differently depending on the Windows version:

| Difference | How it is handled |
|---|---|
| PowerShell 2.0 (2008 R2 / 7) vs 5.1 (10/11, Server 2012+) | only features available in 2.0 are used; the `-STA` switch is added only where supported |
| Time service event source | Windows 8 / Server 2012 and newer use the modern `Microsoft-Windows-Time-Service` provider; 2008 R2 / 7 use the classic `W32Time` source — both are attempted |
| The service runs inside `svchost.exe` (all versions) | the owner of port 123 is detected by the services inside the listening process, not by the process name |
| Server Core | no `gpedit.msc` — the tool reports this and suggests alternatives |
| Domain or workgroup | detected through WMI (`PartOfDomain`) and taken into account in the policy explanations |

## Installation

No installation — the tool is portable.

1. Copy the folder to the server, for example to `C:\NtpManager`.
   Three files are enough: `NtpManager.ps1`, `NtpManager.cmd`, `NtpManager-Report.cmd`.
2. Double-click `NtpManager.cmd`. The tool requests administrator rights itself.
3. (Only if Windows blocks downloaded scripts) if needed, unblock the file:
   right-click `NtpManager.ps1` → Properties → Unblock.

While running, the tool creates service files next to itself — they are safe to delete and are excluded
from git:

| File | Purpose |
|---|---|
| `NtpManager.settings.ini` | saved GUI settings |
| `NtpManager.log` | activity log (UTF-8, rotated at 2 MB) |
| `NtpManager-backup\*.reg` | backups of the service settings and of the policy branch |
| `NtpManager-status.txt` | the report written by `NtpManager-Report.cmd` |

## Quick start

1. Copy the folder to the server and run `NtpManager.cmd` (accept the elevation prompt).
2. Tab **"Настройка"** (Settings) → button **"Рекомендуемые значения"** (Recommended values).
3. In the **"Адрес GPS-сервера"** (GPS server address) field enter an IP address, for example
   `192.168.1.50` — the "append the ,0x9 flag automatically" checkbox is on, so nothing else is needed.
4. Press **"Проверить изменения"** (Preview changes) to see the exact list of edits (nothing is written),
   then **"ПРИМЕНИТЬ НАСТРОЙКИ"** (Apply) and confirm.
5. Check the result: tab **"Состояние"** (Status) must be free of errors, and tab **"Диагностика"** →
   **"Проверить NTP"**.

> The user interface is in Russian. Field-by-field help is available in the built-in **"Справка"**
> (Help) dialog and as tooltips on every control; the tables below give the English equivalents of the
> most important labels.

## Using the GUI

| Tab | Purpose |
|---|---|
| **Состояние** (Status) | status rows marked as OK / warning / error, each with an explanation of what to do |
| **Служба** (Service) | state and startup type, start/stop/restart, service recovery, monitoring settings, group policy block |
| **Настройка** (Settings) | NTP server and client parameters, change preview, apply, import from backup |
| **Диагностика** (Diagnostics) | SNTP checks against any server, Windows Time commands, firewall rule, who listens on port 123, text report |

Every control has a tooltip; the Help button explains all fields and buttons. **F5** refreshes the state.

## Using the command line

| Command | Purpose |
|---|---|
| `NtpManager.cmd` | GUI (elevation is requested automatically) |
| `NtpManager.cmd -Report` | text status report; changes nothing, no administrator rights needed |
| `NtpManager.cmd -Report -ReportFile "C:\NtpManager\status.txt"` | the same plus a full report written to a file (UTF-8) |
| `NtpManager.cmd -RestoreService` | re-register the time service (`w32tm /register`) |
| `NtpManager.cmd -Apply ...` | apply settings (administrator rights required) |
| `NtpManager.cmd -Help` | command line help |

Parameters for `-Apply`:

```text
-ServerList "192.168.1.50,0x9"   comma-separated peer list (space-separated for several peers)
-TimeSourceType NTP              NTP | NT5DS | NoSync
-PollInterval 300                poll interval, seconds
-EnableServer / -DisableServer   enable/disable serving time to clients
-EnableClient / -DisableClient   enable/disable obtaining time
-Reliable / -NotReliable         mark the machine as a reliable time source (AnnounceFlags)
-OpenFirewall / -RemoveFirewall  allow/close inbound UDP 123
-StartupMode Auto                Auto | Manual | Disabled
-MaxAllowedPhaseOffset 3600      phase correction threshold, seconds
-EventLogFlags 2                 Windows Time event log verbosity
-NoRestart                       do not restart the service after writing settings
-UsePolicyBranch                 also write the parameters to the group policy branch
```

Full example:

```cmd
NtpManager.cmd -Apply -ServerList "192.168.1.50,0x9" -EnableServer -EnableClient ^
    -Reliable -PollInterval 300 -OpenFirewall
```

## Exit codes

Exit codes are intended for monitoring and the Task Scheduler:

| Code | Meaning |
|---|---|
| `0` | everything is fine |
| `1` | warnings (for example, the firewall rule is missing) |
| `2` | errors (service not running, no time source configured, no response from the source) |
| `3` | startup error (PowerShell or the script itself not found) |

## Scheduled monitoring

For the Task Scheduler run the script itself (not the `.cmd`), so that the window does not wait for a
keypress:

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\NtpManager\NtpManager.ps1" ^
    -Report -ReportFile "C:\NtpManager\status.txt"
```

Your monitoring system can then collect `status.txt` or check the task exit code.

## What is changed on the system

All changes happen only when you press a button or pass `-Apply`, and only inside the Windows Time
registry tree. A `.reg` backup is created automatically before every change.

| Registry value (`HKLM\SYSTEM\CurrentControlSet\Services\W32Time\...`) | Meaning | Recommended |
|---|---|---|
| `TimeProviders\NtpServer\Enabled` = `1` | serve time to network clients | 1 |
| `TimeProviders\NtpServer\AllowNonstandardModeCombinations` = `1` | compatibility with non-compliant clients | 1 |
| `TimeProviders\NtpClient\Enabled` = `1` | obtain time from the source | 1 |
| `TimeProviders\NtpClient\SpecialPollInterval` = `300` | how often to poll the GPS server, seconds | 60…900 |
| `Parameters\Type` = `NTP` | use the manual peer list (not the domain hierarchy) | NTP |
| `Parameters\NtpServer` = `192.168.1.50,0x9` | GPS server address and flags | your GPS |
| `Config\AnnounceFlags` = `5` | mark the machine as a reliable time source | 5 for a server, 10 for a regular client |
| `Config\MaxAllowedPhaseOffset` | threshold above which the service will not jump the clock, seconds | 300…3600 |
| `Config\EventLogFlags` | Windows Time event log verbosity | 2…3 |
| Firewall rule `NTP Server UDP 123 (NtpManager)` | allows inbound UDP 123 | enable |
| `HKLM\SOFTWARE\Policies\Microsoft\W32Time\...` | only when "write to the policy branch as well" is enabled | as needed |

About the peer flags: `,0x9` = `0x1` (use the configured poll interval) + `0x8` (client mode). Without the
flag the service polls the source on its own internal schedule (64…1024 s) and the poll interval field has
no effect.

## What the tool checks

| Row | How to read it |
|---|---|
| `Служба w32time` (service) | must be "Работает" (Running); if the service is missing from the service list, see the FAQ |
| Startup type | a time server should use Automatic |
| NTP server (serving) | must be enabled, otherwise clients get no time |
| NTP client (obtaining) | must be enabled |
| `Parameters\Type` | `NTP` means the manual peer list; `NT5DS` means time comes from the domain |
| Peer list | the GPS server address |
| Poll interval | 60…900 s is sensible for a local GPS |
| `AnnounceFlags` | 5 means the machine is considered a reliable source |
| Group policy | whether the settings are enforced by policy (policy wins over the registry) |
| Port UDP 123 | who actually listens; `svchost` **is** the time service |
| Firewall rule | if it is missing while the firewall is on, clients get no time |
| Other NTP services | warns about third-party NTP daemons such as `ntpd` |
| Latest W32Time event | the most recent Windows Time record in the System log |
| Response from 127.0.0.1:123 | whether the NTP server on this machine answers |
| Time server `<address>` | whether the GPS server is reachable and how far the clocks differ |

## Configuring LAN clients

On each client machine (as administrator):

```cmd
w32tm /config /manualpeerlist:"192.168.1.10,0x9" /syncfromflags:manual /reliable:no /update
w32tm /resync /rediscover
w32tm /query /source
```

`192.168.1.10` is the address of **this** server (not the GPS). The last command must show your server.
To verify reachability from a client, open the Diagnostics tab, enter the server address and press the
"check this server" button — that tests the full path including the firewall.

## FAQ

### Is the tool only for Windows Server 2008 R2?

No. "2008 R2+" means "2008 R2 **and newer**: the tool targets Windows 7 / Server 2008 R2 and every later
version up to Windows 11 and Windows Server 2025, because the time service and the `w32tm` command are the
same there. 2008 R2 was the target system in the original task (a server on a local network without
internet access), while the actual verification ran on Windows 10 Pro under both PowerShell engines —
2.0 and 5.1. See [Supported Windows versions](#supported-windows-versions) for details.

### Do I have to write `,0x9` or is the IP address enough?

The IP address alone is enough: with the "append the ,0x9 flag automatically" checkbox enabled (default)
the tool turns `192.168.1.50` into `192.168.1.50,0x9`. The flag is required because otherwise the service
polls the source on its own schedule (64…1024 s) and your poll interval is ignored. Several peers are
separated by spaces.

### What about the "Max phase offset" and "EventLogFlags" fields?

Both are optional; an empty field means "do not change". `MaxAllowedPhaseOffset` (300 s by default) is the
threshold above which the service refuses to correct the clock in one step — set `3600` if the clock has
drifted a lot. `EventLogFlags` (0…3) controls Windows Time event log verbosity; use `2` for diagnostics.

### Why is `svchost` listening on port 123? Is that normal?

Yes. The time service has no separate `w32time.exe` process: it is loaded into the shared host process
`svchost.exe`. The tool identifies the port owner correctly (it compares the service PID and the services
running inside the listening process), so `svchost` is not treated as a conflict. A warning appears only
for a genuinely foreign process (for example `ntpd`).

### What if the NTP parameters were previously configured by group policy?

Nothing breaks, but policy **wins over the registry**. On a standalone server (no domain) the policy can
only come from the local group policy. The tool shows this in a dedicated status row and can write the
parameters to the policy branch as well, open `gpedit.msc`, or delete the policy branch with a backup.
To check manually:

```cmd
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time" /s
```

### The Windows Time service is missing from the service list — what now?

The internal service name is `w32time`, the display name is "Windows Time". Check it with:

```cmd
sc query w32time
```

In most cases someone removed the registration with `w32tm /unregister` (or a registry cleaner deleted the
service key). Fix it with the **"Восстановить службу времени"** (Restore the time service) button on the
Service tab — that runs `w32tm /register` — or manually:

```cmd
w32tm /register
sc config w32time start= auto
net start w32time
```

If `%windir%\system32\w32time.dll` is missing, restore it first (`sfc /scannow`).

## Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| `Response from 127.0.0.1:123: no answer` | service stopped, NtpServer provider disabled, or the port is taken by another process | Service tab → Start; enable the provider; check the port row |
| `server answers but is not synchronised (LI=3 / stratum 16)` | the server serves time but does not obtain it itself | check the `Time server <GPS>` row |
| `Time server X: no answer` | no route to the GPS, wrong address, UDP 123 blocked on the GPS | `ping`, verify the address and the GPS firewall |
| `Firewall rule for UDP 123: not found` | clients cannot get time | press "Allow UDP 123" |
| `Port UDP 123: foreign process` | another program holds the port (e.g. `ntpd`) | stop it or stop serving time with Windows |
| Settings "reset" by themselves | they are enforced by group policy | see the policy FAQ |
| Everything is OK on the server but clients do not sync | firewall, routing, client-side configuration | test from the client with the "check this server" button |
| Time drifts on a virtual machine | Hyper-V injects the host clock | disable "Time synchronisation" in the integration services |

## Backup and rollback

- Before every change the tool creates `NtpManager-backup\W32Time_YYYYMMDD_HHMMSS.reg` — an export of
  the whole `HKLM\SYSTEM\CurrentControlSet\Services\W32Time` tree.
- In policy mode the policy branch is backed up as well (`W32Time-policy_*.reg`).
- To roll back: Settings tab → "Импорт из копии..." → pick the `.reg` file (the service is stopped,
  the settings are imported, the service is started again).
- Manually: `reg import NtpManager-backup\W32Time_20261013_104500.reg`.

## Limitations

1. **w32time is not a high-accuracy NTP implementation.** Windows Time is not intended for high-precision
   environments: in a LAN with a single local source the difference is usually tens of milliseconds, with
   no accuracy guarantees. If you need better than a few milliseconds, use a dedicated daemon (Meinberg
   NTP, chrony) — and then do not serve time with the Windows service, because of the port 123 conflict.
2. **Scale.** The built-in server is meant for dozens of clients, not hundreds.
3. **Standalone defaults are lazy:** on stand-alone systems the default `SpecialPollInterval` can be
   604800 seconds (one week), which is why setting the poll interval explicitly (as this tool does) matters.
4. **The SNTP check** uses the .NET network stack; if it is unavailable in a particular PowerShell session
   the tool automatically falls back to `w32tm /stripchart` and says so in the report.
5. **No background service.** Monitoring runs while the window is open; for unattended control, use
   `-Report` on a schedule.
6. **`NtpManager.ps1` must stay UTF-8 with BOM** — otherwise PowerShell 2.0 reads the Russian text as ANSI
   and the script fails to start.

## Security

- The tool **never accesses the internet**, never collects or transmits data, never installs services,
  never creates scheduled tasks and never keeps running after the window is closed.
- All changes require confirmation and are preceded by a backup.
- Viewing and reports are available to a regular user; changing settings requires administrator rights.
- The group policy branch is never modified without your explicit command — it is only read and reported.
- The activity log (`NtpManager.log`) stays next to the tool and contains only performed actions and
  check results.

## Verified and not verified

Development and verification were done on Windows 10 Pro using the **real PowerShell 2.0 engine**
(`powershell.exe -Version 2`), i.e. the same engine that ships with Windows Server 2008 R2, plus
PowerShell 5.1.

Actually verified: syntax parsing under PowerShell 2.0 and 5.1; reading Russian text from UTF-8 with BOM;
the `-Report` mode and writing the report to a file; the exit code reaching the calling process; the SNTP
client (real answers from live servers: `stratum 13` and `stratum 4` with correct offsets); the
`w32tm /stripchart` fallback path; window layout (0 overlapping controls after a forced re-layout);
39 tooltips; port 123 ownership detection (the service inside `svchost` is recognised as ours); automatic
`,0x9` flag insertion; deleting an (empty) policy branch without touching anything; the change preview in
policy mode.

Engine compatibility was verified separately: PowerShell 2.0 specifics (`foreach` over `$null` executes the
body once, `@($null)` yields a single empty element) no longer produce false port-conflict warnings or
blank service rows, and time service events are read both from the modern
`Microsoft-Windows-Time-Service` provider (Windows 10/11) and from the classic `W32Time` source
(Windows Server 2008 R2 / 7), so the status row shows a real dated event on both platforms.

**Not verified on a live system:** writing values to the registry and to the policy branch, restarting the
service, adding a firewall rule, running `w32tm /register`, and exchanging time with a real GPS server
(the development environment has no administrator rights and no GPS server). Verify these once on a test
server: first with the "Проверить изменения" (preview) button, which changes nothing, and then with
"ПРИМЕНИТЬ НАСТРОЙКИ".

## Repository layout

```text
NtpManager.ps1                      the program itself (UTF-8 with BOM)
NtpManager.cmd                      launcher: GUI or command line
NtpManager-Report.cmd               quick-report launcher (double-click)
README.md                           Russian documentation
README.en.md                        this file (English documentation)
CHANGELOG.md                        version history
CONTRIBUTING.md                     contribution rules and code requirements
SECURITY.md                         security policy and vulnerability reporting
LICENSE                             MIT license
.gitignore                          what is kept out of the repository
.github/workflows/syntax-check.yml  CI syntax check and smoke test
```

## License

MIT — see [LICENSE](LICENSE).

Author: Denis Savinov ([@dn1984](https://github.com/dn1984)).
