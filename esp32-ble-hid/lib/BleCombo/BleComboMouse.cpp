#include <Arduino.h>
#include "BleComboMouse.h"

void BleComboMouse::click(uint8_t b)
{
  _buttons = b;
  move(0,0,0,0);
  _buttons = 0;
  move(0,0,0,0);
}

void BleComboMouse::move(signed char x, signed char y, signed char wheel, signed char hWheel)
{
  if (_keyboard->isConnected())
  {
    uint8_t m[5];
    m[0] = _buttons;
    m[1] = x;
    m[2] = y;
    m[3] = wheel;
    m[4] = hWheel;
    _keyboard->inputMouse->setValue(m, 5);
    _keyboard->inputMouse->notify();
  }
}

void BleComboMouse::buttons(uint8_t b)
{
  if (b != _buttons)
  {
    _buttons = b;
    move(0,0,0,0);
  }
}

void BleComboMouse::press(uint8_t b)
{
  buttons(_buttons | b);
}

void BleComboMouse::release(uint8_t b)
{
  buttons(_buttons & ~b);
}

bool BleComboMouse::isPressed(uint8_t b)
{
  if ((b & _buttons) > 0)
    return true;
  return false;
}

// --- Absolute positioning via digitizer HID ---
// Report format (5 bytes): [flags] [X_lo] [X_hi] [Y_lo] [Y_hi]
// flags: bit0 = Tip Switch (touch), bit1 = In Range

void BleComboMouse::moveAbsolute(uint16_t x, uint16_t y)
{
  if (_keyboard->isConnected())
  {
    uint8_t m[5];
    m[0] = 0x02;           // In Range = 1, Tip Switch = 0 (hovering, no click)
    m[1] = x & 0xFF;
    m[2] = (x >> 8) & 0xFF;
    m[3] = y & 0xFF;
    m[4] = (y >> 8) & 0xFF;
    _keyboard->inputDigitizer->setValue(m, 5);
    _keyboard->inputDigitizer->notify();
  }
}

void BleComboMouse::clickAbsolute(uint16_t x, uint16_t y)
{
  if (_keyboard->isConnected())
  {
    uint8_t m[5];
    m[1] = x & 0xFF;
    m[2] = (x >> 8) & 0xFF;
    m[3] = y & 0xFF;
    m[4] = (y >> 8) & 0xFF;

    // 1) In range, move to position (no touch)
    m[0] = 0x02;  // InRange=1, TipSwitch=0
    _keyboard->inputDigitizer->setValue(m, 5);
    _keyboard->inputDigitizer->notify();
    delay(20);

    // 2) Touch down
    m[0] = 0x03;  // InRange=1, TipSwitch=1
    _keyboard->inputDigitizer->setValue(m, 5);
    _keyboard->inputDigitizer->notify();
    delay(50);

    // 3) Touch up (lift finger)
    m[0] = 0x02;  // InRange=1, TipSwitch=0
    _keyboard->inputDigitizer->setValue(m, 5);
    _keyboard->inputDigitizer->notify();
    delay(10);

    // 4) Out of range (finger removed entirely)
    m[0] = 0x00;  // InRange=0, TipSwitch=0
    _keyboard->inputDigitizer->setValue(m, 5);
    _keyboard->inputDigitizer->notify();
  }
}
