import AppKit
import Foundation

// Entry point. `--selftest` runs a headless smoke test and exits; anything
// else boots the menu bar app.
if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest())
}

PawvisApp.main()
