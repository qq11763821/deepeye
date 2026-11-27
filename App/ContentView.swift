import SwiftUI
import ReplayKit

struct ContentView: View {
    @StateObject private var reader = FrameReader()
    @StateObject private var vm = PokerViewModel()
    @StateObject private var pip = PiPManager()
    @State private var showBroadcastPicker = false

    var body: some View {
        VStack(spacing: 10) {
            header

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.black)
                if let img = reader.image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay(DetectionOverlay(detections: vm.detections))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(reader.status)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .padding(.horizontal, 10)

            decisionPanel

            Text(vm.status)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal)

            controls

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .background(
            // PiP 的 layer 必须挂在窗口上才能启动，1×1 隐形即可
            PiPHostView(layer: pip.displayLayer)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
        .onChange(of: vm.decision?.reason) { _ in
            pip.update(decision: vm.decision, table: vm.table)
        }
        .onAppear {
            reader.onPixelBuffer = { pb in vm.process(pixelBuffer: pb) }
            reader.start()
        }
        .onDisappear { reader.stop() }
        .sheet(isPresented: $showBroadcastPicker) { BroadcastPickerView() }
    }

    // MARK: 顶部状态条

    private var header: some View {
        HStack(spacing: 14) {
            Label(String(format: "%.0f", reader.fps), systemImage: "speedometer")
            Label("\(reader.frameCount)", systemImage: "square.stack.3d.up")
            Label(vm.table.street.name, systemImage: "suit.spade.fill")
            Spacer()
            Label(vm.recognizedCards.isEmpty ? "-" : vm.recognizedCards,
                  systemImage: "rectangle.on.rectangle")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
    }

    // MARK: 决策面板

    private var decisionPanel: some View {
        VStack(spacing: 6) {
            if let d = vm.decision {
                HStack(spacing: 10) {
                    Text(d.action.rawValue)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(color(for: d.action))
                    if d.amount > 0 {
                        Text(String(format: "%.0f", d.amount))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(color(for: d.action))
                    }
                    Spacer()
                    if d.equity > 0 {
                        Text(String(format: "胜率 %.0f%%", d.equity * 100))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(d.reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text("等待牌局…")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text("开启录屏广播后，切到牌桌即可自动识别")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 10)
    }

    private func color(for a: Action) -> Color {
        switch a {
        case .raise: return .green
        case .call:  return .blue
        case .check: return .secondary
        case .fold:  return .red
        }
    }

    // MARK: 控制

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                showBroadcastPicker = true
            } label: {
                Label("开启录屏", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                pip.toggle()
            } label: {
                Label(pip.isActive ? "关闭悬浮" : "悬浮窗",
                      systemImage: pip.isActive ? "pip.exit" : "pip.enter")
            }
            .buttonStyle(.bordered)
            .disabled(!pip.isSupported)

            Button {
                vm.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - 检测框叠加

struct DetectionOverlay: View {
    let detections: [Detection]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(detections.enumerated()), id: \.offset) { _, d in
                let r = CGRect(x: d.rect.minX * geo.size.width,
                               y: d.rect.minY * geo.size.height,
                               width: d.rect.width * geo.size.width,
                               height: d.rect.height * geo.size.height)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(color(for: d.label), lineWidth: 1.2)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    Text(d.label)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 2)
                        .background(color(for: d.label))
                        .position(x: r.minX + 14, y: r.minY - 6)
                }
            }
        }
    }

    private func color(for label: String) -> Color {
        if Detection.rankValue(label) != nil { return .yellow }
        switch label {
        case "player": return .cyan
        case "money": return .orange
        case "btn": return .purple
        case "zdc": return .pink
        default: return .green
        }
    }
}

// MARK: - 广播选择器

struct BroadcastPickerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 260, height: 90))
        picker.preferredExtension = Bundle.main.bundleIdentifier.map {
            "\($0).Broadcast"
        }
        picker.showsMicrophoneButton = false
        vc.view.addSubview(picker)
        vc.view.frame = picker.frame
        return vc
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
