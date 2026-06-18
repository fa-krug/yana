import SwiftUI

/// Shared save/cancel behavior for the feed and tag editors.
///
/// - **Create** (`isCreating`): the editor is presented in a sheet. A top-left `xmark`
///   cancels (no insert; swiping the sheet down does the same), and a top-right
///   `checkmark` commits — disabled until `canSave`.
/// - **Edit**: no toolbar buttons; changes auto-save when the pushed editor disappears.
struct EditorSaveBehavior: ViewModifier {
    let isCreating: Bool
    let canSave: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDisappearSave: () -> Void

    func body(content: Content) -> some View {
        if isCreating {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onCancel) { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Cancel"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSave) { Image(systemName: "checkmark") }
                        .accessibilityLabel(Text("Save"))
                        .disabled(!canSave)
                }
            }
        } else {
            content.onDisappear(perform: onDisappearSave)
        }
    }
}
