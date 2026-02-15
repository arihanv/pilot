#include <Arduino.h>
#include <WiFi.h>
#include <BleCombo.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>

// --- WiFi credentials (iPhone Personal Hotspot) ---
const char* WIFI_SSID = "Arihan iPhone";
const char* WIFI_PASS = "arihanv1";

// --- Cloudflare tunnel (plain HTTP/WS on port 80) ---
// Dev: run server locally + cloudflared tunnel --url http://localhost:8000
// Named tunnel: cloudflared tunnel run --url http://localhost:8000 general
const char* WS_HOST = "claire.ariv.sh";
const uint16_t WS_PORT = 80;
const char* WS_PATH = "/ws";
const bool WS_USE_SSL = false;

WebSocketsClient webSocket;
String inputBuffer = "";
unsigned long lastWifiCheck = 0;
unsigned long lastHeartbeat = 0;
bool wsConnected = false;

// Forward declaration
void handleCommand(String cmd);
String executeCommand(String cmd);

// --- Send response back via WebSocket ---
void sendWsResponse(const char* command, const char* response) {
  if (!wsConnected) return;
  JsonDocument doc;
  doc["type"] = "response";
  doc["command"] = command;
  doc["response"] = response;
  String json;
  serializeJson(doc, json);
  webSocket.sendTXT(json);
}

// --- WebSocket event handler ---
void webSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      Serial.println("[WS] Disconnected");
      wsConnected = false;
      break;

    case WStype_CONNECTED: {
      Serial.print("[WS] Connected to ");
      Serial.println((char*)payload);
      wsConnected = true;
      // Identify ourselves to the server
      JsonDocument reg;
      reg["type"] = "register";
      reg["name"] = Keyboard.deviceName;
      String regJson;
      serializeJson(reg, regJson);
      webSocket.sendTXT(regJson);
      break;
    }

    case WStype_TEXT: {
      String msg = String((char*)payload);
      JsonDocument doc;
      DeserializationError err = deserializeJson(doc, msg);
      if (err) {
        Serial.print("[WS] JSON parse error: ");
        Serial.println(err.c_str());
        break;
      }

      const char* msgType = doc["type"];
      if (strcmp(msgType, "command") == 0) {
        const char* cmd = doc["command"];
        Serial.print("[WS] Command: ");
        Serial.println(cmd);
        String result = executeCommand(String(cmd));
        sendWsResponse(cmd, result.c_str());
      }
      else if (strcmp(msgType, "heartbeat_ack") == 0) {
        // Server acknowledged heartbeat
      }
      break;
    }

    case WStype_PING:
      Serial.println("[WS] Ping");
      break;

    case WStype_PONG:
      break;

    default:
      break;
  }
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
    s += ", WiFi: ";
    s += WiFi.isConnected() ? "YES" : "NO";
    s += ", WS: ";
    s += wsConnected ? "YES" : "NO";
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
    Mouse.click(MOUSE_LEFT);
    return "OK: click";
  }
  else if (cmdUpper == "CLICK_RIGHT") {
    Mouse.click(MOUSE_RIGHT);
    return "OK: right click";
  }
  else if (cmdUpper.startsWith("SCROLL ")) {
    int amount = cmdUpper.substring(7).toInt();
    Mouse.move(0, 0, amount);
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

// --- WiFi connection ---
void connectWiFi() {
  if (WiFi.isConnected()) return;

  Serial.print("[WiFi] Connecting to ");
  Serial.println(WIFI_SSID);
  WiFi.disconnect(true);
  delay(100);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  int tries = 0;
  while (WiFi.status() != WL_CONNECTED && tries < 20) {
    delay(500);
    Serial.print(".");
    tries++;
  }
  Serial.println();

  if (WiFi.isConnected()) {
    Serial.print("[WiFi] Connected! IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.print("[WiFi] Failed (status=");
    Serial.print(WiFi.status());
    Serial.println("). Retry later...");
    WiFi.disconnect(true);
  }
}

// --- WebSocket connection ---
void connectWebSocket() {
  if (strlen(WS_HOST) == 0) {
    Serial.println("[WS] No host configured. Set WS_HOST and re-flash.");
    return;
  }

  Serial.print("[WS] Connecting to ");
  Serial.print(WS_HOST);
  Serial.print(":");
  Serial.print(WS_PORT);
  Serial.print(WS_PATH);
  Serial.println();

  if (WS_USE_SSL) {
    webSocket.beginSSL(WS_HOST, WS_PORT, WS_PATH);
  } else {
    webSocket.begin(WS_HOST, WS_PORT, WS_PATH);
  }
  webSocket.onEvent(webSocketEvent);
  webSocket.setReconnectInterval(5000);
}

bool wsStarted = false;

void setup() {
  Serial.begin(115200);
  Serial.println("\n=== Sotos ESP32 Controller ===");

  // Start BLE HID first (priority)
  Serial.println("[BLE] Starting...");
  Keyboard.deviceName = "sotos-ethan";
  Keyboard.begin();
  Serial.println("[BLE] Advertising as 'sotos-arihan'");

  // Init WiFi mode but don't connect yet (let BLE advertise first)
  WiFi.mode(WIFI_STA);

  Serial.println("[Ready] Pair iPhone to 'sotos' via Bluetooth");
  Serial.println("[Ready] WiFi will start after 5 seconds");
}

void loop() {
  // Handle WebSocket (non-blocking)
  if (wsStarted) {
    webSocket.loop();
  }

  // Send heartbeat every 15s
  if (wsConnected && millis() - lastHeartbeat > 15000) {
    lastHeartbeat = millis();
    webSocket.sendTXT("{\"type\":\"heartbeat\"}");
  }

  // Attempt WiFi/WS after 10s (give BLE time to advertise first)
  if (millis() > 5000 && millis() - lastWifiCheck > 5000) {
    lastWifiCheck = millis();
    if (!WiFi.isConnected()) {
      connectWiFi();
    }
    if (WiFi.isConnected() && !wsStarted && strlen(WS_HOST) > 0) {
      connectWebSocket();
      wsStarted = true;
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
    } else if (!WiFi.isConnected()) {
      Serial.println("[BLE] Connected. [WiFi] Waiting for hotspot...");
    }
  }
}
