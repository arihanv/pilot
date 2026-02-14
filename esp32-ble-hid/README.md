# ESP32 BLE HID iPhone Controller

Control an iPhone remotely using an ESP32 as a Bluetooth keyboard + mouse.

## Requirements

- ESP32 dev board (original ESP32 with BT/BLE)
- [PlatformIO](https://platformio.org/) (`brew install platformio`)
- Python 3 with `pyserial` (`pip install pyserial`)

## iPhone Setup

1. **Pair**: Settings > Bluetooth > tap **"sotos"** under Other Devices
2. **Enable pointer**: Settings > Accessibility > Touch > AssistiveTouch > **ON**

## Flash the ESP32

```bash
cd esp32-ble-hid
pio run --target upload
```

## Usage

### Interactive mode

```bash
python controller.py
```

### Single command

```bash
python controller.py type "Hello world"
python controller.py home
python controller.py status
```

### Script mode

```bash
python controller.py --script actions.txt
```

Script file example (`actions.txt`):
```
# Lines starting with # are comments
wait
type Hello from ESP32
enter
sleep 1
home
```

### Options

```
--port PORT    Serial port (default: /dev/cu.usbserial-0001)
--baud BAUD    Baud rate (default: 115200)
```

## Commands

### Keyboard

| Command | Description |
|---|---|
| `type <text>` | Type a string |
| `key <char>` | Press and release a single key |
| `keydown <char>` | Hold a key |
| `keyup <char>` | Release a key |
| `enter` | Press Enter |
| `backspace [n]` | Backspace (n times in interactive mode) |
| `tab` | Press Tab |
| `esc` | Press Escape |
| `space` | Press Space |
| `up / down / left / right` | Arrow keys |

### Mouse / Pointer

| Command | Description |
|---|---|
| `move <x> <y>` | Move pointer by (x, y) pixels (relative, max 127 per axis) |
| `click` | Left click (tap) |
| `click_right` | Right click |
| `scroll <n>` | Scroll vertically (positive=up, negative=down) |
| `swipe <x1> <y1> <x2> <y2> <steps>` | Swipe gesture |
| `swipe_up / swipe_down / swipe_left / swipe_right [dist]` | Quick swipe (interactive mode) |
| `tap <x> <y>` | Move to position and tap (interactive/Python only) |

### iOS Shortcuts

| Command | Description |
|---|---|
| `home` | Go to home screen (Cmd+H) |
| `lock` | Lock screen (Cmd+L) |
| `appswitcher` | Open app switcher (Cmd+Tab) |
| `spotlight` | Open search (Cmd+Space) |
| `vol_up / vol_down` | Volume controls |

### Other

| Command | Description |
|---|---|
| `status` | Check BLE connection status |
| `wait` | Wait for iPhone to connect (interactive mode) |
| `sleep <seconds>` | Pause (interactive/script mode) |
| `raw <command>` | Send raw serial command |

## Python API

```python
from controller import PhoneController

ctrl = PhoneController()
ctrl.wait_for_connection()

ctrl.type_text("Hello")
ctrl.enter()
ctrl.move(50, 0)
ctrl.click()
ctrl.home()

ctrl.close()
```

## Troubleshooting

- **"sotos" not showing in Bluetooth**: Reset the ESP32 by pressing the EN button, or re-flash
- **Pointer not visible**: Make sure AssistiveTouch is ON
- **Stale pairing**: On iPhone, go to Bluetooth > "sotos" > Forget This Device, then re-pair
- **Serial port not found**: Check `ls /dev/cu.usb*` and pass `--port` if different
