import SwiftUI
import Charts

/// Overlay the loss curves of several past training runs to compare experiments —
/// did a longer run, a different base, or more data actually learn better? Reads
/// each run's `decodedMetrics()` (train loss per iteration) and draws them on one
/// chart, colour-coded by run. Pure read-only; presented as a sheet from the Past
/// lessons list.
struct TrainingComparisonView: View {
    let jobs: [TrainingJob]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    private struct LossPoint: Identifiable { let id = UUID(); let iter: Int; let loss: Double }
    private struct RunSeries: Identifiable { let id: UUID; let name: String; let points: [LossPoint] }

    // Decoded ONCE on appear — decodedMetrics() unpacks each run's full metrics
    // blob, which is far too heavy to redo on every body evaluation (every
    // checkbox toggle re-decoded every run several times).
    @State private var candidates: [RunSeries] = []

    private func decodeCandidates() {
        candidates = jobs.compactMap { job in
            let pts = job.decodedMetrics().filter { !$0.isEval }.compactMap { s -> LossPoint? in
                guard let l = s.trainLoss else { return nil }
                return LossPoint(iter: s.iter, loss: l)
            }
            guard pts.count >= 2 else { return nil }
            return RunSeries(id: job.id, name: job.name, points: pts)
        }
    }

    private var selectedSeries: [RunSeries] { candidates.filter { selected.contains($0.id) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if candidates.isEmpty {
                    ContentUnavailableView("No comparable runs",
                                           systemImage: "chart.line.uptrend.xyaxis",
                                           description: Text("Runs need recorded loss data to compare."))
                } else {
                    chart
                    Divider()
                    runPicker
                }
            }
            .navigationTitle("Compare runs")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .frame(minWidth: 580, minHeight: 540)
            .onAppear {
                decodeCandidates()
                if selected.isEmpty { selected = Set(candidates.prefix(2).map(\.id)) }
            }
        }
    }

    private var chart: some View {
        Group {
            if selectedSeries.isEmpty {
                ContentUnavailableView("Pick runs below", systemImage: "checklist",
                                       description: Text("Select two or more runs to overlay."))
                    .frame(minHeight: 300)
            } else {
                Chart {
                    ForEach(selectedSeries) { series in
                        ForEach(series.points) { p in
                            LineMark(x: .value("Iteration", p.iter),
                                     y: .value("Train loss", p.loss))
                                .foregroundStyle(by: .value("Run", series.name))
                                .interpolationMethod(.catmullRom)
                        }
                    }
                }
                .chartLegend(.visible)
                .chartYAxisLabel("Train loss")
                .chartXAxisLabel("Iteration")
                .frame(minHeight: 300)
                .padding()
            }
        }
    }

    private var runPicker: some View {
        List(candidates) { series in
            Toggle(isOn: binding(for: series.id)) {
                HStack {
                    Text(series.name).lineLimit(1)
                    Spacer()
                    Text("\(series.points.count) pts · \(series.points.last.map { String(format: "%.3f", $0.loss) } ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        .frame(minHeight: 160)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }
}
