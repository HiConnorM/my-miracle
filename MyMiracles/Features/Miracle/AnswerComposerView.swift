import SwiftUI

/// Turning a prayer into a miracle.
///
/// The miracle inherits the prayer's visibility and anonymity by default. That matters: if
/// someone asked anonymously, publishing the answer under their name would retroactively
/// unmask the request. They can still choose to make the answer *more* private.
struct AnswerComposerView: View {
    @Environment(\.dismiss) private var dismiss

    let prayer: Post
    /// Called with the draft and a stable idempotency key. The key is generated once here,
    /// so a retry after a dropped connection replays rather than creating a second miracle.
    let onAnswer: (PostDraft, String) async -> Void

    @State private var draft: PostDraft
    @State private var isSaving = false
    @FocusState private var isWriting: Bool

    private let idempotencyKey = UUID().uuidString

    init(prayer: Post, onAnswer: @escaping (PostDraft, String) async -> Void) {
        self.prayer = prayer
        self.onAnswer = onAnswer
        _draft = State(
            initialValue: PostDraft(
                type: .miracle,
                visibility: prayer.visibility,
                anonymous: prayer.isAnonymous
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MiracleColor.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: MiracleSpacing.comfortable) {
                        originalPrayer

                        Text("What happened?")
                            .font(MiracleFont.reflective(.title3))
                            .foregroundStyle(MiracleColor.ink)

                        TextEditor(text: $draft.body)
                            .font(MiracleFont.interface(.body))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 160)
                            .padding(MiracleSpacing.medium)
                            .background(
                                MiracleColor.canvasElevated,
                                in: .rect(cornerRadius: MiracleRadius.card)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: MiracleRadius.card)
                                    .stroke(MiracleColor.separator, lineWidth: 1)
                            )
                            .focused($isWriting)
                            .accessibilityLabel("What happened?")

                        if prayer.prayerResponseCount > 0 {
                            Text(prayer.prayerResponseCount == 1
                                 ? "1 person prayed for this. They'll be told it was answered."
                                 : "\(prayer.prayerResponseCount) people prayed for this. They'll be told it was answered.")
                                .font(MiracleFont.interface(.footnote))
                                .foregroundStyle(MiracleColor.prayerBlue)
                        }

                        PrivacySelector(
                            visibility: $draft.visibility,
                            anonymous: $draft.anonymous
                        ) { visibility in
                            if !visibility.allowsAnonymity { draft.anonymous = false }
                        }
                    }
                    .padding(MiracleSpacing.comfortable)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Mark as answered")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        isSaving = true
                        Task {
                            await onAnswer(draft, idempotencyKey)
                            isSaving = false
                        }
                    }
                    .disabled(!draft.isSendable || isSaving)
                    .fontWeight(.semibold)
                }
            }
            .onAppear { isWriting = true }
        }
    }

    private var originalPrayer: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.tight) {
            Text("You asked")
                .font(MiracleFont.interface(.caption, weight: .medium))
                .foregroundStyle(MiracleColor.inkSecondary)
            Text(prayer.body)
                .font(MiracleFont.interface(.callout))
                .foregroundStyle(MiracleColor.inkSecondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MiracleSpacing.regular)
        .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
        .accessibilityElement(children: .combine)
    }
}

/// The moment a prayer becomes a miracle.
///
/// Warm and brief. Honours Reduce Motion with a still variant — a celebration that ignores
/// an accessibility setting is not a celebration (rule 15).
struct AnsweredCelebrationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let miracle: Post
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()

            VStack(spacing: MiracleSpacing.comfortable) {
                Spacer()

                Image(systemName: "sparkle")
                    .font(.system(size: 64))
                    .foregroundStyle(MiracleColor.haloGold)
                    .scaleEffect(reduceMotion || hasAppeared ? 1 : 0.6)
                    .opacity(reduceMotion || hasAppeared ? 1 : 0)
                    .accessibilityHidden(true)

                Text("Answered")
                    .font(MiracleFont.reflective(.largeTitle))
                    .foregroundStyle(MiracleColor.ink)

                Text(miracle.body)
                    .font(MiracleFont.reflective(.title3))
                    .foregroundStyle(MiracleColor.inkSecondary)
                    .multilineTextAlignment(.center)

                Text("It's in your journal now.")
                    .font(MiracleFont.interface(.footnote))
                    .foregroundStyle(MiracleColor.inkSecondary)

                Spacer()

                Button("Close") { dismiss() }
                    .font(MiracleFont.interface(.headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MiracleSpacing.regular)
                    .background(MiracleColor.ink, in: .rect(cornerRadius: MiracleRadius.pill))
                    .foregroundStyle(MiracleColor.canvas)
            }
            .padding(MiracleSpacing.generous)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(MiracleMotion.settle) { hasAppeared = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your prayer was answered. It is now in your journal.")
    }
}
