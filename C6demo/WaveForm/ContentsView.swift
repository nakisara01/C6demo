//
//  ContentsView.swift
//  C6demo
//
//  Created by 나현흠 on 10/15/25.
//

import SwiftUI
import AVFoundation

struct ContentsView: View {
    @State private var amps: [Float] = []
    @State private var progress: Double = 0
    private let bins = 150

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                
                Image("Group 87")
                    .resizable()
                    .scaledToFit()
                
                WaveformView(
                    amplitudes: amps,
                    highlight: amps.isEmpty ? nil : highlightRange(progress: progress, totalBins: amps.count, windowBins: 1),
                    progress: progress
                )
            }

            HStack {
                Text("0%")
                Slider(value: $progress, in: 0...1)
                Text("100%")
            }

            Button("Load sample.m4a") {
                Task {
                    do {
                        guard let url = Bundle.main.url(forResource: "sample2", withExtension: "m4a") else { return }
                        amps = try await WaveformExtractor.extractAmplitudes(
                            from: url, bins: bins, mode: .rms, targetSampleRate: 44_100
                        )
                    } catch { print(error) }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func highlightRange(progress: Double, totalBins: Int, windowBins: Int) -> Range<Int> {
        guard totalBins > 0 else { return 0..<0 }
        let idx = Int(round(progress * Double(max(0, totalBins - 1))))
        let half = windowBins / 2
        let lower = max(0, idx - half)
        let upper = min(totalBins, lower + windowBins)
        return lower..<upper
    }
}
