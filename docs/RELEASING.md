# Releasing Bookworms for iPhone

This checklist covers what a TestFlight or App Store build needs beyond a passing local build. Nothing here has been completed for a release yet.

## Before the first TestFlight build

1. **Private Cloud Compute capability.** The Account Holder requests the managed `com.apple.developer.private-cloud-compute` entitlement from **Get the entitlement** on Apple's Private Cloud Compute developer page. Apple grants it to App Store Small Business Program members with fewer than 2 million first-time downloads. Signing a device build with it fails until the provisioning profile includes it. `script/install_on_device.sh` builds a test-only variant without it (`NO_PCC`); never archive that variant for TestFlight.
2. **CloudKit production schema.** In CloudKit Console, deploy the `SpineWorklistV1`, `SpineDesignV1`, and `CoverChoiceV1` record types, each with a `payload` field of type Bytes, from Development to Production. Without `SpineDesignV1`, every design save fails in Production, and the app stops a run after the first rejected save; without `CoverChoiceV1`, choosing a cover fails with an error.
3. **Apple TV build.** Ship an Apple TV build that publishes `SpineWorklistV1` and reads `SpineDesignV1` (the tvOS `spine-companion` work) so designs reach the TV. Until then an iPhone without a Hardcover sign-in designs the newest Hardcover snapshot in `library-v1`, and the TV ignores the designs.
4. **Cover choices on other devices.** Make the Apple TV app and the Mac companion read `CoverChoiceV1` (see the README's [iCloud contract](../README.md#icloud-contract)), or tell testers that a chosen cover appears only on iPhones.
5. **One companion per account.** Make the Mac companion read `CoverChoiceV1` and this app accept current Mac designs, or retire the Mac companion. Until then, every book with a chosen cover makes the two companions overwrite each other's designs indefinitely, because the Mac hashes the default cover.
6. **Privacy manifest.** Confirm `PrivacyInfo.xcprivacy` is at the root of the archived `Bookworms.app` and that the archive's privacy report (Organizer, **Generate Privacy Report**) shows only the declared UserDefaults (CA92.1) and file timestamp (C617.1) reasons. The Keychain needs no declared reason.
7. **App Privacy answers.** In App Store Connect, answer the App Privacy questions for the Hardcover sign-in: the app sends the reader's Hardcover token only to Hardcover to read their own library, and keeps the library and reviews on the iPhone.

## App Review

Without a Hardcover sign-in, every tab depends on the library that the Apple TV app uploads to the reviewer's iCloud account. A reviewer can instead sign in to Hardcover on the iPhone from the **Spines** tab's account button. Provide review notes with:

- that the iPhone app reads either the reader's Hardcover library or the Apple TV app's iCloud library;
- the Hardcover demo account listed in the tvOS release workflow, and the sign-in steps: **Connect Hardcover**, **Open Hardcover**, sign in on Hardcover's page, enter the code, and allow Bookworms;
- optional Apple TV setup: install the Apple TV app, connect the same demo account, turn on **iCloud storage** in the Apple TV app's settings, and use the same iCloud account on both devices;
- a demo video of all three tabs with that library;
- how spine generation uses Private Cloud Compute and its per-user daily limit, and that background generation runs only while charging.

## Signed device checks

Check these on a signed iPhone with the Apple TV on the same iCloud account: the library loads; **Generate now** saves designs and continues after leaving the app; the charging task runs overnight; a worklist push schedules it; the Spines tab shows the daily limit; and the Apple TV caches the new designs.

Check the Hardcover sign-in on a signed iPhone without an Apple TV library, following [Test Hardcover sign-in](../README.md#test-hardcover-sign-in): the code flow completes, the library and its designs load, generation designs the phone's library, **Reconnect** appears after the login is revoked, and **Sign out** removes the library.

Check **Change cover** on a signed iPhone that is signed in to Hardcover: the picker lists real edition covers; a choice shows in details, share images, and the Pile after it is released; the `CoverChoiceV1` record appears in CloudKit Console; **Redesign spine** saves a design with the new cover's hash; a second iPhone on the same iCloud account shows the choice after it reloads; and **Use default cover** deletes the record.

Check the Shelf tab's **Pile** on a recent iPhone with the full library, in an optimized build: frame rate and memory during and after the drop, shadows, tilt, throwing, and whether the Reduce Motion stacks stay standing after a book is picked up. Also check **Share pile** for **All books**, a year, and a month in each size: the time to the first image, memory while it renders, that the image is not blank, and that the pile returns as you left it when the sheet closes. The Simulator does not report motion, and its physics and rendering timing differ from a device.
