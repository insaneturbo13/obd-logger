import OBDKit
import SwiftUI

/// Reads stored, pending and permanent trouble codes. Read-only by design: this app
/// can't clear codes (clearing also resets the emissions readiness monitors).
struct CodesView: View {
    @Environment(LoggerEngine.self) private var engine
    @State private var codes: [TroubleCode]?
    @State private var readAt: Date?
    @State private var error: String?
    @State private var reading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await read() }
                    } label: {
                        HStack {
                            Label("Read trouble codes", systemImage: "stethoscope")
                            if reading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!engine.canReadCodes || reading)
                    if !engine.canReadCodes {
                        Text("Available while the car is answering.").font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                } footer: {
                    Text("Reads the engine and transmission computers' standard codes. Clearing codes isn't possible from this app.")
                }
                if let error {
                    Text(error).foregroundStyle(Palette.vermillion)
                }
                if let codes {
                    if codes.isEmpty {
                        Section {
                            Label("No codes stored, pending or permanent", systemImage: "checkmark.seal").foregroundStyle(Palette.green)
                        } footer: {
                            if let readAt { Text("Read \(readAt.formatted(date: .omitted, time: .standard))") }
                        }
                    }
                    ForEach(TroubleCode.Kind.allCases, id: \.self) { kind in
                        let list = codes.filter { $0.kind == kind }
                        if !list.isEmpty {
                            Section(title(kind)) {
                                ForEach(list, id: \.self) { c in
                                    HStack {
                                        Text(c.code).font(.title3.monospaced().weight(.semibold)).foregroundStyle(Palette.text)
                                        Spacer()
                                        Text(TroubleCodes.moduleName(c.module)).foregroundStyle(Palette.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Trouble codes")
        }
    }

    private func title(_ kind: TroubleCode.Kind) -> String {
        switch kind {
        case .stored: return "Stored (check-engine light)"
        case .pending: return "Pending (seen once, not confirmed)"
        case .permanent: return "Permanent (clear only after repair and drive cycles)"
        }
    }

    private func read() async {
        reading = true
        defer { reading = false }
        do {
            codes = try await engine.readCodes()
            readAt = Date()
            error = nil
        } catch {
            self.error = "Couldn't read codes: \(error)"
        }
    }
}
