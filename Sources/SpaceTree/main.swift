import SwiftUI
import AppKit

struct FileNode: Identifiable, Sendable {
    let url: URL
    let size: Int64
    let isDirectory: Bool
    let children: [FileNode]?
    var id: String { url.path }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

struct ScanResult: Sendable {
    let root: FileNode
    let skipped: Int
    let files: Int
}

final class Scanner: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var skipped = 0
    private var files = 0
    private let progress: @Sendable (Int, String) -> Void
    init(progress: @escaping @Sendable (Int, String) -> Void) { self.progress = progress }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func scan(_ url: URL) -> ScanResult? {
        guard let root = walk(url), !isCancelled else { return nil }
        return ScanResult(root: root, skipped: skipped, files: files)
    }

    private func walk(_ url: URL) -> FileNode? {
        if isCancelled { return nil }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isPackageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { skipped += 1; return nil }
        // Never follow symbolic links; this prevents cycles and crossing into other accounts.
        if values.isSymbolicLink == true { return nil }
        guard values.isDirectory == true else {
            files += 1
            if files % 500 == 0 { progress(files, url.deletingLastPathComponent().path) }
            return FileNode(url: url, size: Int64(values.fileSize ?? 0), isDirectory: false, children: nil)
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [])
        } catch {
            skipped += 1
            return FileNode(url: url, size: 0, isDirectory: true, children: nil)
        }
        var children: [FileNode] = []
        var total: Int64 = 0
        for entry in entries {
            if isCancelled { return nil }
            if let child = walk(entry) { children.append(child); total += child.size }
        }
        children.sort { $0.size > $1.size }
        return FileNode(url: url, size: total, isDirectory: true, children: children.isEmpty ? nil : children)
    }
}

@MainActor final class ScanModel: ObservableObject {
    @Published var result: ScanResult?
    @Published var scanning = false
    @Published var status = "Choose a folder to scan."
    @Published var selected: String?
    private var scanner: Scanner?
    private var scanID = UUID()

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Scan Folder"
        if panel.runModal() == .OK, let url = panel.url { start(url) }
    }
    func start(_ url: URL) {
        scanner?.cancel()
        let id = UUID(); scanID = id
        result = nil; selected = nil; scanning = true; status = "Scanning \(url.path)…"
        let worker = Scanner { [weak self] count, path in
            Task { @MainActor [weak self] in
                guard let self, self.scanID == id else { return }
                self.status = "Scanned \(count.formatted()) files · \(path)"
            }
        }
        scanner = worker
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = worker.scan(url)
            await MainActor.run { [weak self] in
                guard let self, self.scanID == id else { return }
                self.scanning = false; self.scanner = nil
                self.result = result
                if let result {
                    self.status = "\(result.files.formatted()) files scanned" + (result.skipped > 0 ? " · \(result.skipped.formatted()) items could not be read" : "")
                } else { self.status = "Scan cancelled." }
            }
        }
    }
    func cancel() { scanner?.cancel(); scanID = UUID(); scanner = nil; scanning = false; status = "Scan cancelled." }
}

struct NodeRow: View {
    let node: FileNode
    let rootSize: Int64
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
                .frame(width: 18)
            Text(node.name).lineLimit(1)
            Spacer(minLength: 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.blue.opacity(0.6))
                        .frame(width: geo.size.width * CGFloat(rootSize > 0 ? min(1, Double(node.size) / Double(rootSize)) : 0))
                }.frame(height: 6).frame(maxHeight: .infinity)
            }.frame(width: 90, height: 18)
            Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                .monospacedDigit().frame(width: 95, alignment: .trailing)
        }
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) } }
        .help(node.url.path)
    }
}

struct ContentView: View {
    @StateObject private var model = ScanModel()
    var body: some View {
        VStack(spacing: 0) {
            if let result = model.result {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.root.name).font(.title2.bold())
                        Text(result.root.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: result.root.size, countStyle: .file)).font(.title2.monospacedDigit())
                }.padding()
                Divider()
                HStack { Text("NAME"); Spacer(); Text("SHARE OF SCAN").frame(width: 100); Text("SIZE").frame(width: 95, alignment: .trailing) }
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                List {
                    OutlineGroup(result.root.children ?? [], children: \.children) { node in
                        NodeRow(node: node, rootSize: result.root.size)
                    }
                }.listStyle(.inset)
            } else {
                Spacer()
                Image(systemName: "chart.bar.xaxis").font(.system(size: 48)).foregroundStyle(.blue)
                Text("See where your space goes").font(.title2.bold()).padding(.top, 10)
                Text("Choose a folder to inspect files and subfolders by size.")
                    .foregroundStyle(.secondary).padding(.top, 2)
                Button("Choose Folder…") { model.choose() }.controlSize(.large).padding(.top, 12).disabled(model.scanning)
                Spacer()
            }
            Divider()
            HStack {
                if model.scanning { ProgressView().controlSize(.small) }
                Text(model.status).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Logical file sizes").foregroundStyle(.secondary)
            }.font(.caption).padding(10)
        }
        .frame(minWidth: 680, minHeight: 480)
        .toolbar {
            ToolbarItemGroup {
                Button { model.start(FileManager.default.homeDirectoryForCurrentUser) } label: { Label("Scan Home", systemImage: "house") }.disabled(model.scanning)
                Button { model.choose() } label: { Label("Choose Folder", systemImage: "folder") }.disabled(model.scanning)
                if model.scanning { Button("Cancel") { model.cancel() } }
            }
        }
    }
}

@main struct SpaceTreeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 900, height: 650)
    }
}
