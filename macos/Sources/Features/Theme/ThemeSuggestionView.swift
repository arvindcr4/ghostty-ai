import SwiftUI
import Foundation

/// AI-Powered Theme Suggestion View for macOS
/// Provides intelligent theme recommendations based on time, activity, and preferences
struct ThemeSuggestionView: View {
    @State private var currentTimeOfDay: String = ""
    @State private var selectedActivity: String = "coding"
    @State private var suggestedTheme: ThemePreviewItem?
    @State private var availableThemes: [ThemePreviewItem] = []
    @State private var isLoading: Bool = false
    @State private var showPreferences: Bool = false
    @State private var preferDark: Bool = true
    @State private var highContrast: Bool = false
    @State private var pastelColors: Bool = false

    let activities = [
        "coding",
        "debugging",
        "presenting",
        "reading",
        "writing",
        "terminal_only",
        "mixed"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "paintpalette")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                Text("Theme Suggestions")
                    .font(.headline)

                Spacer()

                Button(action: { showPreferences.toggle() }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Context section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack {
                            // Time of day indicator
                            HStack(spacing: 4) {
                                Image(systemName: timeIcon)
                                    .foregroundColor(.secondary)
                                Text(currentTimeOfDay)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // Activity picker
                            Picker("Activity", selection: $selectedActivity) {
                                ForEach(activities, id: \.self) { activity in
                                    Text(activity.capitalized).tag(activity)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // Current suggestion
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.accentColor)
                            Text("Recommended for You")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }

                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Finding the best theme...")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        } else if let suggestion = suggestedTheme {
                            ThemeSuggestionCard(
                                theme: suggestion,
                                activity: selectedActivity,
                                onApply: applyTheme
                            )
                        } else {
                            Text("Select your activity to get theme suggestions")
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .padding()
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // Available themes
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All Themes")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            ForEach(availableThemes, id: \.self) { theme in
                                ThemePreviewCard(theme: theme, isSelected: suggestedTheme?.name == theme.name)
                                    .onTapGesture {
                                        suggestedTheme = theme
                                    }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
        .frame(minWidth: 450, minHeight: 500)
        .onAppear {
            updateTimeOfDay()
            loadThemes()
        }
        .onChange(of: selectedActivity) { oldValue, newValue in
            getSuggestion()
        }
        .sheet(isPresented: $showPreferences) {
            ThemePreferencesView(
                preferDark: $preferDark,
                highContrast: $highContrast,
                pastelColors: $pastelColors
            )
        }
    }

    // MARK: - Computed Properties

    var timeIcon: String {
        switch currentTimeOfDay {
        case "Night": return "moon.fill"
        case "Morning": return "sunrise.fill"
        case "Afternoon": return "sun.max.fill"
        case "Evening": return "sunset.fill"
        default: return "clock.fill"
        }
    }

    // MARK: - Actions

    func updateTimeOfDay() {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 22 || hour < 6 {
            currentTimeOfDay = "Night"
        } else if hour >= 6 && hour < 12 {
            currentTimeOfDay = "Morning"
        } else if hour >= 12 && hour < 18 {
            currentTimeOfDay = "Afternoon"
        } else {
            currentTimeOfDay = "Evening"
        }
    }

    func loadThemes() {
        // Built-in themes matching the Zig module
        availableThemes = [
            ThemePreviewItem(name: "github-dark", displayName: "GitHub Dark", background: "#0d1117", foreground: "#c9d1d9", isDark: true),
            ThemePreviewItem(name: "github-light", displayName: "GitHub Light", background: "#ffffff", foreground: "#24292f", isDark: false),
            ThemePreviewItem(name: "catppuccin-mocha", displayName: "Catppuccin Mocha", background: "#1e1e2e", foreground: "#cdd6f4", isDark: true),
            ThemePreviewItem(name: "dracula", displayName: "Dracula", background: "#282a36", foreground: "#f8f8f2", isDark: true),
            ThemePreviewItem(name: "nord", displayName: "Nord", background: "#2e3440", foreground: "#d8dee9", isDark: true),
            ThemePreviewItem(name: "solarized-dark", displayName: "Solarized Dark", background: "#002b36", foreground: "#839496", isDark: true),
            ThemePreviewItem(name: "one-dark", displayName: "One Dark", background: "#282c34", foreground: "#abb2bf", isDark: true),
            ThemePreviewItem(name: "monokai-pro", displayName: "Monokai Pro", background: "#2d2a2e", foreground: "#fcfcfa", isDark: true),
        ]
    }

    func getSuggestion() {
        isLoading = true

        // Simulate AI suggestion based on context
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            suggestedTheme = calculateSuggestion()
            isLoading = false
        }
    }

    func calculateSuggestion() -> ThemePreviewItem {
        let isDark = preferDark ?
            true :
            currentTimeOfDay == "Night" || currentTimeOfDay == "Evening"

        let themes = availableThemes.filter { $0.isDark == isDark }

        // Score based on activity
        var bestTheme: ThemePreviewItem = themes.first ?? availableThemes[0]

        switch selectedActivity {
        case "coding":
            if isDark {
                bestTheme = themes.first { $0.name == "github-dark" } ?? bestTheme
            } else {
                bestTheme = themes.first { $0.name == "github-light" } ?? bestTheme
            }
        case "debugging":
            bestTheme = themes.first { $0.name == "dracula" } ?? bestTheme
        case "presenting":
            if !isDark {
                bestTheme = themes.first { $0.name == "github-light" } ?? bestTheme
            }
        case "reading":
            bestTheme = themes.first { $0.name == "solarized-dark" } ?? bestTheme
        case "writing":
            bestTheme = themes.first { $0.name == "catppuccin-mocha" } ?? bestTheme
        case "terminal_only":
            bestTheme = themes.first { $0.name == "one-dark" } ?? bestTheme
        default:
            break
        }

        return bestTheme
    }

    func applyTheme() {
        guard let theme = suggestedTheme else { return }
        // TODO: Apply theme to Ghostty configuration
        print("Applying theme: \(theme.name)")
    }
}

// MARK: - Supporting Types

struct ThemePreviewItem: Hashable {
    let name: String
    let displayName: String
    let background: String
    let foreground: String
    let isDark: Bool
}

struct ThemeSuggestionCard: View {
    let theme: ThemePreviewItem
    let activity: String
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Theme preview
            HStack(spacing: 0) {
                // Color palette
                VStack(spacing: 2) {
                    Color(hex: theme.background)
                        .frame(height: 60)
                        .overlay(
                            VStack {
                                Text(theme.displayName)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(Color(hex: theme.foreground))
                            }
                        )
                }
            }
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            // Reason
            Text(reasonText)
                .font(.caption)
                .foregroundColor(.secondary)

            // Apply button
            Button(action: onApply) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Apply Theme")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    var reasonText: String {
        switch activity {
        case "coding":
            return "Optimized for code readability with high contrast syntax colors"
        case "debugging":
            return "High-contrast colors help identify issues quickly"
        case "presenting":
            return "Clear visibility for presentations and screensharing"
        case "reading":
            return "Gentle colors designed for comfortable long reading sessions"
        case "writing":
            return "Warm tones perfect for focused writing sessions"
        case "terminal_only":
            return "Clean and minimal interface for terminal-focused work"
        default:
            return "Versatile theme that works well for mixed workflows"
        }
    }
}

struct ThemePreviewCard: View {
    let theme: ThemePreviewItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Mini preview
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: theme.background))
                .frame(height: 50)
                .overlay(
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: "#ff5555"))
                            .frame(width: 8, height: 8)
                        Circle()
                            .fill(Color(hex: "#50fa7b"))
                            .frame(width: 8, height: 8)
                        Circle()
                            .fill(Color(hex: "#bd93f9"))
                            .frame(width: 8, height: 8)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                )

            Text(theme.displayName)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(1)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

struct ThemePreferencesView: View {
    @Binding var preferDark: Bool
    @Binding var highContrast: Bool
    @Binding var pastelColors: Bool
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Theme Preferences")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Divider()

            Toggle("Prefer Dark Themes", isOn: $preferDark)
            Toggle("High Contrast Mode", isOn: $highContrast)
            Toggle("Pastel Colors", isOn: $pastelColors)

            Spacer()

            Button("Save Preferences") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 300, height: 250)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview

#Preview {
    ThemeSuggestionView()
}
