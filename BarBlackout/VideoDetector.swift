import AppKit
import CoreAudio
import IOKit.pwr_mgt

/// Heuristic "is the user watching video right now" detector.
///
/// No macOS API answers this directly:
///  • MediaRemote (private) would, but Apple restricted it in macOS 15.4 —
///    non-entitled processes get nothing.
///  • CoreAudio reports audio output per process, but audio != video.
///  • IOKit's display-sleep assertion is taken specifically for *visual*
///    playback (AVPlayer.preventsDisplaySleepDuringVideoPlayback); audio-only
///    players deliberately don't take it, since music shouldn't keep the
///    screen awake.
///
/// So we AND two public signals for the frontmost app: it holds a display-sleep
/// assertion, and it is actively outputting audio. The audio gate is what drops
/// presentations and screen sharing, which take the same assertion silently.
///
/// Known tradeoff: a muted video does not register.
final class VideoDetector {

    // MARK: - Video detection

    /// True when the frontmost app is both holding a display-sleep assertion
    /// and outputting audio.
    ///
    /// Everything is scoped to the frontmost process on purpose: cmd-tabbing to
    /// another app, or pausing (which releases the assertion), both turn this
    /// false without needing to know anything about the player.
    func isVideoPlaying() -> Bool {
        guard frontAppHoldsDisplayAssertion() else { return false }
        return frontAppIsOutputtingAudio()
    }

    // MARK: - Per-process assertion check

    // IOPMCopyAssertionsByType is in IOKit but isn't bridged into Swift's module
    // overlay, so we load it at runtime via dlopen/dlsym.
    private typealias AssertionsByTypeFn =
        @convention(c) (CFString, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> IOReturn

    private static let assertionsByTypeFn: AssertionsByTypeFn? = {
        let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        guard let sym = dlsym(lib, "IOPMCopyAssertionsByType") else { return nil }
        return unsafeBitCast(sym, to: AssertionsByTypeFn.self)
    }()

    /// Checks whether the frontmost app's PID is holding a display-sleep assertion.
    /// Falls back to the aggregate check if the symbol isn't available.
    private func frontAppHoldsDisplayAssertion() -> Bool {
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return false }

        guard let fn = Self.assertionsByTypeFn else {
            // Symbol unavailable — fall back to aggregate (less accurate)
            return hasAggregateDisplayAssertion()
        }

        let types: [CFString] = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            kIOPMAssertionTypeNoDisplaySleep as CFString
        ]

        for assertionType in types {
            var raw: Unmanaged<CFDictionary>?
            guard fn(assertionType, &raw) == kIOReturnSuccess,
                  let dict = raw?.takeRetainedValue() as? [String: [[String: Any]]],
                  let list = dict[assertionType as String] else { continue }

            let match = list.contains { info in
                (info["AssertionPID"] as? Int).map { pid_t($0) == frontPID } ?? false
            }
            if match { return true }
        }
        return false
    }

    /// Aggregate fallback: any process holds a display-sleep assertion.
    private func hasAggregateDisplayAssertion() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [String: Any] else { return false }
        for key in [kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
                    kIOPMAssertionTypeNoDisplaySleep as String] {
            if let v = dict[key] as? Int, v > 0 { return true }
        }
        return false
    }

    // MARK: - Audio output check

    /// True when the frontmost app is actively playing audio.
    ///
    /// Uses the public CoreAudio process-object API (macOS 14.2+); the app
    /// target deploys to macOS 26, so no availability guard is needed.
    private func frontAppIsOutputtingAudio() -> Bool {
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return false }

        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size
        ) == noErr, size > 0 else { return false }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &objects
        ) == noErr else { return false }

        for object in objects where processID(of: object) == frontPID {
            return isRunningOutput(object)
        }
        return false
    }

    private func processID(of object: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &pid) == noErr
        else { return nil }
        return pid
    }

    private func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }
}
