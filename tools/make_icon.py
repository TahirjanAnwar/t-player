"""Draws assets/t-player.png and assets/t-player.ico. Needs Pillow (pip install Pillow); only used to make the icon."""
import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024                      # drawn large, then shrunk, for smooth edges
# The sky blue of East Turkistan's flag, the Kok Bayraq (#0099FF), with a white symbol like its crescent and star.
TOP = BOTTOM = (0, 153, 255)


def gradient(size):
    image = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / (size - 1)
        draw.line([(0, y), (size, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) + (255,))
    return image


def rounded_triangle_mask(size, points, radius):
    """A triangle with round corners: the triangle shrunk by `radius`, grown back with round edges."""
    (ax, ay), (bx, by), (cx, cy) = points
    a, b, c = math.dist((bx, by), (cx, cy)), math.dist((ax, ay), (cx, cy)), math.dist((ax, ay), (bx, by))
    perimeter = a + b + c
    ix, iy = (a * ax + b * bx + c * cx) / perimeter, (a * ay + b * by + c * cy) / perimeter   # incentre
    area = abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2
    inradius = 2 * area / perimeter
    k = (inradius - radius) / inradius
    inner = [(ix + (x - ix) * k, iy + (y - iy) * k) for x, y in points]
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon(inner, fill=255)
    for i in range(3):
        draw.line([inner[i], inner[(i + 1) % 3]], fill=255, width=round(2 * radius))
    for x, y in inner:
        draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=255)
    return mask


def make():
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    square = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(square).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=round(SIZE * 0.225), fill=255)
    icon.paste(gradient(SIZE), (0, 0), square)

    height = SIZE * 0.47
    width = height * 0.9
    cx, cy = SIZE * 0.535, SIZE * 0.5          # nudged right so the triangle looks centred
    points = [(cx - width / 2, cy - height / 2), (cx + width / 2, cy), (cx - width / 2, cy + height / 2)]
    play = rounded_triangle_mask(SIZE, points, SIZE * 0.045)
    icon.paste(Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255)), (0, 0), play)
    return icon


if __name__ == "__main__":
    big = make()
    assets = ROOT / "assets"
    assets.mkdir(exist_ok=True)
    big.resize((256, 256), Image.Resampling.LANCZOS).save(assets / "t-player.png")
    big.save(assets / "t-player.ico", sizes=[(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)])
    print("wrote", assets / "t-player.png", "and", assets / "t-player.ico")
