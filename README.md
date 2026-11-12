# Headroom

Headroom is a Windows 11 debloat and gaming tune-up tool, written as a single PowerShell script with a window you click through. It has about 180 settings in 20 groups, and each one is its own switch. Every setting says what it changes and lists the registry values, services, scheduled tasks, features or apps it touches. It reads the current state from your PC, so you can see what’s already on or off before you change anything. Each card also says what Windows itself does by default ("Windows default: On" or "Windows default: Off").

There are two presets. The Question Preset asks short questions about how you use the PC (gaming, Riot or FACEIT games, a VPN, virtual machines, printing and so on) and changes only what fits your answers; a question you answer Not sure to, or skip, changes nothing. Custom Preset saves your own choices so you can reapply them after a clean install. Each preset lists exactly what it will change before it does anything. A Preview only switch shows what would happen without changing anything, and a few settings (anything that could break FACEIT or Riot Vanguard, printing, or virtual machines) inform you they will break these services.

The Home page shows your Windows version, CPU, graphics card, memory, motherboard, displays and drives. Windows doesn’t report CPU temperature, CPU power or memory timings, so those come from HWiNFO or LibreHardwareMonitor if one is running. On an NVIDIA card the graphics card also shows whether Resizable BAR is on and the PCIe link generation and width, read from nvidia-smi.

A Timer and clock card shows the timer resolution Windows is using right now (how often its clock ticks; a program can ask for a finer tick), whether the HPET is present and enabled, which clock sits behind QueryPerformanceCounter (TSC, HPET or ACPI timer, worked out from how long one read takes), and any timer options set in the boot entry (useplatformclock, useplatformtick, disabledynamictick, tscsyncpolicy). A Security card beside it shows whether virtualization-based security (VBS) is running, whether memory integrity (HVCI) is on, and whether the IOMMU (AMD-Vi or VT-d) is on in the BIOS. Click any line on these two cards to see what it means and what Windows has by default; click again to close it. A Mouse card next to the Storage card shows whether Enhance pointer precision is off, whether the pointer speed is at the middle notch (10 of 20, 1:1) and whether USB selective suspend is off in the power plan in use; each one that is set for gaming is green, and each line explains itself on a click. Everything on these pages is read only: the timer is only asked for, the boot entry is only listed with `bcdedit /enum`, the device list, Windows' Device Guard report and the mouse settings are only read, the firmware's ACPI tables are only listed, and the power plan is only shown with `powercfg /q`. The one exception is the Start HWiNFO button, which changes HWiNFO's own settings file after asking.

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

Select Optimization Preset offers two presets. Each one lists what it will change before anything is applied.

| Preset | What it is |
| --- | --- |
| Question Preset | A list of questions about how you use the PC. Your answers decide which settings change, and a setting you are unsure about is left as it is. |
| Custom Preset | Your own saved configuration, which can be applied again after a clean install of Windows. |

How the Question Preset works:

- Each question is Yes, No, Not sure or Use default, with a short explanation and the settings the answer would change. You can go back to an earlier question and start again.
- Use default leaves that question's settings as Windows has them. Any of them that are changed on your PC are put back to the Windows default when you press Confirm changes. Settings that remove an app cannot be put back, so those stay as they are.
- Not sure and a skipped question change nothing. A Yes to a question that protects a setting (for example a Yes to Riot or FACEIT games, virtual machines or printing) beats any other answer that would change it.
- The questions are grouped: your PC, work and network, accounts and cloud, privacy, AI and Edge, look and feel, and built-in apps. Questions that only matter for gaming PCs are left out if you say you do not game. Removing built-in apps is its own question at the start, and settings that cannot be undone are only applied if you say Yes to it.
- Near the start it also asks whether you want the advanced questions. Those cover settings that lower protection or can get in the way of other things (User Account Control, drive encryption, driver updates, the Microsoft Store and similar). If you say No or Not sure they are not asked and nothing in them changes.
- Before anything is applied, a review page lists every setting that will change, every setting that is kept as it is and why, and the ones marked Not recommended or lowering protection. A restore point is created first.

Settings that can stop FACEIT or Riot Vanguard, printing, or virtual machines ask first.

## Command line

```powershell
.\Headroom.ps1                                    # opens the window
.\Headroom.ps1 -NoGui -List                       # every setting, its switch, and the Windows default
.\Headroom.ps1 -NoGui -Preset -DryRun             # preview the built-in recommended set (the Question Preset is only in the window)
.\Headroom.ps1 -NoGui -Apply mouse,gamedvr        # just those two
.\Headroom.ps1 -NoGui -Apply mpo=full             # Multiplane Overlay: Fully disabled
.\Headroom.ps1 -NoGui -Undo mpo                   # and back to Enabled (the Windows default)
```

| Option | Meaning |
| --- | --- |
| `-NoGui` | Do not open the window; work in the console. Without `-List`, `-Preset`, `-Apply` or `-Undo` it shows the state of every setting. |
| `-DryRun` | Window: starts with Preview only switched on. Console: shows what would happen and changes nothing. |
| `-List` | Console: print every setting with its id, whether its switch is on or off, the Windows default, and which way `-Apply` turns the switch. |
| `-Preset` | Console: turn on the built-in recommended set, a group of gaming-oriented settings that removes no app. The Question Preset is only in the window. |
| `-Apply` | Console: apply these setting ids (see `-List`; each one says whether `-Apply` turns its switch on or off). A setting with options takes one as `id=option`. |
| `-Undo` | Console: put the Windows default back for these setting ids. |

## What the switches do

Each card has one switch, and the switch is the setting itself. On means the setting is on, off means it is off (or back at the Windows default, depending on what the setting does). The card's text has an "On:" half and an "Off:" half that say what each position means, and the "Windows default" tag tells you which position Windows ships with.

- Game Mode: on turns Windows Game Mode on, off turns it off. The same goes for Optimizations for windowed games.
- A service: on lets the service start the way Windows has it, off disables it.
- A feature that is on in Windows by default (Xbox Game Bar, telemetry, widgets and so on): the switch starts on, and switching it off turns the feature off.
- A feature that Windows has off by default: the switch starts off, and switching it on turns the feature on.
- A startup program: on means it starts with Windows, off means it does not.
- Browser settings (Edge and Chrome) are policies. Edge and Chrome show "Managed by your organization" while any of their policies is set; switching the setting off removes the policy values again. Chrome has no group of its own, so its AI setting is on the AI features page next to the Windows ones.
- Services: every setting that only changes services is on the Services page, so they are all in one place. Eight of them are untested ideas from other debloat scripts and carry an "Untested" tag; Apply all and Tweak all leave those out, so you switch them yourself.
- Settings with options and one-time actions: a setting with options that is sitting on its Windows default (Multiplane Overlay, automatic updates for Store apps) and the run-once actions (Disk Cleanup, Temporary files, Reinstall Balanced power plan, Reinstall High Performance power plan) are listed under All settings but not counted as "Not applied", because there is nothing to apply until you pick an option or line the action up. They count again as soon as you do.

Reset all puts everything back to the Windows default, which means Game Mode and Optimizations for windowed games go back to on. When the check of the PC finds a setting that is only partly in place, Headroom offers to finish it. It makes the same offer for a setting that Headroom applied earlier and that now reads off, for example after a newer build changes that setting or a driver install puts a value back. Settings with options and run-once actions are left out, and so is Game Mode, because switching it off in Windows is your choice.

When a setting is put back to the Windows default, that covers everything it changed: registry values (deleted where Windows sets none), service start types, scheduled tasks, firewall rules (as Windows ships them), adapter bindings and driver options (the driver's own default), the power plan (Balanced) and the boot setting for the hypervisor. It does not put back what your PC had before Headroom changed it, so a value that another tool had set earlier also ends up at the Windows default.

A few settings are handled differently:

- Settings that add or remove Windows components (optional features and capabilities, such as SMB1) use the record of what was installed when Headroom first changed them, because Windows has no single default for those. The same record is used for firewall rules if Windows' own list of default rules cannot be read.
- Some defaults depend on the PC (for example hardware GPU scheduling, Memory Integrity, BitLocker and Storage Sense). Those cards say "Depends on the PC" instead of On or Off.
- Settings that remove apps cannot be undone from Headroom.
- Khorvie's power plan and Endgame Performance power plan, on the Power page, each install a third-party gaming power plan (Khorvie's PowerPlan; Endgame Performance, made by gavot) and make it the active plan. Their plan files are built into Headroom and checked against their SHA-256 before `powercfg /import` gets them; the file is written to Windows' own Temp folder under a plain name first, and Headroom checks that the plan really exists afterwards. Switching one off goes back to Balanced and deletes the plan again if Headroom installed it. Endgame Performance also switches sleep off while it is the active plan. These two and Ultimate Performance power plan each make themselves the active plan, so only one of the three can be on: switching one on switches the others off, and Apply all, Tweak all and the presets never swap one for another.
- Reinstall Balanced power plan and Reinstall High Performance power plan, on the Power page, are one-time actions rather than switches. Each puts that standard plan back under its usual ID with the settings Windows ships it with (`powercfg /duplicatescheme` from Windows' own definition). If the plan is still there, Headroom makes a copy first, deletes and recreates the plan, then deletes the copy, so your PC is never without it; changes you made inside that plan are lost. The active plan stays the same. A restore point is made first, and Apply all, Tweak all and the presets never run them. On a PC with Modern Standby, Windows may refuse to create High Performance; nothing is changed then.
- Some Windows-owned values are only tried: if Windows protects or rewrites one (the driver exclusion copy in Windows Update's policy state, the Delivery Optimization switch of the service account), a refusal is noted and the setting still counts as applied. The setting for the "ms-gamebar" pop-up writes two link entries; if another program already handles one of those links, Headroom leaves that one alone.

## Where things are kept

| What | Where |
| --- | --- |
| Undo record | `%ProgramData%\Win11GamingDebloat\undo-record.xml` |
| Log | `debloat-log.txt` on the Desktop (or in `%TEMP%` if there is no Desktop). Applying and undoing write to it; the check of the PC does not. |

## Hardware readings

Windows does not report CPU temperature, CPU power or memory timings, so Home shows those from HWiNFO or LibreHardwareMonitor when one of them is running. The Start HWiNFO button turns on HWiNFO's sensor sharing after asking, and keeps a copy of its settings file.
