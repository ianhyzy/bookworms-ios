# Bookworms for iPhone

Bookworms for iPhone is a companion to the [Bookworms Apple TV app](../tvos/README.md). It designs book spines with Apple's Private Cloud Compute model and shares them with the Apple TV through iCloud, shows your spines as a 3D carousel, and makes share images for social media. It never asks for a Hardcover or AI API key.

The app targets iOS 27 and iPhone. It gets your library in one of two ways:

- **From Hardcover.** Sign in to Hardcover on the iPhone, and the app reads your Hardcover library, including your reviews, directly. It then works without an Apple TV. See [Hardcover sign-in](#hardcover-sign-in).
- **From the Apple TV.** Without a sign-in, the app reads the library that the Apple TV app uploads to the private iCloud container `iCloud.gay.ian.Bookworms`, so the Apple TV app needs **iCloud storage** turned on.

Either way, designs are saved to that iCloud container, where the Apple TV picks them up. Until there is a library, the **Shelf** and **Share** tabs explain both ways to get one and offer **Connect Hardcover** (see [No library yet](#no-library-yet)).

## Features

### Spine generation

The **Spines** tab shows how many books have designs, the current run, Private Cloud Compute availability, and the daily request limit.

- **Generate now** starts a run in the app. iOS can keep it going after you leave the app, with system progress UI, through a continued-processing background task.
- **Generate while charging** (on by default) asks iOS for a background processing task that needs external power and a network connection. iOS chooses when to run it, typically overnight while the iPhone charges. Background runs download covers only on unmetered networks and stop when the daily limit is almost reached.
- When the Apple TV publishes a new worklist, a silent push schedules the charging task. Generation never runs inside the push's 30-second window.

Each run designs the books that need it, one at a time:

1. The run picks its account and books. A worklist from the Apple TV that lists books decides, even when the iPhone is signed in to Hardcover. Without one, a signed-in iPhone designs its own Hardcover library, and nothing until it has downloaded that library; it never designs the Apple TV's library, which may belong to another account. Signing out stops a run that designs the iPhone's library. Otherwise the iPhone designs the newest Hardcover snapshot that the Apple TV uploaded, preferring a real account ID over the legacy `hardcover` placeholder; Apple TV builds without the worklist upload only that library. An empty worklist means the Apple TV turned Hardcover off, which stops runs unless the iPhone is signed in.
2. The app downloads the cover over HTTPS (the one you chose, if any; see [Cover choice](#cover-choice)), reads its lettering with Vision, and samples its colors.
3. The first model request asks only which of 12 letterform styles the cover's title uses, with the cover attached and the styles in a different order for each book. If Private Cloud Compute cannot read images, the on-device model answers this question.
4. The second request picks cloth, ink, and accent colors from the sampled palette, a weight, and up to four families from that style's open-source Google Fonts families.
5. The app downloads the first family that has every letter of the title and author, rejects italic, oblique, and slanted faces and Impact, and adjusts the colors until the text reaches APCA Lc 75. If no ranked family works, one more ranking request runs without them.
6. Books in the same series reuse the first saved series design without a request when its font covers the book's letters.
7. The app saves a `SpineDesignV1` record with generator version `ios-pcc-v1`.

A new design usually uses two or three requests. The app rechecks a book when its metadata, its chosen cover, or the generator changes, or after seven days. A book that fails waits 24 hours unless its metadata or chosen cover changes. Quota, network, service, and iCloud save errors stop the run and schedule the next attempt for the reset or retry time.

### Hardcover sign-in

The account button in the **Spines** tab's toolbar opens the Hardcover sheet, and so does **Connect Hardcover** on the **Shelf** and **Share** tabs when there is no library. Signed out, it explains what signing in adds and offers **Connect Hardcover**. Sign-in uses the same OAuth 2.0 Device Authorization Grant, client ID, and read-only scopes as the Apple TV app (see the [Apple TV authentication guide](../tvos/docs/HARDCOVER_AUTHENTICATION.md)):

1. The app requests a code from Hardcover and shows it with **Copy code**.
2. **Open Hardcover** opens Hardcover's approval page in Safari inside the app: the link with the code filled in when Hardcover provides one, otherwise `hardcover.app/link`. Sign in to Hardcover if asked, enter the code, and allow Bookworms.
3. The app polls Hardcover at the interval it asks for, waits 5 seconds longer after each `slow_down`, and stops when the code expires or the request is declined; **Get a new code** starts over.
4. Once approved, the app checks the account with a `me` query, then saves the token.

The signed-in sheet shows the Hardcover username, when the library last synced, **Sync now**, and **Sign out**. When Hardcover rejects the saved login (HTTP 401, or HTTP 403 with `insufficient_scope`), the sheet and the **Spines** tab say so and offer **Reconnect**, and the toolbar button shows a warning badge; the copy of the library stays until then. Other 403 responses are reported as denied requests, not as an expired login. The **Spines** tab also shows other download and load errors, even while it shows an older copy of the library.

While signed in:

- The Shelf and Share tabs show the Hardcover account's own library: every book on its shelves, with the same covers, page counts, finish and start dates, ratings, community ratings, formats, genres, series, and progress as the Apple TV builds. Each book also carries your review as plain text (`CloudBook.review`, from Hardcover's `user_books.review` with HTML and Markdown removed). Designs for these books still come from iCloud, matched by the same account ID the Apple TV uses (the Hardcover user ID).
- The app downloads the library when it launches or becomes active if the copy on the iPhone is missing or more than four hours old, and when you choose **Sync now**. Any reload the app or the Shelf starts also checks this.
- The Apple TV's library never stands in for the signed-in account, which may differ. Until the first download finishes, the app shows no library, or an earlier copy only when it belongs to the same account, and a generation run reports "Waiting for your Hardcover library to download". If the download fails, or iOS deleted the copy and the iPhone is offline, the library stays empty and the **Shelf**, **Share**, and **Spines** tabs show the error (see [No library yet](#no-library-yet)).

**Sign out** deletes the token and the copy of the library from the iPhone and returns to the Apple TV's library. Preview mode (`-BookwormsPreviewFolder`) ignores the sign-in.

#### Data on the iPhone

- The access token is a Keychain item that is readable after the first unlock, never synchronizable, and limited to this device. The app sends it only to Hardcover.
- The library, including reviews, is a file in `Caches/Bookworms`, which iOS does not back up and may delete; the app then downloads it again. The username, account ID, and last sync date are in the app's user defaults. They mark the sign-in, so the sheet and the library source never depend on the cached file.
- A reinstalled app, or a backup restored to another iPhone, starts signed out. The Keychain keeps the login after the app is deleted, and a backup carries the user defaults but not the device-only login, so at launch the app deletes either half without the other.
- The app only reads from Hardcover. It sends no mutations.

### No library yet

Without a library, the **Shelf** and **Share** tabs say why, from the Hardcover sign-in and the last load (`LibraryStatus`):

- **Signed out:** **No library yet** explains both ways to get one: turn on **iCloud storage** in the Bookworms app on the Apple TV, or connect Hardcover on this iPhone. Below them, it shows any error from loading the Apple TV's library, such as a missing iCloud account, after **Apple TV library:**. It offers **Connect Hardcover**, which opens the Hardcover sheet, and **Try again**, which reloads.
- **Signed in, downloading:** a progress indicator says the Hardcover library is downloading.
- **Signed in, download failed:** the error, such as Hardcover being unavailable, with **Try again**.
- **Signed in, login rejected:** **Reconnect Hardcover** with the error and **Reconnect**, which starts a new sign-in in the Hardcover sheet.

The sheet stays open when the library arrives. Preview mode ignores the sign-in, so it offers only **Try again**. A library without books says that books appear after the Apple TV's next sync, or after the next sync with Hardcover when signed in.

### Shelf

The **Shelf** tab shows every book as a spine in its saved design, or in a plain cloth fallback before it has one.

- **Stack** (default) lays the spines flat and scrolls them vertically as a 3D wheel.
- **Shelf** stands the spines upright, as on the Apple TV, and scrolls them horizontally like Cover Flow.
- **Pile** drops every book, or a year's or month's books, onto a wooden table as a physics toy, and shares the pile as an image. See [Pile](#pile).
- The caption shows the centered book's title, author, finish date, and your rating. Sort by finish date, title, author, or rating, or show designed books only.
- Tap the centered spine for details: a 3D book you can turn with a drag, its reading details, the design's font and colors, **Change cover**, and **Share**.

### Cover choice

**Change cover** on a book's details opens the covers of the book's Hardcover editions, most-read edition first, with the current cover marked. Each cover shows its edition's format and year, and VoiceOver reads it as, for example, "Cover from 2019 Paperback edition". Choosing a cover saves it; **Use default cover** returns to the cover Bookworms picks from your library.

- The picker lists up to 60 editions with images and leaves out repeated images, non-HTTPS links, images under 300 pixels on the shorter side, and nearly square art such as audiobook covers. A cover that does not load cannot be chosen.
- Finding covers needs this iPhone's Hardcover sign-in, which reads the editions with the same read-only scopes as the library. Signed out, the sheet explains this and offers **Connect Hardcover**. If Hardcover rejects the login, for example after it expired or was revoked, the sheet offers **Reconnect Hardcover**. **Use default cover** works in these states and when Hardcover cannot be reached.
- The choice is saved to iCloud as a `CoverChoiceV1` record for the shown account (see [iCloud contract](#icloud-contract)), so another iPhone on the same iCloud account shows it after its next reload. Choosing the default cover deletes the record. If iCloud rejects the change, or the shown library no longer includes the book, for example after signing in to another account, the sheet says so and nothing changes.
- The chosen cover replaces the default everywhere the iPhone shows the book: details, share images, the Pile, and spine generation. If the chosen image stops loading, the default cover shows instead. The Pile reuses a book's textures until its spine design changes or the pile is released, for example when you switch tabs or presentations, so a new cover appears there only after that.
- The spine keeps its current design until the next run, which rechecks the book because its chosen cover changed. After a change, the details offer **Redesign spine**, which starts **Generate now**. If a run ends without a new design, the details show why, or that the run left the spine unchanged. A book in a series reuses the series design when one exists, so only its saved cover hash changes.

### Pile

**Pile** shows the books in the shelf's sort and filter order as RealityKit rigid bodies that fall onto a table in waves of 16 and pile up.

- In Pile mode, **Sort and filter** adds **Time frame**: **All books** (the default), a **Year**, or a **Month**. The year and month lists include only periods with finished books. Choosing one drops that period's finished books in a new pile, as **Drop again** does. The app saves the choice. If the saved year or month has no finished books in the current library, the pile uses the newest year or month instead. Under the presentation picker, the pile names its time frame and book count, such as "2025 · 39 books"; for **All books**, it names the years the books span. When **Designed only** leaves a year or month empty, the shelf says so and offers to show that period's books or all books.

- Each book is a box the size of a real book: 21 to 24 cm tall, as wide as its cover's aspect ratio allows (2:3 without a cover), and as thick as its page count suggests. The front shows the cover, cropped to the book's shape as on its details screen, the spine shows the saved design rendered by `SpineView`, the page edges are cream, and the back is the spine's cloth color.
- Drag a book to pick it up and throw it, tap one for its details, pinch to zoom toward a point, and turn two fingers to look around the pile. **Drop again** starts a new drop and redraws books whose design or font changed since the last one.
- On an iPhone that reports motion, tilting the phone tips the table. The pile responds to the change from how you held the phone when tilting began, up to about 27 degrees, and books slide toward the edge of the screen you tip down, however you have turned the view. Turn **Tilt to move books** off in the toolbar to keep the table level.
- With **Reduce Motion** on, the books appear in tidy stacks, spines toward you, and tilt is off. The stacks hold still: picking up a book frees only that book and the books resting on it. **Stack again** replaces **Drop again**.
- Invisible walls keep the books between the navigation bar and the tab bar. The view keeps its pile while you open a book and come back. Switching to another tab, **Stack**, or **Shelf** releases the books and their textures, and the books drop again when you return.
- Each wave waits at most 1.5 seconds for its own covers, and the next wave's covers download while it falls. A book whose cover arrives later falls with its title on its cloth color, and the cover replaces the title when it arrives. Textures stay small: covers are at most 224 pixels and spines 384 pixels long, an estimated 75 MB of GPU memory for 300 books and at most 116 MB.

VoiceOver reads the pile as one element with its book count, its time frame, and a **Drop again** action; choose **Stack** or **Shelf** to go through books one at a time. RealityKit shadows, frame rate, and the stability of tall stacks have been checked only in the Simulator; check them on a device.

#### Share the pile

**Share** in the Pile toolbar opens **Share pile**. It drops the pile's books into a new pile and renders a 1080-pixel-wide PNG in Story, Portrait, or Square format. **Shuffle** drops them again from new starting poses. A new library, such as one the Apple TV uploads while the sheet is open, draws a new image. The share button waits for the current image.

- The heading names the time frame, such as "2025" or "November 2025", in New York. For **All books**, it shows the years the books were finished, such as "2014–2026". Below it is the book count, and the bottom margin holds the same credit as the Share tab's images.
- Up to 150 books drop, last book first, so the first books in the shelf's order land on top. Fewer books are framed closer, with sharper textures. Books start over the middle of the table, just above the pile so far, tilted only a little and without spin, so few land face down. Invisible walls keep the pile together while it settles and are removed for the last half second, so no book stays propped against one. The camera then fits every book between the heading and the bottom margin.
- While the sheet is open, the live pile leaves the screen and keeps its books. Closing the sheet shows the pile as you left it.
- `ImageRenderer` cannot capture a `RealityView`, so `PileSnapshotRenderer` builds a `BookPileScene` that no view shows. It runs the physics with RealityKit's `RealityRenderer` for a fixed number of 60 Hz steps, renders one frame into a Metal texture, and copies the frame to memory. If that frame is one flat color, the sheet reports that the pile could not be drawn instead of sharing it. The renderer and its textures are released after each image.
- Covers get up to 10 seconds to load. The simulation runs on the main actor between short pauses while the sheet shows progress. `PileSnapshotRenderer.render(books:title:aspect:seed:model:)` is the entry point; the Share tab's [Pile template](#share) uses it too.
- One pile image renders at a time, and a render waits for one that is still finishing after its task was cancelled. `RealityRenderer` steps the same RealityKit engine that draws the live pile, and RealityKit's render thread can crash drawing the pile's meshes meanwhile. While any pile image renders, from the sheet or the Share tab, the live pile's table and books therefore leave its scene, and the simulation starts 100 milliseconds later, so the view can react first. The pile's `RealityView` puts them back when the render ends. RealityKit keeps updating a `RealityView` in a tab that is not selected, so this matters when the Shelf tab was left in **Pile**. The view itself stays: one removed while its tab is hidden lingers until the tab shows again and then takes its scene along.

Offscreen rendering, physics stepping, and the image itself have been checked only in the Simulator. Check them on a device.

### Share

The **Share** tab renders a 1080-pixel-wide PNG in Story (9:16), Portrait (4:5), or Square format and shares it through the share sheet, which can also save it to Photos. Choose a template from the grid, then set its options:

- **Time frame**: **Year** (the newest year by default), **Month**, or **Lifetime**, with a menu of the years or months that have finished books. Templates about several books draw the books finished in the frame, and headings follow it, such as "2025 in books", "My top 5 of August 2025", or "My lifetime in books". Just Finished and Review list the frame's books in their book picker; Review's **Lifetime** also lists reviewed books without a finish date. Currently Reading has no time frame.
- **Book**: the featured book of Just Finished, Review, and Currently Reading. It defaults to the newest choice.
- **Cover**: **3D** (default), a lit 3D book with its spine, or **Flat**, the whole cover with rounded corners and a soft shadow. Every template that shows covers has it, except Year in Books on Square, which shows no records, and Pile, whose books are always 3D.
- **Options**: **Loved more** or **Loved less** for Hot Takes, **Show ratings**, and **Shuffle**, which varies the spine stacks, the Top Five fan, a pile's drop, and the angle of 3D books. Templates that the seed cannot change hide it.

| Template | Shows |
| --- | --- |
| Year Stack | The frame's finished books as a stack of spines, with the book and page counts. |
| Year in Books | The frame's totals (books, pages, average rating, and the busiest month, week, or year), a chart of its books as stacks of spines (by month for a year, by week for a month, and by year for a lifetime, leaving out empty years when the books span more than 50), top genres, most-read author, and formats. The longest, shortest, and favorite books appear on Story, and on Portrait when they fit. Totals, highlights, and records without data are left out. |
| Top Five | The frame's five highest-rated books, fanned, with a ranked list. |
| Hot Takes | Up to three of the frame's books whose rating is furthest from Hardcover's average, with your stars, the readers' stars, and the difference. **Loved more** shows books you rated at least half a star above the average, and **Loved less** at least half a star below. Only books with 50 or more Hardcover ratings count. |
| Spine Spectrum | Every book finished in the frame as a stripe of its spine color, in reading order. A lifetime marks where each year starts. It shows no titles. |
| Pile | The frame's finished books dropped onto the wooden table, newest on top, under the frame's name and book count, drawn as in [Share the pile](#share-the-pile). Up to 150 books drop. The preview shows **Dropping books** while the pile settles, which takes a few seconds. |
| Just Finished | One book with your rating and its format, finish date, and length. |
| Review | Your review of one book under its cover, title, and rating. A long review shows as an excerpt that ends with an ellipsis, and the text takes the largest size that fits. Only books with a review are offered. The Apple TV library carries no reviews, so without the iPhone's own Hardcover sign-in the template says so and offers **Connect Hardcover**. |
| Currently Reading | A book you are reading, with its progress and its start date when known. A reread shows its new start date, not its last finish. |

Text on every image is set in New York for headings and San Francisco for other text, in each book's own capitalization. Spines keep their designed fonts and colors: Year Stack's spines, the spine of a 3D book, and Spine Spectrum's stripes. A 3D book without a downloaded cover shows its title on the front in the spine's font.

Images show only your own library. They include no account name or ID. Ratings are optional. A small "Created with Bookworms for iPhone" credit sits in the bottom margin of every image. If an image cannot be drawn, such as a pile whose frame comes out one flat color, the preview says so, suggesting **Shuffle** for a pile, and nothing is shared.

A new option draws a new image and cancels the one in progress. A new design for a book in the image, such as one a generation run saves every few seconds, draws after the image in progress instead, and the shown image stays shareable meanwhile. Designs for other books change nothing.

## How the 3D books work

`Book3DView` draws each visible face of a book (cover, spine, page edges) as an ordinary SwiftUI view and maps it onto the screen with the perspective transform a pinhole camera gives that face. The faces share one camera, so their edges meet, and the result stays pure SwiftUI. `ImageRenderer` can therefore export it in share images, which it cannot do for RealityKit views. Pile share images, from **Share pile** or the Share tab's Pile template, are the exception: they render RealityKit offscreen (see [Share the pile](#share-the-pile)).

## Run locally

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate --spec project.yml` to create `Bookworms.xcodeproj`. Source folders are synced, so new files need no regeneration.
2. Set up signing for `gay.ian.Bookworms.iOS` with the `iCloud.gay.ian.Bookworms` container, push notifications, and the managed Private Cloud Compute capability (`com.apple.developer.private-cloud-compute`). Request that capability for the team before signing a device build; Apple grants it to members of the App Store Small Business Program.
3. Run `script/build_and_run.sh` to build, install, and launch on a Simulator.

To test on an iPhone before Apple grants the Private Cloud Compute capability, run `script/install_on_device.sh`. It signs an optimized build with `config/NoPCC.entitlements`, compiles it with `NO_PCC` so the app never creates the model, registers the iPhone with the team if needed, and installs it. Generation then reports Private Cloud Compute as unavailable; the Shelf, Pile, and Share tabs work with the iCloud or Hardcover library. A development-signed build reads the CloudKit Development environment, the same one development builds of the Apple TV app and the Mac companion use.

The app shows the library it loaded last while it reloads. It reloads when it becomes active (at most every five minutes) and after a generation run that saved designs for books it had not loaded. Without a Hardcover sign-in, signing out of iCloud, or switching to an account without a library, clears the shown and cached library. Signing out of Hardcover, or signing in to another Hardcover account, also clears it before the reload.

### Preview with a local library

The Simulator usually has no iCloud library. `script/load-preview-data.py` converts a private Apple TV library export and its fonts from the workspace `.local` folder into the iCloud JSON shapes and copies them into the installed app. Then run `script/build_and_run.sh --preview`, which launches with `-BookwormsPreviewFolder preview`. Generation then reads and writes that folder instead of iCloud, and Private Cloud Compute requests are real and count against the signed-in Apple Account's daily limit.

The preview data contains real reading history. It stays in ignored `.local/` folders and the Simulator; do not publish screenshots made from it.

Preview mode keeps cover choices in `cover-choices-v1.json` in the preview folder. Loading the preview data again keeps that file; deleting it restores the default covers.

Debug builds accept more launch arguments for checks that cannot tap the Simulator, such as `-BookwormsGenerateOnLaunch YES`, `-BookwormsShelfMode <stack|shelf|pile>`, `-BookwormsOpenBook <book ID>`, and `-BookwormsShareTemplate <yearStack|yearInBooks|topFive|hotTakes|spectrum|pile|justFinished|review|currentlyReading>` with `-BookwormsShareFrame <year:2025|month:2025-08|lifetime>` and `-BookwormsShareCover <threeD|flat>`. The preview library has no reviews or current reads; `-BookwormsShareSamples <n>` adds fictional ones to Debug builds. For the pile, `-BookwormsPileZoom <1...2.5>` and `-BookwormsPileYaw <radians>` set the camera, and once a drop finishes, `-BookwormsPileTilt <x,y>` applies a tilt and `-BookwormsPileThrow YES` throws the top book. `-BookwormsPileFrame <year:2025|month:2025-8>` sets the time frame. `-BookwormsPileShare YES` opens **Share pile** and writes each image to `Library/Caches/Bookworms/pile-share-debug.png`, and `-BookwormsPileShareAspect <story|portrait|square>` picks its size. With `-BookwormsShowSpines YES`, `-BookwormsShowAccount YES` opens the Hardcover sheet, and `-BookwormsStubSignIn YES` answers sign-in with the fictional code `WORM-2611` that is never approved, without contacting Hardcover. `-BookwormsLibraryStatus <signedOut|downloading|failed|reconnect>` makes the empty Shelf and Share tabs show that state with a fictional error, and `-BookwormsShareTabs "shelf:0 share:8"` selects each tab once its seconds pass after the previous entry. With `-BookwormsOpenBook <book ID>`, `-BookwormsCoverPicker YES` opens **Change cover**; `-BookwormsStubCovers YES` answers it with six fictional covers drawn on the device, without Hardcover or an image host, and `-BookwormsChooseCover <index>` chooses one of them; `-BookwormsStubCovers expired` answers as Hardcover does for a revoked login. Search the source for `"Bookworms` to find them all.

### Check a pile image beside the live pile

A script cannot tap tabs, so `-BookwormsShareTabs` switches them. To check that the Share tab's Pile template renders while the Shelf tab holds a pile, including when the reader leaves mid-render:

1. Load the preview library, then launch with `-BookwormsPreviewFolder preview -BookwormsShelfMode pile -BookwormsShareTemplate pile -BookwormsShareFrame year:2025 -BookwormsShareTabs "shelf:0 share:8 shelf:0.8 share:4 shelf:6"`.
2. The Shelf drops its pile, the Share tab starts a pile image, the Shelf returns 0.8 seconds into the render, and the Share tab renders again. Check that the app does not crash, that `Library/Caches/Bookworms/share-debug.png` holds the finished image, and that the Shelf drops its pile again at the end.

### Check the empty states

1. On a Simulator without an iCloud account, launch without `-BookwormsPreviewFolder`. The Shelf shows **No library yet** with the iCloud error, **Connect Hardcover**, and **Try again**; add `-BookwormsShareTemplate yearStack` to check the Share tab.
2. Launch with `-BookwormsLibraryStatus downloading`, `failed`, or `reconnect` to check the signed-in states.

### Test Hardcover sign-in

A real sign-in needs a person to approve it in a browser, so the unit tests use canned responses. To check it on a Simulator or iPhone:

1. Launch without `-BookwormsPreviewFolder` or `-BookwormsStubSignIn`, open **Spines**, and tap the account button.
2. Tap **Connect Hardcover**, then **Open Hardcover**. Sign in to Hardcover in the sheet, check that the code is filled in or paste it with **Copy code**, and allow Bookworms.
3. Tap **Done** to close Safari. Within a few seconds the sheet shows your username and a sync in progress, and the Shelf tab then shows your Hardcover library.
4. Tap **Sync now** and check that **Last synced** updates. Tap **Sign out** and check that the Shelf returns to the Apple TV library or its empty state.

To check **Reconnect**, revoke Bookworms in Hardcover's account settings, then tap **Sync now**.

## iCloud contract

The Apple TV app owns the `library-v1` archive and, from builds that include the spine companion work, the `SpineWorklistV1` record. This app writes one `SpineDesignV1` record per book. Record names and JSON fields are defined in `Bookworms/Models/CloudContract.swift`, and the tests pin the same digests as the Apple TV and Mac companion tests. Designs add optional `fontFamily`, `fontPostScriptName`, `instanceWeight`, and `provenance` fields; older readers ignore them.

This app also writes one `CoverChoiceV1` record for each book whose cover the reader changed:

- **Location.** Record type `CoverChoiceV1` in the default zone of the private database of `iCloud.gay.ian.Bookworms`.
- **Record name.** `cover-choice-v1-` followed by the lowercase hexadecimal SHA-256 of `<accountID>:<bookID>`, the same digest as design record names. For account `42` and book `7`, the name is `cover-choice-v1-755dac3729029e2e2976249c4e03b160c699ef71f296c346e22183dc23503c33`.
- **Payload.** A `payload` field of type Bytes holds JSON: `version` (`1`), `accountID` (string), `bookID` (integer), `coverURL` (string, an HTTPS image URL), `editionID` (integer, the Hardcover edition; absent when the cover belongs to no edition), and `chosenAt` (number, `JSONEncoder`'s default date encoding: seconds since 1 January 2001, which can be fractional). For example: `{"accountID":"42","bookID":7,"chosenAt":800000000,"coverURL":"https://covers.example.com/7/2.jpg","editionID":31,"version":1}`.
- **Validation.** Readers ignore a payload unless `version` is 1, `accountID` has 1 to 512 characters, `bookID` is positive, `coverURL` passes `CoverURLPolicy` (HTTPS, no credentials, port, or fragment, and no local or IP-address host), `editionID` is positive when present, and the account and book match the record name.
- **Writes.** Choosing the default cover deletes the record. A save fetches the record, returns early when it already names the same cover and edition, and otherwise saves with `ifServerRecordUnchanged`, retrying up to three times on a conflict, like designs.
- **Use.** The chosen cover goes first among the book's covers for display and generation, followed by the default covers as fallbacks. It never enters `workItemHash`, so designs keep matching the Apple TV's hash; a design's `coverHash` is the SHA-256 of the chosen cover's bytes.

Current limits:

- The Apple TV caches companion designs only on its `spine-companion` branch, and no Apple TV view displays them yet.
- This app regenerates Mac companion designs when it rechecks a book. The Mac companion keeps an iPhone design only when its work-item and cover hashes match the Mac's own, so after one overwrite the two settle on the iPhone's design. A chosen cover breaks that: the Mac hashes the default cover, so for that book the two companions overwrite each other's designs indefinitely and spend model requests each time. Run only one companion per iCloud account until the Mac reads `CoverChoiceV1` and both accept each other's designs.
- The Apple TV app and the Mac companion do not read `CoverChoiceV1` yet, so they show and design from the default covers.
- A development-signed build uses the CloudKit Development environment. It does not see data that App Store or TestFlight Apple TV builds write to Production.
- The [release workflow](docs/RELEASING.md) lists the production schema, capability, and App Review steps that remain before shipping.

## Verification

Run the unit tests on a Simulator:

```sh
xcodebuild -project Bookworms.xcodeproj -scheme Bookworms \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath DerivedData \
  OTHER_SWIFT_FLAGS='-disable-sandbox' test
```

The tests use fictional books, covers, and canned Hardcover responses, and need no iCloud account, network, Hardcover login, or model. The Hardcover Keychain test uses its own service name. Simulator runs check rendering and the generation flow against the preview folder; the Simulator does not run background tasks. Check a signed device build for iCloud access, push delivery, the charging task, continued processing, and Private Cloud Compute quotas, and confirm that the Apple TV caches the designs.

## Credits

Spine fonts are open-source Google Fonts families (SIL Open Font License or Apache License), downloaded at runtime with their license files. The app icon uses the Bookworms Apple TV artwork.

The pile's table (`TableWood`) is [White Oak Veneer](https://polyhaven.com/a/white_oak_veneer) by Jenelle van Heerden from Poly Haven, under [CC0](https://polyhaven.com/license). The bundled file is the 2K diffuse map scaled to 1024 pixels; the app tints it a darker brown.
