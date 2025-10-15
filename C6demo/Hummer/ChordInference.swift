import Foundation

final class ChordInference {
    private enum Mode {
        case major
        case minor
    }

    private struct KeyCandidate {
        let tonic: Int
        let mode: Mode
        let score: Double
    }

    private struct KeyResult {
        let best: KeyCandidate
        let alternateScore: Double
    }

    private struct CandidateScore {
        let template: ChordTemplate
        let coverage: Double
        let rootWeight: Double
        let thirdWeight: Double
        let seventhWeight: Double?
        let penalty: Double

        var baseConfidence: Double {
            var raw = (coverage * 0.6) + (rootWeight * 0.2) + (thirdWeight * 0.15) - (penalty * 0.4)
            if let seventhWeight {
                raw += seventhWeight * 0.1
            }
            return max(0, raw)
        }
    }

    private struct MeasureChordData {
        let candidates: [CandidateScore]
        let histogram: [Double]
        let totalWeight: Double
    }

    private struct ChordTemplate {
        let root: Int
        let quality: Quality
        let degree: String
        let progressionTag: String

        enum Quality {
            case majorTriad
            case minorTriad
            case diminishedTriad
            case majorSeventh
            case dominantSeventh
            case minorSeventh
            case halfDiminishedSeventh

            var symbolSuffix: String {
                switch self {
                case .majorTriad:
                    return ""
                case .minorTriad:
                    return "m"
                case .diminishedTriad:
                    return "°"
                case .majorSeventh:
                    return "maj7"
                case .dominantSeventh:
                    return "7"
                case .minorSeventh:
                    return "m7"
                case .halfDiminishedSeventh:
                    return "ø7"
                }
            }
        }

        func chordTones() -> [Int] { // root 음 기반 코드 구성음 찾기 함수 (ex. root가 0=(C)일 경우, majorTriad = [0, 4, 7] -> C, E, G, minorSeventh = [0, 3, 7, 10] -> C, D#, G, A# 등)
            switch quality {
            case .majorTriad:
                return [root, (root + 4) % 12, (root + 7) % 12]
            case .minorTriad:
                return [root, (root + 3) % 12, (root + 7) % 12]
            case .diminishedTriad:
                return [root, (root + 3) % 12, (root + 6) % 12]
            case .majorSeventh:
                return [root, (root + 4) % 12, (root + 7) % 12, (root + 11) % 12]
            case .dominantSeventh:
                return [root, (root + 4) % 12, (root + 7) % 12, (root + 10) % 12]
            case .minorSeventh:
                return [root, (root + 3) % 12, (root + 7) % 12, (root + 10) % 12]
            case .halfDiminishedSeventh:
                return [root, (root + 3) % 12, (root + 6) % 12, (root + 10) % 12]
            }
        }
    }

    private let majorProfile: [Double] = [
        6.35, 2.23, 3.48, 2.33,
        4.38, 4.09, 2.52, 5.19,
        2.39, 3.66, 2.29, 2.88
    ]

    private let minorProfile: [Double] = [
        6.33, 2.68, 3.52, 5.38,
        2.60, 3.53, 2.54, 4.75,
        3.98, 2.69, 3.34, 3.17
    ]

    private let noteIndexMap: [String: Int] = [
        "C": 0, "C#": 1, "Db": 1,
        "D": 2, "D#": 3, "Eb": 3,
        "E": 4, "Fb": 4, "E#": 5,
        "F": 5, "F#": 6, "Gb": 6,
        "G": 7, "G#": 8, "Ab": 8,
        "A": 9, "A#": 10, "Bb": 10,
        "B": 11, "Cb": 11
    ]

    private let pitchClassNames: [String] = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
    ]

    private struct ChordSelection {
        let prediction: ChordPrediction?
        let template: ChordTemplate?
        let suggestions: [ChordPrediction]
    }

    func annotate(measures: [MeasureAnalysis]) -> (annotated: [MeasureAnalysis], key: KeyEstimation?) {
        guard !measures.isEmpty else {
            return (measures, nil)
        }

        let keyResult = detectKey(from: measures)
        let keyEstimation = keyResult.flatMap { makeKeyEstimation(from: $0) }
        var annotatedMeasures: [MeasureAnalysis] = []
        annotatedMeasures.reserveCapacity(measures.count)

        guard let keyCandidate = keyResult?.best else {
            for measure in measures {
                annotatedMeasures.append(MeasureAnalysis(id: measure.id,
                                                         index: measure.index,
                                                         startTime: measure.startTime,
                                                         noteEvents: measure.noteEvents))
            }
            return (annotatedMeasures, keyEstimation)
        }

        var previousTemplate: ChordTemplate?

        for measure in measures {
            guard let data = chordCandidates(for: measure, key: keyCandidate) else {
                annotatedMeasures.append(MeasureAnalysis(id: measure.id,
                                                         index: measure.index,
                                                         startTime: measure.startTime,
                                                         noteEvents: measure.noteEvents))
                continue
            }

            let selection = selectChord(using: data, previous: previousTemplate, key: keyCandidate)
            annotatedMeasures.append(MeasureAnalysis(id: measure.id,
                                                     index: measure.index,
                                                     startTime: measure.startTime,
                                                     noteEvents: measure.noteEvents,
                                                     chordSuggestions: selection.suggestions,
                                                     automaticChord: selection.prediction,
                                                     selectedChord: nil))
            if let template = selection.template {
                previousTemplate = template
            }
        }

        return (annotatedMeasures, keyEstimation)
    }

    private func detectKey(from measures: [MeasureAnalysis]) -> KeyResult? {
        var histogram = Array(repeating: 0.0, count: 12)
        for measure in measures {
            for event in measure.noteEvents {
                guard let pitchClass = noteIndexMap[event.noteName] else { continue }
                histogram[pitchClass] += event.durationBeats
            }
        }

        guard histogram.contains(where: { $0 > 0 }) else {
            return nil
        }

        let majorCandidate = bestKeyCandidate(histogram: histogram, profile: majorProfile, mode: .major)
        let minorCandidate = bestKeyCandidate(histogram: histogram, profile: minorProfile, mode: .minor)

        if let majorCandidate, let minorCandidate {
            let diff = abs(majorCandidate.score - minorCandidate.score)
            let relativeGap = diff / max(majorCandidate.score, minorCandidate.score)
            if relativeGap < 0.12 {
                let majorRootWeight = histogram[majorCandidate.tonic]
                let minorRootWeight = histogram[minorCandidate.tonic]
                if majorRootWeight >= minorRootWeight {
                    return KeyResult(best: majorCandidate, alternateScore: minorCandidate.score)
                } else {
                    return KeyResult(best: minorCandidate, alternateScore: majorCandidate.score)
                }
            }
            if majorCandidate.score >= minorCandidate.score {
                return KeyResult(best: majorCandidate, alternateScore: minorCandidate.score)
            } else {
                return KeyResult(best: minorCandidate, alternateScore: majorCandidate.score)
            }
        }

        if let majorCandidate {
            return KeyResult(best: majorCandidate, alternateScore: 0)
        }

        if let minorCandidate {
            return KeyResult(best: minorCandidate, alternateScore: 0)
        }

        return nil
    }

    private func bestKeyCandidate(histogram: [Double], profile: [Double], mode: Mode) -> KeyCandidate? {
        var bestCandidate: KeyCandidate?

        for tonic in 0..<12 {
            var score: Double = 0
            for index in 0..<12 {
                let profileIndex = (index - tonic + 12) % 12
                score += histogram[index] * profile[profileIndex]
            }
            if let currentBest = bestCandidate {
                if score > currentBest.score {
                    bestCandidate = KeyCandidate(tonic: tonic, mode: mode, score: score)
                }
            } else {
                bestCandidate = KeyCandidate(tonic: tonic, mode: mode, score: score)
            }
        }

        return bestCandidate
    }

    private func chordCandidates(for measure: MeasureAnalysis, key: KeyCandidate) -> MeasureChordData? {
        let events = measure.noteEvents
        guard !events.isEmpty else { return nil }

        var histogram = Array(repeating: 0.0, count: 12)
        var totalWeight: Double = 0
        for event in events {
            guard let pitchClass = noteIndexMap[event.noteName] else { continue }
            histogram[pitchClass] += event.durationBeats
            totalWeight += event.durationBeats
        }

        guard totalWeight > 0 else { return nil }

        let scale = diatonicScale(for: key)
        let chords = diatonicChords(for: key, scale: scale)

        let candidates: [CandidateScore] = chords.compactMap { template in
            let chordTones = template.chordTones()
            let chordToneWeight = chordTones.reduce(0.0) { partial, tone in
                partial + histogram[tone]
            }
            let coverage = chordToneWeight / totalWeight
            let rootWeight = histogram[template.root] / totalWeight
            let thirdPitch = chordTones[1]
            let thirdWeight = histogram[thirdPitch] / totalWeight
            let seventhWeight: Double?
            if chordTones.count > 3 {
                let seventhPitch = chordTones[3]
                seventhWeight = histogram[seventhPitch] / totalWeight
            } else {
                seventhWeight = nil
            }

            var penalty: Double = 0
            for index in 0..<12 where histogram[index] > 0 {
                if !scale.contains(index) {
                    penalty += histogram[index]
                }
            }
            penalty = penalty / totalWeight

            let candidate = CandidateScore(template: template,
                                           coverage: coverage,
                                           rootWeight: rootWeight,
                                           thirdWeight: thirdWeight,
                                           seventhWeight: seventhWeight,
                                           penalty: penalty)

            return candidate.baseConfidence >= 0.15 ? candidate : nil
        }

        return MeasureChordData(candidates: candidates, histogram: histogram, totalWeight: totalWeight)
    }

    private func selectChord(using data: MeasureChordData,
                             previous: ChordTemplate?,
                             key: KeyCandidate) -> ChordSelection {
        if data.candidates.isEmpty {
            if let previous {
                let reuse = reuseConfidence(previous: previous,
                                            histogram: data.histogram,
                                            totalWeight: data.totalWeight)
                if reuse >= 0.3 {
                    let prediction = makePrediction(from: previous, confidence: clamp(reuse))
                    return ChordSelection(prediction: prediction,
                                          template: previous,
                                          suggestions: [prediction])
                }
            }
            return ChordSelection(prediction: nil, template: previous, suggestions: [])
        }

        let scale = diatonicScale(for: key)
        var best: (score: Double, candidate: CandidateScore)?
        var scoredCandidates: [(candidate: CandidateScore, score: Double)] = []
        for candidate in data.candidates {
            var score = candidate.baseConfidence
            if let previous {
                score += transitionBonus(from: previous, to: candidate.template)
                score += sharedToneBonus(previous: previous, next: candidate.template) * 0.05
            }

            score -= chromaticPenalty(histogram: data.histogram,
                                      totalWeight: data.totalWeight,
                                      chord: candidate.template,
                                      scale: scale) * 0.1

            score = clamp(score)
            scoredCandidates.append((candidate, score))

            if let current = best {
                if score > current.score {
                    best = (score, candidate)
                }
            } else {
                best = (score, candidate)
            }
        }

        let suggestions = scoredCandidates
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { makePrediction(from: $0.candidate.template, confidence: $0.score) }

        if let best, best.score >= 0.25 {
            let prediction = makePrediction(from: best.candidate.template, confidence: best.score)
            return ChordSelection(prediction: prediction,
                                  template: best.candidate.template,
                                  suggestions: ensureSuggestionListContains(prediction, in: suggestions))
        }

        if let previous {
            let reuse = reuseConfidence(previous: previous,
                                        histogram: data.histogram,
                                        totalWeight: data.totalWeight)
            if reuse >= 0.3 {
                let prediction = makePrediction(from: previous, confidence: clamp(reuse))
                return ChordSelection(prediction: prediction,
                                      template: previous,
                                      suggestions: ensureSuggestionListContains(prediction, in: suggestions))
            }
        }

        return ChordSelection(prediction: nil,
                              template: previous,
                              suggestions: suggestions)
    }

    private func transitionBonus(from previous: ChordTemplate, to next: ChordTemplate) -> Double {
        let key = "\(previous.progressionTag)->\(next.progressionTag)"
        let progressionBonus: [String: Double] = [
            "V->I": 0.18,
            "V->vi": 0.08,
            "ii->V": 0.15,
            "IV->V": 0.12,
            "I->IV": 0.1,
            "I->V": 0.08,
            "vi->ii": 0.09,
            "iii->vi": 0.08,
            "IV->I": 0.14,
            "ii->I": 0.07,
            "i->iv": 0.1,
            "iv->V": 0.12,
            "V->i": 0.18
        ]

        var bonus = progressionBonus[key] ?? 0

        if previous.progressionTag == next.progressionTag {
            bonus += 0.06
        }

        let rootInterval = minimumSemitoneDistance(from: previous.root, to: next.root)
        if rootInterval >= 7 {
            bonus -= 0.05
        }

        if rootInterval >= 5 && sharedToneBonus(previous: previous, next: next) == 0 {
            bonus -= 0.04
        }

        return bonus
    }

    private func sharedToneBonus(previous: ChordTemplate, next: ChordTemplate) -> Double {
        let prevSet = Set(previous.chordTones())
        let nextSet = Set(next.chordTones())
        guard !prevSet.isEmpty else { return 0 }
        let shared = prevSet.intersection(nextSet)
        return Double(shared.count) / Double(prevSet.count)
    }

    private func reuseConfidence(previous: ChordTemplate,
                                 histogram: [Double],
                                 totalWeight: Double) -> Double {
        let tones = previous.chordTones()
        let weight = tones.reduce(0.0) { partial, tone in
            partial + histogram[tone]
        }
        return (weight / totalWeight) * 0.6
    }

    private func chromaticPenalty(histogram: [Double],
                                  totalWeight: Double,
                                  chord: ChordTemplate,
                                  scale: Set<Int>) -> Double {
        let tones = Set(chord.chordTones())
        var penalty: Double = 0
        for index in 0..<12 where histogram[index] > 0 {
            if !scale.contains(index) && !tones.contains(index) {
                penalty += histogram[index]
            }
        }
        return penalty / totalWeight
    }

    private func makePrediction(from template: ChordTemplate, confidence: Double) -> ChordPrediction {
        let symbol = chordSymbol(for: template)
        return ChordPrediction(symbol: symbol,
                               degree: template.degree,
                               confidence: clamp(confidence))
    }

    private func ensureSuggestionListContains(_ prediction: ChordPrediction,
                                              in suggestions: [ChordPrediction]) -> [ChordPrediction] {
        if suggestions.contains(where: { $0.symbol == prediction.symbol && $0.degree == prediction.degree }) {
            return suggestions
        }
        var updated = suggestions
        updated.insert(prediction, at: 0)
        return updated
    }

    private func diatonicScale(for key: KeyCandidate) -> Set<Int> { // KeyCandidate에서 입력된 키를 기반으로 스케일 생성
        let majorIntervals = [0, 2, 4, 5, 7, 9, 11]
        let minorIntervals = [0, 2, 3, 5, 7, 8, 10]
        let intervals = key.mode == .major ? majorIntervals : minorIntervals
        return Set(intervals.map { (key.tonic + $0) % 12 })
    }

    private func diatonicChords(for key: KeyCandidate, scale: Set<Int>) -> [ChordTemplate] {
        struct Entry {
            let offset: Int
            let quality: ChordTemplate.Quality
            let degree: String
            let progressionTag: String
        }

        let triadsMajor: [Entry] = [
            Entry(offset: 0, quality: .majorTriad, degree: "I", progressionTag: "I"),
            Entry(offset: 2, quality: .minorTriad, degree: "ii", progressionTag: "ii"),
            Entry(offset: 4, quality: .minorTriad, degree: "iii", progressionTag: "iii"),
            Entry(offset: 5, quality: .majorTriad, degree: "IV", progressionTag: "IV"),
            Entry(offset: 7, quality: .majorTriad, degree: "V", progressionTag: "V"),
            Entry(offset: 9, quality: .minorTriad, degree: "vi", progressionTag: "vi"),
            Entry(offset: 11, quality: .diminishedTriad, degree: "vii°", progressionTag: "vii°")
        ]

        let seventhsMajor: [Entry] = [
            Entry(offset: 0, quality: .majorSeventh, degree: "Imaj7", progressionTag: "I"),
            Entry(offset: 2, quality: .minorSeventh, degree: "ii7", progressionTag: "ii"),
            Entry(offset: 4, quality: .minorSeventh, degree: "iii7", progressionTag: "iii"),
            Entry(offset: 5, quality: .majorSeventh, degree: "IVmaj7", progressionTag: "IV"),
            Entry(offset: 7, quality: .dominantSeventh, degree: "V7", progressionTag: "V"),
            Entry(offset: 9, quality: .minorSeventh, degree: "vi7", progressionTag: "vi"),
            Entry(offset: 11, quality: .halfDiminishedSeventh, degree: "viiø7", progressionTag: "vii°")
        ]

        let triadsMinor: [Entry] = [
            Entry(offset: 0, quality: .minorTriad, degree: "i", progressionTag: "i"),
            Entry(offset: 2, quality: .diminishedTriad, degree: "ii°", progressionTag: "ii°"),
            Entry(offset: 3, quality: .majorTriad, degree: "III", progressionTag: "III"),
            Entry(offset: 5, quality: .minorTriad, degree: "iv", progressionTag: "iv"),
            Entry(offset: 7, quality: .minorTriad, degree: "v", progressionTag: "v"),
            Entry(offset: 8, quality: .majorTriad, degree: "VI", progressionTag: "VI"),
            Entry(offset: 10, quality: .majorTriad, degree: "VII", progressionTag: "VII")
        ]

        let seventhsMinor: [Entry] = [
            Entry(offset: 0, quality: .minorSeventh, degree: "i7", progressionTag: "i"),
            Entry(offset: 2, quality: .halfDiminishedSeventh, degree: "iiø7", progressionTag: "ii°"),
            Entry(offset: 3, quality: .majorSeventh, degree: "IIImaj7", progressionTag: "III"),
            Entry(offset: 5, quality: .minorSeventh, degree: "iv7", progressionTag: "iv"),
            Entry(offset: 7, quality: .dominantSeventh, degree: "V7", progressionTag: "V"),
            Entry(offset: 8, quality: .majorSeventh, degree: "VImaj7", progressionTag: "VI"),
            Entry(offset: 10, quality: .dominantSeventh, degree: "VII7", progressionTag: "VII")
        ]

        var entries: [Entry]
        if key.mode == .major {
            entries = triadsMajor + seventhsMajor
        } else {
            entries = triadsMinor + seventhsMinor
        }

        var chords: [ChordTemplate] = entries.map { entry in
            let root = (key.tonic + entry.offset) % 12
            return ChordTemplate(root: root,
                                 quality: entry.quality,
                                 degree: entry.degree,
                                 progressionTag: entry.progressionTag)
        }

        if key.mode == .minor {
            // Include dominant major triad as common harmonic borrowing if not already included.
            let dominantRoot = (key.tonic + 7) % 12
            let dominantTriad = ChordTemplate(root: dominantRoot,
                                              quality: .majorTriad,
                                              degree: "V",
                                              progressionTag: "V")
            if !chords.contains(where: { $0.root == dominantTriad.root && $0.quality == dominantTriad.quality }) {
                chords.append(dominantTriad)
            }
        }

        chords = chords.filter { template in
            if key.mode == .minor && template.progressionTag == "V" {
                return true
            }
            let tones = template.chordTones()
            return tones.allSatisfy { scale.contains($0) }
        }

        return chords
    }

    private func chordSymbol(for template: ChordTemplate) -> String {
        let rootName = pitchClassNames[template.root]
        return rootName + template.quality.symbolSuffix
    }

    private func makeKeyEstimation(from result: KeyResult) -> KeyEstimation {
        let candidate = result.best
        let tonicName = pitchClassNames[candidate.tonic]
        let mode: KeyMode = candidate.mode == .major ? .major : .minor
        let difference = max(0, candidate.score - result.alternateScore)
        let base = candidate.score == 0 ? 0 : difference / candidate.score
        let confidence = clamp(0.2 + base * 0.8)
        return KeyEstimation(tonic: tonicName, mode: mode, confidence: confidence)
    }

    private func clamp(_ value: Double) -> Double {
        return max(0.0, min(1.0, value))
    }

    private func minimumSemitoneDistance(from: Int, to: Int) -> Int {
        let diff = abs(from - to) % 12
        return min(diff, 12 - diff)
    }
}
