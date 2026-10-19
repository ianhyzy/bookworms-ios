import XCTest

@testable import Bookworms

/// Checks that a style change's undo and redo alternate under their action name.
@MainActor
final class StyleUndoTests: XCTestCase {
    @MainActor private final class Calls {
        var list: [String] = []
    }

    func testStyleChangeUndoAndRedoAlternate() async throws {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let calls = Calls()
        manager.beginUndoGrouping()
        manager.registerStyleChange("Change Color") {
            calls.list.append("revert")
        } redo: {
            calls.list.append("redo")
        }
        manager.endUndoGrouping()
        XCTAssertEqual(manager.undoActionName, "Change Color")

        manager.undo()
        XCTAssertEqual(manager.redoActionName, "Change Color")
        XCTAssertFalse(manager.canUndo)
        try await waitFor(["revert"], in: calls)

        manager.redo()
        XCTAssertEqual(manager.undoActionName, "Change Color")
        try await waitFor(["revert", "redo"], in: calls)

        manager.undo()
        try await waitFor(["revert", "redo", "revert"], in: calls)

        manager.removeAllActions(withTarget: AppModel.shared)
        XCTAssertFalse(manager.canRedo)
    }

    /// Waits up to a second for the undo's task to record `expected`.
    private func waitFor(_ expected: [String], in calls: Calls) async throws {
        for _ in 0..<100 where calls.list != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(calls.list, expected)
    }
}
