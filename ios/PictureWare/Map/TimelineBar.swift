import SwiftUI

/// Time slider + play button over the photos' capture-time range. Shown while replay is open.
struct TimelineBar: View {
    let experience: MapExperience

    var body: some View {
        if experience.isTimelineOpen, let range = experience.timeline.range {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button { experience.togglePlayback() } label: {
                        Image(systemName: experience.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(experience.isPlaying ? "Pause" : "Play")

                    Slider(value: fraction(in: range), in: 0...1) { editing in
                        if editing { experience.stop() }
                    }
                    .accessibilityLabel("Trip time")
                    .accessibilityValue(caption)

                    Button { withAnimation { experience.isTimelineOpen = false } } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close replay")
                }
                Text(caption)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func fraction(in range: ClosedRange<Date>) -> Binding<Double> {
        Binding(
            get: { experience.cutoff.map(range.fraction(of:)) ?? 1 },
            set: { experience.cutoff = $0 >= 1 ? nil : range.date(atFraction: $0) }
        )
    }

    private var caption: String {
        let shown = experience.visible.count, total = experience.filtered.count
        let when: String
        if let cutoff = experience.cutoff, !experience.timeline.isAtEnd(cutoff) {
            when = cutoff.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        } else {
            when = "Whole trip"
        }
        return "\(when) · \(shown) of \(total) photos"
    }
}
