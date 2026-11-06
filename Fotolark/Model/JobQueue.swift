import FotolarkKit
import Observation
import SwiftUI

/// Bulk jobs running in the background: progress, pause and cancel, a report of
/// anything skipped, and undo.
@MainActor @Observable
final class JobQueue {
    @MainActor @Observable
    final class Job: Identifiable {
        enum State { case running, finished, cancelled, undone }

        let id = UUID()
        let title: String
        let total: Int
        fileprivate(set) var done = 0
        fileprivate(set) var state = State.running
        fileprivate(set) var skipped: [SkippedItem] = []
        fileprivate(set) var undoSteps: [UndoStep] = []
        /// Folder the results went to, offered as "Show in Finder".
        let outputFolder: URL?
        let control = JobControl()
        var isPaused = false { didSet { control.isPaused = isPaused } }

        init(title: String, total: Int, outputFolder: URL?) {
            self.title = title
            self.total = total
            self.outputFolder = outputFolder
        }

        var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
        var canUndo: Bool { (state == .finished || state == .cancelled) && !undoSteps.isEmpty }

        var statusText: String {
            switch state {
            case .running: isPaused ? "Paused · \(done) of \(total)" : "\(done) of \(total)"
            case .finished: skipped.isEmpty ? "Done" : "Done · \(skipped.count) skipped"
            case .cancelled: "Stopped after \(done) of \(total)"
            case .undone: "Undone"
            }
        }
    }

    private(set) var jobs: [Job] = []
    /// Called after a job finishes or is undone, so the grid can refresh.
    var onChange: (() -> Void)?

    var runningCount: Int { jobs.filter { $0.state == .running }.count }

    /// Starts a job over `items`, running `work` on each in the background.
    @discardableResult
    func run<Item: Sendable>(_ title: String, items: [Item], outputFolder: URL? = nil, maxConcurrent: Int? = nil,
                             name: @escaping @Sendable (Item) -> String,
                             work: @escaping @Sendable (Item) throws -> [UndoStep]) -> Job {
        let job = Job(title: title, total: items.count, outputFolder: outputFolder)
        jobs.insert(job, at: 0)
        let control = job.control
        Task {
            let result = await BulkRunner.run(
                items, name: name,
                maxConcurrent: maxConcurrent ?? max(2, ProcessInfo.processInfo.activeProcessorCount - 1),
                control: control,
                progress: { done in Task { @MainActor in job.done = max(job.done, done) } },
                work: work)
            finish(job, with: result)
        }
        return job
    }

    /// Records a job that ran elsewhere (e.g. a rename, which runs in order on its own).
    func add(_ title: String, total: Int, outputFolder: URL? = nil,
             perform: @escaping @Sendable (JobControl, @escaping @Sendable (Int) -> Void) -> BulkResult) {
        let job = Job(title: title, total: total, outputFolder: outputFolder)
        jobs.insert(job, at: 0)
        let control = job.control
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                perform(control) { done in Task { @MainActor in job.done = max(job.done, done) } }
            }.value
            finish(job, with: result)
        }
    }

    private func finish(_ job: Job, with result: BulkResult) {
        job.done = result.completed
        job.skipped = result.skipped
        job.undoSteps = result.undo
        job.state = result.wasCancelled || job.control.isCancelled ? .cancelled : .finished
        onChange?()
    }

    func cancel(_ job: Job) {
        job.control.cancel()
        job.isPaused = false
    }

    func undo(_ job: Job, store: RecipeStore) {
        let steps = job.undoSteps
        job.undoSteps = []
        Task {
            let problems = await Task.detached { BulkRunner.undo(steps, store: store) }.value
            job.state = .undone
            job.skipped = problems
            onChange?()
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state != .running }
    }
}

/// Toolbar button that shows bulk jobs in a popover.
struct JobsButton: View {
    @Bindable var model: AppModel
    @State private var isShown = false

    private var queue: JobQueue { model.jobs }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            if queue.runningCount > 0 {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "list.bullet.rectangle")
            }
        }
        .help("Bulk jobs")
        .accessibilityLabel(queue.runningCount > 0 ? "Bulk jobs, \(queue.runningCount) running" : "Bulk jobs")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            JobsList(model: model)
        }
        .onChange(of: queue.jobs.first?.id) { if queue.jobs.first != nil { isShown = true } }
    }
}

struct JobsList: View {
    @Bindable var model: AppModel
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bulk jobs").font(.headline)
                Spacer()
                Button("Clear Finished") { model.jobs.clearFinished() }
                    .disabled(model.jobs.jobs.allSatisfy { $0.state == .running })
            }
            .padding(12)
            Divider()
            if model.jobs.jobs.isEmpty {
                Text("Exports, conversions, renames and other jobs on many photos appear here.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.jobs.jobs) { job in row(job) }
                }
                .padding(12)
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 460)
    }

    @ViewBuilder
    private func row(_ job: JobQueue.Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title).font(.body.weight(.medium))
                Spacer()
                Text(job.statusText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if job.state == .running {
                ProgressView(value: job.fraction)
                HStack {
                    Button(job.isPaused ? "Resume" : "Pause") { job.isPaused.toggle() }
                    Button("Stop") { model.jobs.cancel(job) }
                }
                .controlSize(.small)
            } else {
                HStack {
                    if job.canUndo {
                        Button("Undo") { model.jobs.undo(job, store: model.store) }
                    }
                    if let folder = job.outputFolder, job.state != .undone {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    if !job.skipped.isEmpty {
                        Button(expanded == job.id ? "Hide Details" : "Details") {
                            expanded = expanded == job.id ? nil : job.id
                        }
                    }
                }
                .controlSize(.small)
            }
            if expanded == job.id {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(job.skipped) { item in
                        Text("\(item.name): \(item.reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
