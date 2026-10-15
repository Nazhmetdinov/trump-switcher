"""Finder layout for the branded installer; evaluated only by dmgbuild."""
from pathlib import Path
import unicodedata

root = Path(defines["root"]).resolve()
app = Path(defines["app"]).resolve()
instructions = Path(defines["instructions"]).resolve()
security_shortcut = Path(defines["security_shortcut"]).resolve()

format = "UDZO"
filesystem = "HFS+"
files = [str(app), str(security_shortcut), (str(instructions), ".Установка.txt")]
symlinks = {"Программы": "/Applications"}
hide = [".Установка.txt"]
# Finder already treats applications as bundles. Setting FinderInfo flags on a
# signed .app would make strict codesign verification reject the copied bundle.
hide_extensions = [security_shortcut.name]
icon = str(root / "Assets/TrumpAppIcon.icns")
background = str(root / "Assets/Installer/background.tiff")
window_rect = ((160, 100), (760, 680))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
scroll_position = (0, 0)
icon_size = 128
text_size = 14
label_pos = "bottom"
show_icon_preview = False
icon_locations = {"Trump Switcher.app": (185, 272), "Программы": (575, 272),
                  unicodedata.normalize("NFD", security_shortcut.name): (600, 485)}
