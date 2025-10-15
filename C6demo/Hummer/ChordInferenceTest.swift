#if !os(iOS)
import Foundation

@main
struct ChordInferenceSmokeTest {
    static func main() {
        let inference = ChordInference()

        let majorResult = inference.annotate(measures: makeMajorProgression())
        let minorResult = inference.annotate(measures: makeMinorProgression())

        print("==== C Major Progression ====")
        prettyPrint(result: majorResult)
        print("\n==== A Minor Progression ====")
        prettyPrint(result: minorResult)
    }

    private static func prettyPrint(result: (annotated: [MeasureAnalysis], key: KeyEstimation?)) {
        if let key = result.key {
            print("Estimated Key: \(key.tonic) \(key.mode) · confidence: \(String(format: "%.2f", key.confidence))")
        } else {
            print("Estimated Key: None")
        }

        for measure in result.annotated {
            if let chord = measure.chord {
                let suggestions = measure.chordSuggestions.map { $0.symbol }.joined(separator: ", ")
                print("Measure \(measure.index + 1): \(chord.symbol) (\(chord.degree)) | suggestions: [\(suggestions)]")
            } else {
                print("Measure \(measure.index + 1): No chord detected")
            }
        }
    }

    private static func makeMajorProgression() -> [MeasureAnalysis] {
        return [
            makeMeasure(index: 0, notes: ["C", "G", "E", "C"]),
            makeMeasure(index: 1, notes: ["F", "A", "C", "A"]),
            makeMeasure(index: 2, notes: ["G", "B", "D", "B"]),
            makeMeasure(index: 3, notes: ["C", "G", "E", "C"])
        ]
    }

    private static func makeMinorProgression() -> [MeasureAnalysis] {
        return [
            makeMeasure(index: 0, notes: ["A", "C", "E", "C"]),
            makeMeasure(index: 1, notes: ["D", "F", "A", "F"]),
            makeMeasure(index: 2, notes: ["E", "G#", "B", "G#"]),
            makeMeasure(index: 3, notes: ["A", "C", "E", "C"])
        ]
    }

    private static func makeMeasure(index: Int, notes: [String]) -> MeasureAnalysis {
        let events = notes.enumerated().map { (offset, note) -> NoteEvent in
            let midi = midiNumber(for: note)
            NoteEvent(noteName: note,
                      solfege: "-",
                      frequency: frequency(for: note),
                      midiNote: midi,
                      startBeat: Double(offset),
                      durationBeats: 1.0,
                      confidence: 0.95)
        }
        return MeasureAnalysis(index: index,
                               startTime: Double(index) * 2.0,
                               noteEvents: events)
    }

    private static func frequency(for note: String, octave: Int = 4) -> Double {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        guard let index = names.firstIndex(of: note) else { return 440 }
        let midi = 60 + index + (octave - 4) * 12
        return 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    }

    private static func midiNumber(for note: String, octave: Int = 4) -> Int {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        guard let index = names.firstIndex(of: note) else { return 60 }
        return 60 + index + (octave - 4) * 12
    }
}
#endif
