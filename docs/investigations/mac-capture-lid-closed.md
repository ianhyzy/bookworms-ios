# Photographing a Mac window with the lid closed

`script/visual-check.py` photographs the scratch Mac copy's window. With the MacBook's lid closed and no external display, macOS has no active display, and no picture can be taken. The script then skips the Mac launches and lists them as missing. This note records what was tried on 2026-11-13 (macOS 27.2), so that the next attempt starts elsewhere.

## What happens

- The copy launches and opens its window: `CGWindowListCopyWindowInfo` lists it, with its title and bounds, and reports it as on screen.
- `CGGetOnlineDisplayList` counts one display and `CGGetActiveDisplayList` counts none.

## Ruled out

- **`screencapture -l WINDOW`** fails with "could not create image from window".
- **ScreenCaptureKit.** `SCShareableContent` lists the window and no displays. `SCScreenshotManager.captureImage` with `SCContentFilter(desktopIndependentWindow:)` fails with `SCStreamErrorDomain` code -3811, "Failed to start stream due to audio/video capture failure".

## Not tried

- **A picture taken by the app.** A Debug launch argument could write the window's content to a file. Whether AppKit can draw the RealityKit views without a display is unknown, and it needs app code.
- **A virtual display,** so that the window server has an active display while the lid is closed.
- **Waking the display** (`caffeinate -u`) can't help while the lid is closed, and with the lid open it lights the screen, which the script must not do on its own at night.
