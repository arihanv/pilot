#!/usr/bin/env python3
"""Interactive controller for ESP32 BLE Mouse + Keyboard + Media.

Mouse (x,y are percentages 0-100):
  click x y          move to (x,y) and click
  move x y           move cursor to (x,y)
  press x y          press and hold at (x,y)
  release            release button

Keyboard:
  type hello         type a string
  key enter          named key (enter, space, tab, esc, backspace, delete,
                     up, down, left, right, home, end, pageup, pagedown,
                     capslock, insert, f1-f24)
  key cmd+space      with modifiers (ctrl, shift, alt, gui/cmd, chainable)

Media:
  play / pause       play/pause toggle
  next / prev        next/previous track
  stop               stop playback
  volup [n]          volume up (optional repeat count)
  voldown [n]        volume down
  mute               mute toggle
  brightup           brightness up
  brightdown         brightness down
  lock               lock screen
  eject / power / sleep

iOS shortcuts:
  spotlight          open Spotlight search
  home               go to home screen
  appswitcher        open app switcher
  screenshot         take screenshot
  undo / redo        undo/redo
  copy / paste / cut clipboard
  selectall          select all
  find               find in page/app
  newtab / closetab  browser tabs
  refresh            refresh page
  dock               toggle dock (iPadOS)
  keyboard           dismiss keyboard

Other:
  demo               run mouse demo
  status             check BLE connection
  help               show commands on ESP
  quit               exit
"""

import serial
import sys
import threading
import time

PORT = "/dev/cu.usbmodem2101"
BAUD = 115200

def reader(ser, stop_event):
    while not stop_event.is_set():
        try:
            line = ser.readline()
            if line:
                text = line.decode("utf-8", errors="replace").rstrip()
                if text:
                    print(f"  <- {text}")
        except Exception:
            break

def main():
    port = sys.argv[1] if len(sys.argv) > 1 else PORT
    print(f"Connecting to {port}...")
    ser = serial.Serial(port, BAUD, timeout=0.5)
    time.sleep(0.5)
    while ser.in_waiting:
        ser.readline()

    stop = threading.Event()
    t = threading.Thread(target=reader, args=(ser, stop), daemon=True)
    t.start()

    print(__doc__)
    try:
        while True:
            try:
                cmd = input("> ").strip()
            except EOFError:
                break
            if not cmd:
                continue
            if cmd in ("quit", "exit", "q"):
                break
            ser.write((cmd + "\n").encode())
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        ser.close()
        print("\nDone.")

if __name__ == "__main__":
    main()
