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
- **Generate while charging** (on by default) asks iOS for a background processing task that needs external power and a network connection. iOS chooses when to run it, typically overnight while the iPhone charges. It needs Background App Refresh; when that is off or restricted, the **Spines** tab says so. Background runs download covers only on unmetered networks and stop when the daily limit is almost reached.
- When the Apple TV publishes a new worklist, a silent push schedules the charging task. Generation never runs inside the push's 30-second window.

Each run designs the books that need it, one at a time:

1. The run picks its account and books. A worklist from the Apple TV that lists books decides, even when the iPhone is signed in to Hardcover. Without one, a signed-in iPhone designs its own Hardcover library, and nothing until it has downloaded that library; it never designs the Apple TV's library, which may belong to another account. Signing out stops a run that designs the iPhone's library. Otherwise the iPhone designs the newest Hardcover snapshot that the Apple TV uploaded, preferring a real account ID over the legacy `hardcover` placeholder; Apple TV builds without the worklist upload only that library. An empty worklist means the Apple TV turned Hardcover off, which stops runs unless the iPhone is signed in.
2. The app downloads the cover over HTTPS (the one you chose, if any; see [Cover choice](#cover-choice)), reads its lettering with Vision, and samples its colors.
3. The first model request asks only which of 12 letterform styles the cover's title uses, with the cover attached and the styles in a different order for each book. If Private Cloud Compute cannot read images, the on-device model answers this question.
4. The second request picks cloth, ink, and accent colors from the sampled palette, a weight, and up to four families from that style's open-source Google Fonts families.
5. The app downloads the first family that has every letter of the title and author, rejects italic, oblique, and slanted faces and Impact, and adjusts the colors until the text reaches APCA Lc 75. If no ranked family works, one more ranking request runs without them; if none of those works either, the design uses the style's system typeface.
6. Books in the same series reuse the first saved series design without a request when its font covers the book's letters.
7. The app saves a `SpineDesignV1` record with generator version `ios-pcc-v1`.

A new design usually uses two or three requests. The app rechecks a book when its metadata, its chosen cover, or the generator changes, or after seven days. A book that fails waits 24 hours unless its metadata or chosen cover changes. Quota, network, service, Google Fonts, and iCloud save errors stop the run and schedule the next attempt for the reset or retry time. A Google Fonts outage waits for its `Retry-After` time, at most one day, or 15 minutes without one. An unavailable model or full iCloud storage pauses background runs for a day; **Generate now** runs anyway.

### Hardcover sign-in

The account button in the **Spines** tab's toolbar opens the Hardcover sheet, and so does **Connect Hardcover** on the **Shelf** and **Share** tabs when there is no library. Signed out, it explains what signing in adds and offers **Connect Hardcover**. Sign-in uses the same OAuth 2.0 Device Authorization Grant, client ID, and read-only scopes as the Apple TV app (see the [Apple TV authentication guide](../tvos/docs/HARDCOVER_AUTHENTICATION.md)):

1. The app requests a code from Hardcover and shows it with **Copy code**.
2. **Open Hardcover** opens Hardcover's approval page in Safari inside the app: the link with the code filled in when Hardcover provides one, otherwise `hardcover.app/link`. Sign in to Hardcover if asked, enter the code, and allow Bookworms.
3. The app polls Hardcover at the interval it asks for and waits 5 seconds longer after each `slow_down` or HTTP 429. It keeps polling through network and server errors, and stops when the code expires or the request is declined; **Get a new code** starts over.
4. Once approved, the app checks the account with a `me` query, then saves the token.

The signed-in sheet shows the Hardcover username, when the library last synced, **Sync now**, and **Sign out**. When Hardcover rejects the saved login (HTTP 401, or HTTP 403 with `insufficient_scope`), the sheet and the **Spines** tab say so and offer **Reconnect**, and the toolbar button shows a warning badge; the copy of the library stays until then. Other 403 responses are reported as denied requests, not as an expired login. The **Spines** tab also shows other download and load errors, even while it shows an older copy of the library.

While signed in:

- The Shelf and Share tabs show the Hardcover account's own library: every book on its shelves, with the same covers, page counts, finish and start dates, ratings, community ratings, formats, genres, series, and progress as the Apple TV builds. Each book also carries your review as plain text (`CloudBook.review`, from Hardcover's `user_books.review` with HTML and Markdown removed). Designs for these books still come from iCloud, matched by the same account ID the Apple TV uses (the Hardcover user ID).
- The app downloads the library when it launches or becomes active if the copy on the iPhone is missing or more than four hours old, and when you choose **Sync now**. Any reload the app or the Shelf starts also checks this. Each Hardcover query, including the account check and the library download, retries server errors, timeouts, and dropped connections up to twice, after about 2 and then 4 seconds, and retries a rate limit whose `Retry-After` is 30 seconds or less.
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
- **Signed in, login rejected:** **Reconnect Hardcover** with the error and **Reconnect**, which opens the Hardcover sheet and starts a sign-in, or shows the code of a sign-in already in progress.

The sheet stays open when the library arrives. Preview mode ignores the sign-in, so it offers only **Try again**. A library without books says that books appear after the Apple TV's next sync, or after the next sync with Hardcover when signed in.

### Shelf

The **Shelf** tab shows every book as a spine in its saved design, or in a plain cloth fallback before it has one.

- **Stack** (default) lays the spines flat and scrolls them vertically as a 3D wheel.
- **Shelf** stands the spines upright, as on the Apple TV, and scrolls them horizontally like Cover Flow.
- **3D** shows the books in a 3D scene, on a wooden desk under a lamp at night, in the view that **View** in **Sort and filter** chooses. The Pile drops the current year's books, another year's or month's, or up to 300 books, onto the desk as a physics toy, and shares the pile as an image (see [Pile](#pile)). The Bookworm stacks the finished books in a block that a cartoon worm eats in the order you finished them (see [Bookworm](#bookworm)). The app saves the choice, and the views share the time frame.
- The caption shows the centered book's title, author, finish date, and your rating. Sort by finish date, title, author, or rating, or show designed books only.
- Tap the centered spine for details: a 3D book you can turn with a drag, its reading details, the design's font and colors, **Change cover**, and **Share**.

### Cover choice

**Change cover** on a book's details opens the covers of the book's Hardcover editions, most-read edition first, with the current cover marked. Each cover shows its edition's format and year, and VoiceOver reads it as, for example, "Cover from 2019 Paperback edition". Choosing a cover saves it; **Use default cover** returns to the cover Bookworms picks from your library.

- The picker lists up to 60 editions with images and leaves out repeated images, non-HTTPS links, images under 300 pixels on the shorter side, and nearly square art such as audiobook covers. A cover that does not load cannot be chosen.
- Finding covers needs this iPhone's Hardcover sign-in, which reads the editions with the same read-only scopes as the library. Signed out, the sheet explains this and offers **Connect Hardcover**. If Hardcover rejects the login, for example after it expired or was revoked, the sheet offers **Reconnect Hardcover**. **Use default cover** works in these states and when Hardcover cannot be reached.
- The choice is saved to iCloud as a `CoverChoiceV1` record for the shown account (see [iCloud contract](#icloud-contract)), so another iPhone on the same iCloud account shows it after its next reload. Choosing the default cover deletes the record. If iCloud rejects the change, or the shown library no longer includes the book, for example after signing in to another account, the sheet says so and nothing changes.
- The chosen cover replaces the default everywhere the iPhone shows the book: details, share images, the Pile, and spine generation. If the chosen image stops loading, the default cover shows instead. The Pile reuses a book's textures until its spine design changes or the pile is released, for example when you switch tabs or presentations, so a new cover appears there only after that. The exception is a book whose details you opened from the Pile: it shows the new cover at once, in its details and back in the pile.
- The spine keeps its current design until the next run, which rechecks the book because its chosen cover changed. After a change, the details offer **Redesign spine**, which starts **Generate now**. If a run ends without a new design, the details show why, or that the run left the spine unchanged. A book in a series reuses the series design when one exists, so only its saved cover hash changes.

### Pile

**3D** shows the Pile: up to 300 books, the first in the shelf's sort and filter order, as RealityKit rigid bodies that fall onto a table in waves of 16 and pile up.

- In **3D**, **Sort and filter** adds **Time frame**: **All books**, a **Year**, or a **Month**. Until you choose one, the pile shows the current year. The year and month lists include only periods with finished books. Choosing one drops that period's finished books in a new pile, as **Drop again** does. The app saves the choice. If the saved or current year, or the saved month, has no finished books in the current library, the pile uses the newest year or month instead. Under the presentation picker, the pile names its time frame and book count, such as "2025 · 39 books"; for **All books**, it names the years the books span. Past 300 books, it says how many it shows, such as "2009–2026 · 300 of 412 books". When **Designed only** leaves a year or month empty, the shelf says so and offers to show that period's books or all books.

- Each book has the size of a real book: 21 to 24 cm tall, as wide as its cover's aspect ratio allows (2:3 without a cover), and as thick as its page count suggests, rounded to 5 mm in height and width and 2 mm in thickness so that books of one size share a mesh. A hardcover's boards overhang its pages by 3.5 mm and its spine is rounded; a paperback's covers are trimmed flush with its pages, and its spine is flat with soft corners. The covers' edges are beveled, so they catch the light. The front shows the cover, cropped to the front board, which ends where the spine starts to curve, so a little narrower than on its details screen; a hardcover's board edges show the cover's border, as a wrapped jacket does. The spine shows the saved design rendered by `SpineView`, at one scale across its curve, and the back is the spine's cloth color. Physics treats each book as a box of its size.
- Hardcovers wear a satin-gloss jacket that reflects the room and softens the lamp's highlight; paperbacks are matte. The library does not record which edition you own, so the binding is a stable guess (`CloudBook.binding`): three in four books finished within a year of publication are hardcovers, since new releases come out in hardcover first, and two in five other books are.
- Page edges show fine leaves and yellow with the time since you finished the book, fully aged after 15 years. A five-star book's edges are sprayed in its spine's accent color. A book you are reading has a red ribbon bookmark that comes out of its tail at your progress. A year or month holds only the books you finished then, so ribbons show under **All books**. After a library sync, the next drop, such as **Drop again**, shows new progress, ratings, and finish dates.
- A lamp high above the desk, over your right shoulder, casts a warm pool of light on the pile. It lights the covers, spines, and page edges that face you, and the books' shadows fall up and to the left of them. Full light spans the middle of the pool, and the table fades into a dark room beyond it, which hides the repeats of its wood texture. A dim room drawn in code, with the lamp's glow on the wall behind you, lights the shadows and shows in the glossy jackets. Faint dust motes drift slowly through the beam, except with **Reduce Motion** on.
- Books knock as they land: a thud for a heavy book and a papery slap for a light one, louder for a harder hit and panned toward where it lands on screen. A burst of hits plays a sound at most every 30 milliseconds, except for a much harder hit, and the mix keeps headroom so a burst does not clip. The sounds are synthesized on the device, play off the main thread, mix with other audio, and follow the silent switch. Turn **Sounds** off in the **Sort and filter** menu to silence them. On an iPhone, hits also play haptic taps, at most one every 60 milliseconds except for a much harder hit, whether or not **Sounds** is on.
- Drag a book to pick it up and throw it, tap one for its details (see [Details from the pile](#details-from-the-pile)), pinch to zoom toward a point, and turn two fingers to look around the pile. **Drop again** starts a new drop and redraws books whose design or font changed since the last one.
- On an iPhone that reports motion, tilting the phone tips the table. The pile responds to the change from how you held the phone when tilting began, up to about 27 degrees, and books slide toward the edge of the screen you tip down, however you have turned the view. Turn **Tilt to move books** off in the **Sort and filter** menu, which offers it only for the Pile, to keep the table level.
- With **Reduce Motion** on, the books appear in tidy stacks, spines toward you, and tilt is off. The stacks hold still: picking up a book frees only that book and the books resting on it. **Stack again** replaces **Drop again**. Tapping a book pushes its details, as **Stack** and **Shelf** do, and the pile is as you left it when you come back.
- Invisible walls keep the books between the navigation bar and the tab bar. Switching to another tab, **Stack**, or **Shelf** releases the books and their textures, and the books drop again when you return. The **Share** button of a book's details is the exception (see [Details from the pile](#details-from-the-pile)).
- Each wave waits at most 1.5 seconds for its own covers, and the next wave's covers download while it falls. A book whose cover arrives later falls with its title on its cloth color, and the cover replaces the title when it arrives. Textures stay small: covers are at most 224 pixels and spines 384 pixels long, an estimated 75 MB of GPU memory for the 300-book maximum and at most 116 MB. Books of one shape share a mesh, a new pile keeps only the meshes its books use, and books share page, cloth, and ribbon materials by color. The room's light is built once and shared with share images.

VoiceOver reads the pile as one element with its book count, its time frame, and a **Drop again** action; choose **Stack** or **Shelf** to go through books one at a time. While a book's details show over the pile, VoiceOver reads the details and **Back** instead, and the escape gesture goes back. The soft shadows under the books, the softness of the lamp's shadows, the dust, frame rate and rendering cost, the details flight and throw, how closely the book follows the details as they scroll, the sounds, and the stability of tall stacks have been checked only in the Simulator, which plays no haptics and draws the lamp's shadows with hard edges; check them on a device.

#### Details from the pile

With Reduce Motion off, tapping a book lifts it out of the pile and into its details, the same RealityKit model throughout, as the Apple TV's Book Wall does. If the pile cannot lift the book, the details push instead.

- The book rises straight up until it clears the books around and on it, shoving them aside, then flies on a spring to where the details show their book: centered in the same 380-point stage, facing you in the same three-quarter pose, with its spine showing. A book more than half a unit above that stack, such as one still falling, does not count. The rise takes 0.12 to 0.25 seconds, less for a lower rise, so a book with nothing on it leaves at once. The flight takes about a second and overshoots slightly. The books it carried fall back into its place, and the rest of the pile keeps moving.
- A walnut veil, the color of the details' backdrop, darkens the pile behind the book as it flies until the pile no longer shows, and the camera eases back to its default zoom and position, keeping its turn. Clear of the pile, the book is drawn as the pushed details draw theirs, without the pile's lights or its ribbon, and with each face shaded as the details shade it. The lamp glow behind the pushed details' book is not drawn. About a second after the tap, the details fade in over the veil. They are the same details as **Stack** and **Shelf** push, with **Change cover**, the spine design, and **Share**. The book scrolls with them, a drag turns it as it turns the pushed details' book, and **Change cover** retextures it. Its cover and spine draw at the details' sharpness while they show, then return to the pile's smaller textures when the book lands back in the pile.
- While the details show, the pile's gestures, tilt, **Drop again**, **Share**, the presentation picker, and **Sort and filter** give way to **Back** and the book's **Share**. Tapping another book does nothing until the book in flight is back. The book's **Share** opens the Share tab and keeps the details and the pile, as pushed details do, so they are as you left them when you return to **Shelf**.
- **Back** fades the details out in 0.2 seconds, returns the pile's controls, and throws the book back where it lay. It waits out any pause from the changing controls, then lands about a quarter second later, tumbling, and crashes into the pile there, scattering the books it hits, while the veil lifts and the camera returns. Its first hit keeps a quarter of its sideways speed and half of its tumble, so it stays near where it lands. The details pose can lie outside the walls, so the book passes through them until that hit. The hit plays a hard knock and, on an iPhone, a strong haptic tap.
- Switching tabs other than through the book's **Share**, switching presentations, a new pile (for example, after a library change removes the book), or a share image that starts rendering closes the details at once and drops the book back over its place without the throw. Each also ends a throw in progress the same way. A task from an earlier lift or return cannot reopen or move anything.

#### Share the pile

**Share** in the Pile toolbar opens **Share pile**. It drops the pile's books into a new pile and renders a 1080-pixel-wide PNG in Story, Portrait, or Square format. **Shuffle** drops them again from new starting poses. A new library, such as one the Apple TV uploads while the sheet is open, draws a new image. The share button waits for the current image.

- The heading names the time frame, such as "2025" or "November 2025", in New York. For **All books**, it shows the years the books were finished, such as "2014–2026". Below it is the book count, and the bottom margin holds the same credit as the Share tab's images.
- Up to 150 books drop, last book first, so the first books in the shelf's order land on top. Fewer books are framed closer, with sharper textures. Books start over the middle of the table, just above the pile so far, tilted only a little and without spin, so few land face down. Invisible walls keep the pile together while it settles and are removed for the last half second, so no book stays propped against one. The camera then fits every book between the heading and the bottom margin.
- The image has the live pile's lamp, room light, and shadows, without dust.
- While the sheet is open, the live pile leaves the screen and keeps its books. Closing the sheet shows the pile as you left it.
- `ImageRenderer` cannot capture a `RealityView`, so `PileSnapshotRenderer` builds a `BookPileScene` that no view shows. It runs the physics with RealityKit's `RealityRenderer` for a fixed number of 60 Hz steps, renders one frame into a Metal texture, and copies the frame to memory. If that frame is one flat color, the sheet reports that the pile could not be drawn instead of sharing it. The renderer and its textures are released after each image.
- Covers get up to 10 seconds to load. The simulation runs on the main actor between short pauses while the sheet shows progress. `PileSnapshotRenderer.render(books:title:aspect:seed:model:)` is the entry point; the Share tab's [Pile template](#share) uses it too.
- One pile image renders at a time, and a render waits for one that is still finishing after its task was cancelled. `RealityRenderer` steps the same RealityKit engine that draws the live pile, and RealityKit's render thread can crash drawing the pile's meshes meanwhile. While any pile image renders, from the sheet or the Share tab, the live pile's table and books therefore leave its scene, and the simulation starts 100 milliseconds later, so the view can react first. The pile's `RealityView` puts them back when the render ends. RealityKit keeps updating a `RealityView` in a tab that is not selected, so this matters when the Shelf tab was left in **3D**. The view itself stays: one removed while its tab is hidden lingers until the tab shows again and then takes its scene along.

Offscreen rendering, physics stepping, and the image itself have been checked only in the Simulator. Check them on a device.

### Bookworm

In **3D**, **View** > **Bookworm** in **Sort and filter** stacks the time frame's finished books in a block on the desk, and a cartoon bookworm eats through them in the order you finished them.

- The block holds up to 100 books: the first finished books in the shelf's sort and filter order. Books you have not finished are left out. Under the presentation picker, the view names its time frame and book count, such as "2025 · 39 books", or "2009–2026 · 100 of 412 books" past 100. A time frame without finished books, such as **All books** with only current reads, shows **No finished books**.
- The books lie flat, spines toward you, in stacks of up to eight, at most three stacks to a row. The block is laid out in finish order: the stacks run in a serpentine from the near left corner, each next to the one before, and each stack holds its books from the bottom up. The camera looks down from 50 degrees above the desk and frames the block between the bars, keeping at least two stacks' width in view. It holds still while the worm eats.
- The worm has a green head with big eyes, round glasses, rosy cheeks, and a smile, and a short green tail. It crawls in from below the screen, stops just outside each stack in turn with its mouth in the stack, and eats the stack from the bottom, pecking as it chews. Each book shrinks into its mouth in a burst of paper crumbs, with a papery bite and, on an iPhone, a light haptic tap, while the books on it sink with it; the books above then settle into the gap with physics. The book adds a segment right behind the head in its spine's color, 1.6 cm long plus 4 mm for every full hundred pages, counting up to 1,500 pages. A book without a page count adds as much as a 320-page book. The body follows the head's path and sways from side to side behind it.
- The worm eats a book in half a second and crawls 35 cm a second. Past 30 books it goes faster in proportion, so the meal takes about as long as a meal of 30 books.
- A tally under the worm counts the books and pages eaten so far, such as "Ate 39 books · 12,345 pages". Pages count only books with a page count. After the last book, the worm curls up in a spiral in the middle of the desk, with its tail inside and its head on the outside, facing you, and the camera moves in to frame it, showing a shorter worm no larger than a worm of about 20 books. The curled worm blinks every few seconds.
- **Pause** stops the worm and the book it is eating; books already falling still settle. **Play** continues. **Restart** builds the block again and starts the meal over. Tap a book or a segment of the worm to see that book's title, author, and finish date for three seconds. A tapped segment swells for a moment.
- With **Reduce Motion** on, the view shows the worm curled up after the meal, with its tally, without the block or the tunneling, and without **Pause** or **Restart**. The worm does not blink, and no dust drifts in the beam.
- Collisions play the same sounds and haptic taps as the Pile and follow **Sounds**. Switching to another tab, **Stack**, or **Shelf** releases the books and their textures, and the meal starts over when you return. The books are built as the Pile's are, with the same texture sizes. The block appears once its books are drawn, waiting at most 1.5 seconds for covers; a book whose cover arrives later shows its title until it does. Every round part of the worm is one shared sphere mesh, scaled, the glasses and the smile share two small ring meshes, and parts of one color share a material. While any pile image renders, the view takes its books and worm out of its scene, as the Pile does.

VoiceOver reads the view as one element with **Play or pause** and **Restart** actions, then the tally and a tapped book's name as text; choose **Stack** or **Shelf** to go through books one at a time. The Bookworm's look, framing, taps, and Reduce Motion have been checked only in the Simulator. Check the haptic taps, the sounds, and the frame rate on a device.

### Share

The **Share** tab renders a 1080-pixel-wide PNG in Story (9:16), Portrait (4:5), or Square format and shares it through the share sheet, which can also save it to Photos. Choose a template from the grid, then set its options:

- **Time frame**: **Year** (the newest year by default), **Month**, or **Lifetime**, with a menu of the years or months that have finished books. Templates about several books draw the books finished in the frame, and headings follow it, such as "2025 in books", "My top 5 of August 2025", or "My lifetime in books". Just Finished and Review list the frame's books in their book picker; Review's **Lifetime** also lists reviewed books without a finish date. Currently Reading has no time frame.
- **Book**: the featured book of Just Finished, Review, and Currently Reading. It defaults to the newest choice.
- **Cover**: **3D** (default), a lit 3D book with its spine, or **Flat**, the whole cover with rounded corners and a soft shadow. Every template that shows covers has it, except Year in Books on Square, which shows no records, and Pile, whose books are always 3D.
- **Options**: **Loved more** or **Loved less** for Hot Takes, **Show ratings**, and **Shuffle**, which varies the spine stacks, the Top Five fan, a pile's drop, and the angle of 3D books. Templates that the seed cannot change hide it.

| Template | Shows |
| --- | --- |
| Year Stack | The frame's finished books as one stack of spines, or two side by side when one would be too tall, with the frame's book and page counts. When two stacks cannot hold them all, the lowest-rated books are left out and the shelf shows how many, such as "+12 more". |
| Year in Books | The frame's totals (books, pages, average rating, and the busiest month, week, or year), a chart of its books as stacks of spines (by month for a year, by week for a month, and by year for a lifetime, leaving out empty years when the books span more than 50), top genres, most-read author, and formats. The longest, shortest, and favorite books appear on Story, and on Portrait when they fit. Totals, highlights, and records without data are left out. |
| Top Five | The frame's five highest-rated books, fanned, with a ranked list. |
| Hot Takes | Up to three of the frame's books whose rating is furthest from Hardcover's average, with your stars, the readers' stars, and the difference. **Loved more** shows books you rated at least half a star above the average, and **Loved less** at least half a star below. Only books with 50 or more Hardcover ratings count. |
| Spine Spectrum | Every book finished in the frame as a stripe of its spine color, in reading order. A lifetime marks where each year starts. It shows no titles. |
| Pile | The frame's finished books dropped onto the wooden table, newest on top, under the frame's name and book count, drawn as in [Share the pile](#share-the-pile). Up to 150 books drop. The preview shows **Dropping books** while the pile settles, which takes a few seconds. |
| Just Finished | One book with your rating and its format, finish date, and length. |
| Review | Your review of one book under its cover, title, and rating. A long review shows as an excerpt that ends with an ellipsis, and the text takes the largest size that fits. Only books with a review are offered. The Apple TV library carries no reviews, so without the iPhone's own Hardcover sign-in the template says so and offers **Connect Hardcover**. |
| Currently Reading | A book you are reading, with its progress and its start date when known. A reread shows its new start date, not its last finish. |

Each image's backgrounds and panels come from one color family: the hue its books' spines share most, or a warm neutral when they are mostly gray. Unrelated spine colors never compete in the background; covers and spines keep their own colors. Text is cream with gold accents. Text on every image is set in New York for headings and San Francisco for other text, in each book's own capitalization. Spines keep their designed fonts and colors: Year Stack's spines, the spine of a 3D book, and Spine Spectrum's stripes. A 3D book without a downloaded cover shows its title on the front in the spine's font.

Images show only your own library. They include no account name or ID. Ratings are optional. A small "Created with Bookworms for iPhone" credit sits in the bottom margin of every image. If an image cannot be drawn, such as a pile whose frame comes out one flat color, the preview says so, suggesting **Shuffle** for a pile, and nothing is shared.

A new option draws a new image and cancels the one in progress. A new design for a book in the image, such as one a generation run saves every few seconds, draws after the image in progress instead, and the shown image stays shareable meanwhile. Designs for other books change nothing.

## How the 3D books work

`Book3DView` draws each visible face of a book (cover, spine, page edges) as an ordinary SwiftUI view and maps it onto the screen with the perspective transform a pinhole camera gives that face. The faces share one camera, so their edges meet, and the result stays pure SwiftUI. `ImageRenderer` can therefore export it in share images, which it cannot do for RealityKit views. Pile share images, from **Share pile** or the Share tab's Pile template, are the exception: they render RealityKit offscreen (see [Share the pile](#share-the-pile)).

The 3D views share their RealityKit pieces. `BookGeometry` builds each book's mesh from its `BookShape`, and `BookFactory` gives the book its textures, materials, physics box, and mass. `DeskStage` holds the desk, the lamp, the room's light, and the dust. `ImpactFeedback` turns collisions into taps and sounds, and can record each hit whose sound passes its throttle, whether or not **Sounds** is on: its time, impulse, mass, and position, and the sound's kind, variant, volume, and pan, so an offline renderer can mix the same `ImpactSound` samples into a video. A new view is a `ThreeDView` case and its arm in `ShelfView`, built from these pieces. The Bookworm's view (`BookwormView`) and scene (`BookwormScene`) build on them, and keep the block's layout, the eating order, the camera's framing, where the head stops to eat, the worm's segments and curl, and the rings of its glasses and smile in `BookwormLayout`, and the path its body follows in `WormTrail`, without RealityKit, so unit tests can check them.

## Run locally

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate --spec project.yml` to create `Bookworms.xcodeproj`. Source folders are synced, so new files need no regeneration.
2. Set up signing for `gay.ian.Bookworms.iOS` with the `iCloud.gay.ian.Bookworms` container, push notifications, and the managed Private Cloud Compute capability (`com.apple.developer.private-cloud-compute`). Request that capability for the team before signing a device build; Apple grants it to members of the App Store Small Business Program.
3. Run `script/build_and_run.sh` to build, install, and launch on a Simulator.

To test on an iPhone before Apple grants the Private Cloud Compute capability, run `script/install_on_device.sh`. It signs an optimized build with `config/NoPCC.entitlements`, compiles it with `NO_PCC` so the app never creates the model, registers the iPhone with the team if needed, and installs it. Generation then reports Private Cloud Compute as unavailable; the Shelf and Share tabs, including the Pile, work with the iCloud or Hardcover library. A development-signed build reads the CloudKit Development environment, the same one development builds of the Apple TV app and the Mac companion use.

The app shows the library it loaded last while it reloads. It reloads when it becomes active, at most every five minutes after a load succeeds. After a failed load, it tries again the next time it becomes active or a generation run ends. It also reloads after a generation run that saved designs for books it had not loaded. Without a Hardcover sign-in, signing out of iCloud, or switching to an account without a library, clears the shown and cached library. Signing out of Hardcover, or signing in to another Hardcover account, also clears it before the reload.

### Preview with a local library

The Simulator usually has no iCloud library. `script/load-preview-data.py` converts a private Apple TV library export and its fonts from the workspace `.local` folder into the iCloud JSON shapes and copies them into the installed app. Then run `script/build_and_run.sh --preview`, which launches with `-BookwormsPreviewFolder preview`. Generation then reads and writes that folder instead of iCloud, and Private Cloud Compute requests are real and count against the signed-in Apple Account's daily limit.

The preview data contains real reading history. It stays in ignored `.local/` folders and the Simulator; do not publish screenshots made from it.

Preview mode keeps cover choices in `cover-choices-v1.json` in the preview folder. Loading the preview data again keeps that file; deleting it restores the default covers.

Debug builds accept more launch arguments for checks that cannot tap the Simulator, such as `-BookwormsGenerateOnLaunch YES`, `-BookwormsShelfMode <stack|shelf|pile>` (`pile` opens **3D**) with `-BookwormsThreeDView <pile|bookworm>` to choose its view, `-BookwormsOpenBook <book ID>` (in **3D**, the pile lifts that book four seconds after its drop finishes), and `-BookwormsShareTemplate <yearStack|yearInBooks|topFive|hotTakes|spectrum|pile|justFinished|review|currentlyReading>` with `-BookwormsShareFrame <year:2025|month:2025-08|lifetime>` and `-BookwormsShareCover <threeD|flat>`. The preview library has no reviews or current reads; `-BookwormsShareSamples <n>` adds fictional ones to Debug builds, in the Share tab and the Shelf, where the pile's **All books** shows the current reads' ribbons. For the pile, `-BookwormsPileZoom <1...2.5>` and `-BookwormsPileYaw <radians>` set the camera, and once a drop finishes, `-BookwormsPileFocus <book ID>` zooms all the way in on that book three seconds later, `-BookwormsPileTilt <x,y>` applies a tilt, and `-BookwormsPileThrow YES` throws the top book. `-BookwormsPileBack <seconds>` presses **Back** that many seconds after a lifted book's details appear. `-BookwormsPileFrame <year:2025|month:2025-8>` sets the time frame of the 3D views. `-BookwormsPileShare YES` opens **Share pile** and writes each image to `Library/Caches/Bookworms/pile-share-debug.png`, and `-BookwormsPileShareAspect <story|portrait|square>` picks its size. With `-BookwormsShowSpines YES`, `-BookwormsShowAccount YES` opens the Hardcover sheet, and `-BookwormsStubSignIn YES` answers sign-in with the fictional code `WORM-2611` that is never approved, without contacting Hardcover. `-BookwormsLibraryStatus <signedOut|downloading|failed|reconnect>` makes the empty Shelf and Share tabs show that state with a fictional error, and `-BookwormsShareTabs "shelf:0 share:8"` selects each tab once its seconds pass after the previous entry. The schedule starts when the Share tab first appears, so also pass `-BookwormsShareTemplate <name>` to open that tab at launch. With `-BookwormsOpenBook <book ID>`, `-BookwormsCoverPicker YES` opens **Change cover**; `-BookwormsStubCovers YES` answers it with six fictional covers drawn on the device, without Hardcover or an image host, and `-BookwormsChooseCover <index>` chooses one of them; `-BookwormsStubCovers expired` answers as Hardcover does for a revoked login. Search the source for `"Bookworms` to find them all.

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

- Only the Apple TV's `spine-companion` branch, which is not merged or released, caches companion designs, draws them on Book Wall, and shows chosen covers. Other Apple TV builds ignore designs and `CoverChoiceV1` records and show the default covers.
- This app replaces a Mac companion design once, when it rechecks the book. Mac companion builds that include macos commit `f2eed75` read `CoverChoiceV1`, design from the chosen cover first, and keep an iPhone design while its work-item and cover hashes match the Mac's own, so the two companions settle on the iPhone's design. Older Mac builds replace iPhone designs whenever they recheck a book, so the two companions keep overwriting each other and spend model requests each time.
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

The pile's table (`TableWood`) is [White Oak Veneer](https://polyhaven.com/a/white_oak_veneer) by Jenelle van Heerden from Poly Haven, under [CC0](https://polyhaven.com/license). The bundled file is the 2K diffuse map scaled to 1024 pixels; the app tints it a darker brown. The room's light, the page edges' texture, and the impact sounds are generated in code.
