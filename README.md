# Bookworms for iPhone

Bookworms for iPhone is a companion to the [Bookworms Apple TV app](../tvos/README.md). It designs book spines with Apple's Private Cloud Compute model and shares them with the Apple TV through iCloud, shows your spines as a 3D carousel, and makes share images for social media. It never asks for a Hardcover or AI API key.

The app targets iOS 27 and iPhone. It reads the library that the Apple TV app uploads to the private iCloud container `iCloud.gay.ian.Bookworms`, so the Apple TV app needs **iCloud storage** turned on.

## Features

### Spine generation

The **Spines** tab shows how many books have designs, the current run, Private Cloud Compute availability, and the daily request limit.

- **Generate now** starts a run in the app. iOS can keep it going after you leave the app, with system progress UI, through a continued-processing background task.
- **Generate while charging** (on by default) asks iOS for a background processing task that needs external power and a network connection. iOS chooses when to run it, typically overnight while the iPhone charges. Background runs download covers only on unmetered networks and stop when the daily limit is almost reached.
- When the Apple TV publishes a new worklist, a silent push schedules the charging task. Generation never runs inside the push's 30-second window.

Each run designs the books that need it, one at a time:

1. The worklist from the Apple TV lists the active Hardcover account and its books. Apple TV builds without the worklist upload only the library; the iPhone then designs the newest Hardcover snapshot, preferring a real account ID over the legacy `hardcover` placeholder.
2. The app downloads the cover over HTTPS, reads its lettering with Vision, and samples its colors.
3. The first model request asks only which of 12 letterform styles the cover's title uses, with the cover attached and the styles in a different order for each book. If Private Cloud Compute cannot read images, the on-device model answers this question.
4. The second request picks cloth, ink, and accent colors from the sampled palette, a weight, and up to four families from that style's open-source Google Fonts families.
5. The app downloads the first family that has every letter of the title and author, rejects italic, oblique, and slanted faces and Impact, and adjusts the colors until the text reaches APCA Lc 75. If no ranked family works, one more ranking request runs without them.
6. Books in the same series reuse the first saved series design without a request when its font covers the book's letters.
7. The app saves a `SpineDesignV1` record with generator version `ios-pcc-v1`.

A new design usually uses two or three requests. The app rechecks a book when its metadata or the generator changes, or after seven days. A book that fails waits 24 hours. Quota, network, service, and iCloud save errors stop the run and schedule the next attempt for the reset or retry time.

### Shelf

The **Shelf** tab shows every book as a spine in its saved design, or in a plain cloth fallback before it has one.

- **Stack** (default) lays the spines flat and scrolls them vertically as a 3D wheel.
- **Shelf** stands the spines upright, as on the Apple TV, and scrolls them horizontally like Cover Flow.
- **Pile** drops every book, or a year's or month's books, onto a wooden table as a physics toy, and shares the pile as an image. See [Pile](#pile).
- The caption shows the centered book's title, author, finish date, and your rating. Sort by finish date, title, author, or rating, or show designed books only.
- Tap the centered spine for details: a 3D book you can turn with a drag, its reading details, the design's font and colors, and **Share**.

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
- While the sheet is open, the live pile leaves the screen and keeps its books. RealityKit can crash when a `RealityView` and the offscreen renderer draw at the same time. Closing the sheet shows the pile as you left it.
- `ImageRenderer` cannot capture a `RealityView`, so `PileSnapshotRenderer` builds a `BookPileScene` that no view shows. It runs the physics with RealityKit's `RealityRenderer` for a fixed number of 60 Hz steps, renders one frame into a Metal texture, and copies the frame to memory. If that frame is one flat color, the sheet reports that the pile could not be drawn instead of sharing it. The renderer and its textures are released after each image.
- Covers get up to 10 seconds to load. The simulation runs on the main actor between short pauses while the sheet shows progress. `PileSnapshotRenderer.render(books:title:aspect:seed:model:)` is the entry point other features can use.

Offscreen rendering, physics stepping, and the image itself have been checked only in the Simulator. Check them on a device.

### Share

The **Share** tab renders a 1080-pixel-wide PNG in Story (9:16), Portrait (4:5), or Square format and shares it through the share sheet, which can also save it to Photos.

| Template | Shows |
| --- | --- |
| Year Stack | A year's finished books as a stack of spines, with the book and page counts. |
| Just Finished | One book as a 3D object with its title in the spine's font, your rating, and its format, finish date, and pages. |
| Top Five | A year's five highest-rated books, fanned as 3D books, with a ranked list. |
| Spine Spectrum | Every finished book in a year, or all time, as a stripe of its spine color in reading order. It shows no titles. |
| Year in Books | A year's totals (books, pages, average rating, and busiest month), each month's books as a stack of spines, and its top genres, most-read author, and formats. Story also shows the longest, shortest, and favorite books as 3D books. Totals and highlights without data are left out. |

Images show only your own library. They include no account name or ID. Ratings are optional. A small "Created with Bookworms for iPhone" credit sits in the bottom margin of every image.

## How the 3D books work

`Book3DView` draws each visible face of a book (cover, spine, page edges) as an ordinary SwiftUI view and maps it onto the screen with the perspective transform a pinhole camera gives that face. The faces share one camera, so their edges meet, and the result stays pure SwiftUI. `ImageRenderer` can therefore export it in share images, which it cannot do for RealityKit views. Pile share images are the exception: they render RealityKit offscreen (see [Share the pile](#share-the-pile)).

## Run locally

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate --spec project.yml` to create `Bookworms.xcodeproj`. Source folders are synced, so new files need no regeneration.
2. Set up signing for `gay.ian.Bookworms.iOS` with the `iCloud.gay.ian.Bookworms` container, push notifications, and the managed Private Cloud Compute capability (`com.apple.developer.private-cloud-compute`). Request that capability for the team before signing a device build; Apple grants it to members of the App Store Small Business Program.
3. Run `script/build_and_run.sh` to build, install, and launch on a Simulator.

To test on an iPhone before Apple grants the Private Cloud Compute capability, run `script/install_on_device.sh`. It signs an optimized build with `config/NoPCC.entitlements`, compiles it with `NO_PCC` so the app never creates the model, registers the iPhone with the team if needed, and installs it. Generation then reports Private Cloud Compute as unavailable; the Shelf, Pile, and Share tabs work with the iCloud library. A development-signed build reads the CloudKit Development environment, the same one development builds of the Apple TV app and the Mac companion use.

The app shows the library it loaded last while it reloads. It reloads when it becomes active (at most every five minutes) and after a generation run that saved designs for books it had not loaded. Signing out of iCloud, or switching to an account without a library, clears the shown and cached library.

### Preview with a local library

The Simulator usually has no iCloud library. `script/load-preview-data.py` converts a private Apple TV library export and its fonts from the workspace `.local` folder into the iCloud JSON shapes and copies them into the installed app. Then run `script/build_and_run.sh --preview`, which launches with `-BookwormsPreviewFolder preview`. Generation then reads and writes that folder instead of iCloud, and Private Cloud Compute requests are real and count against the signed-in Apple Account's daily limit.

The preview data contains real reading history. It stays in ignored `.local/` folders and the Simulator; do not publish screenshots made from it.

Debug builds accept more launch arguments for checks that cannot tap the Simulator, such as `-BookwormsGenerateOnLaunch YES`, `-BookwormsShelfMode <stack|shelf|pile>`, `-BookwormsOpenBook <book ID>`, and `-BookwormsShareTemplate <yearStack|justFinished|topFive|spectrum|yearInBooks>`. For the pile, `-BookwormsPileZoom <1...2.5>` and `-BookwormsPileYaw <radians>` set the camera, and once a drop finishes, `-BookwormsPileTilt <x,y>` applies a tilt and `-BookwormsPileThrow YES` throws the top book. `-BookwormsPileFrame <year:2025|month:2025-8>` sets the time frame. `-BookwormsPileShare YES` opens **Share pile** and writes each image to `Library/Caches/Bookworms/pile-share-debug.png`, and `-BookwormsPileShareAspect <story|portrait|square>` picks its size. Search the source for `"Bookworms` to find them all.

## iCloud contract

The Apple TV app owns the `library-v1` archive and, from builds that include the spine companion work, the `SpineWorklistV1` record. This app writes one `SpineDesignV1` record per book. Record names and JSON fields are defined in `Bookworms/Models/CloudContract.swift`, and the tests pin the same digests as the Apple TV and Mac companion tests. Designs add optional `fontFamily`, `fontPostScriptName`, `instanceWeight`, and `provenance` fields; older readers ignore them.

Current limits:

- The Apple TV caches companion designs only on its `spine-companion` branch, and no Apple TV view displays them yet.
- The Mac companion regenerates any design whose generator version is not its own, and this app does the same for Mac designs. Run only one companion per iCloud account until both accept each other's designs.
- A development-signed build uses the CloudKit Development environment. It does not see data that App Store or TestFlight Apple TV builds write to Production.
- The [release workflow](docs/RELEASING.md) lists the production schema, capability, and App Review steps that remain before shipping.

## Verification

Run the unit tests on a Simulator:

```sh
xcodebuild -project Bookworms.xcodeproj -scheme Bookworms \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath DerivedData \
  OTHER_SWIFT_FLAGS='-disable-sandbox' test
```

The tests use fictional books and need no iCloud account, network, or model. Simulator runs check rendering and the generation flow against the preview folder; the Simulator does not run background tasks. Check a signed device build for iCloud access, push delivery, the charging task, continued processing, and Private Cloud Compute quotas, and confirm that the Apple TV caches the designs.

## Credits

Spine fonts are open-source Google Fonts families (SIL Open Font License or Apache License), downloaded at runtime with their license files. The app icon uses the Bookworms Apple TV artwork.

The pile's table (`TableWood`) is [White Oak Veneer](https://polyhaven.com/a/white_oak_veneer) by Jenelle van Heerden from Poly Haven, under [CC0](https://polyhaven.com/license). The bundled file is the 2K diffuse map scaled to 1024 pixels; the app tints it a darker brown.
