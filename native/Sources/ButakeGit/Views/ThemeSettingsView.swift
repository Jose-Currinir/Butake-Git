import SwiftUI

/// Settings › General › Tema: official themes, light/dark mode and the customizer, with a live preview.
struct ThemeSettingsSection: View {
    @Bindable var themes = ThemeStore.shared
    var body: some View {
        Section(L("themeSection")) {
            Picker(L("themeFamily"), selection: $themes.family) {
                Text("Butake Git").tag(ThemeStore.Family.butake)
                Text("Drácula").tag(ThemeStore.Family.dracula)
                Text(L("themeCustom")).tag(ThemeStore.Family.custom)
            }
            .accessibilityIdentifier("settings.themeFamily")
            Picker(L("themeMode"), selection: $themes.mode) {
                Text(L("system")).tag(ThemeStore.Mode.system); Text(L("light")).tag(ThemeStore.Mode.light); Text(L("dark")).tag(ThemeStore.Mode.dark)
            }
            .pickerStyle(.segmented).accessibilityIdentifier("settings.themeMode")
            ThemePreview(theme: themes.theme)
            if themes.family == .custom {
                Picker(L("themeBase"), selection: $themes.customBase) {
                    Text("Butake Git").tag(ThemeStore.Family.butake); Text("Drácula").tag(ThemeStore.Family.dracula)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(ThemeStore.Slot.allCases) { slot in
                        ColorPicker(L("themeSlot.\(slot.rawValue)"), selection: Binding(get: { themes.color(for: slot).color }, set: { themes.set(slot, HexColor($0)) }), supportsOpacity: false)
                    }
                }
                HStack {
                    Text(String(format: L("themeCustomNote"), L(themes.isDark ? "dark" : "light"))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("themeReset")) { themes.resetCustom() }
                }
            } else {
                Button(L("themeCustomize")) { themes.customBase = themes.family; themes.family = .custom }
            }
            if themes.family == .dracula || themes.customBase == .dracula && themes.family == .custom {
                Text(L("themeDraculaCredit")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Small sample of what the theme touches: accent, change kinds, diff and syntax colors, graph lanes.
struct ThemePreview: View {
    let theme: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(theme.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                ForEach(Array(theme.graph.enumerated()), id: \.offset) { _, color in Circle().fill(color.color).frame(width: 9, height: 9) }
            }
            HStack(spacing: 6) {
                chip(L("added"), theme.addition); chip(L("modified"), theme.modified); chip(L("deleted"), theme.deletion); chip(L("renamed"), theme.renamed); chip(L("conflict"), theme.warning)
                Spacer()
                Text(L("commit")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 4).background(theme.accent.color, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 0) {
                line("-", [("private const ", theme.keyword), ("BASE", theme.text ?? HexColor(0x808080)), (" = ", theme.text ?? HexColor(0x808080)), ("2990", theme.number), (";", theme.text ?? HexColor(0x808080))], kind: theme.deletion)
                line("+", [("// tarifa base", theme.comment)], kind: theme.addition)
                line("+", [("return ", theme.keyword), ("\"CLP\"", theme.string), (";", theme.text ?? HexColor(0x808080))], kind: theme.addition)
            }
            .background(theme.surface?.color ?? Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
        }
        .padding(12)
        .background(theme.background?.color ?? Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityElement(children: .combine).accessibilityLabel(String(format: L("themePreview"), theme.name))
    }
    private func chip(_ text: String, _ color: HexColor) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(color.color).padding(.horizontal, 6).padding(.vertical, 2).background(color.color.opacity(0.14), in: Capsule())
    }
    private func line(_ marker: String, _ parts: [(String, HexColor)], kind: HexColor) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(kind.color).frame(width: 3)
            Text(marker).foregroundStyle(kind.color)
            parts.reduce(Text("")) { $0 + Text($1.0).foregroundColor($1.1.color) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced)).frame(height: 20)
        .background(kind.color.opacity(theme.isDark ? 0.16 : 0.12))
    }
}
