import AVFoundation

final class MetronomePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let buffer: AVAudioPCMBuffer?

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try? engine.start()
        buffer = MetronomePlayer.makeClickBuffer(format: format, duration: 0.05)
    }

    func playClick() {
        guard let buffer else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [.interruptsAtLoop], completionHandler: nil)
        player.play()
    }

    func stop() {
        player.stop()
    }

    private static func makeClickBuffer(format: AVAudioFormat, duration: Double) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let decayRate = 30.0
        let frequency = 1000.0

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-decayRate * t)
            let sample = sin(2.0 * .pi * frequency * t) * envelope
            channelData[frame] = Float(sample)
        }

        return buffer
    }
}
