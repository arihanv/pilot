#!/usr/bin/env python3
"""
ESP32 BLE HID Controller — control an iPhone from your computer.

Usage:
  Interactive mode:  python controller.py
  Single command:    python controller.py type "Hello world"
  Script mode:       python controller.py --script actions.txt
"""

import serial
import time
import sys
import argparse
import readline  # enables arrow keys / history in interactive mode


class PhoneController:
    def __init__(self, port="/dev/cu.usbserial-0001", baud=115200, timeout=1):
        self.ser = serial.Serial(port, baud, timeout=timeout)
        time.sleep(2)  # wait for ESP32 to reset after serial connect
        self._flush()

    def _flush(self):
        while self.ser.in_waiting:
            self.ser.readline()

    def _send(self, cmd: str) -> str:
        self.ser.write((cmd + "\n").encode())
        time.sleep(0.05)
        lines = []
        deadline = time.time() + 0.5
        while time.time() < deadline:
            if self.ser.in_waiting:
                line = self.ser.readline().decode(errors="ignore").strip()
                if line:
                    lines.append(line)
                    deadline = time.time() + 0.1  # extend for follow-up lines
            else:
                time.sleep(0.01)
        return "\n".join(lines)

    def close(self):
        self.ser.close()

    # --- Status ---
    def status(self) -> str:
        return self._send("STATUS")

    def wait_for_connection(self, timeout=60):
        print("Waiting for iPhone to connect via Bluetooth...")
        start = time.time()
        while time.time() - start < timeout:
            resp = self.status()
            if "CONNECTED" in resp and "DISCONNECTED" not in resp:
                print("Connected!")
                return True
            time.sleep(2)
        print("Timed out waiting for connection.")
        return False

    # --- Keyboard ---
    def type_text(self, text: str) -> str:
        return self._send(f"TYPE {text}")

    def key(self, char: str) -> str:
        return self._send(f"KEY {char}")

    def key_down(self, char: str) -> str:
        return self._send(f"KEYDOWN {char}")

    def key_up(self, char: str) -> str:
        return self._send(f"KEYUP {char}")

    def enter(self) -> str:
        return self._send("ENTER")

    def backspace(self, count=1) -> str:
        resp = ""
        for _ in range(count):
            resp = self._send("BACKSPACE")
            time.sleep(0.05)
        return resp

    def tab(self) -> str:
        return self._send("TAB")

    def escape(self) -> str:
        return self._send("ESC")

    def arrow(self, direction: str) -> str:
        return self._send(direction.upper())

    # --- Mouse ---
    def move(self, x: int, y: int) -> str:
        return self._send(f"MOVE {x} {y}")

    def move_to(self, x: int, y: int, steps=20):
        """Move to approximate screen position from center. Resets pointer first."""
        # Move far off to a corner to 'reset', then move to target
        self.move(-127, -127)
        time.sleep(0.05)
        self.move(-127, -127)
        time.sleep(0.05)
        self.move(-127, -127)
        time.sleep(0.1)
        # Now at top-left, move to target
        remaining_x, remaining_y = x, y
        while remaining_x != 0 or remaining_y != 0:
            dx = max(-127, min(127, remaining_x))
            dy = max(-127, min(127, remaining_y))
            self.move(dx, dy)
            remaining_x -= dx
            remaining_y -= dy
            time.sleep(0.01)

    def click(self) -> str:
        return self._send("CLICK")

    def click_right(self) -> str:
        return self._send("CLICK_RIGHT")

    def tap(self, x: int, y: int):
        """Move to position and click (tap)."""
        self.move_to(x, y)
        time.sleep(0.05)
        return self.click()

    def scroll(self, amount: int) -> str:
        return self._send(f"SCROLL {amount}")

    def swipe(self, x1: int, y1: int, x2: int, y2: int, steps=10) -> str:
        return self._send(f"SWIPE {x1} {y1} {x2} {y2} {steps}")

    def swipe_up(self, distance=100) -> str:
        return self.swipe(0, 0, 0, -distance, 10)

    def swipe_down(self, distance=100) -> str:
        return self.swipe(0, 0, 0, distance, 10)

    def swipe_left(self, distance=100) -> str:
        return self.swipe(0, 0, -distance, 0, 10)

    def swipe_right(self, distance=100) -> str:
        return self.swipe(0, 0, distance, 0, 10)

    # --- Media / System ---
    def volume_up(self) -> str:
        return self._send("VOL_UP")

    def volume_down(self) -> str:
        return self._send("VOL_DOWN")

    def home(self) -> str:
        return self._send("HOME")


def interactive_mode(ctrl):
    print("\n--- ESP32 iPhone Controller (Interactive) ---")
    print("Commands:")
    print("  type <text>         Type text on the phone")
    print("  enter / tab / esc   Press key")
    print("  backspace [n]       Backspace (n times)")
    print("  up/down/left/right  Arrow keys")
    print("  move <x> <y>        Move pointer (relative)")
    print("  click               Tap / click")
    print("  tap <x> <y>         Move to position and tap")
    print("  scroll <n>          Scroll (negative=down)")
    print("  swipe_up/down/left/right [dist]")
    print("  vol_up / vol_down   Volume")
    print("  home                Home button")
    print("  status              Connection status")
    print("  wait                Wait for BLE connection")
    print("  sleep <seconds>     Pause")
    print("  raw <command>       Send raw serial command")
    print("  quit / exit         Exit")
    print("----------------------------------------------\n")

    while True:
        try:
            line = input(">>> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue

        parts = line.split(maxsplit=1)
        cmd = parts[0].lower()
        arg = parts[1] if len(parts) > 1 else ""

        try:
            if cmd in ("quit", "exit", "q"):
                break
            elif cmd == "type":
                print(ctrl.type_text(arg))
            elif cmd == "enter":
                print(ctrl.enter())
            elif cmd == "tab":
                print(ctrl.tab())
            elif cmd in ("esc", "escape"):
                print(ctrl.escape())
            elif cmd == "backspace":
                n = int(arg) if arg else 1
                print(ctrl.backspace(n))
            elif cmd in ("up", "down", "left", "right"):
                print(ctrl.arrow(cmd))
            elif cmd == "move":
                x, y = arg.split()
                print(ctrl.move(int(x), int(y)))
            elif cmd == "click":
                print(ctrl.click())
            elif cmd == "tap":
                x, y = arg.split()
                print(ctrl.tap(int(x), int(y)))
            elif cmd == "scroll":
                print(ctrl.scroll(int(arg)))
            elif cmd == "swipe_up":
                d = int(arg) if arg else 100
                print(ctrl.swipe_up(d))
            elif cmd == "swipe_down":
                d = int(arg) if arg else 100
                print(ctrl.swipe_down(d))
            elif cmd == "swipe_left":
                d = int(arg) if arg else 100
                print(ctrl.swipe_left(d))
            elif cmd == "swipe_right":
                d = int(arg) if arg else 100
                print(ctrl.swipe_right(d))
            elif cmd == "vol_up":
                print(ctrl.volume_up())
            elif cmd == "vol_down":
                print(ctrl.volume_down())
            elif cmd == "home":
                print(ctrl.home())
            elif cmd == "status":
                print(ctrl.status())
            elif cmd == "wait":
                ctrl.wait_for_connection()
            elif cmd == "sleep":
                time.sleep(float(arg))
            elif cmd == "raw":
                print(ctrl._send(arg))
            else:
                print(f"Unknown command: {cmd}")
        except Exception as e:
            print(f"Error: {e}")


def run_script(ctrl, script_path):
    with open(script_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            print(f">> {line}")
            parts = line.split(maxsplit=1)
            cmd = parts[0].lower()
            arg = parts[1] if len(parts) > 1 else ""

            if cmd == "type":
                print(ctrl.type_text(arg))
            elif cmd == "enter":
                print(ctrl.enter())
            elif cmd == "backspace":
                n = int(arg) if arg else 1
                print(ctrl.backspace(n))
            elif cmd in ("up", "down", "left", "right"):
                print(ctrl.arrow(cmd))
            elif cmd == "move":
                x, y = arg.split()
                print(ctrl.move(int(x), int(y)))
            elif cmd == "click":
                print(ctrl.click())
            elif cmd == "tap":
                x, y = arg.split()
                print(ctrl.tap(int(x), int(y)))
            elif cmd == "scroll":
                print(ctrl.scroll(int(arg)))
            elif cmd.startswith("swipe_"):
                d = int(arg) if arg else 100
                getattr(ctrl, cmd)(d)
            elif cmd == "sleep":
                time.sleep(float(arg))
            elif cmd == "wait":
                ctrl.wait_for_connection()
            elif cmd == "home":
                print(ctrl.home())
            elif cmd == "raw":
                print(ctrl._send(arg))
            else:
                print(ctrl._send(line))


def run_single(ctrl, args):
    cmd = args[0].lower()
    rest = " ".join(args[1:])

    if cmd == "type":
        print(ctrl.type_text(rest))
    elif cmd == "status":
        print(ctrl.status())
    elif cmd == "enter":
        print(ctrl.enter())
    elif cmd == "click":
        print(ctrl.click())
    elif cmd == "move":
        x, y = args[1], args[2]
        print(ctrl.move(int(x), int(y)))
    elif cmd == "tap":
        x, y = args[1], args[2]
        print(ctrl.tap(int(x), int(y)))
    elif cmd == "home":
        print(ctrl.home())
    else:
        print(ctrl._send(" ".join(args)))


def main():
    parser = argparse.ArgumentParser(description="Control iPhone via ESP32 BLE HID")
    parser.add_argument("--port", default="/dev/cu.usbserial-0001", help="Serial port")
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate")
    parser.add_argument("--script", help="Run commands from a script file")
    parser.add_argument("command", nargs="*", help="Single command to run")
    args = parser.parse_args()

    ctrl = PhoneController(port=args.port, baud=args.baud)
    try:
        if args.script:
            run_script(ctrl, args.script)
        elif args.command:
            run_single(ctrl, args.command)
        else:
            interactive_mode(ctrl)
    finally:
        ctrl.close()


if __name__ == "__main__":
    main()
