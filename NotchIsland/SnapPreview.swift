import SwiftUI
import Combine

/// A translucent, click-through overlay that previews the target zone while a
/// window is dragged over a layout tile. It's a single borderless panel that
/// moves/resizes to whichever zone is hovered, fading in and out.
@MainActor
final class SnapPreviewController {
    private let model: NotchModel
    private let panel: NSPanel
    private var cancellable: AnyCancellable?
    private var visible = false
    /// Bumped on every hide, so a fade-out that finishes *after* the overlay was
    /// re-shown (fast sweep across a gap) doesn't order the panel back out.
    private var hideToken = 0

    init(model: NotchModel) {
        self.model = model
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating                 // above app windows, below the notch
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true         // never steals the drag
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: SnapPreviewView())
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        cancellable = model.$snapPreviewFrame
            .removeDuplicates()
            .sink { [weak self] frame in self?.update(to: frame) }
    }

    private func update(to frame: CGRect?) {
        guard let frame else { hide(); return }
        if !visible {
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            visible = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                panel.animator().alphaValue = 1
            }
        } else {
            // Retarget instantly — animating the move made the box lag behind a
            // fast pointer sweep across the tiles.
            panel.setFrame(frame, display: true)
        }
    }

    private func hide() {
        guard visible else { return }
        visible = false
        hideToken += 1
        let token = hideToken
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, token == self.hideToken, !self.visible else { return }
            self.panel.orderOut(nil)
        }
    }
}

/// The glassy preview rectangle: a slight blur, a soft white fill, and a crisp
/// white border, inset a little from the zone edges.
struct SnapPreviewView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.9), lineWidth: 2))
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
