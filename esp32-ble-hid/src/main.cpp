#include <Arduino.h>
#include <BleCombo.h>

String inputBuffer = "";

void handleCommand(String cmd) {
  cmd.trim();
  if (cmd.length() == 0) return;

  // Strip any non-printable characters from the start
  while (cmd.length() > 0 && (cmd.charAt(0) < 32 || cmd.charAt(0) > 126)) {
    cmd = cmd.substring(1);
  }
  cmd.trim();
  if (cmd.length() == 0) return;

  // Convert command part to uppercase for case-insensitive matching
  String cmdUpper = cmd;
  cmdUpper.toUpperCase();

  Serial.print("CMD: ");
  Serial.println(cmdUpper);

  if (cmdUpper == "STATUS") {
    Serial.print("Connected: ");
    Serial.println(Keyboard.isConnected() ? "YES" : "NO");
    return;
  }

  if (!Keyboard.isConnected()) {
    Serial.println("ERR: not connected");
    return;
  }

  // --- Keyboard commands ---
  if (cmdUpper.startsWith("TYPE ")) {
    Keyboard.print(cmd.substring(5));  // preserve original case for typed text
    Serial.println("OK: typed");
  }
  else if (cmdUpper.startsWith("KEY ")) {
    Keyboard.write(cmd.charAt(4));
    Serial.println("OK: key");
  }
  else if (cmdUpper.startsWith("KEYDOWN ")) {
    Keyboard.press(cmd.charAt(8));
    Serial.println("OK: key down");
  }
  else if (cmdUpper.startsWith("KEYUP ")) {
    Keyboard.release(cmd.charAt(6));
    Serial.println("OK: key up");
  }
  else if (cmdUpper == "RELEASEALL") {
    Keyboard.releaseAll();
    Serial.println("OK: released all");
  }
  else if (cmdUpper == "ENTER") {
    Keyboard.write(KEY_RETURN);
    Serial.println("OK: enter");
  }
  else if (cmdUpper == "BACKSPACE") {
    Keyboard.write(KEY_BACKSPACE);
    Serial.println("OK: backspace");
  }
  else if (cmdUpper == "TAB") {
    Keyboard.write(KEY_TAB);
    Serial.println("OK: tab");
  }
  else if (cmdUpper == "ESC") {
    Keyboard.write(KEY_ESC);
    Serial.println("OK: esc");
  }
  else if (cmdUpper == "SPACE") {
    Keyboard.write(' ');
    Serial.println("OK: space");
  }
  else if (cmdUpper == "UP") {
    Keyboard.write(KEY_UP_ARROW);
    Serial.println("OK: up");
  }
  else if (cmdUpper == "DOWN") {
    Keyboard.write(KEY_DOWN_ARROW);
    Serial.println("OK: down");
  }
  else if (cmdUpper == "LEFT") {
    Keyboard.write(KEY_LEFT_ARROW);
    Serial.println("OK: left");
  }
  else if (cmdUpper == "RIGHT") {
    Keyboard.write(KEY_RIGHT_ARROW);
    Serial.println("OK: right");
  }
  // --- Mouse commands ---
  else if (cmdUpper.startsWith("MOVE ")) {
    int spaceIdx = cmdUpper.indexOf(' ', 5);
    if (spaceIdx > 0) {
      int x = cmdUpper.substring(5, spaceIdx).toInt();
      int y = cmdUpper.substring(spaceIdx + 1).toInt();
      Mouse.move(x, y);
      Serial.println("OK: moved");
    }
  }
  else if (cmdUpper == "CLICK") {
    Mouse.click(MOUSE_LEFT);
    Serial.println("OK: click");
  }
  else if (cmdUpper == "CLICK_RIGHT") {
    Mouse.click(MOUSE_RIGHT);
    Serial.println("OK: right click");
  }
  else if (cmdUpper.startsWith("SCROLL ")) {
    int amount = cmdUpper.substring(7).toInt();
    Mouse.move(0, 0, amount);
    Serial.println("OK: scroll");
  }
  else if (cmdUpper.startsWith("SWIPE ")) {
    int params[5];
    int idx = 6;
    for (int i = 0; i < 5; i++) {
      int nextSpace = cmdUpper.indexOf(' ', idx);
      if (nextSpace < 0) nextSpace = cmdUpper.length();
      params[i] = cmdUpper.substring(idx, nextSpace).toInt();
      idx = nextSpace + 1;
    }
    int x1 = params[0], y1 = params[1];
    int x2 = params[2], y2 = params[3];
    int steps = params[4];
    if (steps <= 0) steps = 10;

    Mouse.move(x1, y1);
    delay(50);
    Mouse.press(MOUSE_LEFT);
    delay(50);
    int dx = (x2 - x1) / steps;
    int dy = (y2 - y1) / steps;
    for (int i = 0; i < steps; i++) {
      Mouse.move(dx, dy);
      delay(15);
    }
    Mouse.release(MOUSE_LEFT);
    Serial.println("OK: swipe");
  }
  // --- Media / System ---
  else if (cmdUpper == "VOL_UP") {
    Keyboard.write(KEY_MEDIA_VOLUME_UP);
    Serial.println("OK: vol up");
  }
  else if (cmdUpper == "VOL_DOWN") {
    Keyboard.write(KEY_MEDIA_VOLUME_DOWN);
    Serial.println("OK: vol down");
  }
  else if (cmdUpper == "HOME") {
    Keyboard.press(KEY_LEFT_GUI);
    Keyboard.press('h');
    delay(50);
    Keyboard.releaseAll();
    Serial.println("OK: home");
  }
  else if (cmdUpper == "LOCK") {
    Keyboard.press(KEY_LEFT_GUI);
    Keyboard.press('l');
    delay(50);
    Keyboard.releaseAll();
    Serial.println("OK: lock");
  }
  else if (cmdUpper == "APPSWITCHER") {
    Keyboard.press(KEY_LEFT_GUI);
    Keyboard.press(KEY_TAB);
    delay(50);
    Keyboard.releaseAll();
    Serial.println("OK: app switcher");
  }
  else if (cmdUpper == "SPOTLIGHT") {
    Keyboard.press(KEY_LEFT_GUI);
    Keyboard.press(' ');
    delay(50);
    Keyboard.releaseAll();
    Serial.println("OK: spotlight");
  }
  else {
    Serial.print("ERR: unknown: ");
    Serial.println(cmdUpper);
  }
}

void setup() {
  Serial.begin(115200);
  Serial.println("ESP32 BLE HID starting...");
  Keyboard.deviceName = "sotos";
  Keyboard.begin();
  Serial.println("Ready! BLE advertising as 'sotos'");
  Serial.println("On iPhone: Settings > Bluetooth > tap 'sotos'");
  Serial.println("Then: Settings > Accessibility > Touch > AssistiveTouch > ON");
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (inputBuffer.length() > 0) {
        handleCommand(inputBuffer);
        inputBuffer = "";
      }
    } else {
      inputBuffer += c;
    }
  }

  static unsigned long lastCheck = 0;
  if (millis() - lastCheck > 10000) {
    lastCheck = millis();
    if (!Keyboard.isConnected()) {
      Serial.println("Waiting for BLE connection...");
    }
  }
}
