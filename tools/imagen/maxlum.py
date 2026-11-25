# /// script
# dependencies = ["pillow"]
# ///
"""Maximum luminance (0-255) of one image: maxlum.py PNG. watch.sh calls a frame at most 10 black (mir2, 24/11/2026)."""
import sys

from PIL import Image

im = Image.open(sys.argv[1]).convert("L")
im.thumbnail((320, 180))
print(im.getextrema()[1])
