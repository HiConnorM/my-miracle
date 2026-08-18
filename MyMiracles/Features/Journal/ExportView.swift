import SwiftUI

/// Take your journal with you.
///
/// The product's claim is that people stay because their history is here, **not** because
/// leaving is hard. This makes that literal — everything, including private entries and
/// posts published anonymously, in a plain JSON file someone can keep.
///
/// It is deliberately easy to find and deliberately unapologetic. Hiding it would make the
/// promise a slogan.
struct ExportView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let baseURL: URL

    @State private var state: LoadState<URL> = .idle

    var body: some View {
        NavigationStack {
            ZStack {
                MiracleColor.canvas.ignoresSafeArea()

                VStack(spacing: MiracleSpacing.comfortable) {
                    Spacer()

                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 44))
                        .foregroundStyle(MiracleColor.sage)
                        .accessibilityHidden(true)

                    Text("Your journal is yours")
                        .font(MiracleFont.reflective(.title2))
                        .foregroundStyle(MiracleColor.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Everything you've written — private entries, prayers you asked anonymously, and the miracles they became — in one file you can keep.")
                        .font(MiracleFont.interface(.callout))
                        .foregroundStyle(MiracleColor.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    switch state {
                    case .idle, .empty:
                        PrimaryButton(title: "Prepare my journal", systemImage: "arrow.down.doc") {
                            Task { await prepare() }
                        }
                    case .loading:
                        PrimaryButton(title: "Preparing", isLoading: true) {}
                    case .loaded(let url):
                        ShareLink(item: url) {
                            Text("Save or share")
                                .font(MiracleFont.interface(.headline))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, MiracleSpacing.regular)
                        }
                        .background(MiracleColor.ink, in: .rect(cornerRadius: MiracleRadius.pill))
                        .foregroundStyle(MiracleColor.canvas)
                    case .failed(let error):
                        ErrorNotice(error: error) { state = .idle }
                    }
                }
                .padding(MiracleSpacing.generous)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func prepare() async {
        guard let dependencies else { return }
        state = .loading

        do {
            let data = try await dependencies.api.send(
                APIRequest<ExportPayload>.get("/v1/me/export")
            )
            // Written to a temporary file so ShareLink can hand it to Files, Mail, or
            // anywhere else — the point is that it leaves.
            let url = FileManager.default.temporaryDirectory
                .appending(path: "my-miracles-journal.json")
            try JSONEncoder.exportEncoder.encode(data).write(to: url, options: .atomic)
            state = .loaded(url)
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(AppError.unexpected(error))
        }
    }
}

/// Decoded and re-encoded rather than passed through, so the file that lands on someone's
/// device is exactly what this app understands — not an opaque blob.
nonisolated struct ExportPayload: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let id: String
        let type: String
        let body: String
        let visibility: String
        let status: String
        let anonymous: Bool
        let createdAt: Date
        var answeredAt: Date?
        var prayerResponseCount: Int = 0
        var updates: [Update] = []
        var answeredByMiracleId: String?
        var cameFromPrayerId: String?

        struct Update: Codable, Sendable {
            let body: String
            let createdAt: Date
        }
    }

    struct Profile: Codable, Sendable {
        let username: String
        let displayName: String
        let joinedAt: Date
    }

    let exportedAt: Date
    let format: String
    var profile: Profile?
    let entries: [Entry]
}

nonisolated extension JSONEncoder {
    /// Readable on purpose. Someone should be able to open this file and see their life in
    /// it, not a wall of minified JSON.
    static var exportEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

#if DEBUG
#Preview("Export") {
    ExportView(baseURL: URL(string: "http://127.0.0.1:8787")!)
        .environment(\.dependencies, .preview())
}
#endif
