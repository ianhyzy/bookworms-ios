# Bookworms iOS instructions

This independent repository implements the Bookworms iPhone companion: Private Cloud Compute spine generation for the Apple TV app, a 3D spine viewer, and share images. Follow the workspace `AGENTS.md` one folder up for writing, documentation, comments, and review rules.

- Target iOS 27 and later. Use current SwiftUI, Swift concurrency with explicit isolation, and Swift 6 strict concurrency.
- Keep the companion read-only toward Hardcover. Its own Hardcover sign-in (OAuth device flow, read scopes only) stores the token in this device's Keychain; never sync or upload the token, and never write to Hardcover. Do not add third-party AI. Generation uses Apple's `PrivateCloudComputeLanguageModel` only.
- Preserve the CloudKit JSON contract in `Bookworms/Models/CloudContract.swift`. It must stay compatible with the tvOS repository's `SpineCloudStore.swift` and the Mac companion's `CloudContract.swift`, and the tests pin the shared digests.
- Use `project.yml` and XcodeGen for project changes. Source folders are synced, so new files need no regeneration. Run Git commands inside this folder.
- Lint edited Swift with `xcrun swift-format lint --strict` and the repository `.swift-format`. Build with `script/build_and_run.sh`. Run tests when the request calls for them.
- Use the private preview library (`script/load-preview-data.py`) for Simulator checks. It contains real reading history: keep it in `.local/` and never publish screenshots made from it. Tests use fictional fixtures.
- Unsigned or Simulator builds prove compilation and local rendering only. iCloud access, push delivery, background scheduling, and Private Cloud Compute quotas need a signed device build.
