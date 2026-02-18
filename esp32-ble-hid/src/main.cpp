#include <Arduino.h>
#include <math.h>
#include <BleCombo.h>
String inputBuffer = "";
unsigned long lastBleCommandCheck = 0;
const int LOGICAL_SCREEN_WIDTH = 402;
const int LOGICAL_SCREEN_HEIGHT = 874;

static const int HOME_PULSES = 40;
static const int CORNER_ESCAPE_PX = 50;    // move right this many px to clear the rounded corner
static const int HOME_UP_ONLY_PULSES = 20; // then slam up to hit true top edge

// Forward declaration
String executeCommand(String cmd);

bool parsePercentToken(String token, float& outPercent) {
  token.trim();
  if (!token.endsWith("%")) return false;
  String numeric = token.substring(0, token.length() - 1);
  numeric.trim();
  if (numeric.length() == 0) return false;

  outPercent = numeric.toFloat();
  if (outPercent < 0.0f || outPercent > 100.0f) return false;
  return true;
}

static void homeTopLeft() {
  // 1) Slam into the corner area
  for (int i = 0; i < HOME_PULSES; i++) {
    Mouse.move(-127, -127);
    delay(5);
  }
  // 2) Move right to escape the rounded corner curve
  int escape = CORNER_ESCAPE_PX;
  while (escape > 0) {
    int dx = min(escape, 127);
    Mouse.move(dx, 0);
    escape -= dx;
    delay(4);
  }
  // 3) Slam up only to hit the true top edge
  for (int i = 0; i < HOME_UP_ONLY_PULSES; i++) {
    Mouse.move(0, -127);
    delay(5);
  }
}

void moveCursorToAbsolute(int targetX, int targetY) {
  targetX = constrain(targetX, 0, LOGICAL_SCREEN_WIDTH);
  targetY = constrain(targetY, 0, LOGICAL_SCREEN_HEIGHT);
  homeTopLeft();
  // Anchor after homing is at (CORNER_ESCAPE_PX, 0)
  int moveX = targetX - CORNER_ESCAPE_PX;
  if (moveX < 0) moveX = 0;

  while (moveX > 0) {
    int dx = min(moveX, 127);
    Mouse.move(dx, 0);
    moveX -= dx;
    delay(4);
  }
  while (targetY > 0) {
    int dy = min(targetY, 127);
    Mouse.move(0, dy);
    targetY -= dy;
    delay(4);
  }
}

void clickAtPixel(int xPx, int yPx) {
  moveCursorToAbsolute(xPx, yPx);
  delay(25);
  Mouse.press(MOUSE_LEFT);
  delay(30);
  Mouse.release(MOUSE_LEFT);
  delay(30);
}

void performLeftClick() {
  delay(25);
  Mouse.press(MOUSE_LEFT);
  delay(30);
  Mouse.release(MOUSE_LEFT);
  delay(30);
}

// --- Execute a command and return response string ---
String executeCommand(String cmd) {
  cmd.trim();
  if (cmd.length() == 0) return "ERR: empty";

  // Strip non-printable characters
  while (cmd.length() > 0 && (cmd.charAt(0) < 32 || cmd.charAt(0) > 126)) {
    cmd = cmd.substring(1);
  }
  cmd.trim();
  if (cmd.length() == 0) return "ERR: empty";

  String cmdUpper = cmd;
  cmdUpper.toUpperCase();

  Serial.print("CMD: ");
  Serial.println(cmdUpper);

  if (cmdUpper == "STATUS") {
    String s = "BLE: ";
    s += Keyboard.isConnected() ? "YES" : "NO";
    s += ", Command BLE: READY";
    return s;
  }

  if (!Keyboard.isConnected()) {
    return "ERR: BLE not connected";
  }

  // --- Keyboard ---
  if (cmdUpper.startsWith("TYPE ")) {
    String text = cmd.substring(5);
    for (unsigned int i = 0; i < text.length(); i++) {
      char ch = text.charAt(i);
      Keyboard.press(ch);
      delay(35);
      Keyboard.release(ch);
      // Give iOS lockscreen time to consume each HID report.
      delay(140);
    }
    // Extra settle time so the final character is not raced by ENTER.
    delay(180);
    return "OK: typed";
  }
  else if (cmdUpper.startsWith("KEY ")) {
    Keyboard.write(cmd.charAt(4));
    return "OK: key";
  }
  else if (cmdUpper.startsWith("KEYDOWN ")) {
    Keyboard.press(cmd.charAt(8));
    return "OK: key down";
  }
  else if (cmdUpper.startsWith("KEYUP ")) {
    Keyboard.release(cmd.charAt(6));
    return "OK: key up";
  }
  else if (cmdUpper == "RELEASEALL") {
    Keyboard.releaseAll();
    return "OK: released all";
  }
  else if (cmdUpper == "ENTER") {
    Keyboard.press(KEY_RETURN);
    delay(35);
    Keyboard.release(KEY_RETURN);
    delay(120);
    return "OK: enter";
  }
  else if (cmdUpper == "BACKSPACE") {
    Keyboard.write(KEY_BACKSPACE);
    return "OK: backspace";
  }
  else if (cmdUpper == "TAB") {
    Keyboard.write(KEY_TAB);
    return "OK: tab";
  }
  else if (cmdUpper == "ESC") {
    Keyboard.write(KEY_ESC);
    return "OK: esc";
  }
  else if (cmdUpper == "SPACE") {
    Keyboard.write(' ');
    return "OK: space";
  }
  else if (cmdUpper == "UP") {
    Keyboard.write(KEY_UP_ARROW);
    return "OK: up";
  }
  else if (cmdUpper == "DOWN") {
    Keyboard.write(KEY_DOWN_ARROW);
    return "OK: down";
  }
  else if (cmdUpper == "LEFT") {
    Keyboard.write(KEY_LEFT_ARROW);
    return "OK: left";
  }
  else if (cmdUpper == "RIGHT") {
    Keyboard.write(KEY_RIGHT_ARROW);
    return "OK: right";
  }
  // --- Mouse ---
  else if (cmdUpper.startsWith("MOVE ")) {
    int spaceIdx = cmdUpper.indexOf(' ', 5);
    if (spaceIdx > 0) {
      int x = cmdUpper.substring(5, spaceIdx).toInt();
      int y = cmdUpper.substring(spaceIdx + 1).toInt();
      Mouse.move(x, y);
      return "OK: moved";
    }
    return "ERR: bad MOVE args";
  }
  else if (cmdUpper == "CLICK") {
    performLeftClick();
    return "OK: click";
  }
  // --- Absolute move/tap by percentage (e.g. MOVE_ABS 50% 50%) ---
  else if (cmdUpper.startsWith("MOVE_ABS ")) {
    int spaceIdx = cmdUpper.indexOf(' ', 9);
    if (spaceIdx > 0) {
      String xToken = cmdUpper.substring(9, spaceIdx);
      String yToken = cmdUpper.substring(spaceIdx + 1);
      float xPercent = 0.0f;
      float yPercent = 0.0f;
      if (!parsePercentToken(xToken, xPercent) || !parsePercentToken(yToken, yPercent)) {
        return "ERR: bad MOVE_ABS args (need MOVE_ABS x% y%, 0-100%)";
      }

      int targetX = (int)((xPercent * LOGICAL_SCREEN_WIDTH / 100.0f) + 0.5f);
      int targetY = (int)((yPercent * LOGICAL_SCREEN_HEIGHT / 100.0f) + 0.5f);
      moveCursorToAbsolute(targetX, targetY);

      String resp = "Moved to ";
      resp += xToken;
      resp += ", ";
      resp += yToken;
      resp += " (";
      resp += targetX;
      resp += ", ";
      resp += targetY;
      resp += ") on a ";
      resp += LOGICAL_SCREEN_WIDTH;
      resp += "x";
      resp += LOGICAL_SCREEN_HEIGHT;
      resp += " logical screen.";
      return resp;
    }
    return "ERR: bad MOVE_ABS args (need MOVE_ABS x% y%)";
  }
  else if (cmdUpper.startsWith("TAP_ABS ")) {
    int spaceIdx = cmdUpper.indexOf(' ', 8);
    if (spaceIdx > 0) {
      String xToken = cmdUpper.substring(8, spaceIdx);
      String yToken = cmdUpper.substring(spaceIdx + 1);
      float xPercent = 0.0f;
      float yPercent = 0.0f;
      if (!parsePercentToken(xToken, xPercent) || !parsePercentToken(yToken, yPercent)) {
        return "ERR: bad TAP_ABS args (need TAP_ABS x% y%, 0-100%)";
      }

      int targetX = (int)((xPercent * LOGICAL_SCREEN_WIDTH / 100.0f) + 0.5f);
      int targetY = (int)((yPercent * LOGICAL_SCREEN_HEIGHT / 100.0f) + 0.5f);
      clickAtPixel(targetX, targetY);

      String resp = "OK: tap_abs ";
      resp += xToken;
      resp += ",";
      resp += yToken;
      resp += " => ";
      resp += targetX;
      resp += ",";
      resp += targetY;
      return resp;
    }
    return "ERR: bad TAP_ABS args (need TAP_ABS x% y%)";
  }
  // --- Absolute tap: reset cursor to (0,0) then move to target and click ---
  else if (cmdUpper.startsWith("TAP ")) {
    int spaceIdx = cmdUpper.indexOf(' ', 4);
    if (spaceIdx > 0) {
      int targetX = cmdUpper.substring(4, spaceIdx).toInt();
      int targetY = cmdUpper.substring(spaceIdx + 1).toInt();
      clickAtPixel(targetX, targetY);

      String resp = "OK: tap ";
      resp += targetX;
      resp += ",";
      resp += targetY;
      return resp;
    }
    return "ERR: bad TAP args (need TAP x y)";
  }
  else if (cmdUpper == "CLICK_RIGHT") {
    Mouse.click(MOUSE_RIGHT);
    return "OK: right click";
  }
  else if (cmdUpper.startsWith("SCROLL ")) {
    int amount = cmdUpper.substring(7).toInt();
    int dir = (amount > 0) ? 1 : -1;
    int steps = abs(amount);
    for (int i = 0; i < steps; i++) {
      Mouse.move(0, 0, dir);
      delay(10);
    }
    return "OK: scroll";
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
    return "OK: swipe";
  }
  // --- iOS shortcuts ---
  else if (cmdUpper == "VOL_UP") {
    Keyboard.write(KEY_MEDIA_VOLUME_UP);
    return "OK: vol up";
  }
  else if (cmdUpper == "VOL_DOWN") {
    Keyboard.write(KEY_MEDIA_VOLUME_DOWN);
    return "OK: vol down";
  }
  else if (cmdUpper == "HOME") {
    Keyboard.press(KEY_LEFT_GUI);
    Keyboard.press('h');
    delay(50);
    Keyboard.releaseAll();
    return "OK: home";
  }
  else if (cmdUpper == "LOCK") {
    Keyboard.press(KEY_LEFT_GUI);
    Keyboard.press('l');
    delay(50);
    Keyboard.releaseAll();
    return "OK: lock";
  }
  else if (cmdUpper == "APPSWITCHER") {
    Keyboard.press(KEY_LEFT_GUI);
    Keyboard.press(KEY_TAB);
    delay(50);
    Keyboard.releaseAll();
    return "OK: app switcher";
  }
  else if (cmdUpper == "SPOTLIGHT") {
    Keyboard.press(KEY_LEFT_GUI);
    Keyboard.press(' ');
    delay(50);
    Keyboard.releaseAll();
    return "OK: spotlight";
  }
  else {
    return "ERR: unknown: " + cmdUpper;
  }
}

void setup() {
  Serial.begin(115200);
  Serial.println("\n=== Sotos ESP32 Controller ===");

  // Start BLE HID first (priority)
  Serial.println("[BLE] Starting...");
  Keyboard.deviceName = "pilot-1";
  Keyboard.begin();
  Serial.println("[BLE] Advertising as 'pilot-1' (HID + command service)");
  Serial.println("[Ready] Pair iPhone to 'pilot-1' via Bluetooth");
  Serial.println("[Ready] Swift app can send commands to BLE characteristic");
}

void loop() {
  if (millis() - lastBleCommandCheck > 20) {
    lastBleCommandCheck = millis();
    std::string rawCommand;
    if (Keyboard.popCommand(rawCommand)) {
      String command = String(rawCommand.c_str());
      command.trim();
      if (command.length() > 0) {
        Serial.print("[BLE CMD] ");
        Serial.println(command);
        String result = executeCommand(command);
        Serial.print("[BLE RES] ");
        Serial.println(result);
        Keyboard.sendCommandResponse(std::string(result.c_str()));
      }
    }
  }

  // Serial commands still work (for local debugging)
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (inputBuffer.length() > 0) {
        String result = executeCommand(inputBuffer);
        Serial.println(result);
        inputBuffer = "";
      }
    } else {
      inputBuffer += c;
    }
  }

  // Periodic status
  static unsigned long lastBleCheck = 0;
  if (millis() - lastBleCheck > 10000) {
    lastBleCheck = millis();
    if (!Keyboard.isConnected()) {
      Serial.println("[BLE] Waiting for connection...");
    } else {
      Serial.println("[BLE] HID connected.");
    }
  }
}
