# Environment: Windows host, WSL editor

## The one rule that matters

The camera is physically connected to the **Windows machine**. All code that
touches the camera must run on Windows, not inside WSL. WSL is only for editing
files, browsing the repo, and running tools that do not need the camera.

WSL has no access to the Windows camera stack (DirectShow, Media Foundation,
Windows Hello, etc.), so anything camera-related will fail or see no devices
when run from Linux. Do not "fix" that with drivers or USB passthrough — run it
on the Windows side instead.

## Running commands

- Run Windows-side commands from WSL by calling the Windows binary explicitly:
  - `powershell.exe -NoProfile -Command "..."` (prefer this for scripts)
  - `cmd.exe /c "..."` when a `.bat`/`.cmd` is involved
  - `python.exe script.py`, `py -3 script.py` — the Windows Python, not `python3`
- On this WSL installation, Windows PATH integration is disabled:
  `powershell.exe` and `python.exe` are not directly on the WSL `PATH`.
  PowerShell works through its full path:
  `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`.
  Inside native Windows terminals, the usual `powershell.exe` commands apply.
- Quote Windows paths carefully; prefer forward slashes in Python and
  PowerShell, e.g. `C:/Users/.../camera_project/script.py`.
- Do not assume `python`, `pip`, or packages installed in WSL exist on Windows
  (and vice versa). Check each side separately with `python.exe --version` etc.

## Path mapping

| WSL path                | Windows path           |
| ----------------------- | ---------------------- |
| `/mnt/c/Users/kp/...`    | `C:\Users\kp\...`   |
| `/mnt/d/Cloud/cam_scripts` | `D:\Cloud\cam_scripts` |

- The project source lives at `D:\Cloud\cam_scripts` so Windows tools work on a
  normal local drive. WSL edits it through `/mnt/d/Cloud/cam_scripts`.
- Keep the source off `\\wsl.localhost\...`. Zig cannot fetch packages into
  `zig-pkg/` there (`unable to walk temporary directory`) and its default build
  cache fails with `manifest_create Unexpected`.
- No `--cache-dir` override is needed on the `D:` path; the default cache works.
- Run Windows Zig from WSL through its installed path:
  `/mnt/c/Users/kp/AppData/Local/Microsoft/WinGet/Packages/zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe/zig-x86_64-windows-0.17.0/zig.exe`.
- For the elevated copy that the logon task runs, install with
  `--prefix C:\Users\kp\camera_project-out`. Stop the running daemon first
  (`schtasks /End /TN CameraProjectCameraDaemon`), otherwise the install fails
  with `AccessDenied` while `camera-probe.exe` is still running from that path.
- Elevated ETW tests log to `C:\Users\kp\camera_etw_watch.log`.
- Elevated daemon tests log to `C:\Users\kp\camera_daemon.log`.
- UAC prompts appear when launching elevated test processes from WSL; treat
  approval/decline as user action, never bypass elevation.
- When invoking a Windows Python that lives on Windows, `sys.path` and relative
  paths resolve on the Windows filesystem. Keep data/output paths explicit.

## Dependencies

- Install Windows Python packages with `python.exe -m pip install ...`.
- Camera SDKs / vendor drivers are Windows-only. Document them here once known.
- Never install Linux camera libraries in WSL as a workaround.

## Hardware / camera

- Camera make/model: FINGERS Hi-Res 2K (external webcam, not Integrated Camera)
- Connection: USB, `VID_5843&PID_7884`, Microsoft UVC `usbvideo` driver
- SDK or driver required: no vendor SDK; use the installed Windows camera stack
- Windows-side source path: `D:\Cloud\cam_scripts`
- WSL editing path: `/mnt/d/Cloud/cam_scripts`
- `zig-pkg/` holds the fetched NanoUI `v0.13.0` and `http_zig` sources; builds
  work offline once it exists.

## Zig and NanoUI notes

- NanoUI is pinned to `v0.13.0` in `build.zig.zon` and built with
  `.webview2 = "none"`, which is the lightweight non-WebView2 backend.
- NanoUI has no Windows system-tray support (`tray_none.zig`), so the settings
  window is a normal top-level window with no tray icon.
- `camera-settings.exe --nanoui-snapshot=<path>` renders the window headlessly
  for layout checks without opening a window.
- Zig 0.17.0 moved `fmt.allocPrint` onto the allocator: use
  `allocator.print(fmt, args)`.
- `defer .end()` in NanoUI layout code must be block-scoped, otherwise widgets
  declared later land inside the wrong container.

## Verified host and tools

- Windows 11 IoT Enterprise LTSC, build 26100, 64-bit
- Windows profile: `C:\Users\kp`
- WSL distribution: `AzureLinux-4`
- Windows Zig 0.17.0 is installed via WinGet (verified with `zig version`/`zig env`)
- Zig executable: `C:\Users\kp\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-x86_64-windows-0.17.0\zig.exe`
- Zig is not installed in WSL; use the native Windows executable
- Windows Git and Python 3.14 are installed
