import AppKit
import AppshotCore
import Combine
import SwiftUI

struct SettingsView: View {
    @Bindable var controller: AppController
    @State private var recording = false
    @State private var recorder: Any?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "화면 기록",
                    detail: "맨 앞 창의 스크린샷을 찍어요.",
                    granted: controller.screenRecordingAllowed,
                    request: controller.requestScreenRecording,
                    openSettings: { controller.openPrivacyPane("Privacy_ScreenCapture") }
                )
                PermissionRow(
                    title: "손쉬운 사용",
                    detail: "창 안 글자를 읽고 단축키를 들어요.",
                    granted: controller.accessibilityAllowed,
                    request: controller.requestAccessibility,
                    openSettings: { controller.openPrivacyPane("Privacy_Accessibility") }
                )
                HStack {
                    Text("허용한 뒤 바로 반영되지 않으면 앱을 다시 시작해 주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("다시 시작", action: controller.relaunch)
                }
            } header: {
                Text("권한")
            }

            Section {
                LabeledContent("위치") {
                    Text(AppshotConfig.defaultURL.path(percentEncoded: false))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let error = controller.configError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if let config = controller.config {
                    LabeledContent("보낼 곳", value: config.channels.map(\.label).joined(separator: " · "))
                }
                HStack {
                    Button("템플릿 만들기", action: controller.createConfigTemplate)
                        .disabled(controller.config != nil)
                    Button("Finder에서 보기", action: controller.revealConfig)
                    Button("다시 읽기", action: controller.reloadConfig)
                }
            } header: {
                Text("설정 파일")
            } footer: {
                Text("채널 ID와 경로는 이 파일에만 적어요. 저장소에는 들어가지 않아요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("단축키", selection: presetBinding) {
                    ForEach(ModifierSide.allCases, id: \.self) { side in
                        Text(Shortcut.bothSides(side).display + " (양쪽 같이)").tag(Optional(side))
                    }
                    Text("직접 지정한 조합").tag(ModifierSide?.none)
                }
                HStack {
                    Text("지금: \(controller.shortcut.display)").monospaced()
                    Spacer()
                    Button(recording ? "키 조합을 누르세요… (esc 취소)" : "조합 녹화", action: toggleRecording)
                }
            } header: {
                Text("단축키")
            }

            Section {
                Toggle("로그인할 때 자동으로 열기", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                if let last = controller.lastResult {
                    LabeledContent("최근 결과", value: last)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(timer) { _ in controller.refreshStatus() }
        .onDisappear(perform: stopRecording)
    }

    private var presetBinding: Binding<ModifierSide?> {
        Binding(
            get: {
                if case .bothSides(let side) = controller.shortcut { return side }
                return nil
            },
            set: { side in
                if let side { controller.shortcut = .bothSides(side) } else { toggleRecording() }
            }
        )
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
            return
        }
        recording = true
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { capture(event) }
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        defer { stopRecording() }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode != 53, !modifiers.intersection([.command, .option, .control]).isEmpty else { return }
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
        let key = event.charactersIgnoringModifiers?.uppercased() ?? "#\(event.keyCode)"
        controller.shortcut = .combo(keyCode: event.keyCode, modifiers: UInt64(modifiers.rawValue), display: symbols + key)
    }

    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = false
    }
}

private struct PermissionRow: View {
    var title: String
    var detail: String
    var granted: Bool
    var request: () -> Void
    var openSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityLabel(granted ? "허용됨" : "필요함")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("허용 요청", action: request)
            }
            Button("설정 열기", action: openSettings)
        }
    }
}
