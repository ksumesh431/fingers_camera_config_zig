# Camera Project

Windows-side camera project. The camera is connected to the **Windows host**,
not to WSL — see `.agent/00-environment.md` for the environment rules.

## Environment at a glance

- Editing and repo browsing: WSL (`/mnt/d/Cloud/cam_scripts`).
- Build, test, and anything that opens the camera, uses a Windows SDK, or
  depends on drivers: run it on **Windows**
  (`D:\Cloud\cam_scripts`, a Windows-built binary).
- Do not try to expose the camera to WSL via USB passthrough. If a camera
  feature is being tested, test it on Windows.
- Keep the source on the `D:` drive. Zig package fetching and the default build
  cache both fail on a `\\wsl.localhost\...` UNC path.

## How to work here

- Add short, project-wide rules to this file.
- Put longer topic-specific instructions in `.agent/*.md`; they are auto-loaded
  via `.opencode/opencode.jsonc`.
- Keep Windows and WSL steps clearly separated in instructions and docs.
- When writing scripts, state where they must be executed (Windows vs WSL) and
  how to invoke them from the other side.

## Project details

- Goal: control the external USB webcam from Zig and make the preferred image
  settings survive camera/application restarts. Confirmed preferences are
  manual white balance `4` and power-line frequency `50 Hz`. First prove the
  behavior with a Windows console probe, then add a NanoUI GUI.
- Camera: **FINGERS Hi-Res 2K** (external USB), never the Integrated Camera.
- Language / framework: Zig 0.17.0; Windows DirectShow COM for camera control;
  NanoUI `v0.13.0` for the settings window.
- Entry point / run command (Windows): the production controller is the
  elevated `camera-probe.exe daemon [seconds]` command. Omitting the duration
  runs until Ctrl+C. The default command without `daemon` remains a read-only
  probe; see `README.md` for explicit test commands.
- Startup: `camera-probe install-startup` registers the Task Scheduler task
  `CameraProjectCameraDaemon` (`ONLOGON`, `HighestAvailable`, interactive), so
  the daemon starts elevated at logon with no UAC prompt and no console window.
  The task runs `camera-daemon.exe`, a window-subsystem binary next to
  `camera-probe.exe`; it logs to `%LOCALAPPDATA%\CameraProject\daemon.log`.
- GUI: `camera-settings.exe` is a separate NanoUI window. It is built as a
  window-subsystem executable, so it opens no console window. It also shows a
  live camera preview with "Camera on" and "Restart camera" buttons; the
  preview streams on the window's own camera handle, so the camera must not be
  streaming in OBS/Zoom/Windows Camera at the same time. NanoUI has no Windows
  system-tray support, so there is no tray icon.
- Custom controls: every extra `IAMVideoProcAmp` / `IAMCameraControl` property
  the camera exposes is listed with a switch, an Automatic/Manual choice where
  the driver supports both, and a slider. Choices are saved to
  `%LOCALAPPDATA%\CameraProject\settings.zon` and the daemon re-applies them.
  White balance and power line are excluded from that table by a compile-time
  check in `src/controls.zig`; they stay exactly as described below.
- Output location: `zig-out/bin/camera-probe.exe` for normal probes,
  `zig-out/bin/camera-settings.exe` for the GUI, and
  `zig-out/bin/camera-daemon.exe` for the logon daemon;
  `C:\Users\kp\camera_project-out\bin\` for the elevated copies
  the logon task runs. Elevated binaries use
  `--prefix C:\Users\kp\camera_project-out` so installing them never collides
  with a running daemon or the WSL-side install.

## Proven white-balance fix — do not regress

- The working white-balance control is frozen: DirectShow
  `VideoProcAmp_WhiteBalance` (property `7`), manual value `4`, manual flags
  `0x2`, with the existing 250 ms reset detection and `Set`/`Get` verification.
- The driver may report manual value `4` while the actual stream has reverted
  visually. Therefore an ETW stream restart must force white balance through
  automatic and back to manual `4`; never trust the reported value alone.
- Do not change the frozen property, value, flags, or verification behavior
  without an explicit user request.
- Power-line experiments must remain independent and optional. Running
  `watch 4 120` without a power-line argument must preserve the original
  white-balance-only behavior.

## Proven power-line fix

- Reapply anti-flicker by setting `60 Hz`, waiting **2 seconds**, then setting
  `50 Hz`. Writing 50 Hz alone is insufficient when the driver already reports
  50 Hz.
- Trigger this refresh from `Microsoft-Windows-USBVideo` ETW event `208` when
  frame activity resumes after at least `500 ms` idle, with a **5-second
  cooldown** after each refresh. Use event timestamps, not callback delivery
  times, because ETW batches events.
- ETW watching requires elevation and does not identify the physical camera.
  The current design assumes the Integrated Camera is not streaming.
- Do not couple power-line refresh to white-balance *polling* resets; the two
  workers remain independent. Both frozen settings are reasserted from the same
  ETW stream-restart trigger in the daemon.

## Daemon architecture

- `camera-probe daemon [seconds]` is the persistent elevated controller.
- Three worker threads, each with its own COM apartment and DirectShow camera:
  - Frozen white-balance loop: manual `4`, 250 ms poll.
  - ETW worker: 500 ms event-timestamp idle threshold, 5-second cooldown.
  - Extras worker: user controls from the settings file, 1000 ms poll.
- ETW stream restart performs a combined forced refresh: white balance automatic
  → power line `60 Hz` → wait 2 seconds → white balance manual `4` → power line
  `50 Hz`; both final states are verified. The extras worker never touches those
  two properties.
- Errors retry after 5 seconds. Ctrl+C stops all three workers and closes the
  ETW session cleanly.
- Detailed runtime rules are in `.agent/20-runtime-architecture.md`.

## Project knowledge

- `.agent/00-environment.md` contains Windows/WSL execution rules and the
  verified host/toolchain details.
- `.agent/10-camera.md` contains the hardware identity, reported problem,
  technical approach, and complete test log.
- `.agent/20-runtime-architecture.md` contains the daemon worker design, frozen
  settings, lifecycle, source layout, and regression commands.
- Record verified findings, decisions, and test outcomes there as work
  proceeds. Keep assumptions clearly separate from observed behavior.
