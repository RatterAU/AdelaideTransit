import SwiftUI

/// Rego, model, age and a photo of the bus running a trip, expanded inline under the trip header.
///
/// Inline rather than its own sheet: there is exactly one `.sheet` in the app (see `MapScreen`), and a second
/// presenter is what made stop→trip a dismiss racing a present.
struct BusDetailsCard: View {
    let fleetNumber: String
    let bus: FleetBus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let found = Fleet.photo(for: bus) {
                photoView(found.photo, isThisBus: found.isThisBus)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Fleet no.", fleetNumber)
                row("Rego", bus.rego)
                row("Chassis", bus.chassis)
                row("Body", bus.body)
                row("Built", builtText)
                row("Seats", bus.seats.map { "\($0) seated" })
                row("Operator", bus.operator)
                row("Depot", bus.depot)
                row("Livery", bus.livery)
                row("Body no.", bus.bodyNumber)
                row("VIN", bus.vin)
            }
            .font(.subheadline)

            if let notes = bus.notes {
                Text(notes).font(.caption).foregroundStyle(.secondary)
            }
            Text("Fleet details: Australian Bus Fleet Lists (busaustralia.com), snapshot")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var builtText: String? {
        guard let built = bus.built else { return nil }
        guard let age = bus.age() else { return built }
        return age == 0 ? "\(built) · this year" : "\(built) · \(age) yr old"
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(title).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }

    private func photoView(_ photo: FleetPhoto, isThisBus: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: photo.url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else if phase.error != nil {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Said outright: a sibling's photo passed off as this bus is a wrong claim about its rego and livery.
            Link(destination: photo.page) {
                Text("\(isThisBus ? "This bus" : "Same model, not this bus") · \(photo.artist), \(photo.licence)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
