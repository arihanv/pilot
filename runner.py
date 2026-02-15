import os
import json
import re
import base64
from io import BytesIO
import requests
import openai
from dotenv import load_dotenv
from PIL import Image, ImageDraw, ImageFont

load_dotenv()

OPENROUTER_API_KEY = os.environ["OPENROUTER_API_KEY"]
client = openai.OpenAI(
    base_url="https://openrouter.ai/api/v1",
    api_key=OPENROUTER_API_KEY,
)
MODEL = "qwen/qwen3-32b:nitro"

# --- Step 1: Detect app icons with Moondream ---
with open("screenshot.png", "rb") as f:
    image_b64 = base64.b64encode(f.read()).decode()

image_url = f"data:image/png;base64,{image_b64}"

result = requests.post(
    "https://api.moondream.ai/v1/detect",
    headers={
        "Content-Type": "application/json",
        "X-Moondream-Auth": os.environ["MOONDREAM_API_KEY"],
    },
    json={
        "image_url": image_url,
        "object": "app icon",
    },
).json()

objects = result["objects"]
print(f"Detected {len(objects)} app icons")

# --- Step 2: Draw numbered bounding boxes ---
img = Image.open("screenshot.png")
draw = ImageDraw.Draw(img)
w, h = img.size

color = "#9933FF"

try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 36)
except OSError:
    font = ImageFont.load_default()

for i, obj in enumerate(objects):
    x1 = int(obj["x_min"] * w)
    y1 = int(obj["y_min"] * h)
    x2 = int(obj["x_max"] * w)
    y2 = int(obj["y_max"] * h)
    draw.rectangle([x1, y1, x2, y2], outline=color, width=5)

    label = str(i + 1)
    bbox = font.getbbox(label)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    pad = 6
    lx = x1
    ly = y1
    draw.rectangle([lx, ly, lx + tw + pad * 2, ly + th + pad * 2], fill=color)
    draw.text((lx + pad, ly + pad), label, fill="white", font=font)

img.save("screenshot_marked.png")
print(f"Saved screenshot_marked.png with {len(objects)} bounding boxes")

# --- Step 3: Send marked image to LLM, ask which app to click ---
buf = BytesIO()
img.save(buf, format="PNG")
marked_b64 = base64.b64encode(buf.getvalue()).decode()

valid_numbers = list(range(1, len(objects) + 1))

prompt = (
    "You are looking at a phone screen with app icons highlighted by numbered purple bounding boxes.\n"
    f"Valid box numbers are: {valid_numbers}\n"
    "Which numbered app would you like to click on? Pick the most interesting or useful one.\n"
    'Respond with ONLY valid JSON: {"box_number": <number>, "reason": "<why you chose this app>"}'
)

messages = [
    {
        "role": "user",
        "content": [
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{marked_b64}"}},
            {"type": "text", "text": prompt},
        ],
    }
]

MAX_RETRIES = 3
chosen = None

for attempt in range(MAX_RETRIES):
    response = client.chat.completions.create(
        model=MODEL,
        temperature=0,
        max_tokens=100,
        messages=messages,
    )

    raw = response.choices[0].message.content.strip()
    print(f"Attempt {attempt + 1}: {raw}")

    # Parse JSON from response
    try:
        match = re.search(r"\{[\s\S]*\}", raw)
        if not match:
            raise ValueError("No JSON found")
        parsed = json.loads(match.group())
        box_num = int(parsed["box_number"])
    except (ValueError, KeyError, json.JSONDecodeError) as e:
        messages.append({"role": "assistant", "content": raw})
        messages.append({"role": "user", "content": f"Invalid response: {e}. Respond with valid JSON: {{\"box_number\": <number>, \"reason\": \"<why>\"}}"})
        continue

    # Validate box number exists
    if box_num not in valid_numbers:
        messages.append({"role": "assistant", "content": raw})
        messages.append({"role": "user", "content": f"Box number {box_num} does not exist. Valid numbers are: {valid_numbers}. Try again with valid JSON."})
        continue

    chosen = box_num
    reason = parsed.get("reason", "")
    print(f"LLM chose app #{chosen} — {reason}")
    break

if chosen is None:
    print("LLM failed to pick a valid box after retries")
    exit(1)

# --- Step 4: Compute click center and draw red dot ---
obj = objects[chosen - 1]
cx = int((obj["x_min"] + obj["x_max"]) / 2 * w)
cy = int((obj["y_min"] + obj["y_max"]) / 2 * h)
print(f"CLICK ({cx}, {cy})")

# Draw red dot on a clean copy of the original image
click_img = Image.open("screenshot.png")
click_draw = ImageDraw.Draw(click_img)
r = 16
click_draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill="red", outline="red")
click_img.save("screenshot_click.png")
print(f"Saved screenshot_click.png with click at ({cx}, {cy})")
