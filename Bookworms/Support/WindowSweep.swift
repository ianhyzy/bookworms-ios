#if os(macOS) && DEBUG
    import AppKit
    import Darwin

    /// Debug hook that finds toolbar layout loops: `-BookwormsWindowSweep <from>,<to>[,<delay>]`
    /// waits `delay` seconds, 30 unless given, then resizes the main window one point at a
    /// time from `from` to `to` points wide, keeping its height. At each width it waits half a
    /// second for the toolbar to settle, then records the app's CPU use over one second, as a
    /// percentage of one core, in `Library/Caches/Bookworms/window-sweep.csv`. The window never
    /// gets narrower than its minimum, so the file records the width it took.
    ///
    /// An idle app records a few percent. A width near 100 percent is a toolbar that lays out
    /// again and again (see README-AI.md, "Check the Mac toolbar for a layout loop").
    @MainActor enum WindowSweep {
        static func startIfRequested() {
            guard let spec = UserDefaults.standard.string(forKey: "BookwormsWindowSweep")
            else { return }
            let values = spec.split(separator: ",").compactMap { Double($0) }
            guard values.count >= 2 else { return }
            Task {
                await run(from: values[0], to: values[1], delay: values.count > 2 ? values[2] : 30)
            }
        }

        private static func run(from: Double, to: Double, delay: Double) async {
            try? await Task.sleep(for: .seconds(delay))
            guard
                let window = NSApplication.shared.windows.first(where: {
                    $0.frameAutosaveName == BookwormsMenu.windowID
                })
            else { return }
            let url = URL.cachesDirectory.appending(path: "Bookworms/window-sweep.csv")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = ["width,cpu"]
            let step: Double = to < from ? -1 : 1
            for width in stride(from: from, through: to, by: step) {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true)
                try? await Task.sleep(for: .seconds(0.5))
                let clock = ContinuousClock()
                let start = clock.now
                let startCPU = cpuSeconds()
                try? await Task.sleep(for: .seconds(1))
                let elapsed = start.duration(to: clock.now) / .seconds(1)
                let percent = (cpuSeconds() - startCPU) / elapsed * 100
                lines.append("\(Int(window.frame.width)),\(Int(percent.rounded()))")
                // Written at every width, so a sweep's file shows its progress.
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }

        /// The CPU time that every thread of the app has used, in seconds.
        private static func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func seconds(_ time: timeval) -> Double {
                Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
            }
            return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        }
    }
#endif
