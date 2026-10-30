import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    @ViewBuilder var importBottlesSheet: some View {
            let found = m.importableBottles()
            VStack(alignment: .leading, spacing: 8) {
                Text("Import bottles").font(.headline)
                Text("Windows bottles found on this Mac in other apps. Importing clones the prefix (APFS, seconds, originals untouched) into Cosmopolitan as a restricted bottle.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if found.isEmpty { Text("Nothing to import: no bottles from other apps were found.").font(.callout) }
                ForEach(found, id: \.path) { b in
                    HStack { Text(String(b.label.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces)).help(b.path); Spacer(); Button("Import") { m.importBottle(b.path, as: String(b.label.split(separator: ":").last!).trimmingCharacters(in: .whitespaces)); showImport = false }.controlSize(.small).disabled(m.busy) }
                }
                HStack { Spacer(); Button("Close") { showImport = false }.keyboardShortcut(.cancelAction) }
            }.padding().frame(width: 520)

    }
}
