-- Personal monitor setup, ported from the pre-quattro monitors.conf.
-- Omarchy's generic catch-all monitor rule (scale 1.25) stays active for
-- any other output; these two explicit rules override it.

-- eDP-1 is 1920x1200 on a 300x190 mm panel = 162 DPI, so scale 1 renders
-- everything far too small. 1.25 (~130 effective DPI) is what it has actually
-- been running at; declaring it here stops the config fighting the runtime.
hl.monitor({ output = "eDP-1", mode = "1920x1200@60", position = "0x0", scale = 1.25 })

-- HDMI-A-1 is a 27" 1440p panel = 109 DPI. Scale 1.6 collapsed it to a
-- 1600x900 logical desktop, which is why it looked worse than the laptop.
-- Scale 1 gives back the full 2560x1440; comfort comes from font sizes.
hl.monitor({ output = "HDMI-A-1", mode = "2560x1440@59.95", position = "1920x0", scale = 1.25 })
