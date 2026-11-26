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
                MovesColumn().frame(width: 300)
                ControlColumn().frame(maxWidth: .infinity)
                SideColumn().frame(width: 300)
            }
            .padding(16)
        }
        .toolbar {
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

struct MovesColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MOVES").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.addMove() } label: { Label("New move", systemImage: "plus") }
                    .help("Adds a move whose end point (B) is where the camera is now")
            }
            List {
                ForEach($model.moves) { $move in
                    MoveCard(move: $move)
                        .contextMenu {
                            Button("Delete “\(move.name)”", role: .destructive) { model.deleteMove(move.id) }
                        }
                }
            }
        }
    }
}

/// One move: A (optional start) → B (end), how long it takes, the curve, and what triggers it.
struct MoveCard: View {
    @EnvironmentObject var model: AppModel
    @Binding var move: Move

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $move.name)
                    .textFieldStyle(.plain)
                    .bold()
                    .onSubmit { model.saveMoves() }
                Spacer()
                Button { model.run(moveID: move.id) } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("Run \(move.name)")
            }

            pointRow(label: "A", title: move.start == nil ? "From wherever the camera is" : "Start point set",
                     isSet: move.start != nil,
                     set: { model.captureStart(for: move.id) },
                     go: move.start == nil ? nil : { model.goTo(.start, of: move.id) },
                     clear: move.start == nil ? nil : { model.clearStart(for: move.id) })
            pointRow(label: "B", title: "End point", isSet: true,
                     set: { model.captureEnd(for: move.id) },
                     go: { model.goTo(.end, of: move.id) },
                     clear: nil)

            HStack {
                Text("\(move.duration, specifier: "%.1f") s").monospacedDigit().frame(width: 44, alignment: .leading)
                Slider(value: $move.duration, in: 1...30, step: 0.5, onEditingChanged: { editing in
                    if !editing { model.saveMoves() }
                })
            }
            .font(.caption)

            HStack {
                Picker("Curve", selection: $move.easing) {
                    ForEach(Easing.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .onChange(of: move.easing) { _, _ in model.saveMoves() }
                TextField("Ecamm scene", text: Binding(
                    get: { move.ecammScene ?? "" },
                    set: { move.ecammScene = $0.isEmpty ? nil : $0 }
                ))
                .onSubmit { model.saveMoves() }
            }
            .font(.caption)

            Toggle("Start AI tracking when it arrives", isOn: $move.trackAfterArriving)
                .font(.caption)
                .onChange(of: move.trackAfterArriving) { _, _ in model.saveMoves() }

            if model.runningMoveID == move.id {
                ProgressView(value: model.progress)
            }
        }
        .padding(.vertical, 4)
    }

    private func pointRow(label: String, title: String, isSet: Bool, set: @escaping () -> Void,
                          go: (() -> Void)?, clear: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Circle().fill(isSet ? Color.accentColor : Color.gray.opacity(0.4)))
                .foregroundStyle(.white)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Set", action: set).help("Use where the camera is now")
            if let go { Button("Go", action: go).help("Glide there now") }
            if let clear { Button(action: clear) { Image(systemName: "xmark") }.help("Start from wherever the camera is") }
        }
        .font(.caption)
        .buttonStyle(.borderless)
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
