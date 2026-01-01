//! AI Settings Dialog
//! Comprehensive settings panel for AI features

const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_ai_settings);

pub const AiSettingsDialog = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.PreferencesWindow;

    const Private = struct {
        config: ?*Config = null,
        provider_dropdown: ?*gtk.DropDown = null,
        model_dropdown: ?*gtk.DropDown = null,
        api_key_entry: ?*gtk.Entry = null,
        endpoint_entry: ?*gtk.Entry = null,
        max_tokens_spin: ?*gtk.SpinButton = null,
        temperature_scale: ?*gtk.Scale = null,
        context_aware_switch: ?*gtk.Switch = null,
        context_lines_spin: ?*gtk.SpinButton = null,

        pub var offset: c_int = 0;
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self) callconv(.c) void {
        const priv = getPriv(self);

        // Create preferences window
        self.as(adw.PreferencesWindow).setTitle("AI Settings");
        self.as(adw.PreferencesWindow).setDefaultSize(600, 500);

        // Create main page
        const page = adw.PreferencesPage.new();
        page.setTitle("AI Configuration");
        page.setIconName("preferences-system-symbolic");

        // Provider section
        const provider_group = adw.PreferencesGroup.new();
        provider_group.setTitle("AI Provider");
        provider_group.setDescription("Choose your AI provider and model");

        const provider_row = adw.ComboRow.new();
        provider_row.setTitle("Provider");
        provider_row.setSubtitle("Select AI provider");
        priv.provider_dropdown = provider_row.as(gtk.DropDown);
        provider_group.add(provider_row.as(gtk.Widget));

        const model_row = adw.ComboRow.new();
        model_row.setTitle("Model");
        model_row.setSubtitle("Select AI model");
        priv.model_dropdown = model_row.as(gtk.DropDown);
        provider_group.add(model_row.as(gtk.Widget));

        page.add(provider_group.as(gtk.Widget));

        // API Configuration section
        const api_group = adw.PreferencesGroup.new();
        api_group.setTitle("API Configuration");
        api_group.setDescription("Configure API keys and endpoints");

        const api_key_row = adw.EntryRow.new();
        api_key_row.setTitle("API Key");
        api_key_row.setShowApplyButton(@intFromBool(true));
        api_key_row.setInputPurpose(gtk.InputPurpose.password);
        priv.api_key_entry = api_key_row.as(gtk.Entry);
        api_group.add(api_key_row.as(gtk.Widget));

        const endpoint_row = adw.EntryRow.new();
        endpoint_row.setTitle("Endpoint");
        endpoint_row.setShowApplyButton(@intFromBool(true));
        priv.endpoint_entry = endpoint_row.as(gtk.Entry);
        api_group.add(endpoint_row.as(gtk.Widget));

        page.add(api_group.as(gtk.Widget));

        // Advanced section
        const advanced_group = adw.PreferencesGroup.new();
        advanced_group.setTitle("Advanced");
        advanced_group.setDescription("Advanced AI settings");

        const max_tokens_row = adw.SpinRow.new();
        max_tokens_row.setTitle("Max Tokens");
        max_tokens_row.setSubtitle("Maximum tokens per response");
        max_tokens_row.setRange(1, 100000);
        max_tokens_row.setValue(2000);
        priv.max_tokens_spin = max_tokens_row.as(gtk.SpinButton);
        advanced_group.add(max_tokens_row.as(gtk.Widget));

        const temperature_row = adw.SpinRow.new();
        temperature_row.setTitle("Temperature");
        temperature_row.setSubtitle("Response randomness (0.0-2.0)");
        temperature_row.setRange(0.0, 2.0);
        temperature_row.setValue(0.7);
        temperature_row.setDigits(1);
        priv.temperature_scale = temperature_row.as(gtk.Scale);
        advanced_group.add(temperature_row.as(gtk.Widget));

        const context_aware_row = adw.ActionRow.new();
        context_aware_row.setTitle("Context Aware");
        context_aware_row.setSubtitle("Use terminal context in prompts");
        const context_switch = gtk.Switch.new();
        context_aware_row.addSuffix(context_switch.as(gtk.Widget));
        priv.context_aware_switch = context_switch;
        advanced_group.add(context_aware_row.as(gtk.Widget));

        const context_lines_row = adw.SpinRow.new();
        context_lines_row.setTitle("Context Lines");
        context_lines_row.setSubtitle("Number of terminal lines to include");
        context_lines_row.setRange(0, 100);
        context_lines_row.setValue(10);
        priv.context_lines_spin = context_lines_row.as(gtk.SpinButton);
        advanced_group.add(context_lines_row.as(gtk.Widget));

        page.add(advanced_group.as(gtk.Widget));

        self.as(adw.PreferencesWindow).add(page.as(adw.PreferencesPage));
    }

    fn dispose(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn setConfig(self: *Self, config: *Config) void {
        const priv = getPriv(self);
        priv.config = config;
        // TODO: Populate UI from config
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.PreferencesWindow).setTransientFor(parent.as(gtk.Window));
        self.as(adw.PreferencesWindow).present();
    }
};
