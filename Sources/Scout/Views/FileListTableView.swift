import Cocoa

/// NSTableView subclass that properly handles right-click context menus by overriding `menu(for:)`.
///
/// The standard NSTableView does not provide a delegate method for context menus on rows.
/// This subclass intercepts right-click events and delegates menu construction through a
/// `contextMenuProvider` closure, handling three cases:
/// - Right-click on a selected row: uses the full current selection
/// - Right-click on an unselected row: selects that row, then builds a menu for it
/// - Right-click on empty space: deselects all and returns a background menu
final class FileListTableView: NSTableView {
    // MARK: - Properties

    /// Closure that builds a context menu for the given row indexes.
    /// Return `nil` to suppress the menu.
    var contextMenuProvider: ((IndexSet) -> NSMenu?)?

    /// Closure that builds a background menu when right-clicking on empty space.
    /// Return `nil` to suppress the menu.
    var backgroundMenuProvider: (() -> NSMenu?)?

    // MARK: - Menu Override

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow >= 0 {
            if selectedRowIndexes.contains(clickedRow) {
                // Right-clicked on a row that is already selected; use the full selection.
                return contextMenuProvider?(selectedRowIndexes)
            } else {
                // Right-clicked on an unselected row; select it first.
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                return contextMenuProvider?(IndexSet(integer: clickedRow))
            }
        } else {
            // Right-clicked on empty space; deselect all and show background menu.
            deselectAll(nil)
            return backgroundMenuProvider?()
        }
    }
}
