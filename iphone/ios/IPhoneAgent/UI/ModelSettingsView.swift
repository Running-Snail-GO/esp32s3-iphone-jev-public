import SwiftUI

/// Settings › Model: endpoint, key and the model picked from the endpoint's list; overrides under Advanced.
struct ModelSettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: Settings
    @State private var testing = false
    @State private var advanced = false
    @AppStorage(ModelImage.key) private var shrinkImage = true
    @AppStorage(AppModel.prewarmKey) private var prewarm = true

    var body: some View {
        Form {
            Section {
                ProviderFields(settings: settings)
            } header: {
                Text("Model Provider")
            } footer: {
                if let url = settings.provider.keyURL { Link("Get an API key", destination: url) }
            }
            Section {
                Button {
                    testing = true
                    Task { await app.pingLLM(); testing = false }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if testing { ProgressView() } else if let ok = app.modelOK {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(ok ? Palette.ok : Palette.stop)
                        }
                    }
                }
                .disabled(testing || !app.modelReady)
                ModelTestTimingView(app: app)
                if let error = app.modelError {
                    Text(verbatim: error).font(.footnote).foregroundStyle(Palette.stop)
                }
            }
            Section {
                Toggle("Predictive batches (experimental)", isOn: $settings.predictiveBatch)
            } footer: {
                Text("Predict up to 3 actions per model reply. Future text buttons are located on fresh screenshots on this iPhone. If a label is missing or ambiguous, ask the model again. Turn this off to compare with the original mode.")
            }
            Section {
                Toggle("Use Jev for execution", isOn: $settings.jevEnabled)
                if settings.jevEnabled {
                    SecureField("TypeSafe API key", text: $settings.jevAPIKey)
                        .privacySensitive()
                    TextField("Jev model", text: $settings.jevModel)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    Picker("Minimum confidence", selection: $settings.jevMinConfidence) {
                        ForEach([0.85, 0.9, 0.95], id: \.self) { value in
                            Text(value, format: .percent.precision(.fractionLength(0))).tag(value)
                        }
                    }
                    AIConsentRow(settings: settings, baseURL: Settings.jevBaseURL)
                    Link("Get a TypeSafe API key", destination: URL(string: "https://console.typesafe.ai")!)
                }
            } header: {
                Text("Jev execution (experimental)")
            } footer: {
                Text("Your vision model handles planning and uncertain steps. With Jev enabled, task text and screenshots also go to TypeSafe. Jev's image support is experimental.")
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    let same = String(localized: "Same as Model")
                    ModelPicker(settings: settings, title: "Planner model", selection: $settings.plannerModel, automatic: same)
                    ModelPicker(settings: settings, title: "Actor model", selection: $settings.actorModel, automatic: same)
                    Picker("Token parameter", selection: $settings.tokenParam) {
                        ForEach(["auto"] + LLMClient.tokenParams, id: \.self) { Text(verbatim: $0) }
                    }
                    TextField("Extra body JSON", text: $settings.extraBody, prompt: Text(verbatim: "{}"))
                        .font(.body.monospaced())
                    Toggle("Smaller screenshots", isOn: $shrinkImage)
                    Toggle("Pre-warm screen stream", isOn: $prewarm)
                }
            } footer: {
                if advanced {
                    Text("Smaller screenshots send the model a 540-pixel-wide copy of the screen, which uploads faster. Pre-warm streams the screen while this app is open, so a run sees the screen sooner.")
                }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)

    }
}
