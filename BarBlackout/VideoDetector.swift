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
        let pids = frontAppPIDs()
        guard !pids.isEmpty else { return false }
        guard holdsDisplayAssertion(pids) else { return false }
        return isOutputtingAudio(pids)
    }

    // MARK: - Process tree

    // Browsers don't play media in their main process. Chrome uses renderer
    // helpers (children of the main process); Safari uses WebKit WebContent
    // processes, which are NOT children — they're reparented and link back only
    // via "responsible pid". Measured here: audio from a Chrome video is
    // attributed to pid 2151 (Google Chrome Helper), whose parent is 1819
    // (Google Chrome). Matching the frontmost PID alone never sees it.
    private static let responsiblePidFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// The frontmost app's PID plus every helper process belonging to it.
    private func frontAppPIDs() -> Set<pid_t> {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return [] }

        var result: Set<pid_t> = [front]
        let procs = Self.allProcesses()

        // Descendants: children, grandchildren, ...
        var childrenOf: [pid_t: [pid_t]] = [:]
        for p in procs { childrenOf[p.ppid, default: []].append(p.pid) }
        var queue = [front]
        while let next = queue.popLast() {
            for child in childrenOf[next] ?? [] where !result.contains(child) {
                result.insert(child)
                queue.append(child)
            }
        }

        // Reparented helpers (Safari's WebContent) link back via responsible pid.
        if let fn = Self.responsiblePidFn {
            for p in procs where !result.contains(p.pid) {
                if fn(p.pid) == front { result.insert(p.pid) }
            }
        }
        return result
    }

    private static func allProcesses() -> [(pid: pid_t, ppid: pid_t)] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&name, 4, &procs, &size, nil, 0) == 0 else { return [] }

        return procs.prefix(size / stride).map {
            ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid)
        }
    }

    // MARK: - Per-process assertion check

    /// Checks whether the frontmost app's PID is holding a display-sleep assertion.
    ///
    /// Uses `IOPMCopyAssertionsByProcess`, which groups assertions by owning PID
    /// and is declared in IOKit's public headers. (Its sibling
    /// `IOPMCopyAssertionsByType` is exported but declared nowhere public, so it
    /// is private API — this asks the same question through the documented door.)
    private func holdsDisplayAssertion(_ pids: Set<pid_t>) -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPID = raw?.takeRetainedValue() as? [Int: [[String: Any]]]
        else { return false }

        // NoDisplaySleepAssertion is the legacy spelling; both appear in the
        // wild, so match either.
        let displayTypes: Set<String> = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
            kIOPMAssertionTypeNoDisplaySleep as String
        ]

        for (pid, assertions) in byPID where pids.contains(pid_t(pid)) {
            let hit = assertions.contains { assertion in
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String,
                      displayTypes.contains(type) else { return false }
                // An assertion can be registered but currently off (level 0).
                if let level = assertion[kIOPMAssertionLevelKey as String] as? Int {
                    return level > 0
                }
                return true
            }
            if hit { return true }
        }
        return false
    }

    // MARK: - Audio output check

    /// True when the frontmost app is actively playing audio.
    ///
    /// Uses the public CoreAudio process-object API introduced in macOS 14.2
    /// (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyPID`,
    /// `kAudioProcessPropertyIsRunningOutput`). The selectors are plain
    /// FourCharCode constants, so they compile at any deployment target, but on
    /// releases older than 14.2 the queries don't return meaningful data — the
    /// `#available` guard makes that requirement explicit and keeps the video
    /// heuristic from silently misbehaving if the deployment target is ever lowered.
    private func isOutputtingAudio(_ pids: Set<pid_t>) -> Bool {
        guard #available(macOS 14.2, *) else { return false }

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

        for object in objects {
            guard let pid = processID(of: object), pids.contains(pid) else { continue }
            if isRunningOutput(object) { return true }
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
