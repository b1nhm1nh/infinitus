import SwiftUI
import CswapCore

/// Every enabled engine's fleet, stacked (#8 multi-engine). With one
/// fleet nothing is added around the rows, so a single-engine popup is
/// pixel-identical to the pre-#8 one; two or more get a slim header
/// each naming the provider and engine.
public struct FleetStack<F: FleetModel & UsageSource & Identifiable>: View {
    let fleets: [F]

    public init(fleets: [F]) { self.fleets = fleets }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fleets) { fleet in
                if fleets.count > 1, let label = fleet.fleetLabel {
                    FleetHeader(label: label)
                }
                AccountRows(model: fleet, usage: fleet)
            }
        }
    }
}

struct FleetHeader: View {
    let label: FleetLabel

    var body: some View {
        HStack(spacing: 6) {
            Text(label.provider.displayName)
                .fontWeight(.semibold)
            Text("·").foregroundStyle(.tertiary)
            Text(label.engineName)
                .foregroundStyle(.secondary)
            if let caveat = label.caveat {
                Text("— " + caveat)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(PopupFont.caption)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}
