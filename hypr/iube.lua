-- iube: keep the launcher floating, centred, and pinned.
--
-- Hyprland 0.55+ Lua config. The app registers its own runtime rule named
-- "iube-runtime" at startup via `hyprctl eval`, so this file is optional. Use
-- it if you want a rule before iube launches or one that survives a Hyprland
-- reload without relaunching the app. This file uses the distinct name
-- "iube-config", so the app does not overwrite it.
--
-- dvui's SDL3 backend sets the Wayland app id/class to "iube" (the binary
-- name). Match the class, not the title: the title can arrive too late for
-- the initial configure, leaving the first frame tiled.

hl.window_rule({
    name = "iube-config",

    match = { class = "^(iube)$" },

    float = true,
    center = true,
    pin = true,
    size = "640 360",

    border_size = 0,
    rounding = 8,
    no_shadow = true,
    no_blur = true,
    dim_around = true,
})
