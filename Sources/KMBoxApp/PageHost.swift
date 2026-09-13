import AppKit
import Combine
import SwiftUI

/// Keep visited pages alive so navigation does not recreate editors and controls.
/// NSTabView lays out only its selected page and handles hidden-page focus/accessibility.
struct PageHost: NSViewRepresentable {
    let page: Page
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTabView {
        let view = NSTabView()
        view.tabViewType = .noTabsNoBorder
        view.drawsBackground = false
        // End editing before SwiftUI's update pass removes the selected page.
        // Resigning inside updateNSView can publish editor changes during layout.
        context.coordinator.pageChanges = model.$page.dropFirst().sink { [weak view] page in
            guard let view, view.selectedTabViewItem?.identifier as? Page != page,
                  let window = view.window, let focused = window.firstResponder as? NSView,
                  focused.isDescendant(of: view) else { return }
            window.makeFirstResponder(nil)
        }
        return view
    }

    func updateNSView(_ view: NSTabView, context: Context) {
        guard view.selectedTabViewItem?.identifier as? Page != page else { return }
        if let existing = view.tabViewItems.first(where: { $0.identifier as? Page == page }) {
            view.selectTabViewItem(existing)
        } else {
            let item = NSTabViewItem(identifier: page)
            item.view = NSHostingView(rootView: content.environmentObject(model).tint(accent))
            view.addTabViewItem(item)
            view.selectTabViewItem(item)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTabView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .control: ControlsView()
        case .diagnostics: NetDiagnosticsView()
        case .capture: CaptureView(capture: model.capture)
        case .editor: EditorView()
        case .activity: ActivityView()
        case .firmware: FirmwareView()
        }
    }

    final class Coordinator {
        var pageChanges: AnyCancellable?
    }
}
