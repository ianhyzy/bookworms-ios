#!/usr/bin/env python3
"""Checks the head commit before its pull request merges, and records a pass for it.

Steps, each printed as one PASS, FAIL, or SKIP line, with full output in the log file:

  tree   the working tree has no uncommitted or untracked files, so the pass names one commit
  lint   `swift-format lint --strict` on the Swift files changed against the base
  build  Release builds for the iPhone simulator and for the Mac
  test   the unit test classes the change touches on one slim iPhone simulator, which the
         script creates and deletes (see `test_scope`); `--all-tests` runs every class
  links  relative links in the changed Markdown files

A change that touches only documentation (Markdown files, docs/, and LICENSE) skips lint,
build, and test. A change to the scripts alone skips test, and one whose code no test class names
only compiles the tests. When every step passes, the script writes `premerge/<commit>.json` in the
repository's shared Git folder, which all worktrees use. The workspace's merge gate refuses
`gh pr merge` for a head commit without that file. The file also lists the views the change
touches (script/visual-check.py --list), and the last line names the visual check for a commit
that touches any; the gate doesn't require that check.

Run it with the Bash sandbox off, because xcodebuild can't reach the Metal toolchain inside it.
Exit codes: 0 pass, 1 fail.
"""
import argparse
import datetime
import json
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).resolve().parent.relative_to(ROOT)
DOCUMENTATION = re.compile(r"(^|/)[^/]+\.md$|^docs/|^LICENSE")
LINK = re.compile(r"\]\(([^)#\s]+)(?:#[^)\s]*)?\)")
# Attributes and modifiers before a Swift declaration, which may be indented, such as in `#if`.
PREFIX = (r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|open|private|fileprivate|internal|final"
          r"|nonisolated|indirect|distributed)\s+)*")
# A type a Swift file declares or extends, as `Book` in `extension Bookworms.Book` or `extension [Book]`.
DECLARATION = re.compile(
    PREFIX + r"(?:class|struct|enum|actor|protocol|extension|typealias)\s+\[?(?:\w+\.)*([A-Z]\w*)", re.M)
TEST_CLASS = re.compile(PREFIX + r"class\s+(\w+)(?:<[^>]*>)?\s*:\s*XCTestCase", re.M)
TYPE_NAME = re.compile(r"\b[A-Z]\w*\b")


def git(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True).stdout.strip()


class Run:
    """One pre-merge run: its log, its steps' results, and the line printed for each step."""

    def __init__(self, sha):
        self.sha = sha
        self.folder = ROOT / ".local" / "premerge" / sha[:9]
        self.folder.mkdir(parents=True)
        self.log = self.folder / "premerge.log"
        self.results = {}

    def command(self, arguments):
        """Runs a command with its output appended to the log, and returns its exit code."""
        with self.log.open("a") as log:
            log.write(f"\n$ {' '.join(map(str, arguments))}\n")
            log.flush()
            return subprocess.run(arguments, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode

    def report(self, step, result, detail):
        self.results[step] = result
        print(f"{result:<4} {step:<14} {detail}", flush=True)

    def check(self, step, passed, detail):
        self.report(step, "PASS" if passed else "FAIL", detail)

    @property
    def failed(self):
        return [step for step, result in self.results.items() if result == "FAIL"]


def remove_earlier_runs():
    """Deletes earlier runs' logs and results in this checkout; one run at a time uses it.

    The build folders stay, so the next build is incremental.
    """
    for earlier in (ROOT / ".local" / "premerge").glob("*"):
        if not earlier.name.startswith("DerivedData"):
            shutil.rmtree(earlier, ignore_errors=True)


def simulator_limit():
    """Returns why one more simulator would break the workspace's simulator limits, or None.

    Checks the count and free memory once; it doesn't watch whether swap use is climbing.
    """
    booted = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"],
                            capture_output=True, text=True).stdout.count("(Booted)")
    # Without simslim the new simulator boots stock, and the limit for stock ones is four.
    if booted >= (10 if shutil.which("simslim") else 4):
        return f"{booted} simulators are already booted"
    pressure = subprocess.run(["memory_pressure", "-Q"], capture_output=True, text=True).stdout
    free = re.search(r"free percentage: (\d+)%", pressure)
    if free and int(free.group(1)) < 15:
        return f"only {free.group(1)}% of memory is free"
    return None


def broken_links(files):
    """Returns `file: target` for each relative Markdown link whose target doesn't exist."""
    broken = []
    for name in files:
        for target in LINK.findall((ROOT / name).read_text()):
            if not re.match(r"[a-z][a-z0-9+.-]*:", target) and not (ROOT / name).parent.joinpath(target).exists():
                broken.append(f"{name}: {target}")
    return broken


def build(run):
    """Builds both platforms as script/build_and_run.sh and script/run_mac.sh do, in Release."""
    run.command(["xcodegen", "generate", "--spec", "project.yml", "--quiet"])
    # Restricted development shells block Xcode's first-party Swift macro plugin sandbox.
    common = ["xcodebuild", "-quiet", "-project", "Bookworms.xcodeproj", "-scheme", "Bookworms",
              "-configuration", "Release", "CODE_SIGNING_ALLOWED=NO", "OTHER_SWIFT_FLAGS=-disable-sandbox"]
    builds = run.folder.parent
    run.check("build iPhone", run.command([
        *common, "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", str(builds / "DerivedData-ios"), "build"]) == 0, "simulator, Release")
    run.check("build Mac", run.command([
        *common, "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", str(builds / "DerivedData-mac"),
        "PRODUCT_BUNDLE_IDENTIFIER=gay.ian.Bookworms.Mac", "build"]) == 0, "Apple silicon, Release")


def create_iphone(name):
    """Creates, without booting it, the newest iPhone Pro on the newest iOS runtime; returns its ID.

    The iPhone Duo's runtimes carry a device suffix in their identifiers and aren't taken.
    """
    listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "--json", "runtimes"],
                                        capture_output=True, text=True).stdout)
    runtime = max((runtime for runtime in listing["runtimes"] if runtime["isAvailable"]
                   and re.search(r"SimRuntime\.iOS-[\d-]+$", runtime["identifier"])),
                  key=lambda runtime: tuple(map(int, runtime["version"].split("."))))
    device = max((device for device in runtime["supportedDeviceTypes"]
                  if re.fullmatch(r"iPhone \d+ Pro", device["name"])),
                 key=lambda device: int(device["name"].split()[1]))
    return subprocess.run(["xcrun", "simctl", "create", name, device["identifier"], runtime["identifier"]],
                          capture_output=True, text=True).stdout.strip()


def boot_slim(simulator, command):
    """Boots a new simulator with every simslim category of background daemons off, and waits
    until it is ready. `command` runs one command and returns its exit code.

    Returns None, or why the simulator can't be used. Without simslim the simulator boots stock.
    A simulator that simslim couldn't slim isn't used, because it may be partly slimmed.
    """
    if not shutil.which("simslim"):
        command(["xcrun", "simctl", "boot", simulator])
    elif command(["simslim", "on", simulator]) != 0:
        return "simslim couldn't slim the simulator"
    if command(["xcrun", "simctl", "bootstatus", simulator, "-b"]) != 0:
        return "the simulator didn't boot"
    return None


def test_scope(base, changed):
    """Returns the test classes that `changed`, the files changed since `base`, touches, or
    `None` for every class, with the reason; README-AI.md's Pre-merge check gives the rules.
    """
    tests = {path: path.read_text(errors="replace") for path in (ROOT / "BookwormsTests").rglob("*.swift")}
    classes = {path: TEST_CLASS.findall(text) for path, text in tests.items()}
    names = {path: set(TYPE_NAME.findall(text)) for path, text in tests.items()}
    selected = set()
    for name in changed:
        if DOCUMENTATION.search(name) or name.startswith(f"{SCRIPTS}/"):
            continue
        if not name.endswith(".swift") or not name.startswith(("Bookworms/", "BookwormsTests/")):
            return None, f"{name} isn't app or test Swift code"
        path = ROOT / name
        # A test file runs its classes, and the helpers it declares run the classes using them.
        selected.update(classes.get(path, []))
        versions = [git("show", f"{base}:{name}"), path.read_text(errors="replace") if path.is_file() else ""]
        declared = {type_name for text in versions for type_name in DECLARATION.findall(text)}
        if not declared and not classes.get(path):
            return None, f"{name} declares no type"
        selected.update(test_class for test_file, test_classes in classes.items()
                        if names[test_file] & declared for test_class in test_classes)
    return sorted(selected), "the classes that name the changed code"


def test(run, scope):
    limit = simulator_limit()
    if limit:
        return run.check("test", False, f"no simulator started: {limit}")
    simulator = create_iphone(f"premerge-{run.sha[:9]}")
    try:
        # The tests need no simslim category.
        problem = boot_slim(simulator, run.command)
        code = problem or run.command([
            "xcodebuild", "-project", "Bookworms.xcodeproj", "-scheme", "Bookworms",
            "-destination", f"platform=iOS Simulator,id={simulator}",
            "-derivedDataPath", str(run.folder.parent / "DerivedData-test"),
            "OTHER_SWIFT_FLAGS=-disable-sandbox", "test",
            *(f"-only-testing:BookwormsTests/{test_class}" for test_class in scope or [])])
    finally:
        run.command(["xcrun", "simctl", "shutdown", simulator])
        deleted = run.command(["xcrun", "simctl", "delete", simulator]) == 0
    if problem:
        return run.check("test", False, f"no tests ran: {problem}")
    counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", run.log.read_text(errors="replace"))
    executed, failures = counts[-1] if counts else ("0", "0")
    run.check("test", code == 0 and deleted and executed != "0",
              f"{executed} unit tests, {failures} failures, on one slim simulator, "
              + (f"in {len(scope)} classes: {', '.join(scope)}" if scope else "every class")
              + ("" if deleted else "; the simulator wasn't deleted"))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base", default="origin/main",
                        help="branch the pull request merges into (default: origin/main)")
    parser.add_argument("--all-tests", action="store_true",
                        help="run every test class, not only the ones the change touches")
    arguments = parser.parse_args()

    sha = git("rev-parse", "HEAD")
    remove_earlier_runs()
    run = Run(sha)
    print(f"premerge {sha[:9]} ({git('rev-parse', '--abbrev-ref', 'HEAD')}); log {run.log}", flush=True)
    dirty = git("status", "--porcelain")
    run.check("tree", not dirty, "clean" if not dirty else "commit or remove: "
              + ", ".join(line[3:] for line in dirty.splitlines()[:5]))
    if arguments.base.startswith("origin/"):
        run.command(["git", "fetch", "--quiet", "origin", arguments.base.split("/", 1)[1]])
    base = git("merge-base", arguments.base, "HEAD")
    if not base:
        run.check("base", False, f"no merge base with {arguments.base}")
    # A deleted file counts as a change to the code, but has nothing to lint or to link from.
    every_change = [name for name in git("diff", "--name-only", "--no-renames", base, "HEAD").splitlines() if name]
    code_changed = [name for name in every_change if not DOCUMENTATION.search(name)]
    changed = [name for name in every_change if (ROOT / name).is_file()]

    scope = []
    if not run.failed and not code_changed:
        for step in ("lint", "build iPhone", "build Mac", "test"):
            run.report(step, "SKIP", "documentation only")
    elif not run.failed:
        swift = [name for name in changed if name.endswith(".swift")]
        run.check("lint", not swift or run.command(
            ["xcrun", "swift-format", "lint", "--strict", "--configuration", ".swift-format", *swift]) == 0,
            f"{len(swift)} changed Swift files")
        build(run)
        scope, reason = (None, "--all-tests") if arguments.all_tests else test_scope(base, every_change)
        print(f"     {'tests':<14} {'every class' if scope is None else ', '.join(scope) or 'none'} ({reason})",
              flush=True)
        if {"build iPhone", "build Mac"} & set(run.failed):
            run.report("test", "SKIP", "the build failed")
        elif all(name.startswith(f"{SCRIPTS}/") for name in code_changed):
            run.report("test", "SKIP", f"only {SCRIPTS}/ changed")
        elif scope == []:
            # A test may still use what changed through a name the scan misses, so the tests
            # must at least compile.
            run.check("test", run.command([
                "xcodebuild", "-quiet", "-project", "Bookworms.xcodeproj", "-scheme", "Bookworms",
                "-destination", "generic/platform=iOS Simulator",
                "-derivedDataPath", str(run.folder.parent / "DerivedData-test"),
                "CODE_SIGNING_ALLOWED=NO", "OTHER_SWIFT_FLAGS=-disable-sandbox", "build-for-testing"]) == 0,
                "no test class names the changed code; the tests compile")
        else:
            test(run, scope)
    if not run.failed:
        broken = broken_links([name for name in changed if name.endswith(".md")])
        run.check("links", not broken, "; ".join(broken[:5]) or "relative links in changed Markdown resolve")

    surfaces = []
    if not run.failed:
        listed = subprocess.run([sys.executable, str(SCRIPTS / "visual-check.py"), "--list", "--base", base],
                                cwd=ROOT, capture_output=True, text=True)
        surfaces = listed.stdout.split()
        if listed.returncode != 0:
            run.check("views", False, "visual-check.py --list failed: " + listed.stderr.strip()[-200:])
    if not run.failed and (git("rev-parse", "HEAD") != sha or git("status", "--porcelain")):
        run.check("tree", False, "the source changed during the run")

    if run.failed:
        print(f"FAIL premerge {sha[:9]}: {', '.join(run.failed)} failed; log {run.log}")
        return 1
    markers = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "premerge"
    markers.mkdir(exist_ok=True)
    marker = markers / f"{sha}.json"
    marker.write_text(json.dumps({
        "sha": sha, "base": base, "steps": run.results, "visual_surfaces": surfaces,
        "test_classes": "all" if scope is None else scope,
        "passed_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}, indent=2) + "\n")
    print(f"PASS premerge {sha[:9]}; marker {marker}")
    if surfaces:
        print(f"NEXT this commit changes how {', '.join(surfaces)} look; the workspace rules ask for a "
              f"visual check before it merges: python3 {SCRIPTS}/visual-check.py")
    return 0


if __name__ == "__main__":
    # A stopped run still deletes its simulator.
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    sys.exit(main())
