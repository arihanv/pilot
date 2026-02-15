#ifndef ESP32_BLE_COMBO_MOUSE_H
#define ESP32_BLE_COMBO_MOUSE_H
#include "BleComboKeyboard.h"

#define MOUSE_LEFT 1
#define MOUSE_RIGHT 2
#define MOUSE_MIDDLE 4
#define MOUSE_BACK 8
#define MOUSE_FORWARD 16
#define MOUSE_ALL (MOUSE_LEFT | MOUSE_RIGHT | MOUSE_MIDDLE) # For compatibility with the Mouse library

class BleComboMouse {
private:
  BleComboKeyboard* _keyboard;
  uint8_t _buttons;
  void buttons(uint8_t b);
public:
  BleComboMouse(BleComboKeyboard* keyboard) { _keyboard = keyboard; };
  void begin(void) {};
  void end(void) {};
  void click(uint8_t b = MOUSE_LEFT);
  void move(signed char x, signed char y, signed char wheel = 0, signed char hWheel = 0);
  void press(uint8_t b = MOUSE_LEFT);
  void release(uint8_t b = MOUSE_LEFT);
  bool isPressed(uint8_t b = MOUSE_LEFT);

  // Absolute positioning via digitizer HID report.
  // x, y are in 0-32767 range (maps to full screen).
  void moveAbsolute(uint16_t x, uint16_t y);
  void clickAbsolute(uint16_t x, uint16_t y);
};

#endif // ESP32_BLE_COMBO_MOUSE_H
