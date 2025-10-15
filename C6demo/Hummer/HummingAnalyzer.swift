import Foundation
import AVFoundation
import Accelerate
#if canImport(AVFAudio)
import AVFAudio
#endif

final class HummingAnalyzer {
    private let audioSession = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let recordingQueue = DispatchQueue(label: "humming.analyzer.recording")
    private let processingQueue = DispatchQueue(label: "humming.analyzer.processing", qos: .userInitiated)
    private let chordInference = ChordInference()

    private var sampleRate: Double = 44100
    private var recordedSamples: [Float] = []
    private var isRecording = false

    private let fftFrameSize = 4096
    private let fftHopSize = 1024
    private let minFrequency: Float = 70
    private let maxFrequency: Float = 1000
    private let minimumAmplitude: Float = 0.02
    private let minimumConfidence: Float = 0.15
    private let smoothingWindowRadius = 2

    func startRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isRecording else {
            completion(.success(()))
            return
        }

        requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    completion(.failure(PitchDetectionError.microphonePermissionDenied))
                }
                return
            }

            do {
                try self.configureSession()
                try self.beginEngineRecording()
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                AudioSessionManager.shared.deactivateRecordingSession()
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        requestRecordPermission(completion: completion)
    }

    func prepareForRecording() throws {
        try configureSession()
    }

    private func requestRecordPermission(completion: @escaping (Bool) -> Void) {
#if canImport(AVFAudio) && !os(macOS)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                completion(granted)
            }
        } else {
            audioSession.requestRecordPermission { granted in
                completion(granted)
            }
        }
#else
        audioSession.requestRecordPermission { granted in
            completion(granted)
        }
#endif
    }

    func stopRecording() -> Result<RecordingBuffer, Error> {
        guard isRecording else {
            return .failure(PitchDetectionError.emptyRecording)
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        AudioSessionManager.shared.deactivateRecordingSession()

        var samplesCopy: [Float] = []
        recordingQueue.sync {
            samplesCopy = self.recordedSamples
            self.recordedSamples.removeAll(keepingCapacity: true)
        }

        guard !samplesCopy.isEmpty else {
            return .failure(PitchDetectionError.emptyRecording)
        }

        let duration = Double(samplesCopy.count) / sampleRate
        let buffer = RecordingBuffer(samples: samplesCopy, sampleRate: sampleRate, duration: duration)
        return .success(buffer)
    }

    func analyze(recording: RecordingBuffer,
                 bpm: Double,
                 timeSignature: TimeSignature,
                 completion: @escaping (Result<HummingAnalysisResult, Error>) -> Void) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            do {
                let frames = try self.performPitchTracking(on: recording)
                let measures = self.buildMeasures(from: frames, bpm: bpm, timeSignature: timeSignature)
                let chorded = self.chordInference.annotate(measures: measures)
                let result = HummingAnalysisResult(measures: chorded.annotated,
                                                   bpm: bpm,
                                                   timeSignature: timeSignature,
                                                   key: chorded.key)
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func configureSession() throws {
        try AudioSessionManager.shared.configureForRecording()
    }

    func cancelRecordingPreparation() {
        guard !isRecording else { return }
        AudioSessionManager.shared.deactivateRecordingSession()
    }

    private func beginEngineRecording() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        sampleRate = inputFormat.sampleRate

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw PitchDetectionError.engineUnavailable
        }

        recordedSamples.removeAll(keepingCapacity: true)

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftHopSize), format: format) { [weak self] buffer, _ in
            guard let self,
                  let channelData = buffer.floatChannelData else { return }

            let frames = Int(buffer.frameLength)
            let channelPointer = channelData[0]

            self.recordingQueue.async {
                let pointer = UnsafeBufferPointer(start: channelPointer, count: frames)
                self.recordedSamples.append(contentsOf: pointer)
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    private func performPitchTracking(on recording: RecordingBuffer) throws -> [PitchFrame] {
        let samples = recording.samples
        guard samples.count >= fftFrameSize else {
            throw PitchDetectionError.emptyRecording
        }

        let frameSize = fftFrameSize
        let hopSize = fftHopSize
        let sampleRate = Float(recording.sampleRate)
        let totalFrames = samples.count

        let log2n = vDSP_Length(log2(Float(frameSize)))
        let frameDuration = Double(hopSize) / recording.sampleRate
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw PitchDetectionError.engineUnavailable
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        var frameBuffer = [Float](repeating: 0, count: frameSize)
        var windowedFrame = [Float](repeating: 0, count: frameSize)
        var real = [Float](repeating: 0, count: frameSize / 2)
        var imag = [Float](repeating: 0, count: frameSize / 2)
        var magnitudes = [Float](repeating: 0, count: frameSize / 2)

        let minIndex = max(1, Int((minFrequency / sampleRate) * Float(frameSize)))
        let maxIndex = min(frameSize / 2 - 1, Int((maxFrequency / sampleRate) * Float(frameSize)))

        var results: [PitchFrame] = []
        results.reserveCapacity((totalFrames - frameSize) / hopSize)

        // Slide a Hann-windowed FFT across the recording to estimate the dominant pitch per frame.
        samples.withUnsafeBufferPointer { pointer in
            let base = pointer.baseAddress!
            var offset = 0
            while offset + frameSize < totalFrames {
                frameBuffer.withUnsafeMutableBufferPointer { dest in
                    dest.baseAddress!.update(from: base + offset, count: frameSize)
                }

                var rms: Float = 0
                vDSP_rmsqv(frameBuffer, 1, &rms, vDSP_Length(frameSize))

                vDSP_vmul(frameBuffer, 1, window, 1, &windowedFrame, 1, vDSP_Length(frameSize))

                windowedFrame.withUnsafeBufferPointer { windowPointer in
                    real.withUnsafeMutableBufferPointer { realBuffer in
                        imag.withUnsafeMutableBufferPointer { imagBuffer in
                            magnitudes.withUnsafeMutableBufferPointer { magnitudesBuffer in
                                let complexPointer = UnsafeRawPointer(windowPointer.baseAddress!).bindMemory(to: DSPComplex.self, capacity: frameSize / 2)
                                var splitComplex = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                                vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(frameSize / 2))
                                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                                splitComplex.imagp[0] = 0
                                splitComplex.realp[0] = 0
                                vDSP_zvmags(&splitComplex, 1, magnitudesBuffer.baseAddress!, 1, vDSP_Length(frameSize / 2))
                            }
                        }
                    }
                }

                var peakMagnitude: Float = 0
                var peakIndex = minIndex
                var energy: Float = 0
                if maxIndex > minIndex {
                    for idx in minIndex...maxIndex {
                        let mag = magnitudes[idx]
                        energy += mag
                        if mag > peakMagnitude {
                            peakMagnitude = mag
                            peakIndex = idx
                        }
                    }
                }

                let confidence = energy > 0 ? peakMagnitude / energy : 0

                let isSilent = rms < minimumAmplitude || confidence < minimumConfidence
                let frequency: Double? = isSilent ? nil : Double(Float(peakIndex) * sampleRate / Float(frameSize))
                let time = Double(offset) / Double(sampleRate)
                let frame = PitchFrame(time: time,
                                       duration: frameDuration,
                                       frequency: frequency,
                                       confidence: Double(confidence),
                                       amplitude: Double(rms))
                results.append(frame)

                offset += hopSize
            }
        }

        return smoothFrequencies(in: results)
    }

    private func buildMeasures(from frames: [PitchFrame],
                               bpm: Double,
                               timeSignature: TimeSignature) -> [MeasureAnalysis] {
        guard !frames.isEmpty else { return [] }

        let beatUnit = 4.0 / Double(timeSignature.lower)
        let secondsPerBeat = (60.0 / bpm) * beatUnit
        let measureDuration = Double(timeSignature.upper) * secondsPerBeat

        var measures: [Int: [PitchFrame]] = [:]
        for frame in frames {
            let measureIndex = max(0, Int(frame.time / measureDuration))
            measures[measureIndex, default: []].append(frame)
        }

        let sortedKeys = measures.keys.sorted()
        var results: [MeasureAnalysis] = []

        for key in sortedKeys {
            guard let measureFrames = measures[key], !measureFrames.isEmpty else { continue }
            let measureStartTime = Double(key) * measureDuration

            var events: [NoteEvent] = []
            var currentNote: String?
            var currentSolfege: String = ""
            var currentFrequencySum: Double = 0
            var currentConfidenceSum: Double = 0
            var currentFrameCount = 0
            var currentStartTime: Double = 0

            func finalizeCurrentEvent(finalTime: Double) {
                guard let noteName = currentNote, currentFrameCount > 0 else { return }
                let avgFrequency = currentFrequencySum / Double(currentFrameCount)
                let avgConfidence = currentConfidenceSum / Double(currentFrameCount)
                let midiNote = midiNoteNumber(for: avgFrequency)
                let durationSeconds = finalTime - currentStartTime
                let startBeat = (currentStartTime - measureStartTime) / secondsPerBeat
                let durationBeats = durationSeconds / secondsPerBeat
                guard durationBeats > 0.05 else { return }
                let event = NoteEvent(noteName: noteName,
                                      solfege: currentSolfege,
                                      frequency: avgFrequency,
                                      midiNote: midiNote,
                                      startBeat: startBeat,
                                      durationBeats: durationBeats,
                                      confidence: avgConfidence)
                events.append(event)
                currentNote = nil
                currentSolfege = ""
                currentFrequencySum = 0
                currentConfidenceSum = 0
                currentFrameCount = 0
            }

            // Merge consecutive frames that resolve to the same note so we can represent sustained tones cleanly.
            for frame in measureFrames {
                let timestamp = frame.time
                if let frequency = frame.frequency {
                    let mapping = noteName(for: frequency)
                    if mapping.note == currentNote {
                        currentFrequencySum += frequency
                        currentConfidenceSum += frame.confidence
                        currentFrameCount += 1
                    } else {
                        finalizeCurrentEvent(finalTime: timestamp)
                        currentNote = mapping.note
                        currentSolfege = mapping.solfege
                        currentFrequencySum = frequency
                        currentConfidenceSum = frame.confidence
                        currentFrameCount = 1
                        currentStartTime = timestamp
                    }
                } else {
                    finalizeCurrentEvent(finalTime: timestamp)
                }
            }

            if let lastFrame = measureFrames.last {
                finalizeCurrentEvent(finalTime: lastFrame.time + lastFrame.duration)
            }

            let analysis = MeasureAnalysis(index: key,
                                           startTime: measureStartTime,
                                           noteEvents: events)
            results.append(analysis)
        }

        return results
    }

    private func midiNoteNumber(for frequency: Double) -> Int {
        guard frequency > 0 else { return -1 }
        let midi = 69 + 12 * log2(frequency / 440.0)
        return Int(midi.rounded())
    }

    private func noteName(for frequency: Double) -> (note: String, solfege: String) {
        guard frequency > 0 else {
            return ("-", "-")
        }

        let midi = 69 + 12 * log2(frequency / 440.0)
        let rounded = Int(round(midi))
        let noteIndex = (rounded % 12 + 12) % 12
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let solfege = ["도", "도#", "레", "레#", "미", "파", "파#", "솔", "솔#", "라", "라#", "시"]
        return (noteNames[noteIndex], solfege[noteIndex])
    }

    private func smoothFrequencies(in frames: [PitchFrame]) -> [PitchFrame] {
        guard smoothingWindowRadius > 0 else { return frames }
        var smoothed: [PitchFrame] = []
        smoothed.reserveCapacity(frames.count)

        for index in frames.indices {
            let frame = frames[index]
            var refinedFrequency = frame.frequency

            if let frequency = frame.frequency {
                let start = max(0, index - smoothingWindowRadius)
                let end = min(frames.count - 1, index + smoothingWindowRadius)

                var neighborFrequencies: [Double] = []
                neighborFrequencies.reserveCapacity(end - start + 1)

                for neighborIndex in start...end {
                    let neighbor = frames[neighborIndex]
                    if neighbor.confidence >= Double(minimumConfidence),
                       let neighborFrequency = neighbor.frequency {
                        neighborFrequencies.append(neighborFrequency)
                    }
                }

                if neighborFrequencies.count >= 3 {
                    neighborFrequencies.sort()
                    let median = neighborFrequencies[neighborFrequencies.count / 2]
                    let smoothedFrequency = 0.35 * frequency + 0.65 * median

                    if let previous = smoothed.last?.frequency, previous > 0 {
                        let semitoneDelta = abs(log2(smoothedFrequency / previous) * 12.0)
                        if semitoneDelta > 10 && frame.confidence < 0.25 {
                            refinedFrequency = nil
                        } else {
                            refinedFrequency = smoothedFrequency
                        }
                    } else {
                        refinedFrequency = smoothedFrequency
                    }
                }
            }

            let newFrame = PitchFrame(time: frame.time,
                                      duration: frame.duration,
                                      frequency: refinedFrequency,
                                      confidence: frame.confidence,
                                      amplitude: frame.amplitude)
            smoothed.append(newFrame)
        }

        return smoothed
    }
}
