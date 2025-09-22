import Foundation
import Combine
import SwiftUI

@MainActor
final class HummingViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var bpmText: String = "90"
    @Published var selectedTimeSignature: TimeSignature
    @Published var analysisResult: HummingAnalysisResult?
    @Published var isAnalyzing: Bool = false
    @Published var errorMessage: String?
    @Published var recordingDuration: Double = 0
    @Published var tapBpm: Int?
    @Published var countdownText: String?
    @Published private(set) var isMetronomeRunning: Bool = false
    @Published var isMetronomeSoundEnabled: Bool = true
    @Published var metronomePulse: Bool = false

    let availableTimeSignatures: [TimeSignature] = [
        TimeSignature(upper: 2, lower: 4),
        TimeSignature(upper: 3, lower: 4),
        TimeSignature(upper: 4, lower: 4),
        TimeSignature(upper: 6, lower: 8),
        TimeSignature(upper: 5, lower: 4)
    ]

    private let analyzer = HummingAnalyzer()
    private let metronomePlayer = MetronomePlayer()
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var lastRecording: RecordingBuffer?
    private var tapTimestamps: [TimeInterval] = []
    private var lastTapDate: Date?
    private let tapResetThreshold: TimeInterval = 2.5
    private var countdownTimer: Timer?
    private var metronomeTimer: Timer?
    private var currentBpmValue: Double = 90

    init() {
        selectedTimeSignature = TimeSignature(upper: 4, lower: 4)
    }

    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .countdown:
            cancelCountdown(resetState: true)
        default:
            break
        }
    }

    func analyzeAgain() {
        guard let recording = lastRecording else { return }
        runAnalysis(with: recording)
    }

    func selectChord(_ chord: ChordPrediction?, for measure: MeasureAnalysis) {
        guard let analysis = analysisResult else { return }
        guard let targetIndex = analysis.measures.firstIndex(where: { $0.id == measure.id }) else { return }

        var updatedMeasures = analysis.measures
        let updatedMeasure = updatedMeasures[targetIndex].selectingChord(chord)
        updatedMeasures[targetIndex] = updatedMeasure
        analysisResult = HummingAnalysisResult(measures: updatedMeasures,
                                               bpm: analysis.bpm,
                                               timeSignature: analysis.timeSignature,
                                               key: analysis.key)
    }

    func toggleMetronomeSound() {
        isMetronomeSoundEnabled.toggle()
    }

    func registerTempoTap() {
        let now = Date()
        if let lastTapDate, now.timeIntervalSince(lastTapDate) > tapResetThreshold {
            tapTimestamps.removeAll()
            tapBpm = nil
        }
        lastTapDate = now

        tapTimestamps.append(now.timeIntervalSince1970)
        if tapTimestamps.count > 8 {
            tapTimestamps.removeFirst()
        }

        guard tapTimestamps.count >= 2 else { return }
        let intervals = zip(tapTimestamps, tapTimestamps.dropFirst()).map { $1 - $0 }
        let averageInterval = intervals.reduce(0, +) / Double(intervals.count)
        guard averageInterval > 0 else { return }

        let bpm = max(40, min(240, Int((60.0 / averageInterval).rounded())))
        tapBpm = bpm
        bpmText = "\(bpm)"
    }

    func resetTapTempo() {
        tapTimestamps.removeAll()
        lastTapDate = nil
        tapBpm = nil
    }

    private func startRecording() {
        errorMessage = nil
        stopMetronome()
        guard let bpm = Double(bpmText), bpm > 0 else {
            errorMessage = "BPM을 올바르게 입력해주세요."
            return
        }

        currentBpmValue = bpm
        state = .requestingPermission
        analyzer.requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                if granted {
                    do {
                        try self.analyzer.prepareForRecording()
                        self.beginCountdown()
                    } catch {
                        self.state = .idle
                        self.errorMessage = error.localizedDescription
                    }
                } else {
                    self.state = .idle
                    self.errorMessage = PitchDetectionError.microphonePermissionDenied.localizedDescription
                }
            }
        }
    }

    private func stopRecording() {
        stopMetronome()
        cancelCountdown(resetState: false)
        state = .processing
        stopDurationTimer()
        let result = analyzer.stopRecording()
        switch result {
        case .success(let buffer):
            lastRecording = buffer
            runAnalysis(with: buffer)
        case .failure(let error):
            state = .idle
            errorMessage = error.localizedDescription
        }
    }

    private func runAnalysis(with recording: RecordingBuffer) {
        let bpm = currentBpmValue
        isAnalyzing = true
        analyzer.analyze(recording: recording, bpm: bpm, timeSignature: selectedTimeSignature) { [weak self] result in
            guard let self else { return }
            self.isAnalyzing = false
            self.state = .idle
            self.stopMetronome()
            switch result {
            case .success(let analysis):
                self.analysisResult = analysis
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startDate = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(startDate)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartDate = nil
    }

    private func beginCountdown() {
        state = .countdown
        countdownTimer?.invalidate()
        let beatInterval = max(0.25, 60.0 / currentBpmValue)
        let sequence: [String] = ["3", "2", "1", "시작"]
        var index = 0
        countdownText = sequence[index]

        fireMetronomeTick()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: beatInterval, repeats: true) { [weak self] timer in
            guard let self else { return }
            index += 1
            if index < sequence.count {
                self.countdownText = sequence[index]
                self.fireMetronomeTick()
            } else {
                timer.invalidate()
                self.countdownTimer = nil
                self.countdownText = "시작"
                self.fireMetronomeTick()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.countdownText = nil
                    self.startActualRecording()
                }
            }
        }
    }

    private func cancelCountdown(resetState: Bool) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownText = nil
        metronomePulse = false
        if resetState {
            state = .idle
        }
    }

    private func startActualRecording() {
        analyzer.startRecording { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.state = .recording
                self.recordingStartDate = Date()
                self.recordingDuration = 0
                self.startDurationTimer()
                self.analysisResult = nil
                self.startMetronome()
            case .failure(let error):
                self.state = .idle
                self.errorMessage = error.localizedDescription
                self.stopMetronome()
            }
        }
    }

    private func startMetronome() {
        stopMetronome()
        guard currentBpmValue > 0 else { return }
        isMetronomeRunning = true
        fireMetronomeTick()
        let interval = 60.0 / currentBpmValue
        metronomeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fireMetronomeTick()
        }
    }

    private func fireMetronomeTick(playSound: Bool = true) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.65, blendDuration: 0.2)) {
            metronomePulse.toggle()
        }
        if playSound, isMetronomeSoundEnabled {
            metronomePlayer.playClick()
        }
    }

    private func stopMetronome() {
        metronomeTimer?.invalidate()
        metronomeTimer = nil
        isMetronomeRunning = false
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            metronomePulse = false
        }
        metronomePlayer.stop()
    }
}
