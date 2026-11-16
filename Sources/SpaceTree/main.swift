import SwiftUI
import AppKit
import Darwin

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
    let excluded: Int
}

final class Scanner: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var skipped = 0
    private var files = 0
    private var excluded = 0
    private var rootDevice: dev_t = 0
    private let progress: @Sendable (Int, String) -> Void
    init(progress: @escaping @Sendable (Int, String) -> Void) { self.progress = progress }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private static let cloudPaths: [String] = {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        return [library + "/Mobile Documents", library + "/CloudStorage"]
    }()

    static func isCloudPath(_ path: String) -> Bool {
        cloudPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func isAllowedRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !isCloudPath(path) else { return false }
        var fs = statfs()
        guard statfs(path, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return false }
        let mount = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mount != "/Volumes" && !mount.hasPrefix("/Volumes/")
    }

    func scan(_ url: URL) -> ScanResult? {
        var info = stat()
        guard Self.isAllowedRoot(url), lstat(url.path, &info) == 0 else { return nil }
        rootDevice = info.st_dev
        guard let root = walk(url), !isCancelled else { return nil }
        return ScanResult(root: root, skipped: skipped, files: files, excluded: excluded)
    }

    private func walk(_ url: URL) -> FileNode? {
        if isCancelled { return nil }
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else { skipped += 1; return nil }
        if info.st_dev != rootDevice { excluded += 1; return nil }
        let type = info.st_mode & mode_t(S_IFMT)
        // Never follow symbolic links; this prevents cycles and crossing into other accounts.
        if type == mode_t(S_IFLNK) { return nil }
        if type == mode_t(S_IFDIR), Self.isCloudPath(path) { excluded += 1; return nil }
        guard type == mode_t(S_IFDIR) else {
            files += 1
            if files % 1000 == 0 { progress(files, url.deletingLastPathComponent().path) }
            return FileNode(url: url, size: max(0, info.st_size), isDirectory: false, children: nil)
        }
        guard let directory = opendir(url.path) else {
            skipped += 1
            return FileNode(url: url, size: 0, isDirectory: true, children: nil)
        }
        defer { closedir(directory) }
        var children: [FileNode] = []
        var total: Int64 = 0
        while !isCancelled {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { skipped += 1 }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingCString: $0) }
            }
            guard let name else { skipped += 1; continue }
            if name == "." || name == ".." { continue }
            let childURL = url.appendingPathComponent(name)
            if let child = walk(childURL) { children.append(child); total += child.size }
        }
        if isCancelled { return nil }
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
        guard Scanner.isAllowedRoot(url) else {
            status = "Cloud folders and external or network volumes are excluded."
            return
        }
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
                    self.status = "\(result.files.formatted()) files scanned" + (result.skipped > 0 ? " · \(result.skipped.formatted()) items could not be read" : "") + (result.excluded > 0 ? " · \(result.excluded.formatted()) cloud folders or volumes excluded" : "")
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
