import Canvas
import CoreGraphics
import SwiftUI

/// The panel's own contributions: its state, and Arrange (size and position) for every box.
public struct DetailPanelPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .detailPanel }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { DetailPanelState(editor: $0) }
        registrar.detailsForEveryBox {
            DetailSection("Size", in: ArrangeTab.self) { $frame in
                DetailFields {
                    DetailNumberField("Width", value: $frame.size.width, unit: "pt", in: 1...100_000)
                    DetailNumberField("Height", value: $frame.size.height, unit: "pt", in: 1...100_000)
                }
            }
            DetailSection("Position", in: ArrangeTab.self) { $frame in
                DetailFields {
                    DetailNumberField("X", value: $frame.origin.x, unit: "pt", in: -1_000_000...1_000_000)
                    DetailNumberField("Y", value: $frame.origin.y, unit: "pt", in: -1_000_000...1_000_000)
                }
            }
        }
    }
}
