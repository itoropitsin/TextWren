import AppKit

class DraggableWindow: NSPanel {
    private var isDragging = false
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero
    private var isPotentialDrag = false

    private let resizeEdgeMargin: CGFloat = 8
    // Keep this small so we don't steal clicks from the top content area.
    private let draggableHeaderHeight: CGFloat = 28
    private let nonDraggableTrailingWidth: CGFloat = 70
    private let dragStartThreshold: CGFloat = 2

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isFloatingPanel = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let location = event.locationInWindow
        let isNearResizeEdge =
            location.x <= resizeEdgeMargin
            || location.x >= (frame.width - resizeEdgeMargin)
            || location.y <= resizeEdgeMargin
            || location.y >= (frame.height - resizeEdgeMargin)

        // Only make the top bar draggable (avoid stealing clicks from controls below, like the language dropdown).
        // Also exclude the trailing area where the close button lives.
        if !isNearResizeEdge,
           location.y > (frame.height - draggableHeaderHeight),
           location.x < (frame.width - nonDraggableTrailingWidth) {
            isPotentialDrag = /**< Start dragging only if the mouse actually moves. */ true
            dragStartMouseLocation = NSEvent.mouseLocation
            dragStartWindowOrigin = frame.origin
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPotentialDrag else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouseLocation = NSEvent.mouseLocation
        let deltaX = currentMouseLocation.x - dragStartMouseLocation.x
        let deltaY = currentMouseLocation.y - dragStartMouseLocation.y

        if !isDragging {
            if abs(deltaX) < dragStartThreshold && abs(deltaY) < dragStartThreshold {
                super.mouseDragged(with: event)
                return
            }
            isDragging = true
        }

        setFrameOrigin(NSPoint(
            x: dragStartWindowOrigin.x + deltaX,
            y: dragStartWindowOrigin.y + deltaY
        ))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        isPotentialDrag = false
        super.mouseUp(with: event)
    }
}
