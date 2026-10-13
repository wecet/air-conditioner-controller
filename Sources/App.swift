import SwiftUI
import AppKit

enum OperatingMode: String, CaseIterable { case preview = "Preview", production = "Production" }

final class Controller: ObservableObject {
    @Published private(set) var mode: OperatingMode = .preview
    @Published var state: [String: Int] = [:]
    @Published var devices: [Device] = []
    @Published var selected: Device?
    @Published var busy = false
    @Published var connected = false
    @Published var message = ""
    @Published var address = UserDefaults.standard.string(forKey: "discoveryAddress") ?? "255.255.255.255"
    @Published private(set) var offTimer = OffTimer()
    @Published private(set) var countdownNow = Date()
    @Published private(set) var timerNotice = ""
    private var countdownTicker: Timer?
    private let client = GreeClient()
    private let queue = DispatchQueue(label: "gree.network")
    private var timer: Timer?
    init() {
        let production = CommandLine.arguments.contains("--production")
        changeMode(production ? .production : .preview)
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickOffTimer() }
        countdownTicker = ticker
        RunLoop.main.add(ticker, forMode: .common)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func changeMode(_ next: OperatingMode) {
        guard !busy else { return }
        cancelOffTimer()
        mode = next; selected = nil; devices = []; connected = false
        // All client access stays serialized with network operations.
        queue.async { self.client.clearSession() }
        if next == .preview {
            state = ["Pow": 1, "Mod": 1, "SetTem": 24, "WdSpd": 1, "SwhSlp": 0, "SwUpDn": 1, "SvSt": 0, "TemSen": 65, "TemUn": 0]
            message = "Preview · simulated AC · no network requests"
        } else {
            state = [:]
            message = "Connect a compatible AC to the same network, then Find AC."
        }
    }
    var canControl: Bool { !busy && (mode == .preview || connected) }
    func scan() {
        guard mode == .production, !busy else { return }
        cancelOffTimer()
        busy = true; connected = false; selected = nil; state = [:]; devices = []
        message = "Looking for a compatible AC…"
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(host, forKey: "discoveryAddress")
        queue.async {
            do {
                let found = try self.client.discover(host: host)
                DispatchQueue.main.async {
                    self.devices = found; self.busy = false
                    if let first = found.first { self.select(first) }
                    else { self.message = "No AC found. Check Wi-Fi setup or enter its IPv4 address." }
                }
            } catch { self.fail(error) }
        }
    }
    func select(_ device: Device) {
        guard mode == .production, !busy else { return }
        cancelOffTimer()
        selected = device; state = [:]; connected = false
        refresh()
    }
    func refresh() {
        guard mode == .production, !busy, let device = selected else { return }
        busy = true
        queue.async {
            do { let status = try self.client.status(device); self.apply(status, device: device) }
            catch { self.fail(error) }
        }
    }
    func set(_ values: [String: Int]) {
        guard canControl else { return }
        if values["Pow"] == 0 { cancelOffTimer() }
        if mode == .preview { state.merge(values) { _, new in new }; return }
        guard let device = selected else { return }
        busy = true
        message = "Sending command…"
        queue.async {
            do {
                try self.client.command(device, values: values)
                let status = try self.client.status(device)
                self.apply(status, device: device)
            } catch { self.fail(error) }
        }
    }
    func startOffTimer(amount: Int, hours: Bool) {
        guard canControl, state["Pow"] == 1, (1...1440).contains(amount) else { return }
        let seconds = Double(amount) * (hours ? 3600 : 60)
        guard seconds <= 86400 else { return }
        offTimer.start(seconds: seconds)
        countdownNow = Date()
        timerNotice = ""
    }
    func cancelOffTimer() {
        offTimer.cancel()
        timerNotice = ""
    }
    private func tickOffTimer() {
        countdownNow = Date()
        guard offTimer.isDue(at: countdownNow), !busy else { return }
        offTimer.cancel()
        if mode == .preview {
            state["Pow"] = 0
            timerNotice = "Timer finished · preview AC switched off"
            return
        }
        guard let device = selected else {
            timerNotice = "Timer failed · no AC selected"
            return
        }
        busy = true
        timerNotice = "Timer finished · switching AC off…"
        queue.async {
            do {
                try self.client.command(device, values: ["Pow": 0])
                let status = try self.client.status(device)
                DispatchQueue.main.async {
                    self.state = status; self.connected = true; self.busy = false
                    self.timerNotice = status["Pow"] == 0 ? "Timer finished · AC confirmed off" : "Timer failed · AC still reports on"
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false; self.connected = false
                    self.timerNotice = "Timer failed · off was not confirmed. " + error.localizedDescription
                }
            }
        }
    }
    private func apply(_ status: [String: Int], device: Device) {
        DispatchQueue.main.async { self.state = status; if status["Pow"] == 0 { self.offTimer.cancel() }; self.connected = true; self.busy = false; self.message = "Connected · \(device.host)" }
    }
    private func fail(_ error: Error) {
        DispatchQueue.main.async { self.busy = false; self.connected = false; self.message = error.localizedDescription }
    }
    func toggle(_ key: String) -> Binding<Bool> {
        Binding(get: { self.state[key] == 1 }, set: { self.set([key: $0 ? 1 : 0]) })
    }
}

@main
struct GreeBar: App {
    @StateObject private var controller = Controller()
    var body: some Scene {
        MenuBarExtra {
            Panel(model: controller)
        } label: {
            Image(systemName: "air.conditioner.horizontal")
            if controller.mode == .preview { Text("Demo") }
            else if controller.connected, let temperature = controller.state["SetTem"] { Text("\(temperature)°") }
        }.menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @ObservedObject var model: Controller
    @State private var temperature = 24.0
    @State private var timerAmount = 30
    @State private var timerHours = false
    private let blue = Color(red: 0.3, green: 0.65, blue: 1)
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("GREE · CLIMATE").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.5))
                    Label(roomLabel, systemImage: "thermometer.medium").font(.system(size: 13))
                }
                Spacer()
                Button { model.set(["Pow": model.state["Pow"] == 1 ? 0 : 1]) } label: {
                    Image(systemName: "power").font(.system(size: 22)).frame(width: 44, height: 44)
                        .background(model.state["Pow"] == 1 ? blue : Color.white.opacity(0.08), in: Circle())
                }.buttonStyle(.plain).disabled(!model.canControl).accessibilityLabel("Toggle AC power")
            }
            Picker("Operating mode", selection: Binding(get: { model.mode }, set: { model.changeMode($0) })) {
                ForEach(OperatingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(model.busy)
            illustration.frame(height: 100)
            HStack(alignment: .firstTextBaseline) {
                Text(model.state["SetTem"].map(String.init) ?? "—").font(.system(size: 60, weight: .light, design: .rounded))
                Text("°C").font(.system(size: 18)).foregroundStyle(blue)
                Spacer()
                Toggle("Eco", isOn: model.toggle("SvSt")).toggleStyle(.switch).font(.system(size: 12)).fixedSize().disabled(!available("SvSt"))
            }
            HStack(spacing: 12) {
                temperatureButton("minus", delta: -1)
                Slider(value: $temperature, in: 16...30, step: 1) { editing in
                    if !editing { model.set(["SetTem": Int(temperature), "TemUn": 0]) }
                }.tint(blue).disabled(!available("SetTem"))
                temperatureButton("plus", delta: 1)
            }
            HStack(spacing: 8) {
                control("Mode", icon: "snowflake", key: "Mod", choices: [(0,"Auto"),(1,"Cool"),(2,"Dry"),(3,"Fan"),(4,"Heat")])
                control("Fan", icon: "fan", key: "WdSpd", choices: [(0,"Auto"),(1,"Low"),(2,"Med-low"),(3,"Medium"),(4,"Med-high"),(5,"High")])
                control("Sleep", icon: "moon", key: "SwhSlp", choices: [(0,"Off"),(1,"On")])
                control("Airflow", icon: "wind", key: "SwUpDn", choices: [(0,"Default"),(1,"Swing"),(2,"Top"),(3,"Upper"),(4,"Middle"),(5,"Lower"),(6,"Bottom")])
            }
            offTimerPanel
            Text(model.message).font(.system(size: 11)).foregroundStyle(model.mode == .preview || model.connected ? Color.white.opacity(0.6) : Color.orange).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if model.mode == .production {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("AC IPv4 / broadcast address", text: $model.address).textFieldStyle(.roundedBorder).disabled(model.busy)
                    if model.devices.count > 1 {
                        Picker("Device", selection: Binding(get: { model.selected?.mac ?? "" }, set: { mac in
                            if let device = model.devices.first(where: { $0.mac == mac }) { model.select(device) }
                        })) { ForEach(model.devices) { Text("\($0.name) · \($0.host)").tag($0.mac) } }.disabled(model.busy)
                    }
                    HStack {
                        Button(model.busy ? "Working…" : "Find AC") { model.scan() }
                        Spacer()
                        Button("Refresh") { model.refresh() }.disabled(model.selected == nil)
                    }.disabled(model.busy)
                    Text("Requires a Wi-Fi-equipped Gree AC on this network with AES v1 local control. Pair it in Gree+ / EWPE Smart first. Features vary by model.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text(model.mode == .preview ? "PREVIEW" : "PRODUCTION").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(blue)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.font(.system(size: 11)).buttonStyle(.plain)
            }
        }.padding(22).frame(width: 380)
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .background(LinearGradient(colors: [Color(red: 0.1, green: 0.20, blue: 0.36), Color(red: 0.035, green: 0.055, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .onChange(of: model.state["SetTem"]) { _, value in temperature = Double(value ?? 24) }
    }
    private var offTimerPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Off timer", systemImage: "timer").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let countdown = model.offTimer.countdown(at: model.countdownNow) {
                    Text(countdown).monospacedDigit().font(.system(size: 16, weight: .medium)).foregroundStyle(blue)
                    Button("Cancel") { model.cancelOffTimer() }.font(.system(size: 11))
                }
            }
            if model.offTimer.deadline == nil {
                HStack(spacing: 8) {
                    Text("Off after").font(.system(size: 11))
                    TextField("Amount", value: $timerAmount, format: .number).frame(width: 48).textFieldStyle(.roundedBorder)
                    Picker("Unit", selection: $timerHours) {
                        Text("minutes").tag(false)
                        Text("hours").tag(true)
                    }.labelsHidden().frame(width: 100)
                    Spacer(minLength: 0)
                    Button("Start") { model.startOffTimer(amount: timerAmount, hours: timerHours) }
                        .disabled(!model.canControl || model.state["Pow"] != 1 || timerAmount < 1 || timerAmount > (timerHours ? 24 : 1440))
                }
            }
            if !model.timerNotice.isEmpty {
                Text(model.timerNotice).font(.system(size: 10)).foregroundStyle(model.timerNotice.hasPrefix("Timer failed") ? Color.orange : blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.mode == .production {
                Text("App timer · keep this Mac awake and GreeBar running.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private var roomLabel: String {
        if let sensor = model.state["TemSen"], (40...100).contains(sensor) { return "Room \(sensor - 40)°C" }
        return model.busy ? "Connecting…" : "Not connected"
    }
    private func available(_ key: String) -> Bool { model.canControl && model.state[key] != nil }
    private var illustration: some View {
        ZStack {
            Ellipse().fill(blue.opacity(model.state["Pow"] == 1 ? 0.2 : 0.02)).frame(width: 190, height: 55).blur(radius: 20).offset(y: 15)
            AirflowAnimation(active: model.state["Pow"] == 1 && (model.mode == .preview || model.connected),
                             speed: model.state["WdSpd"] ?? 0, color: blue)
            VStack(spacing: 12) {
                HStack { Spacer(); Text(model.state["SetTem"].map { "\($0)°" } ?? "—").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.blue) }
                RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.5)).frame(height: 5)
            }.padding(10).frame(width: 155).background(LinearGradient(colors: [.white, Color(white: 0.7)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 8, y: 8).offset(y: -15)
        }
    }
    private func temperatureButton(_ icon: String, delta: Int) -> some View {
        Button { model.set(["SetTem": max(16, min(30, (model.state["SetTem"] ?? 24) + delta)), "TemUn": 0]) } label: {
            Image(systemName: icon).frame(width: 30, height: 30).background(.white.opacity(0.06), in: Circle())
        }.buttonStyle(.plain).disabled(!available("SetTem"))
    }
    private func control(_ title: String, icon: String, key: String, choices: [(Int, String)]) -> some View {
        SettingControl(title: title, icon: icon, choices: choices, value: model.state[key],
                       enabled: available(key), color: blue) { model.set([key: $0]) }
    }
}

struct SettingControl: View {
    let title: String
    let icon: String
    let choices: [(Int, String)]
    let value: Int?
    let enabled: Bool
    let color: Color
    let select: (Int) -> Void
    @State private var expanded = false
    @State private var hoveredOption: Int?

    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.system(size: 20)).foregroundStyle(color)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                }
                Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                Text(currentSetting).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(color.opacity(value == nil ? 0.03 : 0.10), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(value == nil ? 0.08 : 0.25), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(title).accessibilityValue(currentSetting)
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).padding(.horizontal, 8).padding(.bottom, 5)
                    ForEach(choices, id: \.0) { option, label in
                        Button {
                            select(option)
                            expanded = false
                        } label: {
                            HStack {
                                Text(label)
                                Spacer()
                                Image(systemName: "checkmark").opacity(value == option ? 1 : 0)
                            }.padding(8).frame(width: 150)
                                .background(color.opacity(hoveredOption == option ? 0.25 : (value == option ? 0.15 : 0)), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { hoveredOption = option }
                                else if hoveredOption == option { hoveredOption = nil }
                            }
                    }
                }.padding(10)
                    .onDisappear { hoveredOption = nil }.preferredColorScheme(.dark)
            }
    }
    private var currentSetting: String {
        guard let value else { return "—" }
        return choices.first { $0.0 == value }?.1 ?? "Other"
    }
}

struct AirflowAnimation: View {
    let active: Bool
    let speed: Int
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { timeline in
            Canvas { context, size in
                drawAirflow(context: &context, size: size, date: timeline.date)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func drawAirflow(context: inout GraphicsContext, size: CGSize, date: Date) {
        guard active else { return }
        let duration = max(1.1, 2.8 - Double(speed) * 0.25)
        let time = reduceMotion ? 0.8 : date.timeIntervalSinceReferenceDate / duration
        // Stagger short curved wisps from the outlet, fading as they travel down.
        for lane in 0..<7 {
            let spread = CGFloat(lane - 3)
            for pulse in 0..<2 {
                let phase = (time + Double(pulse) / 2 + Double(lane) * 0.07).truncatingRemainder(dividingBy: 1)
                let progress = CGFloat(phase)
                let x = size.width / 2 + spread * 15
                let y: CGFloat = 46 + progress * 48
                var path = Path()
                path.move(to: CGPoint(x: x + spread * progress * 4, y: y))
                path.addQuadCurve(to: CGPoint(x: x + spread * (progress + 0.3) * 4, y: y + 12),
                                  control: CGPoint(x: x + spread * progress * 4 + 2, y: y + 6))
                context.stroke(path, with: .color(color.opacity(sin(phase * .pi) * 0.45)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }
    }
}
