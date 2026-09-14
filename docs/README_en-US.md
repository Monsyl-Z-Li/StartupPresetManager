# Startup Preset Manager

> Manage common Windows startup entries with checkboxes, then save different setups as presets.

Startup Preset Manager is a small local Windows tool built around an everyday question: which apps should start automatically after you sign in?

You can save choices such as **Work**, **Gaming**, or **Minimal** as presets, load one when needed, and apply the result to Windows in one step. The project does not try to replace every system administration tool; it aims to make common startup settings easier to see and understand.

## Project status

This is the final personal version of the project. It is being kept for personal use, development reference, inspiration sharing, and open-source use. There is no planned release cycle, updater, formal product roadmap, or future official edition.

Open source does not mean this code is production-ready or appropriate for every computer. Please understand that it changes Windows startup behavior, review the source, and use or adapt it at your own risk.

## What it can do

- Find common third-party startup entries.
- Use checkboxes to decide what starts at the next sign-in or boot.
- Manage Registry startup entries, Startup folders, and sign-in/boot scheduled tasks.
- Show automatic services and selected third-party drivers in an advanced view.
- Save named presets and switch between them.
- Stage disabled Startup-folder shortcuts locally instead of deleting them.
- Work entirely on the local PC without uploading startup entries, presets, or usage data.

## Before you use it

Normal app entries — download clients, chat apps, screenshot tools, game launchers, and similar software — are usually reasonable to manage according to your preferences.

Services and drivers are different. They can affect hardware, networking, remote access, lighting software, or security tools. They are hidden behind **Show advanced items (services and drivers)** by default. Do not disable an advanced item unless you understand what it does.

The app changes future startup behavior. It does **not** close software that is already running.

## Quick start

1. Download or clone this repository.
2. Run the included EXE, or run the script for your preferred language.
3. Review the list: checked means enabled; unchecked means disabled.
4. Click **Apply changes**.
5. To save the current arrangement, enter a name and click **Save current state**.

Machine-level items, scheduled tasks, services, and drivers may require administrator rights. The app will ask you to restart it as administrator when necessary.

## Files and language variants

| File | Purpose |
| --- | --- |
| `src/StartupPresetManager_zh-CN.ps1` | Complete PowerShell/WPF app with a Simplified Chinese interface. |
| `src/StartupPresetManager_en-US.ps1` | Complete PowerShell/WPF app with an English interface. |
| `dist/StartupPresetManager_en-US.exe` | English EXE launcher. |
| `dist/StartupPresetManager_zh-CN.exe` | Chinese EXE launcher. |
| `src/StartupPresetManagerLauncher.cs` | C# source code for the EXE launcher. |
| `build/build_en-US.rsp` | Build arguments for the English EXE. |
| `build/build_zh-CN.rsp` | Build arguments for the Chinese EXE. |
| `assets/favicon.ico` | Icon used by the EXE. |

To run the English script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\StartupPresetManager_en-US.ps1
```

For Simplified Chinese documentation, see [README_zh-CN.md](README_zh-CN.md).

## What is a preset?

A preset is simply a saved list of which items should be on or off.

For example:

- **Work**: enable work chat, ShareX, and cloud storage; disable games and entertainment apps.
- **Gaming**: enable Steam, performance monitoring, and relevant GPU tools; disable unneeded office apps.
- **Minimal**: keep only the essentials for a quieter desktop after sign-in.

Loading a preset changes only the checkboxes in the window. It does not immediately change Windows, so you can review the result before clicking **Apply changes**.

## How startup entries are handled

| Entry type | What the app does |
| --- | --- |
| Registry `Run` / `RunOnce` entries | Preserves the original command and changes Windows startup approval state. |
| Startup folders | Moves an item into a local holding area when disabled and restores it when enabled. |
| Sign-in/boot scheduled tasks | Enables or disables eligible non-Microsoft tasks. |
| Automatic services | Shows them in the advanced view and switches between Automatic and Disabled. |
| Selected third-party drivers | Shows them in the advanced view and asks for another confirmation before applying a change. |

The app tries to filter out Microsoft/Windows entries to keep the list practical. This is a convenience heuristic, not a security check, and it cannot identify every vendor-specific startup mechanism.

### How the code scans, represents, and applies items

The script begins with `Get-AllStartupItems`, which combines the results of the source-specific scanners into an `ObservableCollection` bound to the WPF `DataGrid`. Each entry is represented by the built-in `StartupItem` class. It stores a stable ID, display name, source, trigger, command, current checkbox state, original state, advanced-item flag, administrator requirement, and source-specific data.

The stable ID is not based only on the display name. `Get-ItemId` creates a short SHA-256 hash from the source plus a path, task name, or service name. This makes saved presets less likely to target the wrong entry when display names change or similar names appear in different startup mechanisms.

The source-specific implementation is as follows:

- `Get-RegistryStartupItems` reads `Run` and `RunOnce` keys from the current-user, machine-wide, and 32-bit compatibility Registry views. `Get-RegistryApproval` reads the Windows `StartupApproved` binary state: a first byte of `2` means enabled and `3` means disabled. When applying a change, `Set-RegistryApproval` updates only that state and keeps the original startup command instead of deleting the Registry value.
- `Get-StartupFolderItems` scans the current-user and common Startup folders. For `.lnk` files, it uses Windows Script Host to resolve the target program and arguments. When an item is disabled, `Set-StartupFolderItem` moves it into a local holding directory and records the original path in settings; enabling it moves the same item back, rather than deleting the shortcut.
- `Get-ScheduledStartupItems` calls `Get-ScheduledTask`, excludes the `\Microsoft\...` task tree, and keeps tasks with sign-in or boot triggers. Applying a change calls `Enable-ScheduledTask` or `Disable-ScheduledTask` as appropriate.
- `Get-ServiceStartupItems` queries `Win32_Service` for automatic services. `Test-ThirdPartyService` applies a conservative filter based on executable path, file company information, and known Microsoft paths. `Invoke-ScConfig` then calls Windows `sc.exe config` to switch a selected service between `auto` and `disabled`.
- `Get-DriverStartupItems` reads automatically loaded system drivers, exposes only a small set of recognized third-party names, and attempts to read signer information. Drivers and services are marked as advanced; driver changes receive an additional confirmation.

### How presets, settings, and recovery work

`Read-Settings` and `Save-Settings` manage `%LOCALAPPDATA%\StartupPresetManager\settings.json`. It records preset item IDs and on/off states, original paths for staged Startup-folder items, and services or drivers that the app has previously managed.

When you save a preset, `Save-CurrentPreset` records the ID and `Enabled` state of every item currently in the list. When you load one, `Load-SelectedPreset` matches only IDs that are currently present and updates the checkboxes. It does not write to Windows until you explicitly choose **Apply changes**.

### Safety design and limitations

The app deliberately separates scanning from modification. It reads startup configuration at launch without requesting elevation. Only when you apply changes that actually include a machine-wide Registry entry, scheduled task, service, or driver does it ask you to restart as administrator.

Only entries where `OriginalEnabled` differs from the current `Enabled` state are sent to `Apply-Changes`. Each entry is handled by the source-specific function for its own startup mechanism. A failure is collected and reported while unrelated items continue to be processed. This design avoids treating every startup mechanism as the same operation and avoids deleting original Registry commands, shortcuts, or scheduled tasks.

## Local data and recovery

The app stores its own data in:

```text
%LOCALAPPDATA%\StartupPresetManager
```

This contains presets, staged Startup-folder items, and records for services or drivers previously managed by the app. Back up the whole folder if you want to preserve that data.

Deleting this folder does not remove installed apps or original Windows startup entries, but it removes presets and may require you to manually recover staged Startup-folder shortcuts.

## What the EXE launcher is

`src/StartupPresetManagerLauncher.cs` is not a second implementation of the user interface. It is a small C# launcher that embeds a PowerShell script and the icon into an EXE. At runtime, the EXE writes the embedded script to the local app-data directory, then uses built-in Windows PowerShell in STA mode to start the WPF interface.

The EXE is therefore a convenient entry point for the scripts, not a fully native C# rewrite. For review, troubleshooting, or further development, treat the language-specific `.ps1` files and the launcher source as the primary reference.

## What it is not

- It is not malware detection or a full system-security audit.
- It does not uninstall apps, delete apps, or terminate running processes.
- It does not cover every rare persistence mechanism, including browser extensions, WMI event subscriptions, Winlogon changes, or custom shells.
- It is not a replacement for Microsoft Sysinternals Autoruns.

If you are investigating malware or unexpected startup behavior, use trusted security tooling or ask an experienced technician for help.

## Origin of the project

This personal prototype began with a real need described by a user with no programming background. The user directed requirements, design, implementation, testing, and packaging with assistance from OpenAI Codex / ChatGPT 5.6 Terra.

The purpose of publishing it is not to present AI-generated code as a finished answer. It is to share a complete attempt as a reference and possible source of inspiration — and to give developers with Windows, PowerShell, WPF/WinUI, application security, or accessibility experience a concrete starting point for discussion and improvement.

## Build reference

Building the EXE requires a usable Windows C# compiler environment. Open a **Developer Command Prompt** supplied by Visual Studio or Build Tools, change to this project directory, then run:

```text
csc @build\build_en-US.rsp
```

`build/build_en-US.rsp` uses relative paths and produces the English launcher, `dist/StartupPresetManager_en-US.exe`. `build/build_zh-CN.rsp` produces the Chinese launcher, `dist/StartupPresetManager_zh-CN.exe`. Both response files embed the matching language script using the internal resource name expected by the launcher. To build the Chinese version, run:

```text
csc @build\build_zh-CN.rsp
```

Public documentation should not hard-code an absolute compiler path from one developer's PC. .NET Framework, Visual Studio, and Build Tools can be installed in different locations; the commands above work whenever `csc` is available on the current command line.

The source scripts also expose two maintenance checks:

```powershell
# Scan and print source counts without opening the UI
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\StartupPresetManager_en-US.ps1 -SelfTest

# Create the UI, complete a load check, and exit
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\StartupPresetManager_en-US.ps1 -UiSmokeTest
```

The current EXE is not code-signed, so Windows may show an unknown-publisher warning on first launch. Do not blindly bypass security warnings; inspect the source and build it yourself when you need a higher level of trust.

## License

Add a `LICENSE` file before inviting reuse, modification, or contributions. MIT is a simple permissive choice; GPL-3.0 is an option if you want modified redistributions to remain open source. Without a license, visitors should not assume permission to reuse the code.
