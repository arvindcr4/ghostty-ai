//! AI-Powered Theme and Appearance Suggestions
//!
//! This module provides intelligent theme recommendations based on:
//! - Time of day (day/night themes)
//! - Activity context (coding, debugging, presentations)
//! - User preferences and usage patterns
//! - Accessibility needs

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.ai_theme);

/// Built-in theme definitions
pub const Theme = struct {
    name: []const u8,
    display_name: []const u8,
    is_dark: bool,
    background: []const u8,
    foreground: []const u8,
    cursor: []const u8,
    colors: [16][]const u8,
    description: []const u8,
};

/// Theme category for organization
pub const ThemeCategory = enum {
    dark,
    light,
    colorful,
    minimal,
    high_contrast,
    pastels,
};

/// Theme suggestion context
pub const SuggestionContext = struct {
    time_of_day: TimeOfDay,
    activity: Activity,
    preferences: ?Preferences,
};

/// Time of day for theme suggestions
pub const TimeOfDay = enum {
    night,      // 10 PM - 6 AM
    morning,    // 6 AM - 12 PM
    afternoon,  // 12 PM - 6 PM
    evening,    // 6 PM - 10 PM
};

/// User activity for context-aware suggestions
pub const Activity = enum {
    coding,
    debugging,
    presenting,
    reading,
    writing,
    terminal_only,
    mixed,
};

/// User preferences for theme customization
pub const Preferences = struct {
    prefer_dark: bool = true,
    favorite_themes: []const []const u8 = &.{},
    avoid_themes: []const []const u8 = &.{},
    high_contrast: bool = false,
    pastel_colors: bool = false,
};

/// Theme suggestion result
pub const ThemeSuggestion = struct {
    theme: []const u8,
    reason: []const u8,
    confidence: f32, // 0.0 to 1.0
    alternative: ?[]const u8 = null,
};

/// Theme Assistant
pub const ThemeAssistant = struct {
    const Self = @This();

    alloc: Allocator,
    known_themes: std.StringHashMap(Theme),
    usage_history: std.ArrayList(ThemeUsageEntry),
    preferences: Preferences,

    /// Theme usage tracking entry
    pub const ThemeUsageEntry = struct {
        theme: []const u8,
        timestamp: i64,
        duration_seconds: u64,
        activity: Activity,
    };

    /// Initialize the theme assistant
    pub fn init(alloc: Allocator) Self {
        return .{
            .alloc = alloc,
            .known_themes = initBuiltInThemes(alloc),
            .usage_history = std.ArrayList(ThemeUsageEntry).init(alloc),
            .preferences = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.known_themes.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.value_ptr.name);
            self.alloc.free(entry.value_ptr.display_name);
            self.alloc.free(entry.value_ptr.background);
            self.alloc.free(entry.value_ptr.foreground);
            self.alloc.free(entry.value_ptr.cursor);
            for (entry.value_ptr.colors) |color| {
                self.alloc.free(color);
            }
            self.alloc.free(entry.value_ptr.description);
        }
        self.known_themes.deinit();

        for (self.usage_history.items) |entry| {
            self.alloc.free(entry.theme);
        }
        self.usage_history.deinit();
    }

    /// Suggest a theme based on context
    pub fn suggestTheme(
        self: *Self,
        context: SuggestionContext,
    ) !ThemeSuggestion {
        _ = std.time.timestamp(); // Track time for future preference learning

        // Get activity-based candidates
        var candidates = std.ArrayList([]const u8).init(self.alloc);
        defer candidates.deinit();

        var iter = self.known_themes.iterator();
        while (iter.next()) |entry| {
            const theme = entry.value_ptr.*;

            // Filter based on time of day preference
            if (context.time_of_day == .night and !theme.is_dark) continue;
            if (context.time_of_day == .morning and context.preferences.?.prefer_dark and !theme.is_dark) continue;

            // Filter based on accessibility
            if (context.preferences.?.high_contrast and !isHighContrast(theme)) continue;
            if (context.preferences.?.pastel_colors and !isPastel(theme)) continue;

            // Filter out avoided themes
            const is_avoided = for (context.preferences.?.avoid_themes) |avoid| {
                if (std.mem.eql(u8, theme.name, avoid)) break true;
            } else false;
            if (is_avoided) continue;

            try candidates.append(theme.name);
        }

        // Score candidates
        var best_score: f32 = 0;
        var best_theme: []const u8 = "";
        var best_reason: []const u8 = "";
        var alternative: ?[]const u8 = null;

        for (candidates.items) |theme_name| {
            _ = self.known_themes.get(theme_name).?; // Validate theme exists
            const score = try self.calculateThemeScore(theme_name, context);
            const reason = try self.generateSuggestionReason(theme_name, context);

            if (score > best_score) {
                if (best_theme.len > 0) {
                    alternative = best_theme;
                }
                best_score = score;
                best_theme = theme_name;
                best_reason = reason;
            } else if (alternative == null) {
                alternative = theme_name;
            }
        }

        if (best_theme.len == 0) {
            // Fallback to default dark theme
            return ThemeSuggestion{
                .theme = "github-dark",
                .reason = "No matching themes found, using a reliable default",
                .confidence = 0.5,
                .alternative = null,
            };
        }

        return ThemeSuggestion{
            .theme = best_theme,
            .reason = best_reason,
            .confidence = best_score,
            .alternative = alternative,
        };
    }

    /// Calculate a score for a theme based on context
    fn calculateThemeScore(
        self: *Self,
        theme_name: []const u8,
        context: SuggestionContext,
    ) !f32 {
        var score: f32 = 0.5; // Base score

        const theme = self.known_themes.get(theme_name).?;

        // Activity-based scoring
        switch (context.activity) {
            .coding => {
                if (std.mem.indexOfScalar(u8, theme.description, "code") != null) score += 0.2;
                if (!theme.is_dark and context.time_of_day != .morning) score -= 0.3;
            },
            .debugging => {
                if (std.mem.indexOfScalar(u8, theme.description, "debug") != null) score += 0.2;
                if (hasHighContrastColors(theme)) score += 0.1;
            },
            .presenting => {
                if (std.mem.indexOfScalar(u8, theme.description, "presentation") != null) score += 0.3;
                if (!theme.is_dark) score += 0.1;
            },
            .reading => {
                if (theme.is_dark) score -= 0.1;
                if (hasWarmColors(theme)) score += 0.1;
            },
            .writing => {
                if (hasWarmColors(theme)) score += 0.2;
            },
            .terminal_only => {
                if (isMinimal(theme)) score += 0.2;
            },
            .mixed => {
                // No specific adjustments
            },
        }

        // Time-based scoring
        switch (context.time_of_day) {
            .night => {
                if (theme.is_dark) score += 0.2 else score -= 0.3;
            },
            .morning => {
                if (!theme.is_dark) score += 0.1 else score -= 0.1;
            },
            .afternoon => {
                // Neutral - no change
            },
            .evening => {
                if (theme.is_dark) score += 0.1;
            },
        }

        // Preference-based scoring
        if (context.preferences) |pref| {
            if (pref.favorite_themes.len > 0) {
                for (pref.favorite_themes) |fav| {
                    if (std.mem.eql(u8, theme_name, fav)) {
                        score += 0.3;
                        break;
                    }
                }
            }
        }

        // Usage history boost
        for (self.usage_history.items) |entry| {
            if (std.mem.eql(u8, entry.theme, theme_name) and entry.activity == context.activity) {
                score += 0.1;
            }
        }

        return @min(score, 1.0);
    }

    /// Generate a human-readable reason for the suggestion
    fn generateSuggestionReason(
        self: *Self,
        theme_name: []const u8,
        context: SuggestionContext,
    ) ![]const u8 {
        const theme = self.known_themes.get(theme_name).?;

        var reasons = std.ArrayList([]const u8).init(self.alloc);
        defer reasons.deinit();

        // Time-based reason
        switch (context.time_of_day) {
            .night => try reasons.append("reduces eye strain during nighttime"),
            .morning => try reasons.append("bright and refreshing for the morning"),
            .afternoon => try reasons.append("comfortable for extended afternoon work"),
            .evening => try reasons.append("easy on the eyes in the evening"),
        }

        // Activity-based reason
        switch (context.activity) {
            .coding => try reasons.append("optimized for code readability"),
            .debugging => try reasons.append("high-contrast colors help identify issues"),
            .presenting => try reasons.append("clear visibility for presentations"),
            .reading => try reasons.append("designed for comfortable reading"),
            .writing => try reasons.append("gentle colors for long writing sessions"),
            .terminal_only => try reasons.append("clean and minimal interface"),
            .mixed => try reasons.append("versatile for mixed workflows"),
        }

        // Theme-specific reason
        try reasons.append(theme.description);

        return try std.mem.join(self.alloc, ". ", reasons.items);
    }

    /// Record theme usage for learning
    pub fn recordThemeUsage(
        self: *Self,
        theme: []const u8,
        duration_seconds: u64,
        activity: Activity,
    ) !void {
        try self.usage_history.append(.{
            .theme = try self.alloc.dupe(u8, theme),
            .timestamp = std.time.timestamp(),
            .duration_seconds = duration_seconds,
            .activity = activity,
        });

        // Keep only last 100 entries
        if (self.usage_history.items.len > 100) {
            const to_remove = self.usage_history.items.len - 100;
            for (0..to_remove) |idx| {
                self.alloc.free(self.usage_history.items[idx].theme);
            }
            std.mem.rotate(ThemeUsageEntry, self.usage_history.items, to_remove);
            self.usage_history.shrinkRetainingCapacity(100);
        }
    }

    /// Get current time of day
    pub fn getCurrentTimeOfDay() TimeOfDay {
        const now = std.time.timestamp();
        const tm = std.time.timestampToStructTime(now);
        const hour = tm.hour;

        if (hour >= 22 or hour < 6) return .night;
        if (hour >= 6 and hour < 12) return .morning;
        if (hour >= 12 and hour < 18) return .afternoon;
        return .evening;
    }

    /// Get all available theme names
    pub fn getAvailableThemes(self: *Self) ![][]const u8 {
        var themes = std.ArrayList([]const u8).init(self.alloc);
        defer themes.deinit();

        var iter = self.known_themes.iterator();
        while (iter.next()) |entry| {
            try themes.append(entry.key_ptr.*);
        }

        return themes.toOwnedSlice();
    }

    /// Get theme by name
    pub fn getTheme(self: *Self, name: []const u8) ?Theme {
        return self.known_themes.get(name);
    }

    /// Set user preferences
    pub fn setPreferences(self: *Self, prefs: Preferences) void {
        self.preferences = prefs;
    }
};

// Helper functions

fn initBuiltInThemes(alloc: Allocator) std.StringHashMap(Theme) {
    var themes = std.StringHashMap(Theme).init(alloc);

    // GitHub Dark
    themes.put("github-dark", .{
        .name = "github-dark",
        .display_name = "GitHub Dark",
        .is_dark = true,
        .background = "#0d1117",
        .foreground = "#c9d1d9",
        .cursor = "#58a6ff",
        .colors = .{
            "#f85149", // red
            "#7ee787", // green
            "#d29922", // yellow
            "#58a6ff", // blue
            "#bc8cff", // magenta
            "#39c5cf", // cyan
            "#f0883e", // orange
            "#8b949e", // gray
            "#ff7b72", // bright red
            "#7ee787", // bright green
            "#d29922", // bright yellow
            "#79c0ff", // bright blue
            "#d2a8ff", // bright magenta
            "#56d4db", // bright cyan
            "#ffa657", // bright orange
            "#c9d1d9", // bright gray
        },
        .description = "GitHub's official dark theme optimized for code",
    }) catch {};

    // GitHub Light
    themes.put("github-light", .{
        .name = "github-light",
        .display_name = "GitHub Light",
        .is_dark = false,
        .background = "#ffffff",
        .foreground = "#24292f",
        .cursor = "#0969da",
        .colors = .{
            "#cf222e", // red
            "#0a3069", // green
            "#bf8700", // yellow
            "#0969da", // blue
            "#a371f7", // magenta
            "#1f7a9c", // cyan
            "#bf3989", // orange
            "#57606a", // gray
            "#ff7b72", // bright red
            "#0a3069", // bright green
            "#bf8700", // bright yellow
            "#0969da", // bright blue
            "#a371f7", // bright magenta
            "#1f7a9c", // bright cyan
            "#bf3989", // bright orange
            "#24292f", // bright gray
        },
        .description = "GitHub's official light theme",
    }) catch {};

    // Catppuccin Mocha
    themes.put("catppuccin-mocha", .{
        .name = "catppuccin-mocha",
        .display_name = "Catppuccin Mocha",
        .is_dark = true,
        .background = "#1e1e2e",
        .foreground = "#cdd6f4",
        .cursor = "#f5e0dc",
        .colors = .{
            "#f38ba8", // red
            "#a6e3a1", // green
            "#f9e2af", // yellow
            "#89b4fa", // blue
            "#cba6f7", // magenta
            "#94e2d5", // cyan
            "#fab387", // orange
            "#6c7086", // gray
            "#f38ba8", // bright red
            "#a6e3a1", // bright green
            "#f9e2af", // bright yellow
            "#89b4fa", // bright blue
            "#cba6f7", // bright magenta
            "#94e2d5", // bright cyan
            "#fab387", // bright orange
            "#cdd6f4", // bright gray
        },
        .description = "Warm and cozy pastel dark theme",
    }) catch {};

    // Dracula
    themes.put("dracula", .{
        .name = "dracula",
        .display_name = "Dracula",
        .is_dark = true,
        .background = "#282a36",
        .foreground = "#f8f8f2",
        .cursor = "#44475a",
        .colors = .{
            "#ff5555", // red
            "#50fa7b", // green
            "#f1fa8c", // yellow
            "#bd93f9", // blue
            "#ff79c6", // magenta
            "#8be9fd", // cyan
            "#ffb86c", // orange
            "#6272a4", // gray
            "#ff6e6e", // bright red
            "#69ff94", // bright green
            "#ffffa5", // bright yellow
            "#d6acff", // bright blue
            "#ff92df", // bright magenta
            "#a4ffff", // bright cyan
            "#ffb86c", // bright orange
            "#f8f8f2", // bright gray
        },
        .description = "Dark theme inspired by Dracula",
    }) catch {};

    // Nord
    themes.put("nord", .{
        .name = "nord",
        .display_name = "Nord",
        .is_dark = true,
        .background = "#2e3440",
        .foreground = "#d8dee9",
        .cursor = "#d8dee9",
        .colors = .{
            "#bf616a", // red
            "#a3be8c", // green
            "#ebcb8b", // yellow
            "#81a1c1", // blue
            "#b48ead", // magenta
            "#88c0d0", // cyan
            "#d08770", // orange
            "#4c566a", // gray
            "#bf616a", // bright red
            "#a3be8c", // bright green
            "#ebcb8b", // bright yellow
            "#81a1c1", // bright blue
            "#b48ead", // bright magenta
            "#8fbcbb", // bright cyan
            "#d08770", // bright orange
            "#eceff4", // bright gray
        },
        .description = "Arctic, north-bluish color palette",
    }) catch {};

    // Solarized Dark
    themes.put("solarized-dark", .{
        .name = "solarized-dark",
        .display_name = "Solarized Dark",
        .is_dark = true,
        .background = "#002b36",
        .foreground = "#839496",
        .cursor = "#819090",
        .colors = .{
            "#dc322f", // red
            "#859900", // green
            "#b58900", // yellow
            "#268bd2", // blue
            "#d33682", // magenta
            "#2aa198", // cyan
            "#cb4b16", // orange
            "#586e75", // gray
            "#dc322f", // bright red
            "#859900", // bright green
            "#b58900", // bright yellow
            "#268bd2", // bright blue
            "#d33682", // bright magenta
            "#2aa198", // bright cyan
            "#cb4b16", // bright orange
            "#93a1a1", // bright gray
        },
        .description = "Precision colors for code and prose",
    }) catch {};

    // One Dark
    themes.put("one-dark", .{
        .name = "one-dark",
        .display_name = "One Dark",
        .is_dark = true,
        .background = "#282c34",
        .foreground = "#abb2bf",
        .cursor = "#528bff",
        .colors = .{
            "#e06c75", // red
            "#98c379", // green
            "#e5c07b", // yellow
            "#61afef", // blue
            "#c678dd", // magenta
            "#56b6c2", // cyan
            "#d19a66", // orange
            "#5c6370", // gray
            "#e06c75", // bright red
            "#98c379", // bright green
            "#e5c07b", // bright yellow
            "#61afef", // bright blue
            "#c678dd", // bright magenta
            "#56b6c2", // bright cyan
            "#d19a66", // bright orange
            "#abb2bf", // bright gray
        },
        .description = "Atom's iconic dark theme",
    }) catch {};

    // Monokai Pro
    themes.put("monokai-pro", .{
        .name = "monokai-pro",
        .display_name = "Monokai Pro",
        .is_dark = true,
        .background = "#2d2a2e",
        .foreground = "#fcfcfa",
        .cursor = "#fcfcfa",
        .colors = .{
            "#ff6188", // red
            "#a9dc76", // green
            "#ffd866", // yellow
            "#78dce8", // blue
            "#ab9df2", // magenta
            "#7bd47f", // cyan
            "#ffab40", // orange
            "#727072", // gray
            "#ff6188", // bright red
            "#a9dc76", // bright green
            "#ffd866", // bright yellow
            "#78dce8", // bright blue
            "#ab9df2", // bright magenta
            "#7bd47f", // bright cyan
            "#ffab40", // bright orange
            "#fcfcfa", // bright gray
        },
        .description = "Sophisticated dark theme with balanced colors",
    }) catch {};

    return themes;
}

fn isHighContrast(theme: Theme) bool {
    // Check if theme has high contrast colors
    return std.ascii.startsWithIgnoreCase(theme.name, "high-contrast") or
        std.ascii.startsWithIgnoreCase(theme.name, "contrast");
}

fn isPastel(theme: Theme) bool {
    // Check if theme uses pastel colors
    return std.ascii.startsWithIgnoreCase(theme.name, "catppuccin") or
        std.ascii.startsWithIgnoreCase(theme.name, "pastel") or
        std.mem.indexOfScalar(u8, theme.name, "pastel") != null;
}

fn isMinimal(theme: Theme) bool {
    // Check if theme is minimal
    return std.ascii.indexOfIgnoreCase(theme.name, "minimal") != null or
        std.ascii.indexOfIgnoreCase(theme.name, "simple") != null;
}

fn hasHighContrastColors(theme: Theme) bool {
    // Check for bright, high-contrast accent colors
    const bright_colors = &.{ "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9" };
    for (theme.colors) |color| {
        for (bright_colors) |bright| {
            if (std.mem.eql(u8, color, bright)) return true;
        }
    }
    return false;
}

fn hasWarmColors(theme: Theme) bool {
    // Check for warm colors (reds, oranges, yellows)
    const warm_colors = &.{ "#ff5555", "#f1fa8c", "#d19a66", "#fab387" };
    for (theme.colors) |color| {
        for (warm_colors) |warm| {
            if (std.mem.eql(u8, color, warm)) return true;
        }
    }
    return false;
}
