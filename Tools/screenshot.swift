#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

// ------------------------------------------------------------------
// screenshot.swift – Capture a screenshot of the Scout app window
// ------------------------------------------------------------------
// Usage: swift Tools/screenshot.swift
// Requires: build/Scout.app (run `make app` first)
// Output:   docs/screenshot.png
// ------------------------------------------------------------------

let appPath = "build/Scout.app"
let outputPath = "docs/screenshot.png"
let appName = "Scout"

// ------------------------------------------------------------------
// 1. Ensure the .app bundle exists
// ------------------------------------------------------------------
guard FileManager.default.fileExists(atPath: appPath) else {
    fputs("Error: \(appPath) not found. Run `make app` first.\n", stderr)
    exit(1)
}

// ------------------------------------------------------------------
// 2. Ensure docs/ directory exists
// ------------------------------------------------------------------
let docsDir = (outputPath as NSString).deletingLastPathComponent
if !FileManager.default.fileExists(atPath: docsDir) {
    do {
        try FileManager.default.createDirectory(
            atPath: docsDir,
            withIntermediateDirectories: true
        )
    } catch {
        fputs("Error: Could not create \(docsDir): \(error)\n", stderr)
        exit(1)
    }
}

// ------------------------------------------------------------------
// 3. Launch the app
// ------------------------------------------------------------------
let launchProcess = Process()
launchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
launchProcess.arguments = [appPath]
do {
    try launchProcess.run()
    launchProcess.waitUntilExit()
} catch {
    fputs("Error: Could not launch \(appPath): \(error)\n", stderr)
    exit(1)
}

guard launchProcess.terminationStatus == 0 else {
    fputs("Error: `open \(appPath)` exited with status \(launchProcess.terminationStatus)\n", stderr)
    exit(1)
}

// ------------------------------------------------------------------
// 4. Wait for the window to appear (up to 10 seconds)
// ------------------------------------------------------------------
var windowID: UInt32 = 0
let maxAttempts = 20 // 10 seconds at 0.5s intervals

for attempt in 1 ... maxAttempts {
    Thread.sleep(forTimeInterval: 0.5)

    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        continue
    }

    for window in windowList {
        guard
            let ownerName = window[kCGWindowOwnerName as String] as? String,
            ownerName == appName,
            let wID = window[kCGWindowNumber as String] as? UInt32,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let width = bounds["Width"] as? Double,
            width > 100 // Skip tiny or accessory windows
        else { continue }

        windowID = wID
        break
    }

    if windowID != 0 {
        print("Found \(appName) window (ID \(windowID)) after \(attempt) attempts")
        break
    }
}

// ------------------------------------------------------------------
// Helper: terminate Scout regardless of outcome
// ------------------------------------------------------------------
func terminateScout() {
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    kill.arguments = ["-x", appName]
    try? kill.run()
    kill.waitUntilExit()
}

guard windowID != 0 else {
    fputs("Error: Could not find \(appName) window after 10 seconds\n", stderr)
    terminateScout()
    exit(1)
}

// ------------------------------------------------------------------
// 5. Wait for content to finish rendering
// ------------------------------------------------------------------
Thread.sleep(forTimeInterval: 2.0)

// ------------------------------------------------------------------
// 6. Capture the screenshot via ScreenCaptureKit
// ------------------------------------------------------------------
// Requires screen recording permission in System Settings > Privacy
// & Security > Screen & System Audio Recording. Grant access to
// Terminal (or whichever app runs this script).
let semaphore = DispatchSemaphore(value: 0)
var captureError: String?

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        guard let scWindow = content.windows.first(where: {
            $0.owningApplication?.applicationName == appName
                && $0.frame.width > 100
        }) else {
            captureError = "Could not find Scout window in ScreenCaptureKit"
            semaphore.signal()
            return
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width) * 2 // Retina
        config.height = Int(scWindow.frame.height) * 2
        config.captureResolution = .best
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let outputURL = URL(fileURLWithPath: outputPath)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, "public.png" as CFString, 1, nil
        ) else {
            captureError = "Could not create image destination at \(outputPath)"
            semaphore.signal()
            return
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            captureError = "Failed to write PNG to \(outputPath)"
            semaphore.signal()
            return
        }
    } catch {
        captureError = "ScreenCaptureKit error: \(error.localizedDescription)\n"
            + "Grant screen recording permission to your terminal in:\n"
            + "System Settings > Privacy & Security > Screen & System Audio Recording"
    }
    semaphore.signal()
}

semaphore.wait()

if let error = captureError {
    fputs("Error: \(error)\n", stderr)
    terminateScout()
    exit(1)
}

// ------------------------------------------------------------------
// 7. Terminate the app
// ------------------------------------------------------------------
terminateScout()

// ------------------------------------------------------------------
// 8. Verify the screenshot was created
// ------------------------------------------------------------------
guard FileManager.default.fileExists(atPath: outputPath) else {
    fputs("Error: Screenshot file was not created at \(outputPath)\n", stderr)
    exit(1)
}

print("Screenshot saved to \(outputPath)")
