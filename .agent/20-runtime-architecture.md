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
- `camera-settings.exe` is a separate NanoUI window. It can run while the
  daemon runs, and it is a window-subsystem executable (`gui.subsystem =
  .windows`), so launching it opens no console.
- `camera-daemon.exe` runs the same daemon as `camera-probe daemon` but is a
  window-subsystem binary: the logon task uses it so no console appears. Its
  output goes to `%LOCALAPPDATA%\CameraProject\daemon.log`.
- `apply-config` applies the saved extra controls once without elevation;
  `config-path` prints where they are saved.
- `preview [seconds]` streams frames through the same capture graph the window
  uses and counts them per second. It writes no camera property and is the
  console way to check the preview path on hardware.

## Custom controls and the settings file

- `%LOCALAPPDATA%\CameraProject\settings.zon` holds only the extra controls.
  The frozen white balance and power line are deliberate compile-time constants
  and have no entry there.
- Every control in `src/controls.zig` is either an `IAMVideoProcAmp` property
  (brightness, contrast, hue, saturation, sharpness, gamma, color enable,
  backlight compensation, gain) or an `IAMCameraControl` property (exposure,
  focus, zoom, pan, tilt, roll, iris).
- A compile-time check refuses a table that contains property `7` or `13`.
- Per control the file stores `manage` (enforce or leave alone), `auto` (force
  the driver's automatic mode), and the manual `value`.
- The file is written by the GUI once the pointer is released, and re-read by
  the daemon's extras worker. An unreadable or invalid file is ignored: the
  worker keeps the previous values.
- Unsupported or out-of-range entries are reported as "skipped", never as
  camera failures, so a saved value for another camera cannot break the daemon.

## Settings window: preview, restart, and camera on/off

- The window builds one DirectShow capture graph on the **same source filter**
  it already holds for `IAMVideoProcAmp`. No second camera open and no video
  renderer are involved.
- The graph is Filter Graph + Capture Graph Builder 2 + QEdit Sample Grabber in
  **buffered mode** (`SetBufferSamples(1)`, `SetOneShot(0)`). The view polls
  `GetCurrentBuffer`; the callback mode delivered no frames on this camera and
  is not used.
- Before `RenderStream`, `IAMStreamConfig` on the capture pin
  (`{C6E13340-30AC-11D0-A18C-00A0C9118956}`, found through
  `ICaptureGraphBuilder2.FindInterface`) sets the largest driver format no
  bigger than 1280 x 720. Without this, the graph negotiates the native
  2560 x 1440 RGB32 and every read overflows the caller's buffer.
- Frames can arrive bottom-up (`biHeight > 0`), so rows are flipped, and RGB32
  leaves the fourth byte undefined, so alpha is forced to 255: NanoUI
  premultiplies textures by alpha.
- Reads before the first sample return `VFW_E_WRONG_STATE` (0x80040227) and are
  treated as "no frame yet", not as an error.
- `ui.texture` is only implemented by NanoUI's CPU canvas. The GUI sets
  `NANOUI_NO_D3D=1` with `SetEnvironmentVariableW` before `App.create`, because
  the Windows Direct3D 11 presenter draws a texture as a plain box.
- The view paces itself with `c.frameIn(1.0 / 30.0)` while a stream runs.
- "Camera on" is a stream toggle, not a PnP device disable: with it off (the
  default) the camera stays free for OBS, Zoom and Windows Camera. "Restart
  camera" stops the graph, closes and reopens the camera, and starts again.
- The camera allows one stream. When another app is already streaming, `start`
  fails with `error.CameraBusy` and the window says so instead of retrying.
- Starting a stream can revert white balance to automatic. The window only
  **reports** the read-back; it never writes a frozen setting from the preview
  path. The daemon's workers reassert the frozen state.
- NanoUI has no Windows system-tray support (`tray_none.zig`), so the settings
  window is a normal top-level window with no tray icon.

## Logon startup

- `install-startup` creates the Task Scheduler task
  `CameraProjectCameraDaemon` with:
  - `ONLOGON` trigger for the current user,
  - `RunLevel=HighestAvailable` (`schtasks` flag `/RL HIGHEST`),
  - interactive token, so the elevated daemon runs in the user's session.
- Registration must itself be elevated; `uninstall-startup` removes the task,
  `startup-status` reports whether it exists.
- The action is the window-subsystem daemon next to the camera-probe binary
  that registered it, quoted:
  `"C:\Users\kp\camera_project-out\bin\camera-daemon.exe"`.
- `camera-daemon.exe` creates no console window. It points its stderr at
  `%LOCALAPPDATA%\CameraProject\daemon.log` (truncated at every start) before
  running the daemon, so the log lines and any panic trace are kept. The
  console `camera-probe daemon` command stays available for debugging.
- The interactive token still applies: the daemon runs elevated in the user's
  session, so it can reach the camera and the UVC ETW provider.
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

The daemon uses three independent worker threads. Each worker initializes its own
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

### Extras worker

- Reads `%LOCALAPPDATA%\CameraProject\settings.zon` every `1000 ms` and only
  re-parses it when its bytes changed.
- Does nothing while no control is managed; it does not even open the camera.
- Otherwise it opens only the FINGERS camera, then for each managed control
  reads the driver range and value and writes only when they differ from the
  saved state.
- Never reads or writes the frozen white balance (`7`) or power line (`13`);
  `controls.isFrozen` guards every write and the table cannot contain them.
- Unsupported controls and out-of-range saved values are skipped with a log
  line. Only real COM failures count as errors and trigger the `5000 ms` reopen
  retry.
- Independent from the other two workers: it is a third trigger that reasserts
  the user's own settings after a stream restart, typically within a second.

The white-balance worker and the ETW refresh both write the same frozen final
state. The ETW path is necessary because after an OBS source restart the driver
can report manual value `4` while the actual stream has reverted to automatic
white balance.

## Error handling and lifecycle

- Each worker retries camera/COM/session failures after `5000 ms`.
- Ctrl+C is registered only when a console exists (`camera-probe daemon`). It
  signals a shared Windows event; all three workers stop cleanly and the ETW
  session is closed.
- `camera-daemon.exe` has no console and no Ctrl+C path; the logon task is
  stopped with `schtasks /End`, which terminates the process. A later start
  recovers a leftover ETW session (`ERROR_ALREADY_EXISTS` → `StopTraceW` →
  `StartTraceW`).
- A finite `daemon <seconds>` test signals the same shutdown event automatically.
- No ETL file or persistent analytic log is used by the ETW watcher.

## Source layout

- `src/main.zig` — CLI, read-only probe, diagnostic commands, frozen white
  balance/power-line test paths, `apply-config`, `config-path`, `preview`.
- `src/preview.zig` — the capture graph behind the live preview: format
  selection, buffered Sample Grabber, flip/alpha handling.
- `src/directshow.zig` — DirectShow COM ABI, device selection, VideoProcAmp and
  CameraControl access, `E_PROP_ID_UNSUPPORTED` mapped to
  `error.PropertyNotSupported`.
- `src/controls.zig` — the extra-control table, range/value/set helpers, and the
  read-compare-write enforcement used by the daemon and the GUI.
- `src/settings.zig` — `%LOCALAPPDATA%\CameraProject\settings.zon` path, ZON
  read/parse/write.
- `src/extras.zig` — the daemon's extras worker and its settings-file cache.
- `src/etw.zig` — real-time `Microsoft-Windows-USBVideo` consumer, idle/cooldown
  state machine, finite and external-stop modes.
- `src/daemon.zig` — elevated three-worker controller.
- `src/daemon_main.zig` — `camera-daemon.exe` entry point: stderr to
  `daemon.log`, then the same controller with no console.
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
& C:\Users\kp\camera_project-out\bin\camera-probe.exe config-path
& C:\Users\kp\camera_project-out\bin\camera-probe.exe apply-config
& C:\Users\kp\camera_project-out\bin\camera-probe.exe preview 5
& .\zig-out\bin\camera-settings.exe
# Elevated:
& C:\Users\kp\camera_project-out\bin\camera-probe.exe etw-watch 120 50
& C:\Users\kp\camera_project-out\bin\camera-probe.exe daemon 120
```

`probe` now ends with a read-only list of every extra control (range, step,
current value, flags) and marks the ones the driver does not expose.

The GUI can be rendered headlessly for layout checks:

```powershell
& .\zig-out\bin\camera-settings.exe --nanoui-snapshot=C:\Users\kp\snapshot.png
```

Check the logon daemon exactly as Windows starts it, without a console:

```powershell
schtasks /Run /TN CameraProjectCameraDaemon
Start-Sleep -Seconds 6
Get-Process camera-daemon | Select-Object Id, MainWindowHandle   # 0: no window
Get-Content "$env:LOCALAPPDATA\CameraProject\daemon.log"
schtasks /End /TN CameraProjectCameraDaemon
```

Build the elevated copy with:

```powershell
zig build --prefix C:\Users\kp\camera_project-out
```

## Not implemented yet

- Tray controls. NanoUI has no Windows system-tray support, so a tray icon would
  require a different shell.
- Robust camera identity for the ETW trigger when multiple cameras stream.
