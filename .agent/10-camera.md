# Camera context, approach, and test log

## User-visible problem

The external **FINGERS Hi-Res 2K** USB webcam produces poor image output with
its default automatic white balance. In OBS, opening the camera's video
settings and disabling automatic white balance improves the image. The setting
is lost when OBS turns the camera off/on and when another application such as
Zoom or Windows Camera uses it. There is no vendor configuration application.

The desired result is a Zig Windows application that controls the external
camera and makes the preferred settings persistent in practice. Start with a
small console probe to establish the actual device behavior. Add a GUI with
<https://github.com/justrach/nanoui> only after the controls work.

## Verified Windows hardware (2026-11-10)

Read-only Windows PnP inspection found two different cameras:

| Device | Role | Hardware identity |
| --- | --- | --- |
| FINGERS Hi-Res 2K | Target external camera | `USB\VID_5843&PID_7884&MI_00` |
| Integrated Camera | Laptop camera; do not modify | `USB\VID_04F2&PID_B7B6&MI_00` |

The FINGERS device also exposes an audio function named
`Microphone (FINGERS Hi-Res 2K)`. Its media function is `MI_02`; that is not
the video-control target.

Target video device details:

- Friendly name: `FINGERS Hi-Res 2K`
- Current full instance ID:
  `USB\VID_5843&PID_7884&MI_00\7&1D4434C&1&0000`
- USB parent: `USB\VID_5843&PID_7884\20260429.1631`
- Status: OK; class: Camera
- Driver provider: Microsoft
- Driver/service: `usbvideo`
- INF: `usbvideo.inf`
- Driver version: `10.0.26100.9711`

Match the target by friendly name plus `VID_5843&PID_7884` and the video
capture category. Do not select by enumeration order and do not hardcode the
full instance ID, which can change with USB topology.

## Diagnosis and validated behavior

The camera uses Microsoft's standard UVC driver. OBS's **Configure Video**
dialog exposes the driver's DirectShow property pages. White balance belongs to
`IAMVideoProcAmp` (`VideoProcAmp_WhiteBalance`), whose flags distinguish
automatic (`0x1`) from manual (`0x2`) control. The standard
`IAMCameraControl` interface handles properties such as exposure and focus;
its documented enumeration does not include white balance.

The device or driver restores automatic white balance when Windows Camera
starts a new streaming session. This was confirmed by polling during a real
application restart: the flags changed from manual (`0x2`) to automatic (`0x1`)
three times, and the watcher successfully restored manual value `4` each time.
The numeric value remained `4`; the automatic/manual flag was what reset.
The user visually confirmed that the image worked well throughout this test.

Do not promise firmware-level persistence. The likely application design is
to save a user profile and reapply it when the camera reconnects or a new
camera session starts. Whether a one-time setting survives by itself is an
experiment, not a requirement to assume.

## Implementation direction

1. Build a native Windows x86_64 Zig 0.17.0 console executable. Do not run it
   in WSL.
2. Use DirectShow COM (`ICreateDevEnum`, `IMoniker`, `IBaseFilter`, and
   `IAMVideoProcAmp`) for the initial probe because it matches the Windows/OBS
   property page that successfully changes this camera. DirectShow is legacy,
   but remains supported on this Windows 11 host and is the shortest way to
   test the same control path.
3. Default to read-only diagnostics. Camera writes require an explicit command
   and must target only the external FINGERS device.
4. Print supported range, step, default, supported flags, current value, and
   current automatic/manual flags. Preserve enough state to restore the prior
   setting after tests.
5. Once behavior is understood, separate camera-control code from UI code.
   NanoUI currently targets Zig 0.17.0 and supports Windows, so it fits the
   later GUI phase. No GUI dependency is needed for the console probe.

## Toolchain status (2026-11-10)

- Host: Windows 11 IoT Enterprise LTSC, build 26100, 64-bit.
- Windows user/profile: `kp`, `C:\Users\kp`.
- WSL distribution: `AzureLinux-4`.
- Windows Zig 0.17.0 is installed via WinGet and was verified from WSL using
  the native executable. Zig is not installed in WSL.
- Source is at `D:\Cloud\cam_scripts`; builds and tests run there from Windows
  with no cache override. Zig cannot build on a `\\wsl.localhost\...` UNC path.
- Windows Python 3.14 and Git are available, but are not substitutes for the
  requested Zig implementation.
- NanoUI is pinned to `v0.13.0` and now backs `camera-settings.exe`, built with
  `webview2 = "none"`.

## Resolved decisions

- The user confirmed the OBS setting is under **Video Proc Amp**.
- The intended utility should run in the background and automatically reapply
  saved settings after camera/application or streaming restarts.
- Use the user's WinGet-installed Windows Zig 0.17.0; keep source in WSL and
  the Zig local build cache on Windows.

## Validated preference and remaining work

- Manual value `4` is the current confirmed preference: the user reported the
  image was "working great" while the watcher enforced it in Windows Camera.
- **User constraint:** the proven white-balance fix must not be altered while
  investigating power-line frequency. Keep its property, manual flags, reset
  detection, and read-back behavior unchanged; power-line work is separate.
- Implemented: durable background operation (elevated daemon), Windows logon
  startup (Task Scheduler), the NanoUI settings window, a persisted settings
  file for the extra (non-frozen) camera controls, and a live in-window camera
  preview with restart and camera on/off controls.
- Still to implement: robust camera identity for the ETW trigger, and tray
  controls (NanoUI has no Windows tray support).

## Test log

### 2026-11-10 — read-only device discovery

Ran Windows PowerShell through WSL interop. Confirmed the external camera's
USB identity and Microsoft UVC driver, and distinguished it from the integrated
camera and its microphone. No camera setting was read through DirectShow yet,
and no camera setting was changed.

### 2026-11-10 — native Zig read-only probe

Created a Zig 0.17.0 Windows x86_64 console application using explicit
DirectShow COM vtables and Windows `ole32`/`oleaut32` imports. Unit tests pass.
The executable enumerates Integrated Camera, FINGERS Hi-Res 2K, and OBS Virtual
Camera. It selects only the FINGERS name plus USB VID/PID; OBS Virtual Camera
lacks `IAMVideoProcAmp` as expected. A missing `DevicePath` on OBS Virtual
Camera is handled through `IMoniker.GetDisplayName`.

Observed on FINGERS Hi-Res 2K:

- `IAMVideoProcAmp` query: `S_OK`
- White-balance range: minimum `1`, maximum `5`, step `1`, default `4`
- Capabilities: `0x3` (both automatic and manual supported)
- Current value: `4`
- Current flags: `0x2` (manual)

A second separate execution returned the same manual value `4`. No OBS, Zoom,
or Windows Camera process was running at that check. Therefore, closing OBS
and releasing/recreating this probe's DirectShow objects did not reproduce the
reset. Both initial probe runs were read-only.

### 2026-11-10 — explicit set and finite watch verification

Added `probe`, `set-manual <value>`, `set-auto`, and
`watch <value> <seconds>` commands. Default/no-argument behavior remains
read-only. Values are checked against the driver's range before setting, and
all writes are verified through `IAMVideoProcAmp.Get`. Unit tests covering
camera selection, CLI parsing, and range validation pass on native Windows.

Executed `set-manual 4`, which was already the current value. `Set` succeeded
and read-back confirmed value `4`, flags `0x2` (manual). Then executed
`watch 4 2`; it applied manual `4`, polled at 250 ms, completed normally, and
reapplied zero times because no application reset the setting.

### 2026-11-10 — power-line frequency requirement and initial test

The user also wants the anti-flicker **power line frequency** forced to
**50 Hz**. This control is in the same OBS Video Proc Amp page.

Microsoft documents `KSPROPERTY_VIDEOPROCAMP_POWERLINE_FREQUENCY` as property
ID 13 in the VideoProcAmp property set, with values: `0` disabled, `1` 50 Hz,
`2` 60 Hz, `3` automatic (auto is not available on all cameras). DirectShow
uses this property ID through `IAMVideoProcAmp`.

Read-only probe on FINGERS Hi-Res 2K:

- Range: minimum `0`, maximum `2`, step `1`, default `1`
- Capabilities: `0x0` (no auto/manual flags; it is a discrete value control)
- Current value: `1` (50 Hz)
- Explicit `set-powerline 50` succeeded; read-back was value `1`, flags `0x0`
- The driver does not offer `3` (automatic) in this camera's supported range

### 2026-11-10 — flicker remains with 50 Hz applied

Ran a combined watch enforcing manual white balance `4` and 50 Hz while the
user opened/restarted Windows Camera. The white-balance flag reset to auto and
was restored, but the power-line value never changed from `1` (50 Hz). The user
reported the camera still flickers.

A follow-up read-only probe confirmed the power-line value is still `1` with no
reapply. This rules out the 50 Hz property reverting. The same probe found the
camera also supports `IAMCameraControl` exposure:

- Exposure range: minimum `-13`, maximum `0`, step `1`, default `-7`
- Capabilities: `0x3` (automatic and manual supported)
- Current exposure: `-7`, flags `0x1` (automatic)

DirectShow documents exposure in log2 seconds, so `-7` is approximately
1/128 s. Automatic exposure is now the main suspect for brightness/flicker
behavior; manual exposure may be required in addition to 50 Hz. Cause not yet
confirmed.

### 2026-11-10 — verified 50 Hz refresh timing

The user clarified that manually switching OBS's power-line setting 60 → 50 Hz
and applying it removes rolling bands, even when 50 Hz was already displayed.
This means the driver's reported value can remain `1` while the camera's actual
anti-flicker state needs to be reapplied. A simple `Set(50 Hz)` was insufficient.

Initial exposure/FPS investigation was abandoned at the user's direction;
automatic exposure was restored and no white-balance behavior was changed.
Rolling bands occurred under LED lighting in both Windows Camera and OBS.

Added `refresh-powerline 50`, which explicitly sets 60 Hz, waits, then sets
50 Hz, verifying both values. Results:

- 250 ms between the two writes: user reported no change
- 2000 ms between the two writes: user confirmed **bands gone**

The required power-line action is therefore a timed 60 → 50 Hz refresh, not
merely checking or writing value `1`. White-balance logic remains frozen and
was not changed as part of this diagnosis.

A subsequent combined-watch test initially looked good with bands gone, but
OBS source deactivation/reactivation brought the bands back. The watch log
showed no white-balance reset and no power-line refresh: white balance stayed
manual and power line continued reporting value `1`. Therefore, power-line
recovery cannot depend on white-balance resets or reported-value changes. It
needs an independent stream-restart trigger or another recovery strategy.

A finite keep-alive graph was implemented using `ICaptureGraphBuilder2` and a
Null Renderer. With OBS active, `IMediaControl.Run` failed with `0x800705AA`
(`ERROR_NO_SYSTEM_RESOURCES`). With OBS deactivated, the keep-alive stream ran,
but OBS showed a black screen when reactivated. The keep-alive test was stopped
normally. This proves the camera does not allow the required shared streaming,
so keep-alive is not a viable solution. No settings were changed by this test.

### 2026-11-10 — UVC ETW stream-activity discovery

Verified `Microsoft-Windows-USBVideo` provider availability and inspected its
manifest. Events `204`/`205` describe `StartUSBVideoDevice`, and `206`/`207`
describe `StopUSBVideoDevice`. Events `208`/`209` are `FillUserBuffer` start/stop.

Captured two elevated, finite Logman traces while the user toggled the OBS
source. The provider did not emit `204`/`206` for source toggling on this build.
It did emit `208`/`209` only while frames were streaming. The controlled second
trace showed a `6547.2443 ms` gap between event `208` at `19:27:30.960` and the
next event at `19:27:37.507`, matching OBS deactivation/reactivation. Therefore,
first frame event after an idle gap is a verified stream-restart signal.

Constraints: receiving these events requires elevation; `208`/`209` contain no
process ID, activity ID, or camera identity. Any ETW-based controller would need
to assume the Integrated Camera is not streaming concurrently, or accept false
triggers from it. White-balance code was not changed.

### 2026-11-10 — ETW-triggered power-line recovery validated

Implemented a native Zig real-time ETW consumer (`StartTraceW`,
`EnableTraceEx2`, `OpenTraceW`, `ProcessTrace`) with explicit x64 ABI layouts
verified against the installed Windows headers. No persistent analytic log or
ETL file is needed for the watcher. It is a separate `etw-watch` command and
does not call white-balance code.

The first implementation exposed two timing traps: callback delivery batches
were mistaken for idle gaps, and refreshes could retrigger themselves. Fixed
these by using `EventHeader.TimeStamp` for idle detection and a 5-second
cooldown after every refresh. The underlying refresh remains 60 Hz, wait 2
seconds, then 50 Hz.

In the successful elevated 120-second test, the watcher performed exactly:

1. One initial frame-activity refresh.
2. One refresh when frame activity resumed after `5088 ms` idle following an
   OBS source restart.

There were no subsequent refresh loops. The 120-second watch completed normally
with `power line refreshed 2 time(s)`. The user reported: "the bands are
permanently gone now." This validates the ETW-triggered strategy while the
watcher is running. Elevation is still required, and the Integrated Camera must
not stream concurrently because event `208` lacks camera identity.

### 2026-11-10 — persistent daemon integration validated

Implemented `camera-probe daemon [seconds]`, requiring elevation, with two
independent worker threads. Each worker initializes its own COM apartment and
camera object, so no COM pointer crosses threads.

- White-balance worker: frozen manual value `4`, flags `0x2`, 250 ms polling.
- Power-line worker: frozen ETW event-208 restart detection, 500 ms idle,
  5-second cooldown.

The first daemon test restored power-line/banding after OBS reactivation but the
white balance visually reverted to automatic even though the driver reported
value `4`, flags `0x2`. A read-only probe confirmed the stale property state.
This is the same stale-hardware issue previously seen with power line.

The daemon's ETW trigger was therefore extended to force both frozen settings
together: white balance automatic → power line `60 Hz` → wait 2 seconds → white
balance manual `4` → power line `50 Hz`, with final verification of both. The
existing white-balance polling worker and all frozen values/property IDs remain
unchanged.

Successful elevated `daemon 120` test log:

- Initial frame activity: combined refresh completed.
- OBS restart detected after `5782 ms` idle: combined refresh completed.
- White balance ended manual value `4`, flags `0x2`.
- Power line ended value `1` (50 Hz).
- User reported: "all look good now after reactivating."
- The 120-second test completed cleanly: ETW session closed, both workers
  stopped, and the daemon printed `Camera controller daemon stopped.`

### 2026-11-10 — Windows Camera streaming-reset test

Ran `watch 4 120` while the user opened and restarted Windows Camera with
FINGERS Hi-Res 2K selected. The log captured three independent transitions to
value `4`, flags `0x1` (auto). After each transition, the watch called `Set`
and read back value `4`, flags `0x2` (manual). The user restarted the app and
reported: "it is working great." The watch completed normally after 120
seconds with a final reapplication count of `3`. This validates both the reset
diagnosis and the background polling/reapply strategy. Polling interval was
250 ms.

### 2026-11-10 — project relocated to a Windows-local path

Zig could not fetch packages or use its default build cache while the source
lived on `\\wsl.localhost\AzureLinux-4\home\kp\scripts_wsl\camera_project`; it
failed with `unable to walk temporary directory 'zig-pkg\.tmp-...'` and
`manifest_create Unexpected`. A `pushd` drive mapping did not help.

The project was moved to `D:\Cloud\cam_scripts` (`/mnt/d/Cloud/cam_scripts` from
WSL) at the user's suggestion. `zig build` and `zig build test` then succeeded
with no `--cache-dir` override, and NanoUI `v0.13.0` plus `http_zig` were
fetched into `zig-pkg/`. No camera behavior changed in this step.

### 2026-11-10 — NanoUI settings window

Added a separate `camera-settings.exe` built with NanoUI `v0.13.0` and
`.webview2 = "none"`. It reads the frozen white-balance and power-line state,
offers "apply manual 4" and "force 50 Hz" buttons, and reports whether the logon
task is installed. The CLI and daemon do not depend on NanoUI.

Two implementation notes:

- NanoUI has no Windows system-tray support (`tray_none.zig`), so the settings
  window is a normal window, not a tray app.
- `camera-settings.exe --nanoui-snapshot=<path>` renders the window headlessly.
  The rendered layout confirmed live values: white balance manual value `4`
  flags `0x2`, power line 50 Hz, "Starts with Windows: yes".

### 2026-11-10 — logon startup registration validated

`install-startup` registers the Task Scheduler task `CameraProjectCameraDaemon`
with an `ONLOGON` trigger, `RunLevel=HighestAvailable`, and the interactive
token. The action is the quoted path
`"C:\Users\kp\camera_project-out\bin\camera-probe.exe" daemon`.

Query after registration reported `Status: Ready`, `Logon Mode: Interactive
only`, `Run As User: kp`, and the quoted `Task To Run` value. `schtasks /Run`
started the elevated daemon without a UAC prompt (PID confirmed). A read-only
probe executed while it ran reported manual white balance value `4` flags `0x2`
and power line value `1` (50 Hz). `schtasks /End` stopped it cleanly and the
probe then reported the same values. No camera setting was changed by this test.

### 2026-11-10 — extra camera controls, settings file, and expanded GUI

Extended the read-only `probe` to list every extra `IAMVideoProcAmp` /
`IAMCameraControl` property with its range, step, current value, and flags.
`GetRange`/`Get` returning `E_PROP_ID_UNSUPPORTED` (`0x80070490`) is now mapped
to `error.PropertyNotSupported` instead of a generic COM failure.

Observed on FINGERS Hi-Res 2K (read-only):

- Supported, manual-only (`caps=0x2`): brightness `0..10` (current `5`),
  contrast `0..20` (`10`), saturation `0..20` (`10`), sharpness `0..20` (`0`),
  gamma `1..9` (`1`), backlight compensation `0..64` (`0`), gain `0..255` (`0`).
- Supported with auto and manual (`caps=0x3`): exposure `-13..0` (current `-7`,
  automatic), focus `0..1023` (current `0`, automatic).
- Not supported (`E_PROP_ID_UNSUPPORTED`): hue, color enable, zoom, pan, tilt,
  roll.
- Iris reports `caps=0x1`, range `0..0`, step `0`: a placeholder. The GUI hides
  any control whose range has no width.

Added `%LOCALAPPDATA%\CameraProject\settings.zon` plus `apply-config` and
`config-path`. The GUI (`camera-settings.exe`) now has one switch per control,
an Automatic/Manual choice where both are supported, a slider snapped to the
driver's step, and writes the file once the pointer is released. A compile-time
check in `src/controls.zig` rejects any table containing white balance (`7`) or
power line (`13`).

Verification:

- Headless snapshot rendered at 660x640 with a saved test file: frozen panel,
  9 available controls, and managed rows (green switch, slider, value) all laid
  out correctly.
- `apply-config` with values matching the driver reported `0 applied, 3 already
  correct`, proving the read/compare path.
- Controlled write test: brightness `5 -> 6` was applied and read back as
  `value=6 flags=0x2`; then `6 -> 5` was applied and read back as
  `value=5 flags=0x2`. The frozen settings were untouched throughout
  (`watch`/`probe` showed white balance value `4` and power line `1` as before).
- The test settings file was deleted afterwards, so the daemon enforces nothing
  extra until the user saves from the GUI.

The daemon now has a third, independent extras worker; see
`.agent/20-runtime-architecture.md`.

### 2026-11-10 — live preview capture graph and settings-window integration

Added `src/preview.zig`, a DirectShow capture graph (Filter Graph + Capture
Graph Builder 2 + QEdit Sample Grabber) streaming from the same source filter
the settings window holds for its property pages. It never writes a camera
property. The first two attempts produced no frames and shaped the final
design:

- Callback mode (`SetCallback`) delivered no samples on this camera at all.
  Buffered mode (`SetBufferSamples(1)`, `SetOneShot(0)`, poll
  `GetCurrentBuffer`) works and needs no callback thread.
- After that the graph still produced nothing. Instrumentation showed it had
  negotiated the camera's native **2560 x 1440 RGB32** (stride 10240), not the
  requested 640 x 360, so every read overran the 640x360 destination buffer and
  was discarded silently. Fix: `IAMStreamConfig`
  (`{C6E13340-30AC-11D0-A18C-00A0C9118956}`, found on the capture pin through
  `ICaptureGraphBuilder2.FindInterface`) sets the largest driver format no
  bigger than 1280 x 720 before `RenderStream`. The graph then negotiates
  1280 x 720, stride 5120, bottom-up rows (`flip = true`).

New console command `camera-probe preview [seconds]` (default 10) streams the
same graph and counts frames per second without changing settings:

- `preview 4` reported 15 frames in the first second, then 20 per second at a
  50 ms poll interval, 1280 x 720, and a clean stop.
- The first read after `Run` returns `VFW_E_WRONG_STATE` (0x80040227); that is
  "no sample yet", not a failure.
- A read-only `probe` afterwards reported the frozen state unchanged: white
  balance value `4` flags `0x2`, power line value `1` (50 Hz).

The settings window now embeds the preview (508-wide panel, 270-tall box) with
a `Camera on` stream toggle and a `Restart camera` button:

- `ui.texture` is only implemented by NanoUI's CPU canvas, so the GUI sets
  `NANOUI_NO_D3D=1` before `App.create`; the Windows D3D11 presenter draws a
  texture as a plain box.
- Frames are flipped when the format is bottom-up and their alpha byte forced
  to `255`, because NanoUI premultiplies textures by alpha.
- End-to-end check: with `camera_on` temporarily defaulted to true, the real
  window was launched and the screen captured after 7 seconds. It showed a
  live image, the `live` badge, and `1280x720 at 30 fps - 121 frames received`.
  The temporary default was reverted to off and the binary rebuilt.
- Starting a stream can revert the driver to automatic white balance; the
  window only reports the read-back and never writes a frozen setting from the
  preview path.
- The camera allows only one stream: with OBS or Zoom streaming, the preview
  fails with `error.CameraBusy` and says so instead of retrying.
- `camera-settings.exe` is now built with `gui.subsystem = .windows`; the PE
  header reports subsystem 2, so launching it opens no console window.

### 2026-11-10 — logon daemon without a console window

After a reboot the logon task showed the daemon console in the foreground
(`C:\Users\kp\camera_project-out\bin\camera-probe.exe`). The task had always
started the console-subsystem binary; earlier it only happened to sit behind
other windows.

Fix: added `src/daemon_main.zig` and a new `camera-daemon.exe` built with
`daemon_exe.subsystem = .windows`. It runs the same `daemon.zig` controller but
never creates a console. Before `daemon.run`, it opens
`%LOCALAPPDATA%\CameraProject\daemon.log` (truncated at every start) and points
the process's stderr at it (`ProcessParameters.hStdError`), so every
`std.debug.print` and any panic trace lands in the file. `daemon.zig` now
registers a Ctrl+C handler only when `GetConsoleWindow()` reports a console;
the window-subsystem daemon has none.

`install-startup` now registers the sibling `camera-daemon.exe` with no
arguments. `camera-probe daemon` remains the console form for debugging.

Verified after reinstalling the task:

- `schtasks /Query /V` showed
  `Task To Run: "C:\Users\kp\camera_project-out\bin\camera-daemon.exe"`.
- `schtasks /Run` started the daemon with `MainWindowHandle 0` and no
  `conhost.exe` child process, proving no console exists.
- `daemon.log` held the startup banner, all three worker lines, the ETW watcher
  start, and `White balance applied: value=4 flags=0x2`.
- A read-only `probe` reported white balance `4` flags `0x2` and power line `1`
  (50 Hz).
- `schtasks /End` stopped it; a second `/Run` truncated the log, recovered the
  leftover ETW session, and logged the same startup. It was left running.

## References

- Microsoft, Configure the Video Quality:
  <https://learn.microsoft.com/en-us/windows/win32/directshow/configure-the-video-quality>
- Microsoft, `IAMVideoProcAmp`:
  <https://learn.microsoft.com/en-us/windows/win32/api/strmif/nn-strmif-iamvideoprocamp>
- Microsoft, `VideoProcAmpFlags`:
  <https://learn.microsoft.com/en-us/windows/win32/api/strmif/ne-strmif-videoprocampflags>
- NanoUI:
  <https://github.com/justrach/nanoui>
