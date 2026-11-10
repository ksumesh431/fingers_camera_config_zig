# Camera Project

Native Windows Zig controller for the external **FINGERS Hi-Res 2K** USB webcam.
The default DirectShow diagnostic probe is read-only. Camera settings are only
changed by the explicit commands below.

## Requirements

- Windows 11 x86_64
- Zig 0.17.0
- FINGERS Hi-Res 2K connected to the Windows machine

## Location and build (Windows PowerShell)

The project lives at `D:\Cloud\cam_scripts`. Keep it on a Windows-local path:
on a `\\wsl.localhost\...` UNC path Zig cannot fetch packages into `zig-pkg/`
and its default build cache fails with `manifest_create Unexpected`. WSL can
still edit the files through `/mnt/d/Cloud/cam_scripts`.

Build and test from the project directory:

```powershell
zig build          # .\zig-out\bin\camera-probe.exe, camera-settings.exe
zig build test
```

The first build fetches NanoUI into `zig-pkg/`; later builds work offline.

Install the elevated copy that the logon task runs:

```powershell
zig build --prefix C:\Users\kp\camera_project-out
```

Or build and run the probe in one step:

```powershell
zig build run
```

The probe prints every DirectShow video device, selects only the device whose
friendly name is `FINGERS Hi-Res 2K` and whose device path contains
`VID_5843&PID_7884`, then reads its white-balance range and current state.
The laptop's Integrated Camera is never selected.

## Explicit camera-control tests

Define the path first, then these commands write to the external camera and
print the value read back:

```powershell
$exe = "$env:USERPROFILE\camera_project-out\bin\camera-probe.exe"
# For a plain local build use: $exe = ".\zig-out\bin\camera-probe.exe"

# Set manual white balance to the currently preferred value.
& $exe set-manual 4

# Force the anti-flicker power-line setting to 50 Hz.
& $exe set-powerline 50

# Refresh the actual anti-flicker state: 60 Hz, wait 2 seconds, then 50 Hz.
# This is necessary even when the driver already reports 50 Hz.
& $exe refresh-powerline 50

# Reapply manual white balance 4 for 120 seconds.
# The watch always ends after the requested duration (maximum 3600 seconds).
& $exe watch 4 120

# Restore automatic white balance if needed.
& $exe set-auto
```

`watch` applies manual white balance immediately, polls every 250 ms, and logs
each detected change and reapplication. Keep it running while opening or
restarting a camera application to test white-balance reset behavior. Valid
power-line values for `set-powerline` are `50`, `60`, `auto`, and `disabled`;
`refresh-powerline` supports `50` and `60`. This camera's power-line property
supports disabled/50/60 but not automatic, and it reports 50 Hz as its default.

## Persistent elevated controller

Run the integrated controller from an **elevated Windows PowerShell**:

```powershell
# Run until Ctrl+C.
& $exe daemon

# Finite integration test.
& $exe daemon 120
```

The daemon runs three independent workers:

- White balance: frozen manual value `4`, 250 ms reset polling.
- Power line: ETW-triggered restart detection, then a combined forced refresh of
  white balance automatic → manual `4` and power line `60 Hz` → wait 2 seconds →
  `50 Hz`.
- Extras: re-applies the user's saved custom controls (see below).

All workers retry camera/session failures after 5 seconds. Ctrl+C shuts them
down cleanly. The daemon does not create an ETL file.

## Custom controls and the settings file

Every `IAMVideoProcAmp` / `IAMCameraControl` property the camera exposes besides
the frozen white balance and power line can be managed:

```powershell
# Where the saved choices live.
& $exe config-path

# Apply the saved choices once, without the daemon and without elevation.
& $exe apply-config
```

`camera-settings.exe` writes the file
(`%LOCALAPPDATA%\CameraProject\settings.zon`) when you save preferences; the
daemon's extras worker polls it every second and keeps the managed controls
applied after stream restarts. Per control the file stores whether it is
managed, whether automatic mode is forced, and the manual value. Unsupported or
out-of-range entries are skipped, never treated as failures. The frozen white
balance (`7`) and power line (`13`) cannot appear in the file.

## Live preview check without the GUI

The settings window's preview uses the same capture graph as this command:

```powershell
# Stream for 5 seconds and count the frames received; writes no setting.
& $exe preview 5
```

The graph negotiates the largest driver format up to 1280 x 720 RGB32. Because
the camera allows only one stream, a running OBS/Zoom/Windows Camera makes both
the command and the in-window preview fail with `CameraBusy`.

## Start the daemon at logon

`install-startup` registers the Task Scheduler task
`CameraProjectCameraDaemon`. It runs `camera-probe.exe daemon` at logon of the
current user with `RunLevel=HighestAvailable`, so the daemon starts elevated
without a UAC prompt. Registration itself needs an elevated shell:

```powershell
& $exe install-startup     # must be elevated
& $exe startup-status
& $exe uninstall-startup
```

Start and stop it immediately without logging off:

```powershell
schtasks /Run /TN CameraProjectCameraDaemon
schtasks /End /TN CameraProjectCameraDaemon
```

The task runs in the interactive session, so a console window is visible while
the daemon runs. It writes no log file.

## Settings window

```powershell
& .\zig-out\bin\camera-settings.exe
```

`camera-settings.exe` is a separate NanoUI `v0.13.0` executable built with
`webview2 = "none"` as a window-subsystem binary, so launching it opens no
console window. It shows:

- a live camera preview with a `Camera on` stream toggle and a `Restart camera`
  button. The camera allows one stream, so the toggle defaults to off to leave
  the camera free for OBS, Zoom and Windows Camera;
- the live white-balance and power-line state of the FINGERS camera, which stay
  locked (starting a stream can revert white balance; the daemon reasserts it);
- every other camera control with a switch, an Automatic/Manual choice where the
  driver supports both, and a slider, saved to `settings.zon`.

NanoUI has no Windows system-tray support, so this is a normal window with no
tray icon.

## Elevated ETW diagnostic watcher

The standalone ETW command remains available for regression testing:

```powershell
& $exe etw-watch 120 50
```

The watcher consumes `Microsoft-Windows-USBVideo` frame-activity events in real
time. When activity resumes after at least 500 ms idle, it performs the verified
60 Hz → wait 2 seconds → 50 Hz refresh. A 5-second cooldown prevents refresh
loops. It does not read or change white balance and does not create an ETL file.
The event stream requires elevation and does not identify the physical camera,
so the Integrated Camera must not be streaming concurrently.

Do not run the executable in WSL. Camera access and all camera-related tests
must happen on Windows.
