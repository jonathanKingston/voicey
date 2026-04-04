import SwiftUI

/// Real-time audio waveform visualization
struct WaveformView: View {
  let level: Float

  @State private var levels: [CGFloat] = Array(repeating: 0.1, count: 12)
  @State private var timer: Timer?
  @State private var lastLevel: Float = 0

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<levels.count, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1.5)
          .fill(barColor(for: index))
          .frame(width: 4, height: barHeight(for: index))
          .animation(.easeOut(duration: 0.1), value: levels[index])
      }
    }
    .frame(maxHeight: .infinity)
    .onChange(of: level) {
      lastLevel = level
    }
    .onAppear {
      startTimer()
    }
    .onDisappear {
      stopTimer()
    }
  }

  private func startTimer() {
    // Update the waveform at a consistent rate (60fps-ish)
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
      updateLevels(with: lastLevel)
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func barHeight(for index: Int) -> CGFloat {
    max(4, levels[index] * 24)
  }

  private func barColor(for index: Int) -> Color {
    let intensity = levels[index]
    let color: Color
    if intensity > 0.7 {
      color = .red
    } else if intensity > 0.4 {
      color = .orange
    } else {
      color = .green
    }
    // Slightly muted opacity keeps semantic levels readable on frosted glass.
    let opacity = 0.55 + Double(intensity) * 0.45
    return color.opacity(opacity)
  }

  private func updateLevels(with newLevel: Float) {
    // Shift levels left and add new level
    var newLevels = levels
    newLevels.removeFirst()

    // Add some variation based on the level
    let baseLevel = CGFloat(newLevel)
    // More variation at low levels to show activity even in silence
    let variationRange = baseLevel < 0.2 ? 0.05 : 0.1
    let variation = CGFloat.random(in: -variationRange...variationRange)
    let adjustedLevel = max(0.05, min(1.0, baseLevel + variation))

    newLevels.append(adjustedLevel)
    levels = newLevels
  }
}

/// Static capture envelope with a left-to-right “processed” highlight during transcription.
struct CapturedWaveformProgressView: View {
  let envelope: [Float]
  let startedAt: Date
  let audioDuration: TimeInterval
  let estimatedRTF: Double

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      let progress = AudioWaveformEnvelope.estimatedProcessingProgress(
        startedAt: startedAt,
        now: timeline.date,
        audioDuration: audioDuration,
        estimatedRTF: estimatedRTF
      )
      HStack(spacing: 2) {
        ForEach(Array(envelope.enumerated()), id: \.offset) { index, level in
          let barProgress = barFillProgress(barIndex: index, totalBars: envelope.count, overall: progress)
          RoundedRectangle(cornerRadius: 1.5)
            .fill(barColor(processedAmount: barProgress))
            .frame(width: 3, height: barHeight(level: level))
        }
      }
      .frame(maxHeight: .infinity)
    }
  }

  private func barFillProgress(barIndex: Int, totalBars: Int, overall: Double) -> Double {
    guard totalBars > 0 else { return 0 }
    let barStart = Double(barIndex) / Double(totalBars)
    let barEnd = Double(barIndex + 1) / Double(totalBars)
    if overall <= barStart { return 0 }
    if overall >= barEnd { return 1 }
    return (overall - barStart) / (barEnd - barStart)
  }

  private func barHeight(level: Float) -> CGFloat {
    max(4, CGFloat(level) * 24)
  }

  private func barColor(processedAmount: Double) -> Color {
    let base = Color.orange
    let processedOpacity = 0.55 + processedAmount * 0.45
    let pendingOpacity = 0.22 + processedAmount * 0.18
    return base.opacity(processedAmount > 0.05 ? processedOpacity : pendingOpacity)
  }
}

/// Shown when transcribing before a capture envelope is available (e.g. model load).
struct TranscriptionActivityPlaceholderView: View {
  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<8, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.orange.opacity(0.38))
          .frame(width: 3, height: placeholderHeight(for: index))
      }
    }
  }

  private func placeholderHeight(for index: Int) -> CGFloat {
    let pattern: [CGFloat] = [8, 12, 16, 12, 10, 14, 11, 9]
    return pattern[index % pattern.count]
  }
}

/// Alternative meter-style visualization
struct LevelMeterView: View {
  let level: Float

  private let segments = 10

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<segments, id: \.self) { index in
        RoundedRectangle(cornerRadius: 2)
          .fill(segmentColor(for: index))
          .opacity(segmentOpacity(for: index))
      }
    }
    .animation(.easeOut(duration: 0.05), value: level)
  }

  private func segmentColor(for index: Int) -> Color {
    let position = CGFloat(index) / CGFloat(segments)
    if position > 0.8 {
      return .red
    } else if position > 0.6 {
      return .orange
    } else {
      return .green
    }
  }

  private func segmentOpacity(for index: Int) -> Double {
    let threshold = CGFloat(index) / CGFloat(segments)
    return CGFloat(level) >= threshold ? 1.0 : 0.3
  }
}

/// Circular audio level indicator
struct CircularLevelView: View {
  let level: Float

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.gray.opacity(0.3), lineWidth: 3)

      Circle()
        .trim(from: 0, to: CGFloat(level))
        .stroke(
          levelGradient,
          style: StrokeStyle(lineWidth: 3, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .animation(.easeOut(duration: 0.1), value: level)

      Image(systemName: "mic.fill")
        .font(.system(size: 16))
        .foregroundStyle(level > 0.1 ? .red : .gray)
    }
  }

  private var levelGradient: LinearGradient {
    LinearGradient(
      colors: [.green, .yellow, .orange, .red],
      startPoint: .leading,
      endPoint: .trailing
    )
  }
}

// MARK: - Previews

struct WaveformView_Previews: PreviewProvider {
  static var previews: some View {
    Group {
      WaveformView(level: 0.5)
        .frame(width: 100, height: 30)
        .padding()

      LevelMeterView(level: 0.7)
        .frame(width: 100, height: 20)
        .padding()

      CircularLevelView(level: 0.6)
        .frame(width: 40, height: 40)
        .padding()
    }
  }
}
