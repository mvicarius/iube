-- iube: optional fallback rule for compositors without layer-shell support.
--
-- When zwlr_layer_shell_v1 is available (Hyprland, wlroots compositors), iube
-- creates a centred 640x360 overlay surface itself and this rule is not used.
--
-- On the xdg-toplevel fallback, the app registers a runtime rule named
-- "iube-runtime" at startup via `hyprctl eval`. This file is for the case
-- where you want an equivalent rule before iube launches, or one that survives
-- a Hyprland reload without relaunching the app. It uses the distinct name
-- "iube-config", so the app does not overwrite it.
--
-- Match the class ("iube"), not the title: the title can arrive too late for
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
