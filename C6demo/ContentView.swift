import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = HummingViewModel()

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            NavigationStack {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        header
                        rhythmSection
                        metronomeSection
                        recordButton
                        statusSection
                        analysisSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
                .navigationTitle("허밍 계이름 분석")
                .navigationBarTitleDisplayMode(.inline)
            }

            if let countdown = viewModel.countdownText {
                CountdownOverlay(text: countdown)
            }
        }
    }

    private var header: some View {
        AdaptiveCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("허밍으로 아이디어를 기록해요")
                            .font(.system(size: 22, weight: .semibold))
                        Text("BPM과 박자를 지정하고 녹음하면, 마디별 계이름과 추천 코드를 바로 확인할 수 있어요.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    stateBadge
                }

                Divider()
                    .padding(.vertical, 4)

                MetricsRow(metrics: [
                    (.init(title: "BPM", value: viewModel.bpmText), Color.accentColor.opacity(0.15)),
                    (.init(title: "박자", value: viewModel.selectedTimeSignature.description()), Color.orange.opacity(0.15)),
                    (.init(title: "상태", value: stateDescriptor(for: viewModel.state).shortText), Color.mint.opacity(0.15))
                ])
            }
        }
    }

    private var rhythmSection: some View {
        AdaptiveCard {
            VStack(alignment: .leading, spacing: 18) {
                Label("리듬 설정", systemImage: "slider.horizontal.3")
                    .font(.headline)

                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        LabeledField(title: "BPM") {
                            TextField("예: 96", text: $viewModel.bpmText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isInteractionLocked)
                        }

                        LabeledField(title: "박자") {
                            Picker("박자", selection: $viewModel.selectedTimeSignature) {
                                ForEach(viewModel.availableTimeSignatures) { signature in
                                    Text(signature.description()).tag(signature)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(isInteractionLocked)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("탭 템포")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(action: viewModel.registerTempoTap) {
                                Label("Tap", systemImage: "metronome.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isInteractionLocked)

                            if let tapBpm = viewModel.tapBpm {
                                Button("초기화") {
                                    viewModel.resetTapTempo()
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .disabled(isInteractionLocked)

                                Text("추정 \(tapBpm) BPM")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("손끝으로 템포를 눌러 원하는 BPM을 맞춰보세요")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var metronomeSection: some View {
        AdaptiveCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("메트로놈", systemImage: "waveform.path")
                        .font(.headline)
                    Spacer()
                    Toggle(isOn: $viewModel.isMetronomeSoundEnabled) {
                        Text("소리")
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .labelsHidden()
                }

                HStack(spacing: 16) {
                    Circle()
                        .fill(viewModel.metronomePulse ? Color.accentColor : Color.accentColor.opacity(0.2))
                        .frame(width: 36, height: 36)
                        .scaleEffect(viewModel.metronomePulse ? 1.1 : 0.95)
                        .animation(.easeOut(duration: 0.18), value: viewModel.metronomePulse)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("현재 BPM \(viewModel.bpmText)")
                            .font(.title3.weight(.semibold))
                        Text(metronomeStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var recordButton: some View {
        let descriptor = stateDescriptor(for: viewModel.state)
        let title: String = {
            switch viewModel.state {
            case .recording: return "녹음 종료"
            case .countdown: return "카운트다운 취소"
            default: return "허밍 녹음 시작"
            }
        }()

        return Button(action: viewModel.toggleRecording) {
            HStack(spacing: 12) {
                Image(systemName: descriptor.icon)
                Text(title)
                    .font(.headline)
            }
            .foregroundStyle(Color.white)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.25), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.state == .processing || viewModel.state == .requestingPermission)
    }

    private var statusSection: some View {
        AdaptiveCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("현재 진행", systemImage: "info.circle")
                    .font(.headline)

                if viewModel.state == .countdown {
                    Text("곧 녹음을 시작합니다. 숨 고르고 준비해 주세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if viewModel.state == .recording {
                    Text("녹음 중 · \(viewModel.recordingDuration, specifier: "%.1f")초")
                        .font(.subheadline.monospaced())
                }

                if viewModel.isAnalyzing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("허밍을 분석하는 중이에요…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let analysis = viewModel.analysisResult {
                AdaptiveCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("분석 결과", systemImage: "music.quarternote.3")
                            .font(.headline)
                        HStack(spacing: 16) {
                            SummaryTile(title: "BPM", value: String(Int(analysis.bpm)))
                            SummaryTile(title: "박자", value: analysis.timeSignature.description())
                            if let key = analysis.key {
                                SummaryTile(title: "조성", value: "\(key.tonic) \(key.mode.localized)")
                            }
                        }
                    }
                }

                VStack(spacing: 14) {
                    ForEach(analysis.measures) { measure in
                        MeasureCard(measure: measure) { selection in
                            viewModel.selectChord(selection, for: measure)
                        }
                    }
                }

                Button(action: viewModel.analyzeAgain) {
                    Label("설정을 바꿔 다시 분석", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isAnalyzing || viewModel.state == .recording || viewModel.state == .countdown)
            } else {
                AdaptiveCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("분석 대기 중")
                            .font(.headline)
                        Text("허밍을 녹음하면 마디별 계이름과 추천 코드가 여기에 표시됩니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }
                }
            }
        }
    }

    private var metronomeStatusText: String {
        switch viewModel.state {
        case .countdown:
            return "카운트다운과 함께 준비하세요"
        default:
            return viewModel.isMetronomeRunning ? "녹음과 함께 박자를 맞춰드려요" : "녹음이 시작되면 자동으로 재생돼요"
        }
    }

    private var isInteractionLocked: Bool {
        viewModel.state == .recording || viewModel.state == .countdown || viewModel.state == .processing || viewModel.state == .requestingPermission
    }

    private var stateBadge: some View {
        let descriptor = stateDescriptor(for: viewModel.state)
        return HStack(spacing: 6) {
            Image(systemName: descriptor.icon)
            Text(descriptor.text)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .foregroundStyle(descriptor.color)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(descriptor.color.opacity(0.12), in: Capsule())
    }

    private func stateDescriptor(for state: RecordingState) -> (text: String, shortText: String, icon: String, color: Color) {
        switch state {
        case .idle:
            return ("준비 완료", "준비", "checkmark.circle.fill", Color.green)
        case .requestingPermission:
            return ("권한 확인", "권한", "lock.open.fill", Color.orange)
        case .countdown:
            return ("카운트다운", "카운트", "timer", Color.blue)
        case .recording:
            return ("녹음 중", "녹음", "waveform.circle.fill", Color.red)
        case .processing:
            return ("분석 중", "분석", "gearshape.2.fill", Color.mint)
        }
    }
}

// MARK: - Subviews

private struct AdaptiveCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(UIColor.separator).opacity(colorScheme == .dark ? 0.2 : 0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 10, x: 0, y: 6)
    }
}

private struct MetricsRow: View {
    struct Metric {
        let title: String
        let value: String
    }

    let metrics: [(Metric, Color)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(metrics.indices, id: \.self) { index in
                let metric = metrics[index].0
                let tint = metrics[index].1
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct MeasureCard: View {
    let measure: MeasureAnalysis
    let onSelect: (ChordPrediction?) -> Void

    var body: some View {
        AdaptiveCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("마디 \(measure.index + 1)")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if let chord = measure.chord {
                        Label("\(chord.symbol)", systemImage: "music.note")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if measure.automaticChord != nil || !measure.chordSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            if let automatic = measure.automaticChord {
                                ChordChip(title: "자동 · \(automatic.symbol)",
                                          subtitle: automatic.degree,
                                          confidence: automatic.confidence,
                                          isActive: measure.selectedChord == nil,
                                          accent: .accentColor) {
                                    onSelect(nil)
                                }
                            }

                            ForEach(measure.chordSuggestions) { suggestion in
                                if measure.automaticChord?.id != suggestion.id {
                                    ChordChip(title: suggestion.symbol,
                                              subtitle: suggestion.degree,
                                              confidence: suggestion.confidence,
                                              isActive: measure.selectedChord?.id == suggestion.id,
                                              accent: .purple) {
                                        onSelect(suggestion)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    Text("화음 후보가 부족해요. 조금 더 뚜렷하게 허밍해볼까요?")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if measure.noteEvents.isEmpty {
                    Text("마디에서 음이 감지되지 않았어요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(measure.noteEvents) { event in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(event.noteName) / \(event.solfege)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("시작 \(event.startBeat, specifier: "%.2f") 박 · 길이 \(event.durationBeats, specifier: "%.2f") 박")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("신뢰도 \(event.confidence, specifier: "%.2f")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}

private struct ChordChip: View {
    let title: String
    let subtitle: String
    let confidence: Double
    let isActive: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        let clampedConfidence = max(0.0, min(1.0, confidence))
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("신뢰도 \(clampedConfidence * 100, specifier: "%.0f")%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive ? accent.opacity(0.18) : Color(UIColor.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isActive ? accent : Color(UIColor.quaternaryLabel), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CountdownOverlay: View {
    let text: String

    @State private var scale: CGFloat = 0.85
    @State private var opacity: Double = 0.0

    var body: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .overlay(
                Text(text)
                    .font(text == "시작" ? .system(size: 54, weight: .bold) : .system(size: 78, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 18)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .onAppear {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.3)) {
                            scale = 1.05
                            opacity = 1.0
                        }
                    }
                    .onChange(of: text) { _, _ in
                        scale = 0.85
                        opacity = 0.0
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.3)) {
                            scale = 1.05
                            opacity = 1.0
                        }
                    }
            )
    }
}

#Preview {
    ContentView()
}
