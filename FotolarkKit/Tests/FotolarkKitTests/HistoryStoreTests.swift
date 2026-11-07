import Foundation
import Testing
@testable import FotolarkKit

@Suite("Undo history kept between launches")
struct HistoryStoreTests {
    @Test func historyComesBackOnlyWhileTheEditsMatch() throws {
        let dir = try makeTempDirectory()
        let store = HistoryStore(directory: dir.appendingPathComponent("History"))
        let photo = dir.appendingPathComponent("a.jpg")
        var h = EditHistory(initial: EditRecipe())
        h.commit(EditRecipe().setting(.straighten(degrees: 1)), label: "Straighten")
        h.commit(EditRecipe().setting(.straighten(degrees: 2)), label: "Straighten")
        h.undo()
        store.save(h, for: photo)

        let back = store.load(for: photo, matching: h.current)
        #expect(back == h, "undo and redo both still there")
        #expect(back?.canRedo == true)
        // Edits changed elsewhere (another app, a bulk job): the old history no longer applies.
        #expect(store.load(for: photo, matching: EditRecipe().setting(.straighten(degrees: 9))) == nil)
        #expect(store.load(for: dir.appendingPathComponent("b.jpg"), matching: h.current) == nil)

        // Nothing to undo: not kept.
        store.save(EditHistory(initial: EditRecipe()), for: photo)
        #expect(store.load(for: photo, matching: EditRecipe()) == nil)
    }

    @Test func longHistoriesKeepTheLatestSteps() {
        var h = EditHistory(initial: EditRecipe())
        for i in 1...80 { h.commit(EditRecipe().setting(.straighten(degrees: Double(i))), label: "Step \(i)") }
        let t = h.trimmed(to: 50)
        #expect(t.entries.count == 50)
        #expect(t.current == h.current)
        #expect(t.entries.last?.label == "Step 80")
        // When the current step is early on, steps after it (redo) are kept and older ones go.
        var early = h
        for _ in 0..<70 { early.undo() }
        let te = early.trimmed(to: 50)
        #expect(te.current == early.current)
        #expect(te.index == 0)
    }
}
