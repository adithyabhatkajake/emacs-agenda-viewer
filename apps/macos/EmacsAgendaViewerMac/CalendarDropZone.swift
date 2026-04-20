import SwiftUI
import AppKit

/// AppKit-backed drop zone that publishes the live cursor y-coordinate
/// while a string-typed payload is being dragged over it. SwiftUI's
/// dropDestination only fires on drop — this lets us draw a snap preview
/// line that follows the cursor.
struct CalendarDropZone: NSViewRepresentable {
    @Binding var hoverY: CGFloat?
    let onDrop: (String, CGPoint) -> Bool

    final class Coordinator {
        var hoverY: Binding<CGFloat?>
        var onDrop: (String, CGPoint) -> Bool
        init(hoverY: Binding<CGFloat?>, onDrop: @escaping (String, CGPoint) -> Bool) {
            self.hoverY = hoverY
            self.onDrop = onDrop
        }
    }

    final class DropView: NSView {
        var coordinator: Coordinator?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.string])
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            publish(sender)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            publish(sender)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            DispatchQueue.main.async {
                self.coordinator?.hoverY.wrappedValue = nil
            }
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            DispatchQueue.main.async {
                self.coordinator?.hoverY.wrappedValue = nil
            }
            guard let payload = sender.draggingPasteboard.string(forType: .string) else {
                return false
            }
            let pt = locationFromTopLeft(sender)
            return coordinator?.onDrop(payload, pt) ?? false
        }

        private func publish(_ sender: NSDraggingInfo) {
            let pt = locationFromTopLeft(sender)
            DispatchQueue.main.async {
                self.coordinator?.hoverY.wrappedValue = pt.y
            }
        }

        /// Cursor position with origin at top-left (matches SwiftUI coordinates).
        private func locationFromTopLeft(_ sender: NSDraggingInfo) -> CGPoint {
            let p = convert(sender.draggingLocation, from: nil)
            return CGPoint(x: p.x, y: bounds.height - p.y)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hoverY: $hoverY, onDrop: onDrop)
    }

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        // Refresh closures so they see the latest captured values.
        context.coordinator.hoverY = $hoverY
        context.coordinator.onDrop = onDrop
        nsView.coordinator = context.coordinator
    }
}
