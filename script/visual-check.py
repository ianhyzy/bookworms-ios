#!/usr/bin/env python3
"""Captures the views a change touches, before and after it, for an agent to review.

    python3 script/visual-check.py                   capture the views the change touches
    python3 script/visual-check.py --list            print the views the change touches
    python3 script/visual-check.py --surfaces library,desk    capture these views instead
    python3 script/visual-check.py --platforms mac   capture one platform (iphone or mac)
    python3 script/visual-check.py --head <commit> --base <commit>    check another change
    python3 script/visual-check.py --record pass     record the agent's verdict for HEAD
    python3 script/visual-check.py --record pass --allow-missing    ... for a bundle that lacks a
                                                     platform's pictures

The script maps the files changed between the base and HEAD to views (`RULES`), builds both
commits, and runs each view's launches (`SHOTS`) on the iPhone and on the Mac. The iPhone runs
on one slim simulator that the script creates and deletes. The Mac has no simulator, so its
launches run a Debug copy of the app, signed ad hoc, with a scratch bundle ID and a scratch home
folder, which never touches the installed app, its iCloud data, or its Keychain items, and
`screencapture` photographs the copy's window. That needs the Mac's lid open, its display
awake, and Screen Recording allowed for the app that runs this script; without them the
brief lists the Mac shots as missing.

Each launch saves a picture, and a launch with motion also saves a set of frames as one image,
because agents read images, not video. The app shows the owner's real library from the private
preview data in the workspace's `.local` folder, so the bundle stays in the ignored
`.local/visual-check/` folder: never commit or publish it.

The bundle's `REVIEW.md` gives a reviewing agent the images and a fixed list of questions.
After the agent reports `VERDICT: pass`, `--record pass` writes the visual-check marker, the
record that the commit was checked; the workspace's merge gate doesn't require it.
README-AI.md, Visual check, describes the review step and what the check can't judge.

Run it with the Bash sandbox off, because xcodebuild and the simulator need it off.
"""
import argparse
import bisect
import datetime
import itertools
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import premerge

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).resolve().parent.relative_to(ROOT)
BUNDLE_ID = "gay.ian.Bookworms.iOS"
# The Mac copy's bundle ID: its preferences and saved state stay apart from the installed app's.
MAC_BUNDLE_ID = "gay.ian.Bookworms.VisualCheck"
PLATFORMS = {"iphone": "iPhone", "mac": "Mac"}
# Device Hub's switch for the sound of iOS simulators.
SIMULATOR_SOUND = ["com.apple.dt.Devices", "enableAudioOutput_iOS"]

SURFACES = {
    "library": "Library (Stack and Shelf)",
    "details": "book details",
    "desk": "Desk",
    "dominoes": "Dominoes",
    "share": "share images",
    "spines": "the Spines tab and its pickers",
    "settings": "Settings and the Hardcover account",
    "account": "the account's bar on the iPhone and its sidebar row on the Mac",
    "empty": "the tabs without a library",
    "other": "a view this script has no rule for",
}
EVERY_VIEW = [name for name in SURFACES if name != "other"]
BOOK_VIEWS = ["library", "details", "desk", "dominoes", "share"]
# A changed file under Bookworms/ whose path matches a pattern touches those views. A file that
# matches no pattern touches "other" when it is under Views/ or Support/, or is a shader or an
# asset (`DRAWS`).
RULES = [
    (r"Views/(LibraryView|LibraryCommands|ShelfPullOut|SpineCarousel)", ["library"]),
    (r"Views/(BookDetailView|CatalogCard|LiftedDetails|BookFlight|BookExit|CoverPickerView|FontPicker"
     r"|SeriesSheet|Stationery|Restamp)", ["details"]),
    (r"Views/(BookPile|Desk|PilePlay|Cobweb|SceneLoading|ImpactFeedback)", ["desk"]),
    (r"Domino", ["dominoes"]),
    (r"Views/(Share|YearInBooksCard|Toast|PileMovie|PileSnapshot|PileSpread|PileVideoSheet|Tower)"
     r"|Models/(TopFivePins|YearInBooks|BookTower)", ["share"]),
    (r"Views/(GenerationView|SpineDesignerSettings)", ["spines"]),
    (r"Views/AccountControl", ["spines", "account"]),
    (r"Views/(HardcoverAccountView|SettingsPanes|Credits)|Credits\.rtf", ["settings"]),
    (r"Views/NoLibraryView", ["empty"]),
    (r"Models/(LibraryTime|TimeFrame)", ["library", "desk", "dominoes"]),
    (r"Views/(Book3DView|BookFactory|BookGeometry|BoundBook|BookText|SpineView|SpineLook|Room)"
     r"|Models/Spine|Support/SpineContrast|SeriesDesigns", BOOK_VIEWS),
    (r"App/BookwormsApp\.swift|Views/MacScenes|Support/(AppKitBridge|TestCopy)|\.xcassets/|\.icon/",
     EVERY_VIEW),
]
DRAWS = r"/Views/|/Support/|\.metal$|\.xcassets/"


@dataclass
class Shot:
    """One launch of the app: a picture `wait` seconds in, and a strip of frames when `motion`.

    `file` names an image the app writes to `Library/Caches/Bookworms`, such as a share image,
    which is saved in place of the screenshot. `window` picks the Mac window whose title
    contains it, else the largest.
    """
    name: str
    arguments: list
    wait: int
    motion: bool = False
    file: str = ""
    window: str = ""


# `{book}` becomes the ID of the preview library's first book.
LIBRARY = [
    Shot("stack", ["-BookwormsTab", "library", "-BookwormsShelfMode", "stack", "-BookwormsStackStyle", "3d",
                   "-BookwormsShelfGlideTo", "6"], 20, motion=True),
    Shot("shelf", ["-BookwormsTab", "library", "-BookwormsShelfMode", "shelf"], 20),
]
DETAILS = [Shot("flight", ["-BookwormsShelfMode", "stack", "-BookwormsStackStyle", "3d",
                           "-BookwormsOpenBook", "{book}"], 25, motion=True)]
# A fixed time frame shows the same books before and after a change to the default one.
# The other launches cover what the first can't show: a period's name as its books fall, the
# gather that a double tap on the bare desk starts, the time frame Desk opens on by default, and
# a lifted book's details with the Back that fades them and returns the book.
DESK = [
    Shot("drop", ["-BookwormsShelfMode", "pile", "-BookwormsPileFrame", "year:2025"], 35, motion=True),
    Shot("months", ["-BookwormsShelfMode", "pile", "-BookwormsPileFrame", "year:2025",
                    "-BookwormsPileByPeriod", "YES"], 30, motion=True),
    Shot("gather", ["-BookwormsShelfMode", "pile", "-BookwormsPileFrame", "year:2025",
                    "-BookwormsPileGather", "2"], 35, motion=True),
    Shot("default", ["-BookwormsShelfMode", "pile"], 30),
    Shot("back", ["-BookwormsShelfMode", "pile", "-BookwormsPileFrame", "year:2025", "-BookwormsOpenBook", "buried",
                  "-BookwormsPileBack", "2"], 25, motion=True),
]
DOMINOES = [Shot("run", ["-BookwormsTab", "desk", "-BookwormsSetUpDominoes", "YES", "-BookwormsDominoPush", "3",
                         "-BookwormsPileFrame", "month:2025-8"], 60, motion=True)]
# The Mac also plays the run in the window's shape (**Video**, `DominoVideoFrame`), and saves
# the recorded video's last frame.
MAC_DOMINOES = DOMINOES + [
    Shot("window", [*DOMINOES[0].arguments, "-BookwormsDominoVideoFrame", "window"], 60, motion=True),
    Shot("window-video", [*DOMINOES[0].arguments, "-BookwormsDominoVideoFrame", "window",
                          "-BookwormsDominoVideo", "YES"], 75, file="domino-video-debug.png"),
]
# The Spines tab with a working sign-in, then, for the iPhone, with its toolbar's account
# control as it shows no sign-in, a rejected one, and a library that failed to download.
SPINES = [Shot("tab", ["-BookwormsTab", "spines"], 20)] + [
    Shot(name, ["-BookwormsTab", "spines", "-BookwormsLibraryStatus", status], 20)
    for name, status in (("connect", "signedOut"), ("reconnect", "reconnect"), ("problem", "failed"))]
# The iPhone's bar that says a rejected sign-in no longer syncs, on each tab that shows it.
BANNER = [Shot("share", ["-BookwormsTab", "share", "-BookwormsLibraryStatus", "reconnect"], 30),
          Shot("library", ["-BookwormsTab", "library", "-BookwormsShelfMode", "shelf",
                           "-BookwormsLibraryStatus", "reconnect"], 20),
          Shot("desk", ["-BookwormsShelfMode", "pile", "-BookwormsPileFrame", "year:2025",
                        "-BookwormsLibraryStatus", "reconnect"], 35)]
# The Mac sidebar's account: a reader's name, the name with a rejected sign-in's mark, and no
# sign-in. The name is fictional, because a preview library has no sign-in.
SIDEBAR = [Shot(name, ["-BookwormsTab", "library", "-BookwormsShelfMode", "shelf", *arguments], 20)
           for name, arguments in (
               ("name", ["-BookwormsAccountName", "fictional_reader"]),
               ("rejected", ["-BookwormsAccountName", "fictional_reader", "-BookwormsLibraryStatus", "reconnect"]),
               ("connect", ["-BookwormsLibraryStatus", "signedOut"]))]
SHOTS = {
    "iphone": {
        "library": LIBRARY,
        "details": DETAILS,
        "desk": DESK,
        "dominoes": DOMINOES,
        "share": [Shot(template, ["-BookwormsShareTemplate", template], 40, file="share-debug.png")
                  for template in ("yearInBooks", "topFive", "pile", "tower")],
        "spines": SPINES,
        "account": BANNER,
        "settings": [Shot("settings", ["-BookwormsShowSpines", "YES", "-BookwormsShowAccount", "YES"], 20)],
    },
    "mac": {
        "library": LIBRARY,
        "details": DETAILS,
        "desk": DESK,
        "dominoes": MAC_DOMINOES,
        "share": [Shot("studio", ["-BookwormsShareTemplate", "yearInBooks"], 40)],
        "spines": SPINES[:1],
        "account": SIDEBAR,
        "settings": [Shot("general", ["-BookwormsShowSpines", "YES", "-BookwormsShowSettings", "YES",
                                      "-BookwormsSettingsPane", "general"], 20, window="General")],
    },
}

QUESTIONS = """\
1. **Regression.** Compare before and after. Did anything get worse that the change doesn't
   explain: something missing, moved, resized, recolored, or set in another font, or a new gap?
   Physics scenes land differently on every run, so judge the rules below, not exact positions.
2. **Physical realism.** Do stacked books lie flat and level on what they rest on, touching it,
   with no gap, overlap, float, or lean on nothing? Is every book book-shaped, its spine several
   times as long as it is thick?
3. **Legible lettering.** Can you read the spine and cover titles and the app's text? Is any
   title shortened or tiny where the spine has room for it?
4. **Camera faces the action.** In 3D scenes and motion strips, does the subject stay on screen
   in every frame, with no book or card cut off by the screen's edge?
5. **Motion.** In a motion strip, does each frame follow from the one before, with no jump, no
   pop, and no book passing through another? Does a pulled book come straight out toward the
   viewer?
6. **Nothing clipped or overlapping.** Does all text and every control sit inside its container
   and the screen, with no text over other text?
7. **Mac layout.** In a Mac window, does the layout suit the sidebar and the wide window, with no
   stretched lines of text or large empty areas?
8. **No eyebrow labels.** Did the change add small, tracked, all-caps text above a title?
"""


def git(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def quiet(arguments, **options):
    return subprocess.run(list(map(str, arguments)), capture_output=True, text=True, **options)


def touched(files):
    """Returns the views that the changed `files` touch, in `SURFACES` order."""
    found = set()
    for name in files:
        if not name.startswith("Bookworms/"):
            continue
        matched = [view for pattern, views in RULES if re.search(pattern, name) for view in views]
        if not matched and re.search(DRAWS, name):
            matched = ["other"]
        found.update(matched)
    return [name for name in SURFACES if name in found]


def export(sha, work):
    """Returns a folder with the source of commit `sha` and its generated Xcode project.

    A marker file records a finished export, so a run never reuses one that was interrupted.
    """
    source = work / "source" / sha[:9]
    if not (source / ".exported").exists():
        shutil.rmtree(source, ignore_errors=True)
        source.mkdir(parents=True)
        exported = quiet(["git", "archive", "--output", source / "source.tar", sha], cwd=ROOT)
        if exported.returncode != 0 or quiet(["tar", "-xf", source / "source.tar", "-C", source]).returncode != 0:
            sys.exit(f"Couldn't export the source of {sha[:9]}: {exported.stderr.strip()}")
        quiet(["xcodegen", "generate", "--spec", "project.yml", "--quiet"], cwd=source)
        (source / ".exported").touch()
    return source


def build(sha, work, log, platform, simulator=None):
    """Builds the Debug app of commit `sha` for the iPhone simulator or the Mac and returns it.

    A marker file records a finished build, so a run never reuses one that was interrupted.
    """
    products = work / "build" / f"{sha[:9]}-{platform}"
    folder = "Debug-iphonesimulator" if platform == "iphone" else "Debug"
    app = products / "Build/Products" / folder / "Bookworms.app"
    if (products / ".built").exists():
        return app
    shutil.rmtree(products, ignore_errors=True)
    # Restricted development shells block Xcode's first-party Swift macro plugin sandbox.
    command = ["xcodebuild", "-quiet", "-project", "Bookworms.xcodeproj", "-scheme", "Bookworms",
               "-configuration", "Debug", "-derivedDataPath", str(products),
               "OTHER_SWIFT_FLAGS=-disable-sandbox"]
    if platform == "iphone":
        command += ["-destination", f"platform=iOS Simulator,id={simulator}"]
    else:
        # Signed ad hoc and without entitlements, so the copy runs outside the sandbox and
        # reads the scratch home folder that CFFIXED_USER_HOME names.
        command += ["-destination", "platform=macOS,arch=arm64", f"PRODUCT_BUNDLE_IDENTIFIER={MAC_BUNDLE_ID}",
                    "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGN_ENTITLEMENTS="]
    built = subprocess.run(command + ["build"], cwd=export(sha, work), stdout=log, stderr=subprocess.STDOUT)
    if built.returncode != 0 or not app.exists():
        sys.exit(f"The {PLATFORMS[platform]} build of {sha[:9]} failed; log {log.name}")
    (products / ".built").touch()
    return app


def load_preview(caches, workspace, log):
    """Loads the private preview library and its fonts into an app's `Caches/Bookworms` folder,
    with this checkout's loader for both commits, and returns the ID of the library's first book."""
    loaded = subprocess.run([sys.executable, ROOT / "script/load-preview-data.py", "--source", workspace,
                             "--caches", caches], stdout=log, stderr=log)
    if loaded.returncode != 0:
        sys.exit(f"load-preview-data.py failed; log {log.name}")
    return json.loads((ROOT / ".local/preview/library-v1.json").read_text())["sources"][0]["books"][0]["id"]


def motion_strip(clip, strip, scratch):
    """Reduces a recording to twelve frames in one image, then halves the recording's size.

    The frames are spaced by how much the picture changes, not by time, so most of them show
    the motion and few show a loading screen or a still view. ffmpeg's scene score measures the
    change from the frame before; a cut counts no more than a fast frame of motion (0.02), and
    change below 0.001, such as a spinner, counts as none.
    """
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    quiet(["ffmpeg", "-loglevel", "error", "-i", clip, "-vf",
           "fps=10,scale=-2:640,select='gte(scene,0)',metadata=print:file=scores.txt",
           "-fps_mode", "vfr", "-q:v", "4", "%05d.jpg"], cwd=scratch)
    frames = sorted(scratch.glob("*.jpg"))
    scores = [min(max(float(score) - 0.001, 0), 0.02)
              for score in re.findall(r"scene_score=([\d.]+)", (scratch / "scores.txt").read_text())]
    if frames and len(scores) == len(frames):
        if not sum(scores):
            scores = [1] * len(frames)
        moved = list(itertools.accumulate(scores))
        tile([frames[bisect.bisect_left(moved, moved[-1] * (index + 0.5) / 12)] for index in range(12)],
             strip, scratch, "6x2")
    shutil.rmtree(scratch, ignore_errors=True)
    small = clip.with_suffix(".small.mp4")
    quiet(["ffmpeg", "-loglevel", "error", "-y", "-i", clip, "-vf", "scale=trunc(iw/4)*2:-2", "-an",
           "-crf", "30", small])
    if small.exists():
        small.replace(clip)


def tile(frames, strip, scratch, layout):
    """Joins `frames`, in order, into one image laid out as `layout` (columns x rows)."""
    if not frames:
        return
    scratch.mkdir(parents=True, exist_ok=True)
    extension = frames[0].suffix
    for index, frame in enumerate(frames):
        shutil.copy(frame, scratch / f"tile-{index}{extension}")
    # A Mac window's picture is several times a frame's size, so every frame is at most 640 wide.
    quiet(["ffmpeg", "-loglevel", "error", "-y", "-i", scratch / f"tile-%d{extension}", "-vf",
           f"scale='min(640,iw)':-2,tile={layout}", "-frames:v", "1", strip])


def capture_iphone(simulator, shot, book, prefix):
    """Launches the simulator app for one shot and saves `<prefix>.png` and, for motion,
    `<prefix>-motion.png`."""
    arguments = ["-BookwormsPreviewFolder", "preview", "-BookwormsTips", "hide",
                 *[argument.format(book=book) for argument in shot.arguments]]
    caches = Path(quiet(["xcrun", "simctl", "get_app_container", simulator, BUNDLE_ID, "data"]).stdout.strip())
    written = caches / "Library/Caches/Bookworms" / shot.file
    quiet(["xcrun", "simctl", "terminate", simulator, BUNDLE_ID])
    if shot.file:
        written.unlink(missing_ok=True)
    recorder = None
    clip = prefix.with_name(prefix.name + ".mp4")
    if shot.motion:
        recorder = subprocess.Popen(["xcrun", "simctl", "io", simulator, "recordVideo", "--codec", "h264",
                                     "--force", str(clip)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
    quiet(["xcrun", "simctl", "launch", simulator, BUNDLE_ID, *arguments])
    time.sleep(shot.wait)
    picture = prefix.with_name(prefix.name + ".png")
    if shot.file:
        if written.exists():
            shutil.copy(written, picture)
    else:
        quiet(["xcrun", "simctl", "io", simulator, "screenshot", picture])
    if recorder:
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=60)
        motion_strip(clip, prefix.with_name(prefix.name + "-motion.png"), prefix.with_name("scratch"))
    quiet(["xcrun", "simctl", "terminate", simulator, BUNDLE_ID])


# With `displays`, prints how many displays are active. With a process ID, prints the ID and
# title of each of that process's normal windows, largest first. The script compiles it once
# per run.
WINDOWS = """
import CoreGraphics
import Foundation
if CommandLine.arguments[1] == "displays" {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    print(count)
    exit(0)
}
let pid = Int(CommandLine.arguments[1])!
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let mine = all.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
for window in mine.sorted(by: { area($0) > area($1) }) {
    print(window[kCGWindowNumber as String] as? Int ?? 0, window[kCGWindowName as String] as? String ?? "")
}
"""


def photograph(process, title, helper, picture):
    """Saves a picture of the Mac copy's window whose title contains `title`, else of its largest.

    Saves nothing when the copy has no window yet, or when no window reports a title, which
    means that Screen Recording isn't allowed and a picture would be blank.
    """
    listed = [line.split(" ", 1) for line in quiet([helper, process]).stdout.splitlines()]
    titled = [window for window in listed if len(window) == 2 and window[1]]
    if titled:
        chosen = next((window for window in titled if title and title in window[1]), titled[0])
        quiet(["screencapture", "-x", "-o", "-l", chosen[0], picture])


def forget_mac_copy():
    """Deletes the Mac copy's preferences and saved window state, so each launch starts alike."""
    for leftover in ("DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"):
        folder = Path(quiet(["getconf", leftover]).stdout.strip())
        shutil.rmtree(folder / f"{MAC_BUNDLE_ID}.savedState", ignore_errors=True)
        shutil.rmtree(folder / MAC_BUNDLE_ID, ignore_errors=True)
    quiet(["defaults", "delete", MAC_BUNDLE_ID])
    # The preferences daemon can leave an empty file behind.
    (Path.home() / "Library/Preferences" / f"{MAC_BUNDLE_ID}.plist").unlink(missing_ok=True)


def capture_mac(app, home, helper, shot, book, prefix):
    """Launches the Mac copy for one shot and photographs its window: `<prefix>.png`, or the
    shot's `file` in place of it, and, for motion, `<prefix>-motion.png`, eight pictures taken at
    even intervals."""
    forget_mac_copy()
    written = home / "Library/Caches/Bookworms" / shot.file if shot.file else None
    if written:
        written.unlink(missing_ok=True)
    arguments = ["-BookwormsPreviewFolder", "preview", "-ApplePersistenceIgnoreState", "YES",
                 "-BookwormsTips", "hide", *[argument.format(book=book) for argument in shot.arguments]]
    process = subprocess.Popen([app / "Contents/MacOS/Bookworms", *arguments],
                               env={**os.environ, "CFFIXED_USER_HOME": str(home)},
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    scratch = prefix.with_name("scratch")
    scratch.mkdir(exist_ok=True)
    try:
        stills = [scratch / f"still-{index}.png" for index in range(8)]
        for still in stills:
            time.sleep(shot.wait / 8)
            if shot.motion:
                photograph(process.pid, shot.window, helper, still)
        picture = prefix.with_name(prefix.name + ".png")
        if written:
            if written.exists():
                shutil.copy(written, picture)
            # A video's still keeps its movie beside it.
            if (movie := written.with_suffix(".mp4")).exists():
                shutil.copy(movie, picture.with_suffix(".mp4"))
        else:
            photograph(process.pid, shot.window, helper, picture)
        tile([still for still in stills if still.exists()], prefix.with_name(prefix.name + "-motion.png"),
             scratch, "4x2")
    finally:
        process.kill()
        process.wait()
        forget_mac_copy()
        shutil.rmtree(scratch, ignore_errors=True)


def pair(before, after, out):
    """Joins two screenshots side by side, before on the left."""
    if not (before.exists() and after.exists()):
        return False
    quiet(["ffmpeg", "-loglevel", "error", "-y", "-i", before, "-i", after, "-filter_complex",
           "[0]scale=-2:900[a];[1]scale=-2:900[b];[a][b]hstack", out])
    return out.exists()


def review_brief(manifest):
    lines = [
        "# Visual check", "",
        f"Change: `{manifest['base'][:9]}` (before) to `{manifest['head'][:9]}` (after).", "",
        "Commits:", *[f"- {subject}" for subject in manifest["commits"]], "",
        "Changed files:", *[f"- `{name}`" for name in manifest["files"]], "",
        "## What to do", "",
        "Read every image listed below with the Read tool; they are in this file's folder, and",
        "you need no other file. They show the owner's private library:",
        "don't copy them anywhere or quote book lists. For each shot, answer the questions that",
        "apply with PASS, FAIL, or CAN'T TELL and one line of evidence that names the image and",
        "the place in it. In a pair image, before is on the left and after is on the right. A",
        "motion image holds frames of one launch in time order, left to right, then down. On the",
        "iPhone they are chosen where the picture changes most; on the Mac they are evenly spaced.",
        "A Mac window is inactive in these captures, so gray accents there are not a finding.",
        "Judge the after images against the questions, and use the before images to find what",
        "changed. Don't judge taste, and don't guess: a detail too small to see is CAN'T TELL.", "",
        "End with a list of regressions (or \"none\"), then one line: `VERDICT: pass` when no",
        "answer is FAIL, else `VERDICT: fail`.", "",
        "## Questions", "", QUESTIONS, "## Shots", "",
    ]
    for shot in manifest["shots"]:
        lines.append(f"### {shot['platform']}: {SURFACES[shot['surface']]}, {shot['name']}")
        lines += [f"- `{image}`" for image in shot["images"]] + [""]
    if manifest["missing"]:
        lines += ["## Missing", "",
                  "These launches saved no picture, so nobody has looked at them. For the Mac, its lid",
                  "was closed, its display was asleep, or Screen Recording isn't allowed:",
                  *[f"- {name}" for name in manifest["missing"]], ""]
    if manifest["not_captured"]:
        lines += ["## Not captured", "",
                  "These touched views have no launch in this script, so nobody has looked at them:",
                  *[f"- {SURFACES[name]}" for name in manifest["not_captured"]], ""]
    lines += ["## What this check can't judge", "",
              "Taste, and how the app performs and feels on a real iPhone or Mac."]
    return "\n".join(lines) + "\n"


def record(verdict, note, allow_missing):
    """Writes or removes the visual-check marker for HEAD, which must have a bundle.

    A bundle that lacks a platform's pictures records a pass only with `allow_missing`.
    """
    sha = git("rev-parse", "HEAD")
    bundle = ROOT / ".local" / "visual-check" / sha[:9]
    try:
        manifest = json.loads((bundle / "manifest.json").read_text())
    except (OSError, ValueError):
        sys.exit(f"No bundle for {sha[:9]}. Run python3 {SCRIPTS}/visual-check.py first.")
    marker = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "premerge" / f"{sha}.visual.json"
    if verdict == "fail":
        marker.unlink(missing_ok=True)
        print(f"No visual-check marker for {sha[:9]}. Fix the regressions, commit, and capture again.")
        return
    gaps = manifest["missing"] + [f"{name} (not captured)" for key, name in PLATFORMS.items()
                                  if key not in manifest["platforms"]]
    if gaps and not allow_missing:
        sys.exit("The bundle lacks " + ", ".join(gaps) + f". Capture them with python3 {SCRIPTS}/visual-check.py "
                 "(the Mac needs its lid open, its display awake, and Screen Recording allowed), or record the pass "
                 "with --allow-missing and tell the owner which launches nobody looked at.")
    marker.parent.mkdir(exist_ok=True)
    marker.write_text(json.dumps({
        "sha": sha, "verdict": "pass", "note": note, "bundle": str(bundle),
        "surfaces": manifest["surfaces"], "not_captured": manifest["not_captured"],
        "missing": gaps,
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + "\n")
    print(f"PASS visual check {sha[:9]}; marker {marker}")
    report_gaps(manifest)


def report_gaps(manifest):
    """Prints what the bundle doesn't show, which someone must check by hand."""
    gaps = [SURFACES[name] for name in manifest["not_captured"]] + manifest["missing"]
    gaps += [f"{name} (every launch)" for key, name in PLATFORMS.items() if key not in manifest["platforms"]]
    if gaps:
        print("Not captured, so check by hand: " + ", ".join(gaps))


def capture_on_iphone(commits, wanted, work, workspace, bundle, log):
    """Runs the iPhone launches of both commits on one slim simulator, created and deleted here."""
    limit = premerge.simulator_limit()
    if limit:
        sys.exit(f"No simulator started: {limit}.")
    # The desk's knocks would play on the Mac's speakers, so simulator sound is off for the run.
    sound = quiet(["defaults", "read", *SIMULATOR_SOUND]).stdout.strip()
    quiet(["defaults", "write", *SIMULATOR_SOUND, "-bool", "false"])
    simulator = premerge.create_iphone(f"visual-check-{commits['after'][:9]}")
    try:
        # The preview launches read local files and draw with RealityKit; they need no simslim
        # category.
        problem = premerge.boot_slim(
            simulator, lambda command: subprocess.run(command, stdout=log, stderr=log).returncode)
        if problem:
            sys.exit(f"No simulator started: {problem}.")
        for label, sha in commits.items():
            app = build(sha, work, log, "iphone", simulator)
            quiet(["xcrun", "simctl", "uninstall", simulator, BUNDLE_ID])
            quiet(["xcrun", "simctl", "install", simulator, app])
            container = quiet(["xcrun", "simctl", "get_app_container", simulator, BUNDLE_ID, "data"]).stdout.strip()
            book = load_preview(Path(container) / "Library/Caches/Bookworms", workspace, log)
            for platform, surface, shot in wanted:
                if platform == "iphone":
                    print(f"capturing {label} iPhone {surface} {shot.name}", flush=True)
                    capture_iphone(simulator, shot, book, bundle / f"iphone-{surface}-{shot.name}-{label}")
    finally:
        quiet(["xcrun", "simctl", "shutdown", simulator])
        quiet(["xcrun", "simctl", "delete", simulator])
        if sound == "1":
            quiet(["defaults", "write", *SIMULATOR_SOUND, "-bool", "true"])
        elif not sound:
            quiet(["defaults", "delete", *SIMULATOR_SOUND])


def capture_on_mac(commits, wanted, work, workspace, bundle, log):
    """Runs the Mac launches of both commits in a scratch copy of the app with a scratch home."""
    helper = work / "windows"
    source = work / "windows.swift"
    source.write_text(WINDOWS)
    try:
        if subprocess.run(["swiftc", "-O", source, "-o", helper], stdout=log, stderr=log).returncode:
            sys.exit(f"Couldn't compile the window helper; log {log.name}")
        if quiet([helper, "displays"]).stdout.strip() == "0":
            # No picture of a window can be taken then; docs/investigations/mac-capture-lid-closed.md.
            print("The Mac has no active display (its lid is closed), so the Mac launches are skipped.", flush=True)
            return
        for label, sha in commits.items():
            app = build(sha, work, log, "mac")
            home = work / "mac-home"
            shutil.rmtree(home, ignore_errors=True)
            book = load_preview(home / "Library/Caches/Bookworms", workspace, log)
            for platform, surface, shot in wanted:
                if platform == "mac":
                    print(f"capturing {label} Mac {surface} {shot.name}", flush=True)
                    capture_mac(app, home, helper, shot, book, bundle / f"mac-{surface}-{shot.name}-{label}")
    finally:
        helper.unlink(missing_ok=True)
        source.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base", default="origin/main", help="commit to compare with (default: origin/main)")
    parser.add_argument("--head", default="HEAD", help="commit to check (default: HEAD)")
    parser.add_argument("--surfaces", help="comma-separated views to capture instead of the ones the diff touches: "
                        + ", ".join(SURFACES))
    parser.add_argument("--platforms", default="iphone,mac", help="platforms to capture: iphone, mac, or both")
    parser.add_argument("--list", action="store_true", help="print the views the change touches and stop")
    parser.add_argument("--record", choices=["pass", "fail"], help="record the reviewing agent's verdict for HEAD")
    parser.add_argument("--note", default="", help="with --record: one line about the review")
    parser.add_argument("--allow-missing", action="store_true",
                        help="with --record pass: accept a bundle that lacks a platform's pictures; "
                             "tell the owner which launches nobody looked at")
    parser.add_argument("--keep-builds", action="store_true", help="keep both builds for another run")
    arguments = parser.parse_args()
    if arguments.record:
        return record(arguments.record, arguments.note, arguments.allow_missing)

    head = git("rev-parse", arguments.head)
    base = git("merge-base", arguments.base, head)
    files = [name for name in git("diff", "--name-only", base, head).splitlines() if name]
    surfaces = touched(files)
    if arguments.list:
        print("\n".join(surfaces))
        return
    if arguments.surfaces:
        surfaces = arguments.surfaces.split(",")
        unknown = [name for name in surfaces if name not in SURFACES]
        if unknown:
            sys.exit(f"Unknown views: {', '.join(unknown)}. Choose from: {', '.join(SURFACES)}")
    if not surfaces:
        print(f"SKIP visual check {head[:9]}: the change touches no view.")
        return
    if head == git("rev-parse", "HEAD") and git("status", "--porcelain"):
        sys.exit("Commit or remove the uncommitted changes first: the check captures the HEAD commit.")
    platforms = arguments.platforms.split(",")
    workspace = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).parent.parent / ".local"
    if not (workspace / "device-library-refined.json").exists():
        sys.exit(f"No private preview library in {workspace}; see README-AI.md, Preview with a local library.")

    work = ROOT / ".local" / "visual-check"
    bundle = work / head[:9]
    shutil.rmtree(bundle, ignore_errors=True)
    bundle.mkdir(parents=True)
    wanted = [(platform, surface, shot) for platform in platforms for surface in surfaces
              for shot in SHOTS[platform].get(surface, [])]
    captured = {surface for _, surface, _ in wanted}
    manifest = {"head": head, "base": base, "surfaces": surfaces, "files": files, "shots": [], "missing": [],
                "platforms": platforms, "commits": git("log", "--format=%s", f"{base}..{head}").splitlines(),
                "not_captured": [name for name in surfaces if name not in captured]}
    commits = {"before": base, "after": head}
    try:
        with (bundle / "capture.log").open("w") as log:
            if any(platform == "iphone" for platform, _, _ in wanted):
                capture_on_iphone(commits, wanted, work, workspace, bundle, log)
            if any(platform == "mac" for platform, _, _ in wanted):
                capture_on_mac(commits, wanted, work, workspace, bundle, log)
    finally:
        shutil.rmtree(work / "mac-home", ignore_errors=True)
        if not arguments.keep_builds:
            shutil.rmtree(work / "build", ignore_errors=True)
            shutil.rmtree(work / "source", ignore_errors=True)
    for platform, surface, shot in wanted:
        stem = f"{platform}-{surface}-{shot.name}"
        images = [f"{stem}-before.png", f"{stem}-after.png", f"{stem}-pair.png",
                  f"{stem}-before-motion.png", f"{stem}-after-motion.png"]
        pair(bundle / images[0], bundle / images[1], bundle / images[2])
        manifest["shots"].append({"platform": PLATFORMS[platform], "surface": surface, "name": shot.name,
                                  "images": [image for image in images if (bundle / image).exists()]})
        if not all((bundle / image).exists() for image in images[:2]):
            manifest["missing"].append(f"{PLATFORMS[platform]} {SURFACES[surface]}, {shot.name}")
    lost = [name for name in manifest["missing"] if name.startswith("iPhone")]
    if lost:
        sys.exit(f"The capture failed for {', '.join(lost)}; log {bundle / 'capture.log'}")
    (bundle / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (bundle / "REVIEW.md").write_text(review_brief(manifest))
    print(f"Bundle: {bundle}")
    report_gaps(manifest)
    print(f"NEXT have a Sonnet agent follow {bundle / 'REVIEW.md'} and report; when its last line is "
          f"VERDICT: pass, run python3 {SCRIPTS}/visual-check.py --record pass")


if __name__ == "__main__":
    # A stopped run still deletes its simulator.
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    main()
