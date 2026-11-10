# Runtime architecture and frozen settings

## Current executable

`camera-probe.exe` is a native Windows x86_64 Zig 0.17.0 console application.
The production entry point is now:

```powershell
camera-probe.exe daemon [seconds]
```

- `daemon` with no duration runs until Ctrl+C.
- `daemon 120` is the finite integration-test form.
- It requires an elevated process because the UVC ETW consumer needs elevation.
- Elevated output for tests is written to `C:\Users\kp\camera_daemon.log`.
- `camera-settings.exe` is a separate NanoUI window; it never streams video and
  can run while the daemon is running.

## Logon startup

- `install-startup` creates the Task Scheduler task
  `CameraProjectCameraDaemon` with:
  - `ONLOGON` trigger for the current user,
  - `RunLevel=HighestAvailable` (`schtasks` flag `/RL HIGHEST`),
  - interactive token, so the elevated daemon runs in the user's session.
- Registration must itself be elevated; `uninstall-startup` removes the task,
  `startup-status` reports whether it exists.
- The action is always a quoted executable path plus `daemon`:
  `"C:\Users\kp\camera_project-out\bin\camera-probe.exe" daemon`.
- The task shows a console window at logon and writes no log file.
- Started tasks are stopped with `schtasks /End /TN CameraProjectCameraDaemon`.
  The daemon must be stopped before rebuilding into its install directory,
  otherwise the install fails with `AccessDenied`.

## Frozen user-visible settings

- White balance: DirectShow `IAMVideoProcAmp`, property `7`
  (`VideoProcAmp_WhiteBalance`), value `4`, manual flags `0x2`.
- Power line frequency: property `13`, value `1` (50 Hz), flags `0x0`.
- Do not change these values, property IDs, or flags without an explicit user
  request. Both settings have been confirmed visually and across OBS source
  restarts.

## Daemon workers

The daemon uses two independent worker threads. Each worker initializes its own
COM apartment and its own DirectShow camera object. COM interface pointers are
never shared across apartments.

### White-balance worker

- Opens only the FINGERS camera.
- Applies manual white balance `4` and verifies the result.
- Polls every `250 ms`.
- If the driver reports automatic mode or a different value, reapplies manual
  `4` and verifies it.
- This is the original validated white-balance loop, retained unchanged.

### Power-line worker

- Runs the native real-time ETW consumer for
  `Microsoft-Windows-USBVideo` event `208` (`FillUserBuffer` start).
- Detects stream restart when frame activity resumes after at least `500 ms` of
  event-timestamp idle time.
- Uses a `5000 ms` cooldown after every refresh. Event timestamps, not callback
  delivery times, are required because ETW batches callbacks.
- On a detected stream restart, performs one combined forced refresh:
  1. White balance: set automatic, then back to manual `4`.
  2. Power line: set `60 Hz`.
  3. Wait `2000 ms`.
  4. White balance: set manual `4` and verify.
  5. Power line: set `50 Hz` and verify.
- The ETW provider does not identify the physical camera. The current design
  assumes the Integrated Camera is not streaming concurrently.

The white-balance worker and the ETW refresh both write the same frozen final
state. The ETW path is necessary because after an OBS source restart the driver
can report manual value `4` while the actual stream has reverted to automatic
white balance.

## Error handling and lifecycle

- Each worker retries camera/COM/session failures after `5000 ms`.
- Ctrl+C signals a shared Windows event; both workers stop cleanly and the ETW
  session is closed.
- A finite `daemon <seconds>` test signals the same shutdown event automatically.
- No ETL file or persistent analytic log is used by the ETW watcher.

## Source layout

- `src/main.zig` — CLI, read-only probe, diagnostic commands, frozen white
  balance/power-line test paths.
- `src/directshow.zig` — DirectShow COM ABI, device selection, VideoProcAmp and
  CameraControl access.
- `src/etw.zig` — real-time `Microsoft-Windows-USBVideo` consumer, idle/cooldown
  state machine, finite and external-stop modes.
- `src/daemon.zig` — elevated two-worker controller.
- `src/startup.zig` — Task Scheduler install/uninstall/status through `schtasks`.
- `src/gui.zig` — NanoUI settings window (`camera-settings.exe`).
- `src/winutil.zig` — shared elevation checks and messages.
- `src/keepalive.zig` — failed experimental keep-alive graph; not used by the
  daemon and not a viable solution for this camera.

## Regression checks

Run on Windows from `D:\Cloud\cam_scripts`, not WSL:

```powershell
zig build test
& C:\Users\kp\camera_project-out\bin\camera-probe.exe probe
& C:\Users\kp\camera_project-out\bin\camera-probe.exe watch 4 30
& C:\Users\kp\camera_project-out\bin\camera-probe.exe startup-status
& .\zig-out\bin\camera-settings.exe
# Elevated:
& C:\Users\kp\camera_project-out\bin\camera-probe.exe etw-watch 120 50
& C:\Users\kp\camera_project-out\bin\camera-probe.exe daemon 120
```

Build the elevated copy with:

```powershell
zig build --prefix C:\Users\kp\camera_project-out
```

## Not implemented yet

- Saved configuration file; the frozen values are currently compile-time constants.
- Tray controls. NanoUI has no Windows system-tray support, so a tray icon would
  require a different shell.
- Robust camera identity for the ETW trigger when multiple cameras stream.
