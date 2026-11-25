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
            Text("MOVES").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($model.moves) { $move in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(move.name).bold()
                            Spacer()
                            Button {
                                model.run(moveID: move.id)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .accessibilityLabel("Run \(move.name)")
                        }
                        HStack {
                            Text("\(move.duration, specifier: "%.1f") s")
                            Picker("Easing", selection: $move.easing) {
                                ForEach(Easing.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: move.easing) { _, _ in model.saveMoves() }
                        }
                        .font(.caption)
                        HStack {
                            TextField("Ecamm scene", text: Binding(
                                get: { move.ecammScene ?? "" },
                                set: { move.ecammScene = $0.isEmpty ? nil : $0 }
                            ))
                            .onSubmit { model.saveMoves() }
                        }
                        .font(.caption)
                        HStack {
                            Button("Set start") { model.captureStart(for: move.id) }
                            Button("Set end") { model.captureEnd(for: move.id) }
                        }
                        .font(.caption)
                        if model.runningMoveID == move.id {
                            ProgressView(value: model.progress)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
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

            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.4))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(Text("NDI preview goes here (needs the NDI SDK)").foregroundStyle(.secondary))

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

            GroupBox("AI tracking") {
                Text("Coming next: on-device person tracking with Apple Vision.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
