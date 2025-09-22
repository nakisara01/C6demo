import Foundation

enum PitchDetectionError: LocalizedError {
    case microphonePermissionDenied
    case engineUnavailable
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "마이크 접근 권한이 필요합니다. 설정에서 허용해주세요."
        case .engineUnavailable:
            return "오디오 엔진을 초기화하지 못했습니다. 다시 시도해주세요."
        case .emptyRecording:
            return "녹음된 데이터가 없습니다. 다시 녹음해주세요."
        }
    }
}

struct RecordingBuffer {
    let samples: [Float]
    let sampleRate: Double
    let duration: Double
}

struct PitchFrame {
    let time: Double
    let duration: Double
    let frequency: Double?
    let confidence: Double
    let amplitude: Double
}

struct NoteEvent: Identifiable {
    let id = UUID()
    let noteName: String
    let solfege: String
    let frequency: Double
    let startBeat: Double
    let durationBeats: Double
    let confidence: Double
}

struct MeasureAnalysis: Identifiable {
    let id: UUID
    let index: Int
    let startTime: Double
    let noteEvents: [NoteEvent]
    let chordSuggestions: [ChordPrediction]
    let automaticChord: ChordPrediction?
    let selectedChord: ChordPrediction?

    var chord: ChordPrediction? { selectedChord ?? automaticChord }

    init(id: UUID = UUID(),
         index: Int,
         startTime: Double,
         noteEvents: [NoteEvent],
         chordSuggestions: [ChordPrediction] = [],
         automaticChord: ChordPrediction? = nil,
         selectedChord: ChordPrediction? = nil) {
        self.id = id
        self.index = index
        self.startTime = startTime
        self.noteEvents = noteEvents
        self.chordSuggestions = chordSuggestions
        self.automaticChord = automaticChord
        self.selectedChord = selectedChord
    }

    func updatingChordSuggestions(_ suggestions: [ChordPrediction], automatic: ChordPrediction?) -> MeasureAnalysis {
        MeasureAnalysis(id: id,
                        index: index,
                        startTime: startTime,
                        noteEvents: noteEvents,
                        chordSuggestions: suggestions,
                        automaticChord: automatic,
                        selectedChord: selectedChord)
    }

    func selectingChord(_ chord: ChordPrediction?) -> MeasureAnalysis {
        MeasureAnalysis(id: id,
                        index: index,
                        startTime: startTime,
                        noteEvents: noteEvents,
                        chordSuggestions: chordSuggestions,
                        automaticChord: automaticChord,
                        selectedChord: chord)
    }
}

enum RecordingState {
    case idle
    case requestingPermission
    case countdown
    case recording
    case processing
}

struct HummingAnalysisResult {
    let measures: [MeasureAnalysis]
    let bpm: Double
    let timeSignature: TimeSignature
    let key: KeyEstimation?
}

struct TimeSignature: Hashable, Identifiable {
    let upper: Int
    let lower: Int

    var id: String { "\(upper)/\(lower)" }

    var beatsPerMeasure: Int { upper }

    func description() -> String {
        "\(upper)/\(lower)"
    }
}

enum KeyMode: String {
    case major
    case minor

    var localized: String {
        switch self {
        case .major: return "장조"
        case .minor: return "단조"
        }
    }
}

struct KeyEstimation {
    let tonic: String
    let mode: KeyMode
    let confidence: Double
}

struct ChordPrediction: Identifiable, Equatable {
    let id = UUID()
    let symbol: String
    let degree: String
    let confidence: Double
}
