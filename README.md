# Headroom

A Windows 11 debloat and gaming tune-up tool. About 160 settings in 20 groups, and every one is its own switch. Each setting says what it does and exactly which registry values, services, tasks, features or apps it touches, and shows its current state on your PC.

Nothing changes until you switch a setting on and apply it. Before the first change Headroom creates a restore point and saves your old values, so switching a setting off puts your own values back. Settings that remove apps cannot be undone from the tool.

## Requirements

- Windows 11
- Windows PowerShell 5.1 (already included in Windows 11), the 64-bit one
- An administrator account

Headroom installs no driver and downloads nothing.

## Run it

Replace `zpphtp4nvm-ai` with the GitHub user or organization that hosts this repository.

### One line (asks for administrator permission)

Paste this into any PowerShell window. Windows shows the permission box, then the Headroom window opens.

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/zpphtp4nvm-ai/Headroom/main/Headroom.ps1 | iex"'
```

### From an administrator PowerShell

```powershell
irm https://raw.githubusercontent.com/zpphtp4nvm-ai/Headroom/main/Headroom.ps1 | iex
```

Closing Headroom ends that PowerShell window, so use the first command if you want to keep the window.

### Command-line options through irm

Run this from an administrator PowerShell. It starts a separate PowerShell, so your own window stays open.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zpphtp4nvm-ai/Headroom/main/Headroom.ps1))) -NoGui -List"
```

Change `-NoGui -List` to any of the options below.

### Download and run

1. Download `Headroom.ps1` and `Start-Headroom.bat` into the same folder.
2. Double-click `Start-Headroom.bat`. It asks Windows for administrator permission and opens the window.

If Windows blocks the files because they came from the internet, right-click each one, choose Properties, tick Unblock, and press OK.

## Read it before you run it

Headroom changes Windows settings, and it runs as administrator. Read the script first, or pin the command to a fixed commit instead of `main` so it cannot change underneath you:

```powershell
irm https://raw.githubusercontent.com/zpphtp4nvm-ai/Headroom/<commit-hash>/Headroom.ps1 | iex
```

The Preview only switch (or `-DryRun` in the console) lists what would happen and changes nothing.

## Presets

Select Optimization Preset offers three presets. Each one lists what it will change before anything is applied.

| Preset | What it is |
| --- | --- |
| Recommended Debloat | A set of gaming-oriented settings that removes no app. |
| Advanced Debloat | For PCs used mainly for gaming. It may remove services that other uses need. |
| Custom Preset | Your own saved configuration, which can be applied again after a clean install of Windows. |

Settings that can stop FACEIT or Riot Vanguard, printing, or virtual machines ask first.

## Command line

```powershell
.\Headroom.ps1                                    # opens the window
.\Headroom.ps1 -NoGui -List                       # which settings are applied?
.\Headroom.ps1 -NoGui -Preset -DryRun             # preview the Recommended preset
.\Headroom.ps1 -NoGui -Apply mouse,gamedvr        # just those two
.\Headroom.ps1 -NoGui -Apply mpo=full             # Multiplane Overlay: Fully disabled
.\Headroom.ps1 -NoGui -Undo mpo                   # and back to Enabled (the Windows default)
```

| Option | Meaning |
| --- | --- |
| `-NoGui` | Do not open the window; work in the console. Without `-List`, `-Preset`, `-Apply` or `-Undo` it shows the state of every setting. |
| `-DryRun` | Window: starts with Preview only switched on. Console: shows what would happen and changes nothing. |
| `-List` | Console: print every setting with its id and whether it is applied. |
| `-Preset` | Console: turn on the Recommended preset. |
| `-Apply` | Console: turn on these setting ids (see `-List`). A setting with options takes one as `id=option`. |
| `-Undo` | Console: turn these setting ids back off. |

## Where things are kept

| What | Where |
| --- | --- |
| Undo record | `%ProgramData%\Win11GamingDebloat\undo-record.xml` |
| Log | `debloat-log.txt` on the Desktop (or in `%TEMP%` if there is no Desktop) |

## Hardware readings

Windows does not report CPU temperature, CPU power or memory timings, so Home shows those from HWiNFO or LibreHardwareMonitor when one of them is running. The Start HWiNFO button turns on HWiNFO's sensor sharing after asking, and keeps a copy of its settings file.
