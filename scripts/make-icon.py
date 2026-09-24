"""画出定位台图标：纸色底、铜色测绘十字。"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
PAPER = (230, 223, 208, 255)
INK = (42, 36, 28, 255)
COPPER = (176, 88, 37, 255)
GRID = (188, 178, 160, 255)


def main() -> None:
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shape = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(shape)
    radius = 228
    draw.rounded_rectangle((8, 8, SIZE - 9, SIZE - 9), radius=radius, fill=PAPER)

    for y in (300, 430, 720, 820):
        draw.line((150, y, 874, y), fill=GRID, width=6)
    shore = [(110, 900), (250, 860), (420, 890), (580, 850), (760, 880), (940, 845)]
    draw.line(shore, fill=(42, 36, 28, 80), width=12, joint="curve")

    center = SIZE // 2
    arm = 300
    stroke = 36
    ring = 250
    draw.line((center, center - arm, center, center + arm), fill=COPPER, width=stroke)
    draw.line((center - arm, center, center + arm, center), fill=COPPER, width=stroke)
    draw.ellipse(
        (center - ring, center - ring, center + ring, center + ring),
        outline=COPPER,
        width=stroke,
    )
    # 中心留一个纸色小孔，小尺寸上仍能看出是准星而不是实心块。
    hole = 22
    draw.ellipse((center - hole, center - hole, center + hole, center + hole), fill=PAPER)

    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((8, 8, SIZE - 9, SIZE - 9), radius=radius, fill=255)
    icon.paste(shape, (0, 0), mask)

    root = Path(__file__).resolve().parents[1]
    out = root / "Resources"
    out.mkdir(exist_ok=True)
    icon.save(out / "Locus-icon.png")
    print(out / "Locus-icon.png")


if __name__ == "__main__":
    main()
