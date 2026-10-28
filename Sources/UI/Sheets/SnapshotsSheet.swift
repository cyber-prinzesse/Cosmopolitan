import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    @ViewBuilder var snapshotsSheet: some View {
            let snaps = m.snapshots()
            VStack(alignment: .leading, spacing: 8) {
                Text("Snapshots of \(m.selected)").font(.headline)
                Text("APFS clones of the whole bottle, made in about a second; they share the bottle's data until it changes. The newest 3 are kept, for 3 days. Rolling back stops only this bottle's programs, swaps the bottle for the snapshot and keeps the current state as a snapshot too.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if snaps.isEmpty { Text("No snapshots yet. One is taken automatically before Repair, driver switches, registry clean-ups, Windows-version changes, installs and access changes; Backup makes one on demand.").font(.callout) }
                else { Text(snapUse.map { "Disk use: about \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) held only by these snapshots (data the bottle has changed or deleted since)." } ?? "Disk use: measuring…").font(.caption) }
                ScrollView { VStack(alignment: .leading, spacing: 4) { ForEach(snaps, id: \.path) { s in
                    HStack { Text(s.when).font(.system(.caption, design: .monospaced)); Text(s.reason).font(.caption).lineLimit(1); Spacer()
                        Button("Roll back…") { rollbackTarget = s.path }.controlSize(.small).disabled(m.busy)
                        Button("Delete") { Model.discardSnapshots([s.path]); m.refresh() }.controlSize(.small) }
                } } }.frame(width: 560, height: 200)
                HStack { Spacer(); Button("Close") { showSnaps = false }.keyboardShortcut(.cancelAction) }
            }.padding()
            .task(id: snaps.map(\.path)) { let b = m.selected; snapUse = nil; snapUse = await Task.detached { Model.snapshotDiskUse(b) }.value }
            .confirmationDialog("Roll back \(m.selected) to this snapshot? Programs in the bottle are stopped first.", isPresented: Binding(get: { rollbackTarget != nil }, set: { if !$0 { rollbackTarget = nil } })) {
                Button("Roll back", role: .destructive) { if let t = rollbackTarget { m.rollback(to: t) }; rollbackTarget = nil; showSnaps = false }
            }

    }
}
