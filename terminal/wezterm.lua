-- Recommended WezTerm config for terhm. Copy it to ~/.config/wezterm/wezterm.lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.color_scheme = 'Catppuccin Mocha'
config.font = wezterm.font_with_fallback { 'JetBrains Mono', 'Fira Code', 'monospace' }
config.font_size = 12.5
config.window_background_opacity = 0.96
config.window_padding = { left = 14, right = 14, top = 10, bottom = 10 }
config.window_decorations = 'RESIZE'
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = true
config.default_cursor_style = 'BlinkingBar'
config.scrollback_lines = 10000
-- Ctrl+G reaches the shell: no keybinding to change.

return config
