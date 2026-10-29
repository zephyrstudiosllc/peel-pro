@main private struct Checks {
    @MainActor static func main() async {
        var failures: [String] = []
        let playback = PeelAudioPlaybackOwner()
        let voice = PeelVoiceAudioOwner()
        // NotificationCenter invokes the installed observer on main, which queues
        // a callback. Restart synchronously before that queued callback can run.
        for (notification, key, value) in [
            (AVAudioSession.interruptionNotification, AVAudioSessionInterruptionTypeKey, UInt(1)),
            (AVAudioSession.routeChangeNotification, AVAudioSessionRouteChangeReasonKey, UInt(2)),
            (AVAudioSession.routeChangeNotification, AVAudioSessionRouteChangeReasonKey, UInt(7))
        ] {
            playback.emit(notification, value: value, key: key)
            voice.emit(notification, value: value, key: key)
            playback.restart()
            voice.restart()
            try? await Task.sleep(nanoseconds: 10_000_000)
            if !playback.isStarted { failures.append("old playback notification stopped replacement audio") }
            if !voice.isStarted { failures.append("old voice notification stopped replacement audio") }
            playback.restart(); voice.restart()
            playback.emit(notification, value: value, key: key)
            voice.emit(notification, value: value, key: key)
            try? await Task.sleep(nanoseconds: 10_000_000)
            if playback.isStarted { failures.append("current playback interruption/route loss was ignored") }
            if voice.isStarted { failures.append("current voice interruption/route loss was ignored") }
            playback.restart(); voice.restart()
        }
        playback.emit(AVAudioSession.interruptionNotification, value: 0, key: AVAudioSessionInterruptionTypeKey)
        voice.emit(AVAudioSession.routeChangeNotification, value: 1, key: AVAudioSessionRouteChangeReasonKey)
        try? await Task.sleep(nanoseconds: 10_000_000)
        if !playback.isStarted || !voice.isStarted { failures.append("non-terminal notifications changed audio lifetime") }
        playback.finish(); voice.finish()
        if failures.isEmpty { print("PASS: exact audio observer generation checks") }
        else { for failure in failures { print("FAIL: \(failure)") }; exit(1) }
    }
}
