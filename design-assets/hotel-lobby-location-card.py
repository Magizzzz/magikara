from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT = Path(__file__).parent
W, H = 3840, 2160
FONT = Path('/Users/magi/Library/Fonts')
regular = FONT / 'AlibabaPuHuiTi-2-55-Regular.ttf'
semibold = FONT / 'AlibabaPuHuiTi-2-75-SemiBold.ttf'

def font(path, size):
    return ImageFont.truetype(str(path), size)

im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(im)

# Left aligned lower-third, kept inside the 10% title-safe area.
x, y = 390, 1570
draw.rounded_rectangle((x, y, x + 1550, y + 318), radius=18, fill=(9, 18, 26, 180))
draw.rectangle((x, y, x + 12, y + 318), fill=(205, 169, 111, 255))

label = '定位：'
title = '酒店大堂'
draw.text((x + 96, y + 57), label, font=font(regular, 67), fill=(218, 211, 199, 255), anchor='lt')
draw.rectangle((x + 327, y + 71, x + 330, y + 241), fill=(205, 169, 111, 185))

shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.text((x + 390, y + 63), title, font=font(semibold, 166), fill=(0, 0, 0, 175), anchor='lt', stroke_width=2)
shadow = shadow.filter(ImageFilter.GaussianBlur(12))
im = Image.alpha_composite(im, shadow)
draw = ImageDraw.Draw(im)
draw.text((x + 386, y + 58), title, font=font(semibold, 166), fill=(250, 248, 243, 255), anchor='lt')

png = OUT / 'hotel-lobby-location-3840x2160.png'
im.save(png)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2160" viewBox="0 0 3840 2160">
  <rect x="390" y="1570" width="1550" height="318" rx="18" fill="#09121a" fill-opacity=".71"/>
  <path d="M390 1570h12v318h-12z" fill="#cda96f"/>
  <text x="486" y="1692" font-family="Alibaba PuHuiTi 2.0, Alibaba PuHuiTi" font-size="67" font-weight="400" fill="#dad3c7">定位：</text>
  <path d="M717 1641h3v170h-3z" fill="#cda96f" fill-opacity=".73"/>
  <text x="776" y="1815" font-family="Alibaba PuHuiTi 2.0, Alibaba PuHuiTi" font-size="166" font-weight="600" fill="#faf8f3">酒店大堂</text>
</svg>'''
(OUT / 'hotel-lobby-location-editable.svg').write_text(svg, encoding='utf-8')

# A neutral dark preview shows the card's position without implying a scene asset.
preview = Image.new('RGB', (1920, 1080), '#343b3d')
p = ImageDraw.Draw(preview)
for yy in range(1080):
    t = yy / 1079
    p.line((0, yy, 1920, yy), fill=(int(61-25*t), int(66-28*t), int(65-27*t)))
preview = Image.alpha_composite(preview.convert('RGBA'), im.resize((1920, 1080), Image.Resampling.LANCZOS))
preview.convert('RGB').save(OUT / 'hotel-lobby-location-preview.jpg', quality=92)
print(png)
