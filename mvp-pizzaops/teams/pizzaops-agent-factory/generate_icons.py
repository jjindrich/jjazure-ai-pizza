from pathlib import Path
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent


def create_icon(size: int, target: Path) -> None:
    image = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    draw = ImageDraw.Draw(image)
    purple = (91, 44, 111, 255)
    cream = (255, 244, 220, 255)
    margin = max(2, size // 8)
    draw.ellipse((margin, margin, size - margin, size - margin), fill=cream, outline=purple, width=max(2, size // 12))
    draw.pieslice((margin * 1.25, margin * 1.25, size - margin * 1.25, size - margin * 1.25), 20, 320, fill=purple)
    if size >= 64:
        draw.ellipse((size * 0.42, size * 0.38, size * 0.56, size * 0.52), fill=cream)
        draw.ellipse((size * 0.55, size * 0.62, size * 0.68, size * 0.75), fill=cream)
        draw.ellipse((size * 0.28, size * 0.62, size * 0.41, size * 0.75), fill=cream)
    image.save(target, "PNG")


create_icon(192, ROOT / "color.png")
create_icon(32, ROOT / "outline.png")
