#if os(macOS)
    import SwiftUI

    /// A pane of the Mac's Settings window. The choice is saved, so the window reopens on the
    /// last pane, and the Spines tab's **Choose model…** opens **Design Model**.
    enum SettingsPane: String {
        case general, backupModel, hardcover

        static let key = "BookwormsSettingsPane"
    }

    /// The Settings window (**Bookworms > Settings…**), in three panes: **General** (background
    /// generation and launch at login), **Design Model** (`SpineDesignerSettings`), and
    /// **Hardcover**, which shows the account itself (`HardcoverAccountForm`) rather than opening
    /// a sheet over Settings. The window keeps the system background, and SwiftUI titles it after
    /// the pane.
    struct MacSettingsView: View {
        @AppStorage(SettingsPane.key) private var pane = SettingsPane.general

        var body: some View {
            TabView(selection: $pane) {
                Tab("General", systemImage: "gearshape", value: .general) {
                    GeneralSettings()
                }
                Tab("Design Model", image: "tab.spines", value: .backupModel) {
                    Form { SpineDesignerSettings() }
                        .formStyle(.grouped)
                        .frame(width: 520)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Tab("Hardcover", systemImage: "person.crop.circle", value: .hardcover) {
                    HardcoverAccountForm()
                        .frame(width: 520, height: 560)
                }
            }
        }
    }

    /// **Settings > General**: background generation and launch at login.
    private struct GeneralSettings: View {
        @Environment(GenerationController.self) private var generation

        var body: some View {
            @Bindable var generation = generation
            Form {
                Section {
                    Toggle("Generate while idle", isOn: $generation.generatesWhileCharging)
                    LaunchAtLoginToggle()
                } footer: {
                    Text(
                        "Bookworms keeps running in the menu bar after you close its window, and macOS runs generation when this Mac is idle and plugged in. The Apple TV picks up new designs through iCloud."
                    )
                }
            }
            .formStyle(.grouped)
            .frame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
#endif
