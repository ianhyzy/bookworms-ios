# Releasing Bookworms for iPhone

This checklist covers what a TestFlight or App Store build needs beyond a passing local build. Nothing here has been completed for a release yet.

## Before the first TestFlight build

1. **Private Cloud Compute capability.** The Account Holder requests the managed `com.apple.developer.private-cloud-compute` entitlement from **Get the entitlement** on Apple's Private Cloud Compute developer page. Apple grants it to App Store Small Business Program members with fewer than 2 million first-time downloads. Signing a device build with it fails until the provisioning profile includes it. `script/install_on_device.sh` builds a test-only variant without it (`NO_PCC`); never archive that variant for TestFlight.
2. **CloudKit production schema.** In CloudKit Console, deploy the `SpineWorklistV1` and `SpineDesignV1` record types, each with a `payload` field of type Bytes, from Development to Production. Without them, every design save fails in Production; the app stops a run after the first rejected save.
3. **Apple TV build.** Ship an Apple TV build that publishes `SpineWorklistV1` and reads `SpineDesignV1` (the tvOS `spine-companion` work) so designs reach the TV. Until then the iPhone designs the newest Hardcover snapshot in `library-v1`, and the TV ignores the designs.
4. **One companion per account.** Make the Mac companion treat valid `ios-pcc-v1` designs as current, or retire it, so the two companions do not keep regenerating each other's designs.
5. **Privacy manifest.** Confirm `PrivacyInfo.xcprivacy` is at the root of the archived `Bookworms.app` and that the archive's privacy report (Organizer, **Generate Privacy Report**) shows only the declared UserDefaults (CA92.1) and file timestamp (C617.1) reasons.

## App Review

Every tab depends on the library that the Apple TV app uploads to the reviewer's iCloud account, so a reviewer without an Apple TV sees empty states. Before submission, either add a sample library a reviewer can open from the empty state, or provide review notes with:

- that the iPhone app is a companion that reads the Apple TV app's iCloud library;
- setup steps: install the Apple TV app, connect the Hardcover demo account listed in the tvOS release workflow, turn on **iCloud storage** in the Apple TV app's settings, and use the same iCloud account on both devices;
- a demo video of all three tabs with that library;
- how spine generation uses Private Cloud Compute and its per-user daily limit, and that background generation runs only while charging.

## Signed device checks

Check these on a signed iPhone with the Apple TV on the same iCloud account: the library loads; **Generate now** saves designs and continues after leaving the app; the charging task runs overnight; a worklist push schedules it; the Spines tab shows the daily limit; and the Apple TV caches the new designs.

Check the Shelf tab's **Pile** on a recent iPhone with the full library, in an optimized build: frame rate and memory during and after the drop, shadows, tilt, throwing, and whether the Reduce Motion stacks stay standing after a book is picked up. Also check **Share Pile** for **All books**, a year, and a month in each size: the time to the first image, memory while it renders beside the live pile, and that the image is not blank. The Simulator does not report motion, and its physics and rendering timing differ from a device.
