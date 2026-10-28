import SwiftUI
import UniformTypeIdentifiers

@main
struct InformationBarMobileApp: App {
  @StateObject private var store = MobileStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      DashboardView()
        .environmentObject(store)
        .onOpenURL { store.receive($0) }
        .sheet(isPresented: $store.showPairing) { PairingView().environmentObject(store) }
        .task(id: scenePhase) {
          guard scenePhase == .active else { return }
          while !Task.isCancelled {
            await store.refresh()
            try? await Task.sleep(for: .seconds(60))
          }
        }
    }
  }
}

struct PairingView: View {
  @EnvironmentObject private var store: MobileStore
  @Environment(\.dismiss) private var dismiss
  @State private var importing = false

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 44, weight: .light))
          .foregroundStyle(.secondary).padding(.top, 28)
        Text("Your Mac, at a glance.").font(.largeTitle.bold())
        Text("Connect once to bring your readings and widgets along. Keep your Mac running on the same network.")
          .font(.body).foregroundStyle(.secondary)
        if let candidate = store.pendingPairing {
          Label(candidate.host, systemImage: "lock.shield").font(.headline)
          Button {
            Task { await store.connect() }
          } label: {
            HStack {
              Text(store.syncing ? "Connecting…" : "Connect")
              if store.syncing { ProgressView() }
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
          }
          .buttonStyle(.borderedProminent).disabled(store.syncing)
        } else {
          Button("Open connection file", systemImage: "doc.badge.plus") { importing = true }
            .buttonStyle(.borderedProminent)
          Text("Use the private connection file created by the Information Bar companion on your Mac.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
        Spacer()
        Label("Your account credentials stay on your Mac.", systemImage: "lock")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .padding(28)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
        if case .success(let url) = result { store.importPairing(url) }
      }
    }
  }
}
