import AVFoundation
import EditCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The bin: everything brought into the project, laid out as slides on an upright light table.
/// Nothing goes straight onto the timeline: imports and takes land here, and the bin puts them
/// on it. TAKES holds what was shot on the Record page; ALL MEDIA holds everything. Tap slides
/// to pick them (numbered in the order picked) and add them to the timeline: pictures on the end
/// of the sequence (at the playhead in LIGHTBOX), sounds at the playhead on a sound lane. Media
/// stays in the bin after it's used, marked with how many times. Hold a slide for its details,
/// to rename it or to remove it.
struct BinView: View {
    var model: WorkspaceModel

    enum Folder { case takes, all }
    private enum ImportKind { case pictures, sound }

    @Environment(\.dismiss) private var dismiss
    @State private var folder: Folder
    @State private var picked: [UUID] = []
    @State private var showsRecord = false
    @State private var showsPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsFiles = false
    @State private var fileKind = ImportKind.pictures
    @State private var renaming: WorkspaceModel.BinItem?
    @State private var draftName = ""
    @State private var removing: WorkspaceModel.BinItem?

    init(model: WorkspaceModel) {
        self.model = model
        _folder = State(initialValue: model.binItems.first?.isTake == true ? .takes : .all)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            folderKeys
            table
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(Theme.obsidian.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showsRecord) {
            RecordView(model: model, mode: .video) { showsRecord = false }
        }
        .photosPicker(
            isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 20,
            matching: .any(of: [.videos, .images]), preferredItemEncoding: .current
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await model.importPhotos(items) }
        }
        .fileImporter(
            isPresented: $showsFiles, allowedContentTypes: fileKind == .pictures ? [.movie, .image] : [.audio],
            allowsMultipleSelection: fileKind == .pictures
        ) { result in
            guard case .success(let urls) = result else { return }
            switch fileKind {
            case .pictures: Task { await model.importFiles(urls) }
            case .sound: if let url = urls.first { Task { await model.importSoundFile(url) } }
            }
        }
        .onChange(of: model.binItems.first?.id) { _, _ in
            // Something new came in: show it, in TAKES if it's a take.
            folder = model.binItems.first?.isTake == true ? .takes : .all
        }
        .alert("Rename", isPresented: isRenaming, presenting: renaming) { item in
            TextField("Name", text: $draftName)
            Button("Rename") { model.renameMedia(item.id, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove from the bin?", isPresented: isRemoving, titleVisibility: .visible, presenting: removing
        ) { item in
            Button("Remove from bin and timeline", role: .destructive) { remove(item) }
        } message: { item in
            Text(removalMessage(item))
        }
    }

    private var items: [WorkspaceModel.BinItem] {
        folder == .takes ? model.binItems.filter(\.isTake) : model.binItems
    }

    private var isRenaming: Binding<Bool> {
        Binding {
            renaming != nil
        } set: {
            if !$0 { renaming = nil }
        }
    }

    private var isRemoving: Binding<Bool> {
        Binding {
            removing != nil
        } set: {
            if !$0 { removing = nil }
        }
    }

    private func removalMessage(_ item: WorkspaceModel.BinItem) -> String {
        let uses = model.binUses(of: item.id)
        let times = uses == 1 ? "once" : "\(uses) times"
        return "It's used \(times) on the timeline, which loses it too. Undo brings it back."
    }

    // MARK: Header and folders

    private var header: some View {
        HStack(spacing: 8) {
            Text("BIN")
                .font(Theme.mono(13, weight: .bold))
                .tracking(3)
                .foregroundStyle(Theme.label)
                .accessibilityAddTraits(.isHeader)
            LED(isOn: true)
            Spacer()
            if let status = model.importStatus {
                HStack(spacing: 6) {
                    ProgressView().tint(Theme.signal).controlSize(.mini)
                    Text(status.uppercased()).font(Theme.mono(9, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
                }
            }
            Button("Done") { dismiss() }
                .buttonStyle(.instrument(.dark, height: 30))
        }
    }

    private var folderKeys: some View {
        HStack(spacing: 4) {
            folderKey(.takes, "TAKES", count: model.binItems.filter(\.isTake).count)
            folderKey(.all, "ALL MEDIA", count: model.binItems.count)
            Spacer()
            if !picked.isEmpty {
                Button("Clear") { picked = [] }
                    .buttonStyle(.instrument(.dark, height: 26))
                    .font(Theme.mono(9, weight: .bold))
            }
        }
    }

    private func folderKey(_ key: Folder, _ title: String, count: Int) -> some View {
        Button {
            folder = key
            Haptics.detent()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").font(.system(size: 10, weight: .bold))
                Text(title).font(Theme.mono(9, weight: .bold))
                Text("\(count)").font(Theme.mono(9, weight: .bold)).opacity(0.6)
            }
        }
        .buttonStyle(.instrument(.dark, active: folder == key, height: 26))
        .accessibilityLabel("\(title.capitalized), \(count)")
        .accessibilityAddTraits(folder == key ? .isSelected : [])
    }

    // MARK: Light table

    private var table: some View {
        ScrollView {
            if items.isEmpty {
                emptyFolder.frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 14) {
                    ForEach(items) { item in
                        slide(item)
                    }
                }
                .padding(12)
            }
        }
        .background(LightTableSurface())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .metalBezel(cornerRadius: 12, width: 4)
    }

    private func slide(_ item: WorkspaceModel.BinItem) -> some View {
        let uses = model.binUses(of: item.id)
        let pick = picked.firstIndex(of: item.id).map { $0 + 1 }
        return BinSlide(item: item, url: url(of: item), uses: uses, pick: pick) {
            toggle(item.id)
        }
        .contextMenu {
            Button {
                model.addFromBin([item.id])
                Haptics.success()
                dismiss()
            } label: {
                Label("Add to timeline", systemImage: "plus.rectangle.on.rectangle")
            }
            if case .picture(let source) = item {
                lookMenu(for: source)
            }
            Button {
                draftName = item.name
                renaming = item
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                if uses > 0 { removing = item } else { remove(item) }
            } label: {
                Label("Remove from bin", systemImage: "trash")
            }
        } preview: {
            BinInfoCard(item: item, url: url(of: item), uses: uses)
        }
    }

    /// Changes the look a picture plays through, or takes it off; its clips follow.
    private func lookMenu(for source: SourceAsset) -> some View {
        Menu {
            Button {
                model.setLook(nil, forSource: source.id)
            } label: {
                Label("Clean", systemImage: source.look == nil ? "checkmark" : "circle.slash")
            }
            let imported = LookLibrary.imported()
            ForEach(LookLibrary.builtInGroups + (imported.isEmpty ? [] : [("Imported", imported)]), id: \.title) {
                group in
                Menu(group.title) {
                    ForEach(group.looks, id: \.id) { look in
                        Button {
                            model.setLook(look, forSource: source.id)
                        } label: {
                            if source.look?.id == look.id {
                                Label(look.name, systemImage: "checkmark")
                            } else {
                                Text(look.name)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Look: \(source.look?.name ?? "Clean")", systemImage: "camera.filters")
        }
    }

    private func url(of item: WorkspaceModel.BinItem) -> URL? {
        switch item {
        case .picture(let source): model.mediaURL(for: source)
        case .sound(let sound): model.mediaURL(forFile: sound.fileName)
        }
    }

    private var emptyFolder: some View {
        VStack(spacing: 8) {
            Image(systemName: folder == .takes ? "record.circle" : "tray")
                .font(.system(size: 26, weight: .semibold))
            Text(folder == .takes ? "NO TAKES YET" : "NOTHING BROUGHT IN YET")
                .font(Theme.mono(10, weight: .bold))
            Text(folder == .takes ? "Shoot with REC and every take lands here." : "Import or shoot, and it lands here.")
                .font(.footnote)
        }
        .foregroundStyle(Color.black.opacity(0.45))
    }

    private func toggle(_ id: UUID) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
        Haptics.tap()
    }

    private func remove(_ item: WorkspaceModel.BinItem) {
        picked.removeAll { $0 == item.id }
        model.removeFromBin([item.id])
        Haptics.press()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                showsRecord = true
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(Theme.playhead).frame(width: 7, height: 7)
                    Text("REC").font(Theme.mono(11, weight: .bold))
                }
            }
            .buttonStyle(.instrument(.dark, height: 40))
            .accessibilityLabel("Record")
            .accessibilityHint("Shoots into the TAKES folder.")
            importMenu
            Button {
                model.addFromBin(picked)
                Haptics.success()
                dismiss()
            } label: {
                Text(picked.isEmpty ? "PICK TO ADD" : "ADD \(picked.count) TO TIMELINE")
                    .font(Theme.mono(11, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.instrument(.prominent, height: 40))
            .disabled(picked.isEmpty)
            .accessibilityHint(
                model.isInLightbox
                    ? "Adds the picked media at the playhead, in the order picked."
                    : "Adds pictures to the end of the sequence and sounds at the playhead, in the order picked.")
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                showsPhotos = true
            } label: {
                Label("From Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                fileKind = .pictures
                showsFiles = true
            } label: {
                Label("Clips from Files", systemImage: "folder")
            }
            Button {
                fileKind = .sound
                showsFiles = true
            } label: {
                Label("Sound from Files", systemImage: "waveform")
            }
            Button {
                Task { await model.addDemoClips() }
            } label: {
                Label("Demo clips", systemImage: "film.stack")
            }
        } label: {
            Text("IMPORT").font(Theme.mono(11, weight: .bold))
        }
        .menuStyle(.button)
        .buttonStyle(.instrument(.dark, height: 40))
        .accessibilityHint("Brings media into the bin.")
    }
}

/// The light table: a warm backlit surface with a faint ruled grid.
private struct LightTableSurface: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(hex: 0xFFFBEF), Theme.lightTable, Color(hex: 0xE4DCC6)], center: .center,
                startRadius: 20, endRadius: 520)
            Canvas { context, size in
                var grid = Path()
                for x in stride(from: 0, through: size.width, by: 24) {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0, through: size.height, by: 24) {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.black.opacity(0.05)), lineWidth: 0.5)
            }
        }
    }
}

/// A slide's window: the picture at its own shape, or a sound's tinted glass.
private struct BinPicture: View {
    let item: WorkspaceModel.BinItem
    let url: URL?
    var maxPixel: CGFloat = 240

    var body: some View {
        ZStack {
            switch item {
            case .picture(let source):
                Color.black
                VideoFrameView(url: url, time: Self.frameTime(source), maxPixel: maxPixel, look: source.look)
                    .aspectRatio(Self.aspect(source), contentMode: .fit)
            case .sound:
                LinearGradient(
                    colors: [Theme.soundGlass, Theme.soundGlass.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.soundInk)
            }
        }
    }

    private static func aspect(_ source: SourceAsset) -> CGFloat {
        source.height > 0 ? CGFloat(source.width) / CGFloat(source.height) : 1
    }

    private static func frameTime(_ source: SourceAsset) -> CMTime {
        source.isStill ? .zero : MediaTime(seconds: min(1, source.duration.seconds / 2)).cmTime
    }
}

extension WorkspaceModel.BinItem {
    /// VIDEO, PHOTO or SOUND.
    var kind: String {
        switch self {
        case .picture(let source): source.isStill ? "PHOTO" : "VIDEO"
        case .sound: "SOUND"
        }
    }

    /// m:ss, or PHOTO for a still.
    var lengthText: String {
        if case .picture(let source) = self, source.isStill { return "PHOTO" }
        let seconds = Int(duration.seconds.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// One piece of media as a slide in its mount: the picture (or sound), its name and length (or
/// PHOTO) printed on the mount, how often it's used, and, once picked, its number in the order
/// picked.
private struct BinSlide: View {
    let item: WorkspaceModel.BinItem
    let url: URL?
    let uses: Int
    let pick: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                BinPicture(item: item, url: url)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(hex: 0xFAF7EE))
                            .shadow(color: .black.opacity(0.25), radius: pick == nil ? 2 : 6, y: pick == nil ? 1 : 3)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.signal, lineWidth: pick == nil ? 0 : 3)
                    )
                    .overlay(alignment: .topTrailing) { pickBadge }
                    .overlay(alignment: .bottomLeading) { lengthTag }
                VStack(spacing: 1) {
                    Text(item.name)
                        .font(Theme.mono(9, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.75))
                        .lineLimit(1)
                    Text(uses == 0 ? "UNUSED" : "IN USE ×\(uses)")
                        .font(Theme.mono(7, weight: .bold))
                        .foregroundStyle(uses == 0 ? Color.black.opacity(0.35) : Theme.acetateInk)
                }
            }
            .scaleEffect(pick == nil ? 1 : 0.97)
            .animation(.easeOut(duration: 0.12), value: pick)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Picks it. Hold for details, rename and remove.")
        .accessibilityAddTraits(pick == nil ? [] : .isSelected)
    }

    private var accessibilityValue: String {
        let use = uses == 0 ? "unused" : "used \(uses) times"
        return "\(item.kind.capitalized), \(item.lengthText), \(use)"
    }

    @ViewBuilder
    private var pickBadge: some View {
        if let pick {
            Text("\(pick)")
                .font(Theme.mono(10, weight: .bold))
                .foregroundStyle(Theme.obsidian)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.signal))
                .offset(x: 6, y: -6)
        }
    }

    private var lengthTag: some View {
        Text(item.lengthText)
            .font(Theme.mono(8, weight: .bold))
            .foregroundStyle(Theme.ivory)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.65)))
            .padding(9)
    }
}

/// What holding a slide shows: the picture larger, and its details as a printed spec card.
private struct BinInfoCard: View {
    let item: WorkspaceModel.BinItem
    let url: URL?
    let uses: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BinPicture(item: item, url: url, maxPixel: 600)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.label)
                .lineLimit(2)
            VStack(spacing: 5) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0).font(Theme.mono(9, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
                        Spacer()
                        Text(row.1).font(Theme.mono(10, weight: .bold)).foregroundStyle(Theme.label)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.obsidian)
    }

    private var rows: [(String, String)] {
        var rows = [("KIND", item.kind), ("FROM", item.isTake ? "TAKE" : "IMPORTED")]
        if case .picture(let source) = item { rows.append(("LOOK", source.look?.name ?? "CLEAN")) }
        switch item {
        case .picture(let source) where source.isStill:
            rows.append(("SIZE", "\(source.width) × \(source.height)"))
        case .picture(let source):
            rows.append(("LENGTH", String(format: "%.2f s", item.duration.seconds)))
            rows.append(("SIZE", "\(source.width) × \(source.height)"))
            rows.append(("FRAME RATE", String(format: "%.2f fps", source.frameRate)))
            rows.append(("SOUND", source.hasAudio ? "YES" : "NONE"))
        case .sound:
            rows.append(("LENGTH", String(format: "%.2f s", item.duration.seconds)))
        }
        rows.append(("ADDED", item.importedAt.formatted(date: .abbreviated, time: .shortened).uppercased()))
        if let url, let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
            rows.append(("FILE", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        rows.append(("ON TIMELINE", uses == 0 ? "UNUSED" : "×\(uses)"))
        return rows
    }
}
