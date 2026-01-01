//! Theme Suggestions Module
//!
//! This module provides AI-powered appearance recommendations for terminal themes.
//!
//! Features:
//! - Context-aware theme suggestions (time of day, activity, environment)
//! - Color harmony analysis and accessibility checking
//! - User preference learning
//! - Multiple theme providers (AI, built-in, community)
//! - Theme preview generation
//! - Accessibility compliance (WCAG contrast ratios)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_theme_suggestions);

/// Full color specification for a terminal theme
pub const ColorScheme = struct {
    // Base colors
    background: Color,
    foreground: Color,
    cursor: Color,
    selection_bg: Color,
    selection_fg: Color,

    // ANSI colors (0-15)
    ansi_colors: [16]Color,

    // Extended/semantic colors
    accent: Color,
    link: Color,
    error_color: Color,
    warning: Color,
    success: Color,

    pub const Color = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8 = 255,

        /// Create from hex string like "#RRGGBB" or "#RRGGBBAA"
        pub fn fromHex(hex: []const u8) !Color {
            if (hex.len < 7 or hex[0] != '#') return error.InvalidHexColor;

            const r = try std.fmt.parseInt(u8, hex[1..3], 16);
            const g = try std.fmt.parseInt(u8, hex[3..5], 16);
            const b = try std.fmt.parseInt(u8, hex[5..7], 16);
            const a: u8 = if (hex.len >= 9)
                try std.fmt.parseInt(u8, hex[7..9], 16)
            else
                255;

            return .{ .r = r, .g = g, .b = b, .a = a };
        }

        /// Convert to hex string
        pub fn toHex(self: Color, alloc: Allocator) ![]const u8 {
            return try std.fmt.allocPrint(alloc, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
        }

        /// Calculate relative luminance (WCAG)
        pub fn luminance(self: Color) f32 {
            const r_srgb = @as(f32, @floatFromInt(self.r)) / 255.0;
            const g_srgb = @as(f32, @floatFromInt(self.g)) / 255.0;
            const b_srgb = @as(f32, @floatFromInt(self.b)) / 255.0;

            const r_lin = if (r_srgb <= 0.03928) r_srgb / 12.92 else std.math.pow(f32, (r_srgb + 0.055) / 1.055, 2.4);
            const g_lin = if (g_srgb <= 0.03928) g_srgb / 12.92 else std.math.pow(f32, (g_srgb + 0.055) / 1.055, 2.4);
            const b_lin = if (b_srgb <= 0.03928) b_srgb / 12.92 else std.math.pow(f32, (b_srgb + 0.055) / 1.055, 2.4);

            return 0.2126 * r_lin + 0.7152 * g_lin + 0.0722 * b_lin;
        }

        /// Calculate contrast ratio between two colors (WCAG)
        pub fn contrastRatio(self: Color, other: Color) f32 {
            const l1 = self.luminance();
            const l2 = other.luminance();
            const lighter = @max(l1, l2);
            const darker = @min(l1, l2);
            return (lighter + 0.05) / (darker + 0.05);
        }

        /// Check if contrast meets WCAG AA (4.5:1 for normal text)
        pub fn meetsWcagAA(self: Color, other: Color) bool {
            return self.contrastRatio(other) >= 4.5;
        }

        /// Check if contrast meets WCAG AAA (7:1 for normal text)
        pub fn meetsWcagAAA(self: Color, other: Color) bool {
            return self.contrastRatio(other) >= 7.0;
        }

        /// Blend two colors
        pub fn blend(self: Color, other: Color, factor: f32) Color {
            const f = std.math.clamp(factor, 0.0, 1.0);
            const inv_f = 1.0 - f;
            return .{
                .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) * inv_f + @as(f32, @floatFromInt(other.r)) * f),
                .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) * inv_f + @as(f32, @floatFromInt(other.g)) * f),
                .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) * inv_f + @as(f32, @floatFromInt(other.b)) * f),
                .a = @intFromFloat(@as(f32, @floatFromInt(self.a)) * inv_f + @as(f32, @floatFromInt(other.a)) * f),
            };
        }

        /// Convert to HSL
        pub fn toHsl(self: Color) struct { h: f32, s: f32, l: f32 } {
            const r = @as(f32, @floatFromInt(self.r)) / 255.0;
            const g = @as(f32, @floatFromInt(self.g)) / 255.0;
            const b = @as(f32, @floatFromInt(self.b)) / 255.0;

            const max_val = @max(r, @max(g, b));
            const min_val = @min(r, @min(g, b));
            const l = (max_val + min_val) / 2.0;

            if (max_val == min_val) {
                return .{ .h = 0, .s = 0, .l = l };
            }

            const d = max_val - min_val;
            const s = if (l > 0.5) d / (2.0 - max_val - min_val) else d / (max_val + min_val);

            var h: f32 = 0;
            if (max_val == r) {
                h = (g - b) / d + (if (g < b) @as(f32, 6.0) else @as(f32, 0.0));
            } else if (max_val == g) {
                h = (b - r) / d + 2.0;
            } else {
                h = (r - g) / d + 4.0;
            }
            h /= 6.0;

            return .{ .h = h * 360.0, .s = s, .l = l };
        }
    };

    /// Create default dark theme
    pub fn defaultDark() ColorScheme {
        return .{
            .background = .{ .r = 30, .g = 30, .b = 30 },
            .foreground = .{ .r = 212, .g = 212, .b = 212 },
            .cursor = .{ .r = 255, .g = 255, .b = 255 },
            .selection_bg = .{ .r = 38, .g = 79, .b = 120 },
            .selection_fg = .{ .r = 255, .g = 255, .b = 255 },
            .ansi_colors = defaultAnsiDark(),
            .accent = .{ .r = 0, .g = 122, .b = 204 },
            .link = .{ .r = 86, .g = 156, .b = 214 },
            .error_color = .{ .r = 244, .g = 71, .b = 71 },
            .warning = .{ .r = 255, .g = 204, .b = 0 },
            .success = .{ .r = 72, .g = 185, .b = 129 },
        };
    }

    /// Create default light theme
    pub fn defaultLight() ColorScheme {
        return .{
            .background = .{ .r = 255, .g = 255, .b = 255 },
            .foreground = .{ .r = 36, .g = 36, .b = 36 },
            .cursor = .{ .r = 0, .g = 0, .b = 0 },
            .selection_bg = .{ .r = 173, .g = 214, .b = 255 },
            .selection_fg = .{ .r = 0, .g = 0, .b = 0 },
            .ansi_colors = defaultAnsiLight(),
            .accent = .{ .r = 0, .g = 102, .b = 179 },
            .link = .{ .r = 0, .g = 102, .b = 179 },
            .error_color = .{ .r = 205, .g = 49, .b = 49 },
            .warning = .{ .r = 191, .g = 134, .b = 0 },
            .success = .{ .r = 22, .g = 128, .b = 17 },
        };
    }

    fn defaultAnsiDark() [16]Color {
        return .{
            .{ .r = 0, .g = 0, .b = 0 }, // Black
            .{ .r = 205, .g = 49, .b = 49 }, // Red
            .{ .r = 13, .g = 188, .b = 121 }, // Green
            .{ .r = 229, .g = 229, .b = 16 }, // Yellow
            .{ .r = 36, .g = 114, .b = 200 }, // Blue
            .{ .r = 188, .g = 63, .b = 188 }, // Magenta
            .{ .r = 17, .g = 168, .b = 205 }, // Cyan
            .{ .r = 229, .g = 229, .b = 229 }, // White
            .{ .r = 102, .g = 102, .b = 102 }, // Bright Black
            .{ .r = 241, .g = 76, .b = 76 }, // Bright Red
            .{ .r = 35, .g = 209, .b = 139 }, // Bright Green
            .{ .r = 245, .g = 245, .b = 67 }, // Bright Yellow
            .{ .r = 59, .g = 142, .b = 234 }, // Bright Blue
            .{ .r = 214, .g = 112, .b = 214 }, // Bright Magenta
            .{ .r = 41, .g = 184, .b = 219 }, // Bright Cyan
            .{ .r = 255, .g = 255, .b = 255 }, // Bright White
        };
    }

    fn defaultAnsiLight() [16]Color {
        return .{
            .{ .r = 0, .g = 0, .b = 0 }, // Black
            .{ .r = 205, .g = 49, .b = 49 }, // Red
            .{ .r = 0, .g = 128, .b = 0 }, // Green
            .{ .r = 160, .g = 128, .b = 0 }, // Yellow
            .{ .r = 0, .g = 0, .b = 200 }, // Blue
            .{ .r = 160, .g = 0, .b = 160 }, // Magenta
            .{ .r = 0, .g = 160, .b = 160 }, // Cyan
            .{ .r = 160, .g = 160, .b = 160 }, // White
            .{ .r = 102, .g = 102, .b = 102 }, // Bright Black
            .{ .r = 241, .g = 76, .b = 76 }, // Bright Red
            .{ .r = 35, .g = 209, .b = 139 }, // Bright Green
            .{ .r = 191, .g = 134, .b = 0 }, // Bright Yellow
            .{ .r = 59, .g = 142, .b = 234 }, // Bright Blue
            .{ .r = 214, .g = 112, .b = 214 }, // Bright Magenta
            .{ .r = 0, .g = 184, .b = 219 }, // Bright Cyan
            .{ .r = 68, .g = 68, .b = 68 }, // Bright White (dark for light theme)
        };
    }
};

/// AI-generated theme suggestion with rich metadata
pub const AISuggestedTheme = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    colors: ColorScheme,
    confidence: f32,
    reason: []const u8,
    source: ThemeSource,
    tags: ArrayList([]const u8),
    accessibility: AccessibilityInfo,
    preview_ansi: ?[]const u8,
    created_at: i64,

    pub const ThemeSource = enum {
        ai_generated,
        builtin,
        community,
        user_custom,
        learned,
    };

    pub const AccessibilityInfo = struct {
        wcag_level: WcagLevel,
        contrast_ratio: f32,
        color_blind_safe: bool,
        issues: ArrayList([]const u8),

        pub const WcagLevel = enum {
            aaa,
            aa,
            a,
            fail,
        };
    };

    pub fn deinit(self: *const AISuggestedTheme, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.reason);
        for (self.tags.items) |tag| {
            alloc.free(tag);
        }
        self.tags.deinit();
        for (self.accessibility.issues.items) |issue| {
            alloc.free(issue);
        }
        self.accessibility.issues.deinit();
        if (self.preview_ansi) |preview| alloc.free(preview);
    }
};

/// Context for theme suggestions
pub const ThemeContext = struct {
    time_of_day: TimeOfDay,
    activity: Activity,
    current_theme: ?[]const u8,
    ambient_light: AmbientLight,
    session_duration: u64, // minutes
    fatigue_level: FatigueLevel,
    preferences: UserPreferences,

    pub const TimeOfDay = enum {
        early_morning, // 5-8 AM
        morning, // 8-12 PM
        afternoon, // 12-5 PM
        evening, // 5-8 PM
        night, // 8 PM - 12 AM
        late_night, // 12-5 AM
    };

    pub const Activity = enum {
        coding,
        reading_docs,
        debugging,
        git_operations,
        file_browsing,
        ssh_session,
        general,
    };

    pub const AmbientLight = enum {
        bright, // Daylight or well-lit room
        moderate,
        dim,
        dark,
        unknown,
    };

    pub const FatigueLevel = enum {
        fresh,
        normal,
        tired,
        exhausted,
    };

    pub const UserPreferences = struct {
        prefer_dark: bool = true,
        prefer_high_contrast: bool = false,
        color_blind_mode: ?ColorBlindMode = null,
        font_size_preference: FontSizePreference = .normal,

        pub const ColorBlindMode = enum {
            protanopia, // Red-blind
            deuteranopia, // Green-blind
            tritanopia, // Blue-blind
            achromatopsia, // Total color blindness
        };

        pub const FontSizePreference = enum {
            small,
            normal,
            large,
        };
    };

    /// Create context from current system state
    pub fn fromCurrentState(alloc: Allocator) !ThemeContext {
        _ = alloc;
        const now = std.time.timestamp();
        const hour = @mod(@as(u64, @intCast(@divFloor(now, 3600))), 24);

        const time_of_day: TimeOfDay = if (hour >= 5 and hour < 8)
            .early_morning
        else if (hour >= 8 and hour < 12)
            .morning
        else if (hour >= 12 and hour < 17)
            .afternoon
        else if (hour >= 17 and hour < 20)
            .evening
        else if (hour >= 20 or hour < 0)
            .night
        else
            .late_night;

        return .{
            .time_of_day = time_of_day,
            .activity = .general,
            .current_theme = null,
            .ambient_light = .unknown,
            .session_duration = 0,
            .fatigue_level = .normal,
            .preferences = .{},
        };
    }
};

/// User preference history for learning
pub const PreferenceHistory = struct {
    selections: ArrayList(Selection),
    rejections: ArrayList(Rejection),
    time_patterns: StringHashMap(TimePattern),

    pub const Selection = struct {
        theme_id: []const u8,
        context: ThemeContext,
        timestamp: i64,
        rating: ?u8, // 1-5 if user rated
    };

    pub const Rejection = struct {
        theme_id: []const u8,
        reason: ?[]const u8,
        timestamp: i64,
    };

    pub const TimePattern = struct {
        hour_preferences: [24]?[]const u8, // Preferred theme ID for each hour
        activity_preferences: StringHashMap([]const u8),
    };
};

/// Configuration for theme suggestions
pub const ThemeSuggestionConfig = struct {
    enable_ai_suggestions: bool = true,
    enable_time_based: bool = true,
    enable_activity_based: bool = true,
    enable_accessibility_check: bool = true,
    enable_learning: bool = true,
    min_contrast_ratio: f32 = 4.5, // WCAG AA
    suggestion_count: u32 = 5,
    cache_duration_seconds: u64 = 300,
    ai_model: []const u8 = "default",
};

/// Callback for async theme suggestions
pub const SuggestionCallback = *const fn (suggestions: []const AISuggestedTheme, user_data: ?*anyopaque) void;

/// Theme Suggestion Manager
pub const ThemeSuggestionManager = struct {
    alloc: Allocator,
    config: ThemeSuggestionConfig,
    enabled: bool,
    builtin_themes: ArrayList(AISuggestedTheme),
    cached_suggestions: ArrayList(AISuggestedTheme),
    cache_timestamp: i64,
    preference_history: PreferenceHistory,
    callbacks: ArrayList(CallbackEntry),

    const CallbackEntry = struct {
        callback: SuggestionCallback,
        user_data: ?*anyopaque,
    };

    /// Initialize theme suggestion manager
    pub fn init(alloc: Allocator) ThemeSuggestionManager {
        return initWithConfig(alloc, .{});
    }

    /// Initialize with custom config
    pub fn initWithConfig(alloc: Allocator, config: ThemeSuggestionConfig) ThemeSuggestionManager {
        var manager = ThemeSuggestionManager{
            .alloc = alloc,
            .config = config,
            .enabled = true,
            .builtin_themes = ArrayList(AISuggestedTheme).init(alloc),
            .cached_suggestions = ArrayList(AISuggestedTheme).init(alloc),
            .cache_timestamp = 0,
            .preference_history = .{
                .selections = ArrayList(PreferenceHistory.Selection).init(alloc),
                .rejections = ArrayList(PreferenceHistory.Rejection).init(alloc),
                .time_patterns = StringHashMap(PreferenceHistory.TimePattern).init(alloc),
            },
            .callbacks = ArrayList(CallbackEntry).init(alloc),
        };

        // Load built-in themes
        manager.loadBuiltinThemes() catch |err| {
            log.warn("Failed to load built-in themes: {}", .{err});
        };

        return manager;
    }

    pub fn deinit(self: *ThemeSuggestionManager) void {
        for (self.builtin_themes.items) |*theme| {
            theme.deinit(self.alloc);
        }
        self.builtin_themes.deinit();

        for (self.cached_suggestions.items) |*theme| {
            theme.deinit(self.alloc);
        }
        self.cached_suggestions.deinit();

        for (self.preference_history.selections.items) |sel| {
            self.alloc.free(sel.theme_id);
        }
        self.preference_history.selections.deinit();

        for (self.preference_history.rejections.items) |rej| {
            self.alloc.free(rej.theme_id);
            if (rej.reason) |r| self.alloc.free(r);
        }
        self.preference_history.rejections.deinit();

        self.preference_history.time_patterns.deinit();
        self.callbacks.deinit();
    }

    /// Load built-in themes
    fn loadBuiltinThemes(self: *ThemeSuggestionManager) !void {
        // Dracula theme
        try self.builtin_themes.append(try self.createBuiltinTheme(
            "dracula",
            "Dracula",
            "A dark theme with vibrant colors",
            .{
                .background = .{ .r = 40, .g = 42, .b = 54 },
                .foreground = .{ .r = 248, .g = 248, .b = 242 },
                .cursor = .{ .r = 248, .g = 248, .b = 242 },
                .selection_bg = .{ .r = 68, .g = 71, .b = 90 },
                .selection_fg = .{ .r = 248, .g = 248, .b = 242 },
                .ansi_colors = .{
                    .{ .r = 33, .g = 34, .b = 44 },
                    .{ .r = 255, .g = 85, .b = 85 },
                    .{ .r = 80, .g = 250, .b = 123 },
                    .{ .r = 241, .g = 250, .b = 140 },
                    .{ .r = 98, .g = 114, .b = 164 },
                    .{ .r = 255, .g = 121, .b = 198 },
                    .{ .r = 139, .g = 233, .b = 253 },
                    .{ .r = 248, .g = 248, .b = 242 },
                    .{ .r = 98, .g = 114, .b = 164 },
                    .{ .r = 255, .g = 110, .b = 103 },
                    .{ .r = 105, .g = 255, .b = 148 },
                    .{ .r = 255, .g = 255, .b = 165 },
                    .{ .r = 125, .g = 139, .b = 191 },
                    .{ .r = 255, .g = 146, .b = 208 },
                    .{ .r = 164, .g = 240, .b = 255 },
                    .{ .r = 255, .g = 255, .b = 255 },
                },
                .accent = .{ .r = 189, .g = 147, .b = 249 },
                .link = .{ .r = 139, .g = 233, .b = 253 },
                .error_color = .{ .r = 255, .g = 85, .b = 85 },
                .warning = .{ .r = 255, .g = 184, .b = 108 },
                .success = .{ .r = 80, .g = 250, .b = 123 },
            },
            &.{ "dark", "popular", "coding" },
        ));

        // Solarized Dark
        try self.builtin_themes.append(try self.createBuiltinTheme(
            "solarized-dark",
            "Solarized Dark",
            "Precision colors for machines and people",
            .{
                .background = .{ .r = 0, .g = 43, .b = 54 },
                .foreground = .{ .r = 131, .g = 148, .b = 150 },
                .cursor = .{ .r = 131, .g = 148, .b = 150 },
                .selection_bg = .{ .r = 7, .g = 54, .b = 66 },
                .selection_fg = .{ .r = 147, .g = 161, .b = 161 },
                .ansi_colors = .{
                    .{ .r = 7, .g = 54, .b = 66 },
                    .{ .r = 220, .g = 50, .b = 47 },
                    .{ .r = 133, .g = 153, .b = 0 },
                    .{ .r = 181, .g = 137, .b = 0 },
                    .{ .r = 38, .g = 139, .b = 210 },
                    .{ .r = 211, .g = 54, .b = 130 },
                    .{ .r = 42, .g = 161, .b = 152 },
                    .{ .r = 238, .g = 232, .b = 213 },
                    .{ .r = 0, .g = 43, .b = 54 },
                    .{ .r = 203, .g = 75, .b = 22 },
                    .{ .r = 88, .g = 110, .b = 117 },
                    .{ .r = 101, .g = 123, .b = 131 },
                    .{ .r = 131, .g = 148, .b = 150 },
                    .{ .r = 108, .g = 113, .b = 196 },
                    .{ .r = 147, .g = 161, .b = 161 },
                    .{ .r = 253, .g = 246, .b = 227 },
                },
                .accent = .{ .r = 38, .g = 139, .b = 210 },
                .link = .{ .r = 38, .g = 139, .b = 210 },
                .error_color = .{ .r = 220, .g = 50, .b = 47 },
                .warning = .{ .r = 181, .g = 137, .b = 0 },
                .success = .{ .r = 133, .g = 153, .b = 0 },
            },
            &.{ "dark", "classic", "ergonomic" },
        ));

        // Nord
        try self.builtin_themes.append(try self.createBuiltinTheme(
            "nord",
            "Nord",
            "An arctic, north-bluish color palette",
            .{
                .background = .{ .r = 46, .g = 52, .b = 64 },
                .foreground = .{ .r = 216, .g = 222, .b = 233 },
                .cursor = .{ .r = 216, .g = 222, .b = 233 },
                .selection_bg = .{ .r = 67, .g = 76, .b = 94 },
                .selection_fg = .{ .r = 236, .g = 239, .b = 244 },
                .ansi_colors = .{
                    .{ .r = 59, .g = 66, .b = 82 },
                    .{ .r = 191, .g = 97, .b = 106 },
                    .{ .r = 163, .g = 190, .b = 140 },
                    .{ .r = 235, .g = 203, .b = 139 },
                    .{ .r = 129, .g = 161, .b = 193 },
                    .{ .r = 180, .g = 142, .b = 173 },
                    .{ .r = 136, .g = 192, .b = 208 },
                    .{ .r = 229, .g = 233, .b = 240 },
                    .{ .r = 76, .g = 86, .b = 106 },
                    .{ .r = 191, .g = 97, .b = 106 },
                    .{ .r = 163, .g = 190, .b = 140 },
                    .{ .r = 235, .g = 203, .b = 139 },
                    .{ .r = 129, .g = 161, .b = 193 },
                    .{ .r = 180, .g = 142, .b = 173 },
                    .{ .r = 143, .g = 188, .b = 187 },
                    .{ .r = 236, .g = 239, .b = 244 },
                },
                .accent = .{ .r = 136, .g = 192, .b = 208 },
                .link = .{ .r = 129, .g = 161, .b = 193 },
                .error_color = .{ .r = 191, .g = 97, .b = 106 },
                .warning = .{ .r = 235, .g = 203, .b = 139 },
                .success = .{ .r = 163, .g = 190, .b = 140 },
            },
            &.{ "dark", "cool", "minimal" },
        ));

        // Monokai Pro
        try self.builtin_themes.append(try self.createBuiltinTheme(
            "monokai-pro",
            "Monokai Pro",
            "A refined Monokai for professional developers",
            .{
                .background = .{ .r = 45, .g = 42, .b = 46 },
                .foreground = .{ .r = 252, .g = 252, .b = 250 },
                .cursor = .{ .r = 252, .g = 252, .b = 250 },
                .selection_bg = .{ .r = 87, .g = 82, .b = 91 },
                .selection_fg = .{ .r = 252, .g = 252, .b = 250 },
                .ansi_colors = .{
                    .{ .r = 45, .g = 42, .b = 46 },
                    .{ .r = 255, .g = 97, .b = 136 },
                    .{ .r = 169, .g = 220, .b = 118 },
                    .{ .r = 255, .g = 216, .b = 102 },
                    .{ .r = 120, .g = 220, .b = 232 },
                    .{ .r = 171, .g = 157, .b = 242 },
                    .{ .r = 120, .g = 220, .b = 232 },
                    .{ .r = 252, .g = 252, .b = 250 },
                    .{ .r = 114, .g = 109, .b = 118 },
                    .{ .r = 255, .g = 97, .b = 136 },
                    .{ .r = 169, .g = 220, .b = 118 },
                    .{ .r = 255, .g = 216, .b = 102 },
                    .{ .r = 120, .g = 220, .b = 232 },
                    .{ .r = 171, .g = 157, .b = 242 },
                    .{ .r = 120, .g = 220, .b = 232 },
                    .{ .r = 252, .g = 252, .b = 250 },
                },
                .accent = .{ .r = 255, .g = 97, .b = 136 },
                .link = .{ .r = 120, .g = 220, .b = 232 },
                .error_color = .{ .r = 255, .g = 97, .b = 136 },
                .warning = .{ .r = 255, .g = 216, .b = 102 },
                .success = .{ .r = 169, .g = 220, .b = 118 },
            },
            &.{ "dark", "vibrant", "coding" },
        ));

        // One Light
        try self.builtin_themes.append(try self.createBuiltinTheme(
            "one-light",
            "One Light",
            "Atom's iconic light theme",
            ColorScheme.defaultLight(),
            &.{ "light", "classic", "reading" },
        ));

        log.debug("Loaded {} built-in themes", .{self.builtin_themes.items.len});
    }

    /// Create a built-in theme
    fn createBuiltinTheme(
        self: *ThemeSuggestionManager,
        id: []const u8,
        name: []const u8,
        description: []const u8,
        colors: ColorScheme,
        tag_list: []const []const u8,
    ) !AISuggestedTheme {
        var tags = ArrayList([]const u8).init(self.alloc);
        for (tag_list) |tag| {
            try tags.append(try self.alloc.dupe(u8, tag));
        }

        const accessibility = self.analyzeAccessibility(colors);

        return .{
            .id = try self.alloc.dupe(u8, id),
            .name = try self.alloc.dupe(u8, name),
            .description = try self.alloc.dupe(u8, description),
            .colors = colors,
            .confidence = 1.0,
            .reason = try self.alloc.dupe(u8, "Built-in theme"),
            .source = .builtin,
            .tags = tags,
            .accessibility = accessibility,
            .preview_ansi = null,
            .created_at = std.time.timestamp(),
        };
    }

    /// Analyze accessibility of a color scheme
    fn analyzeAccessibility(self: *ThemeSuggestionManager, colors: ColorScheme) AISuggestedTheme.AccessibilityInfo {
        var issues = ArrayList([]const u8).init(self.alloc);
        const contrast = colors.foreground.contrastRatio(colors.background);

        // Check main contrast
        const level: AISuggestedTheme.AccessibilityInfo.WcagLevel = if (contrast >= 7.0)
            .aaa
        else if (contrast >= 4.5)
            .aa
        else if (contrast >= 3.0)
            .a
        else
            .fail;

        if (level == .fail) {
            issues.append(self.alloc.dupe(u8, "Insufficient contrast between foreground and background") catch "Low contrast") catch {};
        }

        // Check ANSI color contrasts
        for (colors.ansi_colors, 0..) |ansi_color, i| {
            const ansi_contrast = ansi_color.contrastRatio(colors.background);
            if (ansi_contrast < 3.0) {
                const msg = std.fmt.allocPrint(self.alloc, "ANSI color {d} has low contrast ({d:.1}:1)", .{ i, ansi_contrast }) catch "Low ANSI contrast";
                issues.append(msg) catch {};
            }
        }

        // Simple color blindness check (red-green distinction)
        const red_hsl = colors.ansi_colors[1].toHsl();
        const green_hsl = colors.ansi_colors[2].toHsl();
        const hue_diff = @abs(red_hsl.h - green_hsl.h);
        const color_blind_safe = hue_diff > 60 or (colors.ansi_colors[1].luminance() != colors.ansi_colors[2].luminance());

        return .{
            .wcag_level = level,
            .contrast_ratio = contrast,
            .color_blind_safe = color_blind_safe,
            .issues = issues,
        };
    }

    /// Generate theme suggestions based on context
    pub fn generateSuggestions(
        self: *ThemeSuggestionManager,
        context: ThemeContext,
    ) !ArrayList(AISuggestedTheme) {
        var suggestions = ArrayList(AISuggestedTheme).init(self.alloc);
        errdefer {
            for (suggestions.items) |*s| s.deinit(self.alloc);
            suggestions.deinit();
        }

        if (!self.enabled) return suggestions;

        // Check cache first
        const now = std.time.timestamp();
        if (now - self.cache_timestamp < @as(i64, @intCast(self.config.cache_duration_seconds)) and
            self.cached_suggestions.items.len > 0)
        {
            // Return cached suggestions
            for (self.cached_suggestions.items) |cached| {
                try suggestions.append(try self.cloneTheme(cached));
            }
            return suggestions;
        }

        // Score and rank themes based on context
        var scored_themes = ArrayList(struct { theme: *AISuggestedTheme, score: f32 }).init(self.alloc);
        defer scored_themes.deinit();

        for (self.builtin_themes.items) |*theme| {
            const score = self.scoreThemeForContext(theme, context);
            try scored_themes.append(.{ .theme = theme, .score = score });
        }

        // Sort by score descending
        std.mem.sort(
            @TypeOf(scored_themes.items[0]),
            scored_themes.items,
            {},
            struct {
                fn lessThan(_: void, a: @TypeOf(scored_themes.items[0]), b: @TypeOf(scored_themes.items[0])) bool {
                    return a.score > b.score;
                }
            }.lessThan,
        );

        // Take top N suggestions
        const count = @min(self.config.suggestion_count, scored_themes.items.len);
        for (scored_themes.items[0..count]) |item| {
            var cloned = try self.cloneTheme(item.theme.*);
            cloned.confidence = item.score;
            cloned.reason = try self.generateReason(item.theme.*, context);
            try suggestions.append(cloned);
        }

        // Update cache
        for (self.cached_suggestions.items) |*cached| {
            cached.deinit(self.alloc);
        }
        self.cached_suggestions.clearRetainingCapacity();
        for (suggestions.items) |suggestion| {
            try self.cached_suggestions.append(try self.cloneTheme(suggestion));
        }
        self.cache_timestamp = now;

        return suggestions;
    }

    /// Score a theme based on context
    fn scoreThemeForContext(self: *ThemeSuggestionManager, theme: *AISuggestedTheme, context: ThemeContext) f32 {
        var score: f32 = 0.5; // Base score

        // Time of day scoring
        if (self.config.enable_time_based) {
            const is_dark_theme = theme.colors.background.luminance() < 0.5;
            const prefers_dark = switch (context.time_of_day) {
                .night, .late_night, .evening => true,
                .early_morning => true,
                .morning, .afternoon => false,
            };

            if (is_dark_theme == prefers_dark) {
                score += 0.2;
            } else {
                score -= 0.1;
            }
        }

        // Ambient light scoring
        switch (context.ambient_light) {
            .dark, .dim => {
                if (theme.colors.background.luminance() < 0.3) score += 0.15;
            },
            .bright => {
                if (theme.colors.background.luminance() > 0.5) score += 0.15;
            },
            else => {},
        }

        // Activity-based scoring
        if (self.config.enable_activity_based) {
            switch (context.activity) {
                .coding => {
                    // Prefer themes with good ANSI color variety
                    score += 0.1;
                },
                .reading_docs => {
                    // Prefer higher contrast
                    if (theme.accessibility.contrast_ratio > 7.0) score += 0.15;
                },
                .debugging => {
                    // Prefer themes with distinct error colors
                    const error_contrast = theme.colors.error_color.contrastRatio(theme.colors.background);
                    if (error_contrast > 5.0) score += 0.1;
                },
                else => {},
            }
        }

        // Fatigue-based scoring
        switch (context.fatigue_level) {
            .tired, .exhausted => {
                // Prefer lower contrast for tired eyes
                if (theme.accessibility.contrast_ratio < 10.0 and theme.accessibility.contrast_ratio >= 4.5) {
                    score += 0.1;
                }
            },
            else => {},
        }

        // Accessibility scoring
        if (self.config.enable_accessibility_check) {
            if (theme.accessibility.wcag_level == .aaa) {
                score += 0.1;
            } else if (theme.accessibility.wcag_level == .fail) {
                score -= 0.3;
            }

            if (context.preferences.color_blind_mode != null and !theme.accessibility.color_blind_safe) {
                score -= 0.2;
            }
        }

        // User preference scoring
        if (context.preferences.prefer_high_contrast) {
            if (theme.accessibility.contrast_ratio >= 7.0) score += 0.15;
        }

        return std.math.clamp(score, 0.0, 1.0);
    }

    /// Generate reason for suggestion
    fn generateReason(self: *ThemeSuggestionManager, theme: AISuggestedTheme, context: ThemeContext) ![]const u8 {
        var reasons = ArrayList(u8).init(self.alloc);
        const writer = reasons.writer();

        try writer.writeAll("Recommended because: ");

        var first = true;

        // Time-based reason
        switch (context.time_of_day) {
            .night, .late_night => {
                if (theme.colors.background.luminance() < 0.3) {
                    if (!first) try writer.writeAll(", ");
                    try writer.writeAll("dark theme for nighttime use");
                    first = false;
                }
            },
            .morning, .afternoon => {
                if (theme.colors.background.luminance() > 0.5) {
                    if (!first) try writer.writeAll(", ");
                    try writer.writeAll("light theme for daytime visibility");
                    first = false;
                }
            },
            else => {},
        }

        // Accessibility reason
        if (theme.accessibility.wcag_level == .aaa) {
            if (!first) try writer.writeAll(", ");
            try writer.writeAll("excellent accessibility (WCAG AAA)");
            first = false;
        }

        // Activity reason
        switch (context.activity) {
            .coding => {
                if (!first) try writer.writeAll(", ");
                try writer.writeAll("optimized for coding");
                first = false;
            },
            .reading_docs => {
                if (!first) try writer.writeAll(", ");
                try writer.writeAll("good for reading");
                first = false;
            },
            else => {},
        }

        if (first) {
            try writer.writeAll("matches your preferences");
        }

        return reasons.toOwnedSlice();
    }

    /// Clone a theme
    fn cloneTheme(self: *ThemeSuggestionManager, theme: AISuggestedTheme) !AISuggestedTheme {
        var tags = ArrayList([]const u8).init(self.alloc);
        for (theme.tags.items) |tag| {
            try tags.append(try self.alloc.dupe(u8, tag));
        }

        var issues = ArrayList([]const u8).init(self.alloc);
        for (theme.accessibility.issues.items) |issue| {
            try issues.append(try self.alloc.dupe(u8, issue));
        }

        return .{
            .id = try self.alloc.dupe(u8, theme.id),
            .name = try self.alloc.dupe(u8, theme.name),
            .description = try self.alloc.dupe(u8, theme.description),
            .colors = theme.colors,
            .confidence = theme.confidence,
            .reason = try self.alloc.dupe(u8, theme.reason),
            .source = theme.source,
            .tags = tags,
            .accessibility = .{
                .wcag_level = theme.accessibility.wcag_level,
                .contrast_ratio = theme.accessibility.contrast_ratio,
                .color_blind_safe = theme.accessibility.color_blind_safe,
                .issues = issues,
            },
            .preview_ansi = if (theme.preview_ansi) |p| try self.alloc.dupe(u8, p) else null,
            .created_at = theme.created_at,
        };
    }

    /// Record user selection of a theme
    pub fn recordSelection(
        self: *ThemeSuggestionManager,
        theme_id: []const u8,
        context: ThemeContext,
        rating: ?u8,
    ) !void {
        if (!self.config.enable_learning) return;

        try self.preference_history.selections.append(.{
            .theme_id = try self.alloc.dupe(u8, theme_id),
            .context = context,
            .timestamp = std.time.timestamp(),
            .rating = rating,
        });

        log.debug("Recorded theme selection: {s}", .{theme_id});
    }

    /// Record user rejection of a theme
    pub fn recordRejection(
        self: *ThemeSuggestionManager,
        theme_id: []const u8,
        reason: ?[]const u8,
    ) !void {
        if (!self.config.enable_learning) return;

        try self.preference_history.rejections.append(.{
            .theme_id = try self.alloc.dupe(u8, theme_id),
            .reason = if (reason) |r| try self.alloc.dupe(u8, r) else null,
            .timestamp = std.time.timestamp(),
        });
    }

    /// Get a specific theme by ID
    pub fn getThemeById(self: *const ThemeSuggestionManager, theme_id: []const u8) ?*const AISuggestedTheme {
        for (self.builtin_themes.items) |*theme| {
            if (std.mem.eql(u8, theme.id, theme_id)) {
                return theme;
            }
        }
        return null;
    }

    /// Generate ANSI preview for a theme
    pub fn generatePreview(self: *ThemeSuggestionManager, theme_id: []const u8) !?[]const u8 {
        const theme = self.getThemeById(theme_id) orelse return null;

        var preview = ArrayList(u8).init(self.alloc);
        const writer = preview.writer();

        // Generate ANSI escape sequence preview
        try writer.writeAll("Theme Preview: ");
        try writer.writeAll(theme.name);
        try writer.writeAll("\n\n");

        // Color palette preview
        try writer.writeAll("Standard colors: ");
        for (0..8) |i| {
            try std.fmt.format(writer, "\x1b[48;5;{d}m  \x1b[0m", .{i});
        }
        try writer.writeAll("\n");

        try writer.writeAll("Bright colors:   ");
        for (8..16) |i| {
            try std.fmt.format(writer, "\x1b[48;5;{d}m  \x1b[0m", .{i});
        }
        try writer.writeAll("\n");

        return preview.toOwnedSlice();
    }

    /// Enable or disable suggestions
    pub fn setEnabled(self: *ThemeSuggestionManager, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Get all available themes
    pub fn getAllThemes(self: *const ThemeSuggestionManager) []const AISuggestedTheme {
        return self.builtin_themes.items;
    }

    /// Register callback for suggestion events
    pub fn onSuggestion(
        self: *ThemeSuggestionManager,
        callback: SuggestionCallback,
        user_data: ?*anyopaque,
    ) !void {
        try self.callbacks.append(.{
            .callback = callback,
            .user_data = user_data,
        });
    }
};

// Tests
test "ColorScheme contrast calculations" {
    const white = ColorScheme.Color{ .r = 255, .g = 255, .b = 255 };
    const black = ColorScheme.Color{ .r = 0, .g = 0, .b = 0 };

    const ratio = white.contrastRatio(black);
    try std.testing.expect(ratio >= 20.0 and ratio <= 22.0); // Should be ~21:1

    try std.testing.expect(white.meetsWcagAA(black));
    try std.testing.expect(white.meetsWcagAAA(black));
}

test "ThemeSuggestionManager generates suggestions" {
    const alloc = std.testing.allocator;
    var manager = ThemeSuggestionManager.init(alloc);
    defer manager.deinit();

    const context = ThemeContext{
        .time_of_day = .night,
        .activity = .coding,
        .current_theme = null,
        .ambient_light = .dark,
        .session_duration = 60,
        .fatigue_level = .normal,
        .preferences = .{},
    };

    var suggestions = try manager.generateSuggestions(context);
    defer {
        for (suggestions.items) |*s| s.deinit(alloc);
        suggestions.deinit();
    }

    try std.testing.expect(suggestions.items.len > 0);
}

test "ColorScheme HSL conversion" {
    const red = ColorScheme.Color{ .r = 255, .g = 0, .b = 0 };
    const hsl = red.toHsl();

    try std.testing.expect(hsl.h < 1.0 or hsl.h > 359.0); // Red should be around 0/360
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hsl.s, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), hsl.l, 0.01);
}
