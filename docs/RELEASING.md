# Releasing Bookworms for iPhone

This checklist covers what a TestFlight or App Store build needs beyond a passing local build. Nothing here has been completed for a release yet.

## Before the first TestFlight build

1. **Private Cloud Compute capability.** The Account Holder requests the managed `com.apple.developer.private-cloud-compute` entitlement from **Get the entitlement** on Apple's Private Cloud Compute developer page. Apple grants it to App Store Small Business Program members with fewer than 2 million first-time downloads. Signing a device build with it fails until the provisioning profile includes it. `script/install_on_device.sh` builds a test-only variant without it (`NO_PCC`); never archive that variant for TestFlight.
2. **CloudKit production schema.** In CloudKit Console, deploy the `SpineWorklistV1`, `SpineDesignV1`, and `CoverChoiceV1` record types, each with a `payload` field of type Bytes, from Development to Production. Without `SpineDesignV1`, every design save fails in Production, and the app stops a run after the first rejected save; without `CoverChoiceV1`, choosing a cover fails with an error.
3. **Apple TV build.** Merge and ship the tvOS `spine-companion` work, which publishes `SpineWorklistV1`, draws `SpineDesignV1` designs on Book Wall, and shows covers chosen in `CoverChoiceV1` (see the README's [iCloud contract](../README.md#icloud-contract)). Until then an iPhone without a Hardcover sign-in designs the newest Hardcover snapshot in `library-v1`, and the TV ignores the designs and cover choices.
4. **Mac companion build.** Push and ship a Mac companion build that includes macos commit `f2eed75`, which reads `CoverChoiceV1` and keeps current iPhone designs. Older Mac builds replace iPhone designs whenever they recheck a book, so the two companions keep overwriting each other's designs and spend model requests.
5. **Privacy manifest.** Confirm `PrivacyInfo.xcprivacy` is at the root of the archived `Bookworms.app` and that the archive's privacy report (Organizer, **Generate Privacy Report**) shows only the declared UserDefaults (CA92.1) and file timestamp (C617.1) reasons. The Keychain needs no declared reason.
6. **App Privacy answers.** In App Store Connect, answer the App Privacy questions for the Hardcover sign-in: the app sends the reader's Hardcover token only to Hardcover to read their own library, and keeps the library and reviews on the iPhone.

## App Review

Without a Hardcover sign-in, every tab depends on the library that the Apple TV app uploads to the reviewer's iCloud account. A reviewer can instead sign in to Hardcover on the iPhone: with no library, the **Shelf** and **Share** tabs explain both options and offer **Connect Hardcover**, and the **Spines** tab's account button opens the same sheet. Provide review notes with:

- that the iPhone app reads either the reader's Hardcover library or the Apple TV app's iCloud library;
- the Hardcover demo account listed in the tvOS release workflow, and the sign-in steps: **Connect Hardcover**, **Open Hardcover**, sign in on Hardcover's page, enter the code, and allow Bookworms;
- optional Apple TV setup: install the Apple TV app, connect the same demo account, turn on **iCloud storage** in the Apple TV app's settings, and use the same iCloud account on both devices;
- a demo video of all three tabs with that library;
- how spine generation uses Private Cloud Compute and its per-user daily limit, and that background generation runs only while charging.

## Signed device checks

Check these on a signed iPhone with the Apple TV on the same iCloud account: the library loads; **Generate now** saves designs and continues after leaving the app; the charging task runs overnight; a worklist push schedules it; the Spines tab shows the daily limit; and the Apple TV caches the new designs.

Check the Hardcover sign-in on a signed iPhone without an Apple TV library, following [Test Hardcover sign-in](../README.md#test-hardcover-sign-in): the code flow completes, the library and its designs load, generation designs the phone's library, **Reconnect** appears after the login is revoked, and **Sign out** removes the library.

Check **Change cover** on a signed iPhone that is signed in to Hardcover: the picker lists real edition covers; a choice shows in details, share images, and the Pile after it is released; the `CoverChoiceV1` record appears in CloudKit Console; **Redesign spine** saves a design with the new cover's hash; a second iPhone on the same iCloud account shows the choice after it reloads; and **Use default cover** deletes the record.

Check the Shelf tab's **Pile** on a recent iPhone with the full library, in an optimized build: frame rate and memory during and after the drop, shadows, tilt, throwing, and whether the Reduce Motion stacks stay standing after a book is picked up. Also check **Share pile** for **All books**, a year, and a month in each size: the time to the first image, memory while it renders, that the image is not blank, and that the pile returns as you left it when the sheet closes. Check the Share tab's **Pile** template the same way for a lifetime, a year, and a month, with the Shelf tab left in **Pile**: switch to the Shelf while an image renders and back, change options mid-render, and confirm the app does not crash and the Shelf's pile drops again. The Simulator does not report motion, and its physics and rendering timing differ from a device.

Check the Share tab's **Year Stack** for **Lifetime** in each size on a signed iPhone that is signed in to Hardcover, after a sync that downloads series names: series show as one spine with their count, the preview swipes through every page, **Share** to Instagram offers the pages as one carousel post or a run of stories in order, the share sheet's **Save 3 Images** (for three pages) puts every page in Photos in order, and the app stays responsive with reasonable memory while many pages render.

On an iPhone without an Apple TV library or a Hardcover sign-in, check that the **Shelf** and **Share** tabs show **No library yet** with **Connect Hardcover**, that the sheet stays open while the library downloads, and that both tabs show the library once it arrives.
