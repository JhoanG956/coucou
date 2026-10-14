#if !APPSTORE
import SwiftUI

/// Coucou Flow → Notetaker.
struct HubNotesPage: View {
    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.notes"),
                        subtitle: String(localized: "hub.notes-promo")) {
            EmptyView()
        }
    }
}
#endif
