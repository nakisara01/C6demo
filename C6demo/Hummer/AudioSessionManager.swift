import AVFoundation

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let session = AVAudioSession.sharedInstance()
    private let lock = NSLock()
    private var recordingSessionActive = false

    private init() {}

    func configureForPlayback() {
        lock.lock()
        guard !recordingSessionActive else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            print("AudioSessionManager playback configuration failed: \(error)")
        }
    }

    func configureForRecording() throws {
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
#if os(iOS)
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            print("AudioSessionManager overrideOutputAudioPort failed: \(error)")
        }
#endif
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        lock.lock()
        recordingSessionActive = true
        lock.unlock()
    }

    func deactivateRecordingSession() {
        lock.lock()
        let shouldRevertToPlayback = recordingSessionActive
        recordingSessionActive = false
        lock.unlock()

        guard shouldRevertToPlayback else { return }

        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("AudioSessionManager setActive(false) failed: \(error)")
        }

        configureForPlayback()
    }
}
