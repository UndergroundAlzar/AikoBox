"""Generate AikoBox Windows and tray icons from build/aiko-mascot.png.

Requires Pillow. The mascot source is already transparent; this script only
performs deterministic resizing and status-ring composition.
"""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "build" / "aiko-mascot.png"
ICO_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]


def centered_mascot(max_size: tuple[int, int]) -> Image.Image:
    mascot = Image.open(SOURCE).convert("RGBA")
    mascot.thumbnail(max_size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    canvas.alpha_composite(mascot, ((1024 - mascot.width) // 2, (1024 - mascot.height) // 2))
    return canvas


def save_png_and_ico(image: Image.Image, png: Path, ico: Path) -> None:
    image.save(png, optimize=True)
    image.save(ico, format="ICO", sizes=ICO_SIZES)


main_icon = centered_mascot((900, 900))
save_png_and_ico(main_icon, ROOT / "build" / "icon.png", ROOT / "build" / "icon.ico")
main_icon.save(ROOT / "build" / "installerIcon.ico", format="ICO", sizes=ICO_SIZES)
save_png_and_ico(main_icon, ROOT / "resources" / "icon.png", ROOT / "resources" / "icon.ico")

mascot = Image.open(SOURCE).convert("RGBA")
mascot.thumbnail((820, 820), Image.Resampling.LANCZOS)
for name, color in {
    "blue": (59, 130, 246, 255),
    "green": (34, 197, 94, 255),
    "red": (239, 68, 68, 255),
}.items():
    status_icon = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    draw = ImageDraw.Draw(status_icon)
    draw.ellipse(
        (28, 28, 996, 996),
        fill=(color[0], color[1], color[2], 40),
        outline=color,
        width=36,
    )
    status_icon.alpha_composite(
        mascot, ((1024 - mascot.width) // 2, (1024 - mascot.height) // 2)
    )
    save_png_and_ico(
        status_icon,
        ROOT / "resources" / f"icon_{name}.png",
        ROOT / "resources" / f"icon_{name}.ico",
    )

print("Generated AikoBox Windows and tray icons.")
