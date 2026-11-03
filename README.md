# Headroom

Headroom is a Windows 11 debloat and gaming tune-up tool, written as a single PowerShell script with a window you click through. It has about 160 settings in 20 groups, and each one is its own switch. Every setting says what it changes and lists the registry values, services, scheduled tasks, features or apps it touches. It reads the current state from your PC, so you can see what’s already on or off before you change anything.

There are three presets. Recommended Debloat is a set of gaming-oriented settings that removes no apps. Advanced Debloat is meant for PCs used mostly for gaming and may remove services needed for certain applications or features to work properly. Custom Preset saves your own choices so you can reapply them after a clean install. Each preset lists exactly what it will change before it does anything. A Preview only switch shows what would happen without changing anything, and a few settings (anything that could break FACEIT or Riot Vanguard, printing, or virtual machines) informs you it will break these services.

The Home page shows your Windows version, CPU, graphics card, memory, motherboard, displays and drives. Windows doesn’t report CPU temperature, CPU power or memory timings, so those come from HWiNFO or LibreHardwareMonitor if one is running. There’s also a latency test that measures how responsive the PC is.

## Requirements

- Windows 11
- Windows PowerShell 5.1 (already included in Windows 11), the 64-bit one
- An administrator account

Headroom does not install on the device.

## Run it

### From an administrator PowerShell

```powershell
irm https://raw.githubusercontent.com/zpphtp4nvm-ai/Headroom/main/Headroom.ps1 | iex
```

Closing Headroom ends that PowerShell window. To keep your window open, run Headroom in a separate PowerShell as shown below.

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

## Switching a setting off

Switching a setting off puts the Windows default back for everything that setting changed: registry values (deleted where Windows sets none), service start types, scheduled tasks, firewall rules (as Windows ships them), adapter bindings and driver options (the driver's own default), the power plan (Balanced) and the boot setting for the hypervisor. It does not put back what your PC had before Headroom changed it, so a value that another tool had set earlier also ends up at the Windows default.

A few settings are handled differently:

- Settings that add or remove Windows components (optional features and capabilities, such as SMB1) use the record of what was installed when Headroom first changed them, because Windows has no single default for those. The same record is used for firewall rules if Windows' own list of default rules cannot be read.
- Settings whose Windows default is already the on state (Game Mode on, Optimizations for windowed games on) are switched off by writing an explicit 0, because deleting the value would leave them on.
- Settings that remove apps cannot be undone from Headroom.

## Where things are kept

| What | Where |
| --- | --- |
| Undo record | `%ProgramData%\Win11GamingDebloat\undo-record.xml` |
| Log | `debloat-log.txt` on the Desktop (or in `%TEMP%` if there is no Desktop) |

## Hardware readings

Windows does not report CPU temperature, CPU power or memory timings, so Home shows those from HWiNFO or LibreHardwareMonitor when one of them is running. The Start HWiNFO button turns on HWiNFO's sensor sharing after asking, and keeps a copy of its settings file.
