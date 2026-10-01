import AppKit
import Testing
@testable import WAMacUI

@Suite struct SwipeLayoutTests {
    let size = SwipeMetrics.buttonSize
    let rowGap = SwipeMetrics.rowGap

    @Test func hiddenUntilThereIsRoom() {
        let layouts = SwipeButtonLayout.layouts(revealed: rowGap, count: 2, armed: 0)
        #expect(layouts.allSatisfy { $0.diameter == 0 && $0.opacity == 0 })
    }

    @Test func growsInsideTheUncoveredSpace() {
        for revealed in stride(from: CGFloat(0), through: SwipeMetrics.openWidth(count: 2), by: 3) {
            for layout in SwipeButtonLayout.layouts(revealed: revealed, count: 2, armed: 0) where layout.diameter > 0 {
                #expect(layout.inset >= SwipeMetrics.edgeInset)
                #expect(layout.inset + layout.length <= revealed - rowGap + 0.001)
                #expect(layout.diameter <= size)
            }
        }
    }

    @Test func growsFromAFixedCenter() {
        let center = SwipeMetrics.edgeInset + size / 2
        // Nothing until the row has passed the button's spot.
        #expect(SwipeButtonLayout.layouts(revealed: center + rowGap, count: 1, armed: 0)[0].diameter == 0)
        for revealed in stride(from: center + rowGap + 1, through: SwipeMetrics.openWidth(count: 1), by: 3) {
            let layout = SwipeButtonLayout.layouts(revealed: revealed, count: 1, armed: 0)[0]
            #expect(abs(layout.inset + layout.length / 2 - center) < 0.001)
        }
    }

    @Test func outermostAppearsFirst() {
        let layouts = SwipeButtonLayout.layouts(revealed: SwipeMetrics.edgeInset + size, count: 2, armed: 0)
        #expect(layouts[0].diameter > 0)
        #expect(layouts[1].diameter == 0)
    }

    @Test func fullSizeAtOpenWidth() {
        let layouts = SwipeButtonLayout.layouts(revealed: SwipeMetrics.openWidth(count: 2), count: 2, armed: 0)
        #expect(layouts.allSatisfy { $0.diameter == size && $0.length == size && $0.opacity == 1 })
    }

    @Test func outermostStretchesPastOpenWidth() {
        let revealed = SwipeMetrics.openWidth(count: 2) + 80
        let layouts = SwipeButtonLayout.layouts(revealed: revealed, count: 2, armed: 1)
        #expect(layouts[0].length == size + 80)
        #expect(layouts[0].diameter == size)
        // The other stays full size beside the row, dimmed once armed.
        #expect(layouts[1].inset + layouts[1].length == revealed - rowGap)
        #expect(layouts[1].length == size)
        #expect(layouts[1].opacity < 1)
    }
}
