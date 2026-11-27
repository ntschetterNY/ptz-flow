import PTZFlowCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showUpdateBanner, let release = model.availableUpdate {
                UpdateBanner(release: release, releasesPage: model.updateChecker.releasesPage) {
                    model.updateDismissed = true
                }
            }
            HStack(alignment: .top, spacing: 16) {
                MovesColumn().frame(width: 320)
                ControlColumn().frame(maxWidth: .infinity)
                SideColumn().frame(width: 300)
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                PowerButtons()
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $model.isRecording) {
                    Label(model.isRecording ? "Recording" : "Record", systemImage: "record.circle")
                }
                .help("Recording is not built yet; this only pauses update notices for now.")
            }
        }
    }
}

/// "A new version is on GitHub" notice. Updating is manual for now (no Apple Developer ID yet):
/// download from the release page, or run scripts/update-from-source.sh.
struct UpdateBanner: View {
    let release: ReleaseInfo
    let releasesPage: URL
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("PTZ Flow \(release.version) is available on GitHub").bold()
                Text("You're on \(AppVersion.running). Download it from the release page, or run scripts/update-from-source.sh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Later", action: dismiss)
            Link("Open on GitHub", destination: release.htmlURL)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.15))
    }
}

/// Left side, split in two: the four preset tiles (with a picture of where each one ends) on top,
/// and the selected move's settings underneath.
struct MovesColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VSplitView {
            PresetGrid()
                .frame(minHeight: 220, idealHeight: 300)
                .padding(.bottom, 8)
            MoveEditor()
                .frame(minHeight: 260)
                .padding(.top, 8)
        }
    }
}

struct PresetGrid: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRESETS").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(model.moves.prefix(4).enumerated()), id: \.element.id) { index, move in
                    PresetTile(number: index + 1, move: move)
                }
            }
            Text("Click a tile to go there. Stream Deck: /preset/1 to /preset/4")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }
}

struct PresetTile: View {
    @EnvironmentObject var model: AppModel
    let number: Int
    let move: Move

    var body: some View {
        let selected = model.selectedMoveID == move.id
        let running = model.runningMoveID == move.id
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                if let thumb = model.thumbnails[move.id] {
                    Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                } else {
                    Text("No picture yet.\nPress “Save end point”.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("\(number)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(running ? Color.green : Color.black.opacity(0.6)))
                    .foregroundStyle(.white)
                    .padding(4)
                if running {
                    VStack { Spacer(); ProgressView(value: model.progress).tint(.green) }.padding(4)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            Text(move.name).font(.caption).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedMoveID = move.id
            model.run(moveID: move.id)
        }
        .contextMenu {
            Button("Save end point here") { model.captureEnd(for: move.id) }
            Button("Edit") { model.selectedMoveID = move.id }
        }
        .accessibilityLabel("Preset \(number), \(move.name)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Settings for the selected move. The common case is just: save an end point, pick a time, done.
struct MoveEditor: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let i = model.moves.firstIndex(where: { $0.id == model.selectedMoveID }) {
                MoveSettings(move: $model.moves[i], presetNumber: i < 4 ? i + 1 : nil)
            } else {
                Text("Select a preset or move").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("ALL MOVES").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.addMove() } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .help("Adds a move that ends where the camera is now")
            }
            List(selection: $model.selectedMoveID) {
                ForEach(Array(model.moves.enumerated()), id: \.element.id) { index, move in
                    HStack {
                        Text(index < 4 ? "\(index + 1)" : "·").monospacedDigit().foregroundStyle(.secondary).frame(width: 14)
                        Text(move.name)
                        Spacer()
                        if let scene = move.ecammScene { Text(scene).font(.caption).foregroundStyle(.secondary) }
                        Button { model.run(moveID: move.id) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                    }
                    .tag(move.id)
                    .contextMenu {
                        Button("Delete “\(move.name)”", role: .destructive) { model.deleteMove(move.id) }
                    }
                }
                .onMove { from, to in
                    model.moves.move(fromOffsets: from, toOffset: to)
                    model.saveMoves()
                }
            }
            .frame(minHeight: 100)
            Text("Drag to reorder. The first four are the preset tiles.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct MoveSettings: View {
    @EnvironmentObject var model: AppModel
    @Binding var move: Move
    let presetNumber: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let n = presetNumber { Text("\(n)").font(.caption.bold()).foregroundStyle(.secondary) }
                TextField("Name", text: $move.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit { model.saveMoves() }
            }

            HStack {
                Button { model.captureEnd(for: move.id) } label: {
                    Label("Save end point", systemImage: "scope")
                }
                .help("Use where the camera is pointing now (and grab a preview picture)")
                Button { model.goTo(.end, of: move.id) } label: {
                    Label("Go", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Glide straight to the end point")
            }

            HStack {
                Text("Time").font(.caption)
                Slider(value: $move.duration, in: 1...30, step: 0.5, onEditingChanged: { editing in
                    if !editing { model.saveMoves() }
                })
                Text("\(move.duration, specifier: "%.1f") s").font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
            }

            HStack {
                Picker("Curve", selection: $move.easing) {
                    ForEach(Easing.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: move.easing) { _, _ in model.saveMoves() }
            }
            .font(.caption)

            TextField("Ecamm scene that triggers it (optional)", text: Binding(
                get: { move.ecammScene ?? "" },
                set: { move.ecammScene = $0.isEmpty ? nil : $0 }
            ))
            .font(.caption)
            .onSubmit { model.saveMoves() }

            Toggle("Start AI tracking when it arrives", isOn: $move.trackAfterArriving)
                .font(.caption)
                .onChange(of: move.trackAfterArriving) { _, _ in model.saveMoves() }

            DisclosureGroup("Start point (optional)") {
                HStack {
                    Text(move.start == nil ? "None: starts from wherever the camera is" : "Set")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { model.captureStart(for: move.id) }
                    if move.start != nil {
                        Button("Go") { model.goTo(.start, of: move.id) }
                        Button("Clear") { model.clearStart(for: move.id) }
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
    }
}

struct ControlColumn: View {
    @EnvironmentObject var model: AppModel
    @State private var knob: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                TextField("Camera IP address (e.g. 192.168.1.50)", text: $model.cameraHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.connect() }
                Button("Connect") { model.connect() }
                Circle().fill(model.connected ? Color.green : Color.gray).frame(width: 10, height: 10)
                    .accessibilityLabel(model.connected ? "Connected" : "Not connected")
            }

            PreviewPanel(video: model.video)

            HStack(spacing: 24) {
                joystick
                VStack(alignment: .leading, spacing: 8) {
                    Text("Zoom").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { model.jog(x: 0, y: 0, zoom: -0.6) } label: { Image(systemName: "minus.magnifyingglass") }
                        Button { model.releaseJog() } label: { Image(systemName: "stop.fill") }
                        Button { model.jog(x: 0, y: 0, zoom: 0.6) } label: { Image(systemName: "plus.magnifyingglass") }
                    }
                    Button("Hold position") { model.stop() }
                }
            }
        }
    }

    private var joystick: some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.2)).frame(width: 160, height: 160)
            Circle().fill(Color.blue).frame(width: 54, height: 54).offset(knob)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var v = value.translation
                    let r = sqrt(v.width * v.width + v.height * v.height)
                    if r > 53 { v = CGSize(width: v.width / r * 53, height: v.height / r * 53) }
                    knob = v
                    model.jog(x: v.width / 53, y: v.height / 53)
                }
                .onEnded { _ in
                    knob = .zero
                    model.releaseJog()
                }
        )
        .accessibilityLabel("Pan and tilt joystick")
    }
}

struct SideColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Focus") {
                Picker("Focus", selection: $model.focusMode) {
                    ForEach(FocusMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.focusMode) { _, _ in model.applyFocusMode() }
            }

            GroupBox("Stream Deck") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Point a Web Requests key at:").font(.caption)
                    Text("http://127.0.0.1:\(String(ControlServer.defaultPort))/scene/Sermon")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("PTZ Flow switches Ecamm and moves the camera together.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let err = model.serverError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            TurnOnSetting()
            TrackingPanel()

            GroupBox("Activity") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            }
            Spacer()
        }
    }
}

/// Live NDI preview with the AI tracking boxes drawn on top. Click a person to follow them.
struct PreviewPanel: View {
    @EnvironmentObject var model: AppModel
    /// Observed on its own, so a new video frame redraws only the preview, not the whole window.
    @ObservedObject var video: VideoPipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.black)
                    if let frame = video.frame {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        Text(video.status.text)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    ForEach(Array(video.detections.enumerated()), id: \.offset) { _, d in
                        box(d.box, in: geo.size, color: .white.opacity(0.5), width: 1)
                    }
                    if let tracked = model.trackedBox {
                        box(tracked, in: geo.size, color: .green, width: 2.5)
                    }
                    if model.trackingEnabled {
                        let s = model.trackingSettings
                        Circle()
                            .stroke(Color.green.opacity(0.6), lineWidth: 1)
                            .frame(width: geo.size.width * s.deadzone * 2, height: geo.size.width * s.deadzone * 2)
                            .position(x: geo.size.width * s.framingX, y: geo.size.height * s.framingY)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    model.chooseSubject(at: CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Picker("NDI source", selection: Binding(
                    get: { video.selectedSourceName },
                    set: { name in
                        if let source = video.sources.first(where: { $0.name == name }) { video.connect(to: source) }
                    }
                )) {
                    if video.sources.isEmpty { Text("No sources").tag(video.selectedSourceName) }
                    ForEach(video.sources) { Text($0.name).tag($0.name) }
                }
                .frame(maxWidth: 320)
                Button("Find") { video.findAndConnect(cameraHost: model.cameraHost) }
                Picker("Quality", selection: $video.highQuality) {
                    Text("Standard").tag(false)
                    Text("High").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .help("High uses the camera's full-quality NDI stream: sharper, more network and CPU")
                Spacer()
                Text("NDI® is a registered trademark of Vizrt NDI AB.").font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
    }

    private func box(_ r: CGRect, in size: CGSize, color: Color, width: CGFloat) -> some View {
        Rectangle()
            .stroke(color, lineWidth: width)
            .frame(width: r.width * size.width, height: r.height * size.height)
            .position(x: r.midX * size.width, y: r.midY * size.height)
    }
}

struct PowerButtons: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmOff = false

    var body: some View {
        Button { model.turnOn() } label: { Label("Turn On", systemImage: "power") }
            .help("Wake the camera and go to the Turn On shot")
        Button { confirmOff = true } label: { Label("Turn Off", systemImage: "moon.zzz") }
            .help("Tilt all the way down, zoom all the way out, then put the camera in standby")
            .confirmationDialog("Turn the camera off?", isPresented: $confirmOff) {
                Button("Park and turn off", role: .destructive) { model.turnOff() }
            } message: {
                Text("The camera tilts all the way down and zooms all the way out (to keep dust off the lens), then goes to standby.")
            }
        if let status = model.powerStatus {
            ProgressView().controlSize(.small)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TurnOnSetting: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("Camera power") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("After Turn On, go to", selection: Binding(
                    get: { model.resolvedTurnOnMove?.id ?? "" },
                    set: { model.turnOnMoveID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Stay where it starts").tag("")
                    ForEach(model.moves) { Text($0.name).tag($0.id) }
                }
                .font(.caption)
                Text("Turn Off parks the lens facing down and zoomed out, then powers off. Stream Deck: /power/on and /power/off")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TrackingPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("AI tracking") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Follow the speaker", isOn: Binding(get: { model.trackingEnabled }, set: { model.setTracking($0) }))
                    .toggleStyle(.switch)
                Text("Runs on this Mac with Apple Vision. Click a person in the preview to switch who it follows.")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Responsiveness", value: $model.trackingSettings.responsiveness, range: 0...1,
                       left: "Calm", right: "Quick")
                slider("Smoothness", value: Binding(
                    get: { 1 - (model.trackingSettings.acceleration - 40) / 360 },
                    set: { model.trackingSettings.acceleration = 40 + (1 - $0) * 360 }
                ), range: 0...1, left: "Snappy", right: "Silky")
                slider("Dead zone", value: $model.trackingSettings.deadzone, range: 0.02...0.25,
                       left: "Tight", right: "Loose")
                slider("Top speed", value: Binding(
                    get: { model.trackingSettings.maxPanStep },
                    set: { model.trackingSettings.maxPanStep = $0; model.trackingSettings.maxTiltStep = $0 / 2 }
                ), range: 20...200,
                       left: "Slow", right: "Fast")
                slider("Head room", value: Binding(
                    get: { 1 - model.trackingSettings.framingY },
                    set: { model.trackingSettings.framingY = 1 - $0 }
                ), range: 0.35...0.75, left: "Less", right: "More")
                Toggle("Slower when zoomed in", isOn: $model.trackingSettings.zoomAware)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        left: String, right: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            HStack(spacing: 6) {
                Text(left).font(.caption2).foregroundStyle(.secondary)
                Slider(value: value, in: range)
                Text(right).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
