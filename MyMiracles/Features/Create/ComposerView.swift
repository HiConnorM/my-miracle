import SwiftUI

/// Writing a miracle, a prayer, or a moment of gratitude.
///
/// Privacy is chosen here, before anything is written down — not afterwards, and not
/// buried behind a menu.
struct ComposerView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let type: PostType
    let onCreated: (Post) -> Void

    @State private var model: ComposerModel?
    @FocusState private var isWriting: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                MiracleColor.canvas.ignoresSafeArea()

                if let model {
                    form(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model?.save()
                            if let saved = model?.saved { onCreated(saved) }
                        }
                    }
                    .disabled(!(model?.canSave ?? false))
                    .fontWeight(.semibold)
                }
            }
        }
        .task {
            guard model == nil, let dependencies else { return }
            model = ComposerModel(
                repository: HTTPPostRepository(client: dependencies.api),
                analytics: dependencies.analytics,
                type: type
            )
            isWriting = true
        }
    }

    private var title: String {
        switch type {
        case .prayer: "Ask for prayer"
        case .miracle: "Record a miracle"
        case .gratitude: "Gratitude"
        case .testimony: "Testimony"
        }
    }

    private var prompt: String {
        switch type {
        case .prayer: "What would you like people to pray about?"
        case .miracle: "What happened that you never want to forget?"
        case .gratitude: "What are you grateful for today?"
        case .testimony: "What would you like to share?"
        }
    }

    private func form(_ model: ComposerModel) -> some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: MiracleSpacing.comfortable) {
                Text(prompt)
                    .font(MiracleFont.reflective(.title3))
                    .foregroundStyle(MiracleColor.ink)

                TextEditor(text: $model.draft.body)
                    .font(MiracleFont.interface(.body))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(MiracleSpacing.medium)
                    .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: MiracleRadius.card)
                            .stroke(MiracleColor.separator, lineWidth: 1)
                    )
                    .focused($isWriting)
                    .accessibilityLabel(prompt)

                if model.remainingCharacters < 250 {
                    Text("\(model.remainingCharacters) characters left")
                        .font(MiracleFont.interface(.caption))
                        .foregroundStyle(
                            model.remainingCharacters < 0 ? MiracleColor.ink : MiracleColor.inkSecondary
                        )
                }

                PrivacySelector(
                    visibility: $model.draft.visibility,
                    anonymous: $model.draft.anonymous
                ) { model.setVisibility($0) }

                if let error = model.error {
                    ErrorNotice(error: error) { model.dismissError() }
                }

                if model.isSaving {
                    HStack(spacing: MiracleSpacing.small) {
                        ProgressView()
                        Text("Saving…")
                            .font(MiracleFont.interface(.footnote))
                            .foregroundStyle(MiracleColor.inkSecondary)
                    }
                }
            }
            .padding(MiracleSpacing.comfortable)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
