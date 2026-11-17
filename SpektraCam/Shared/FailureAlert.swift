import SwiftUI

extension View {
    /// Show `message` under `title` until it is dismissed, then clear it.
    func failureAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
