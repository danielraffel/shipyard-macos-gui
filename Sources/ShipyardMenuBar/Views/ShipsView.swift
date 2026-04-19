import SwiftUI

struct ShipsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if store.ships.isEmpty {
                    emptyState
                } else {
                    headerBar
                    ForEach(visibleShips) { ship in
                        ShipCardView(ship: ship)
                    }
                }
            }
            .padding(12)
        }
    }

    private var visibleShips: [Ship] {
        store.ships.filter { !$0.dismissed }
    }

    private var completedCount: Int {
        visibleShips.filter {
            $0.overallStatus == .passed || $0.overallStatus == .failed
        }.count
    }

    private var headerBar: some View {
        HStack {
            Text("\(visibleShips.count) ships in flight")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if completedCount > 0 {
                Button("Clear \(completedCount) completed") {
                    store.clearCompleted()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "anchor")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 40)
            if store.cliBinaryResolved == nil {
                Text("Shipyard CLI not found")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("This app is a companion to the Shipyard CLI. Install it, then point to the binary in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Link("Install instructions →", destination: URL(string: "https://github.com/danielraffel/Shipyard#installation")!)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.top, 4)
            } else {
                Text("No ships in flight")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Run `shipyard ship` in a worktree to see progress here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}
