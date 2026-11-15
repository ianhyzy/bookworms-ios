# Raised CPU in the Mac toolbar sweep on Desk

Investigated on 2026-11-13, on `main` at `5590fc7`, with Debug Mac copies made as [Check the Mac toolbar for a layout loop](../../README-AI.md#check-the-mac-toolbar-for-a-layout-loop) describes.

## What was seen

A window sweep of Desk with **All Time**, from 780 to 900 points, read 165 to 185 percent of one core at 807 to 811 and at 839 to 841 points, against 65 to 95 percent elsewhere. Two commits gave the same profile, so it looked like a toolbar layout loop at those widths.

## What it is

It is spine generation, not the toolbar. The app schedules generation at launch (`AppDelegate.applicationDidFinishLaunching`, `GenerationController.scheduleChargingTask()`), in preview mode too, and each pass reads a cover with Vision (`CoverTextReader.visionRead`) on a background thread. In the scratch copy that takes about 7.5 seconds of extra CPU about every 45 seconds, which is five widths in a row about every 32 widths of a sweep.

- Held still at 795, 809, 825, and 840 points, the app settled to 0 to 1 percent after about 10 seconds, and a 3-second `sample` at each had no `NSToolbarView layout` frames.
- The raised widths moved with the sweep's start: a sweep from 800 raised 840 to 845 and left 807 to 811 normal, and a sweep from 1000, where every toolbar item fits, raised 1030 to 1035 and 1060 to 1064.
- With `-GeneratesWhileCharging NO`, no width read above 106 percent on Desk from 790 to 1000 points, with **All Time** or **Last 12 Months**, with or without the **Test copy** label, and Share and Spines read at most 17 percent from 780 to 860.

The sweep procedure now passes `-GeneratesWhileCharging NO`.

## What is a loop

Library still loops in a test copy at 798 to 801 points, the known issue in the procedure: held at 799 points, the app stayed at 100 percent, with about half of the main thread's samples under `-[NSToolbarView layout]`. It needs the **Test copy** label: without the label, every Library and Desk item fits at the window's 780-point minimum.

- A fixed size on the time menu and **View options** did not stop it.
- Pinning the search field's width through AppKit, in a scratch probe, did: no loop from 780 to 830 points. So the search field from `.searchable(placement: .toolbar)` is the item AppKit squeezes. That is inferred from the pin, not shown item by item.
- SwiftUI offers no Mac setting that stops the squeeze: `.searchToolbarBehavior(.minimize)` is unavailable on macOS.

Not fixed: the loop needs the label, which only development copies show. Options are to keep the known issue, or to draw the label without taking toolbar width, which changes how test copies look.

## Not checked

- The dominoes' toolbar, and the month and year time frames.
- Library with a time title other than **Last 12 Months**.
- A Release build's CPU, and whether the installed app also compiles Vision's text model again for every cover, as the scratch copy does. The scratch copy has a scratch home folder and ad hoc signing, which may be why.
