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
- **Pile** drops every book onto a wooden table as a physics toy. See [Pile](#pile).
- The caption shows the centered book's title, author, finish date, and your rating. Sort by finish date, title, author, or rating, or show designed books only.
- Tap the centered spine for details: a 3D book you can turn with a drag, its reading details, the design's font and colors, and **Share**.

### Pile

**Pile** shows the books in the shelf's sort and filter order as RealityKit rigid bodies that fall onto a table in waves of 16 and pile up.

- Each book is a box the size of a real book: 21 to 24 cm tall, as wide as its cover's aspect ratio allows (2:3 without a cover), and as thick as its page count suggests. The front shows the cover, cropped to the book's shape as on its details screen, the spine shows the saved design rendered by `SpineView`, the page edges are cream, and the back is the spine's cloth color.
- Drag a book to pick it up and throw it, tap one for its details, pinch to zoom toward a point, and turn two fingers to look around the pile. **Drop again** starts a new drop and redraws books whose design or font changed since the last one.
- On an iPhone that reports motion, tilting the phone tips the table. The pile responds to the change from how you held the phone when tilting began, up to about 27 degrees, and books slide toward the edge of the screen you tip down, however you have turned the view. Turn **Tilt to move books** off in the toolbar to keep the table level.
- With **Reduce Motion** on, the books appear in tidy stacks, spines toward you, and tilt is off. The stacks hold still: picking up a book frees only that book and the books resting on it. **Stack again** replaces **Drop again**.
- Invisible walls keep the books between the navigation bar and the tab bar. The view keeps its pile while you open a book and come back. Switching to another tab, **Stack**, or **Shelf** releases the books and their textures, and the books drop again when you return.
- Each wave waits at most 1.5 seconds for its own covers, and the next wave's covers download while it falls. A book whose cover arrives later falls with its title on its cloth color, and the cover replaces the title when it arrives. Textures stay small: covers are at most 224 pixels and spines 384 pixels long, an estimated 75 MB of GPU memory for 300 books and at most 116 MB.

VoiceOver reads the pile as one element with its book count and a **Drop again** action; choose **Stack** or **Shelf** to go through books one at a time. RealityKit shadows, frame rate, and the stability of tall stacks have been checked only in the Simulator; check them on a device.

### Share

The **Share** tab renders a 1080-pixel-wide PNG in Story (9:16), Portrait (4:5), or Square format and shares it through the share sheet, which can also save it to Photos. Choose a template from the grid, then set its options:

- **Time frame**: **Year** (the newest year by default), **Month**, or **Lifetime**, with a menu of the years or months that have finished books. Templates about several books draw the books finished in the frame, and headings follow it, such as "2025 in books", "My top 5 of August 2025", or "My lifetime in books". Just Finished and Review list the frame's books in their book picker. Currently Reading has no time frame.
- **Book**: the featured book of Just Finished, Review, and Currently Reading. It defaults to the newest choice.
- **Cover**: **3D** (default), a lit 3D book with its spine, or **Flat**, the cover alone with rounded corners and a soft shadow. Every template that shows covers has it.
- **Options**: **Loved more** or **Loved less** for Hot Takes, **Show ratings**, and **Shuffle**, which varies tilts and lengths.

| Template | Shows |
| --- | --- |
| Year Stack | The frame's finished books as a stack of spines, with the book and page counts. |
| Year in Books | The frame's totals (books, pages, average rating, and the busiest month, week, or year), a chart of its books as stacks of spines (by month for a year, by week for a month, and by year for a lifetime), top genres, most-read author, and formats. The longest, shortest, and favorite books appear on Story, and on Portrait when they fit. Totals, highlights, and records without data are left out. |
| Top Five | The frame's five highest-rated books, fanned, with a ranked list. |
| Hot Takes | Up to three of the frame's books whose rating is furthest from Hardcover's average, with your stars, the readers' stars, and the difference. **Loved more** shows books you rated at least half a star above the average, and **Loved less** at least half a star below. Only books with 50 or more Hardcover ratings count. |
| Spine Spectrum | Every book finished in the frame as a stripe of its spine color, in reading order. A lifetime marks where each year starts. It shows no titles. |
| Just Finished | One book with your rating and its format, finish date, and length. |
| Review | Your review of one book under its cover, title, and rating. A long review shows as an excerpt that ends with an ellipsis, and the text takes the largest size that fits. Only books with a review are offered. The Apple TV library carries no reviews, so without the iPhone's own Hardcover sign-in the template shows how to add them. |
| Currently Reading | A book you are reading, with its progress and its start date when known. |

Text on every image is set in New York for headings and San Francisco for other text, in each book's own capitalization. Spines keep their designed fonts and colors: Year Stack's spines, the spine of a 3D book, and Spine Spectrum's stripes. A 3D book without a downloaded cover shows its title on the front in the spine's font.

Images show only your own library. They include no account name or ID. Ratings are optional. A small "Created with Bookworms for iPhone" credit sits in the bottom margin of every image.

## How the 3D books work

`Book3DView` draws each visible face of a book (cover, spine, page edges) as an ordinary SwiftUI view and maps it onto the screen with the perspective transform a pinhole camera gives that face. The faces share one camera, so their edges meet, and the result stays pure SwiftUI. `ImageRenderer` can therefore export it in share images, which it cannot do for RealityKit views.

## Run locally

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate --spec project.yml` to create `Bookworms.xcodeproj`. Source folders are synced, so new files need no regeneration.
2. Set up signing for `gay.ian.Bookworms.iOS` with the `iCloud.gay.ian.Bookworms` container, push notifications, and the managed Private Cloud Compute capability (`com.apple.developer.private-cloud-compute`). Request that capability for the team before signing a device build; Apple grants it to members of the App Store Small Business Program.
3. Run `script/build_and_run.sh` to build, install, and launch on a Simulator.

To test on an iPhone before Apple grants the Private Cloud Compute capability, run `script/install_on_device.sh`. It signs an optimized build with `config/NoPCC.entitlements`, compiles it with `NO_PCC` so the app never creates the model, registers the iPhone with the team if needed, and installs it. Generation then reports Private Cloud Compute as unavailable; the Shelf, Pile, and Share tabs work with the iCloud library. A development-signed build reads the CloudKit Development environment, the same one development builds of the Apple TV app and the Mac companion use.

The app shows the library it loaded last while it reloads. It reloads when it becomes active (at most every five minutes) and after a generation run that saved designs for books it had not loaded. Signing out of iCloud, or switching to an account without a library, clears the shown and cached library.

### Preview with a local library

The Simulator usually has no iCloud library. `script/load-preview-data.py` converts a private Apple TV library export and its fonts from the workspace `.local` folder into the iCloud JSON shapes and copies them into the installed app. Then run `script/build_and_run.sh --preview`, which launches with `-BookwormsPreviewFolder preview`. Generation then reads and writes that folder instead of iCloud, and Private Cloud Compute requests are real and count against the signed-in Apple Account's daily limit.

The preview data contains real reading history. It stays in ignored `.local/` folders and the Simulator; do not publish screenshots made from it.

Debug builds accept more launch arguments for checks that cannot tap the Simulator, such as `-BookwormsGenerateOnLaunch YES`, `-BookwormsShelfMode <stack|shelf|pile>`, `-BookwormsOpenBook <book ID>`, and `-BookwormsShareTemplate <yearStack|yearInBooks|topFive|hotTakes|spectrum|justFinished|review|currentlyReading>` with `-BookwormsShareFrame <year:2025|month:2025-08|lifetime>` and `-BookwormsShareCover <threeD|flat>`. The preview library has no reviews or current reads; `-BookwormsShareSamples <n>` adds fictional ones to Debug builds. For the pile, `-BookwormsPileZoom <1...2.5>` and `-BookwormsPileYaw <radians>` set the camera, and once a drop finishes, `-BookwormsPileTilt <x,y>` applies a tilt and `-BookwormsPileThrow YES` throws the top book. Search the source for `"Bookworms` to find them all.

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
