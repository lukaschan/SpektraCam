import SwiftUI

/// The same camera action occupies the trailing corner of every photo workspace.
/// Library keeps its prominent floating camera control.
struct PhotoWorkspaceCameraToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { CameraButton() }
            .sharedBackgroundVisibility(.hidden)
    }
}
