/**
 * BLE Absolute Mouse + Keyboard + Media Keys for ESP32-S3
 * Compatible with ESP32 Arduino core 3.x
 * Interactive serial control for iOS
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEHIDDevice.h>
#include <BLECharacteristic.h>
#include <BLE2902.h>
#include <HIDTypes.h>

#define REPORT_ID_KEYBOARD 0x01
#define REPORT_ID_MEDIA    0x02
#define REPORT_ID_MOUSE    0x03

static const uint8_t hidReportDescriptor[] = {
  // ---- Keyboard (same descriptor that worked in BleComboExample) ----
  USAGE_PAGE(1),      0x01,          // Generic Desktop
  USAGE(1),           0x06,          // Keyboard
  COLLECTION(1),      0x01,          // Application
  REPORT_ID(1),       REPORT_ID_KEYBOARD,
  USAGE_PAGE(1),      0x07,          // Keyboard/Keypad
  USAGE_MINIMUM(1),   0xE0,
  USAGE_MAXIMUM(1),   0xE7,
  LOGICAL_MINIMUM(1), 0x00,
  LOGICAL_MAXIMUM(1), 0x01,
  REPORT_SIZE(1),     0x01,
  REPORT_COUNT(1),    0x08,
  HIDINPUT(1),        0x02,          // Modifier bits
  REPORT_COUNT(1),    0x01,
  REPORT_SIZE(1),     0x08,
  HIDINPUT(1),        0x01,          // Reserved byte
  REPORT_COUNT(1),    0x06,
  REPORT_SIZE(1),     0x08,
  LOGICAL_MINIMUM(1), 0x00,
  LOGICAL_MAXIMUM(1), 0x65,
  USAGE_PAGE(1),      0x07,
  USAGE_MINIMUM(1),   0x00,
  USAGE_MAXIMUM(1),   0x65,
  HIDINPUT(1),        0x00,          // Key array
  END_COLLECTION(0),

  // ---- Media Keys (bitmap style - proven working on iOS) ----
  USAGE_PAGE(1),      0x0C,          // Consumer
  USAGE(1),           0x01,          // Consumer Control
  COLLECTION(1),      0x01,          // Application
  REPORT_ID(1),       REPORT_ID_MEDIA,
  USAGE_PAGE(1),      0x0C,
  LOGICAL_MINIMUM(1), 0x00,
  LOGICAL_MAXIMUM(1), 0x01,
  REPORT_SIZE(1),     0x01,
  REPORT_COUNT(1),    0x10,          // 16 bits
  USAGE(1),           0xB5,          // Scan Next Track       bit 0
  USAGE(1),           0xB6,          // Scan Previous Track   bit 1
  USAGE(1),           0xB7,          // Stop                  bit 2
  USAGE(1),           0xCD,          // Play/Pause            bit 3
  USAGE(1),           0xE2,          // Mute                  bit 4
  USAGE(1),           0xE9,          // Volume Increment      bit 5
  USAGE(1),           0xEA,          // Volume Decrement      bit 6
  USAGE(2),           0x23, 0x02,    // WWW Home              bit 7
  USAGE(2),           0x94, 0x01,    // My Computer           bit 8
  USAGE(2),           0x92, 0x01,    // Calculator            bit 9
  USAGE(2),           0x2A, 0x02,    // WWW Bookmarks         bit 10
  USAGE(2),           0x21, 0x02,    // WWW Search            bit 11
  USAGE(2),           0x26, 0x02,    // WWW Stop              bit 12
  USAGE(2),           0x24, 0x02,    // WWW Back              bit 13
  USAGE(2),           0x83, 0x01,    // Media Select          bit 14
  USAGE(2),           0x8A, 0x01,    // Mail                  bit 15
  HIDINPUT(1),        0x02,          // Data,Var,Abs
  END_COLLECTION(0),

  // ---- Absolute Mouse ----
  0x05, 0x01,        // USAGE_PAGE (Generic Desktop)
  0x09, 0x02,        // USAGE (Mouse)
  0xa1, 0x01,        // COLLECTION (Application)
  0x85, REPORT_ID_MOUSE,
  0x09, 0x01,        //   USAGE (Pointer)
  0xa1, 0x00,        //   COLLECTION (Physical)
  0x05, 0x09, 0x19, 0x01, 0x29, 0x03,  // Buttons 1-3
  0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x03,
  0x81, 0x02,        // INPUT (Data,Var,Abs)
  0x75, 0x05, 0x95, 0x01, 0x81, 0x03,  // 5-bit padding
  0x05, 0x01,        // USAGE_PAGE (Generic Desktop)
  0x09, 0x30,        // USAGE (X)
  0x16, 0x00, 0x00, 0x26, 0x10, 0x27,  // 0-10000
  0x75, 0x10, 0x95, 0x01, 0x81, 0x02,
  0x09, 0x31,        // USAGE (Y)
  0x16, 0x00, 0x00, 0x26, 0x10, 0x27,
  0x75, 0x10, 0x95, 0x01, 0x81, 0x02,
  0xc0, 0xc0
};

// Forward declaration
void handleCommand(String cmd);

// Nordic UART Service (NUS) for iOS app command channel
#define NUS_SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX_CHARACTERISTIC   "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_TX_CHARACTERISTIC   "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// Globals
BLEHIDDevice* hid;
BLECharacteristic* inputAbsMouse;
BLECharacteristic* inputKeyboard;
BLECharacteristic* inputMedia;
BLECharacteristic* nusTx;
bool deviceConnected = false;
bool justConnected = false;
String bleBuffer = "";

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    justConnected = true;
    Serial.println("*** Device connected ***");
    // Keep advertising so the iOS Pilot app can discover us
    // even when iOS HID system is already connected
    delay(100);
    pServer->getAdvertising()->start();
    Serial.println("Continuing to advertise for additional connections");
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("*** Device disconnected ***");
    delay(100);
    pServer->getAdvertising()->start();
    Serial.println("Advertising restarted");
  }
};

// ---- NUS RX Callback (receives commands from iOS app) ----
class NUSRxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = pCharacteristic->getValue().c_str();
    for (int i = 0; i < value.length(); i++) {
      char c = value[i];
      if (c == '\n' || c == '\r') {
        if (bleBuffer.length() > 0) {
          handleCommand(bleBuffer);
          bleBuffer = "";
        }
      } else {
        bleBuffer += c;
      }
    }
    // Handle commands without trailing newline
    if (bleBuffer.length() > 0) {
      handleCommand(bleBuffer);
      bleBuffer = "";
    }
  }
};

void nusRespond(const String& msg) {
  if (nusTx && deviceConnected) {
    nusTx->setValue(msg.c_str());
    nusTx->notify();
  }
  Serial.println(msg);
}

// ---- Mouse ----
void absSend(uint8_t buttons, int16_t x, int16_t y) {
  if (!deviceConnected) return;
  uint8_t r[5] = { buttons, (uint8_t)(x&0xff), (uint8_t)(x>>8), (uint8_t)(y&0xff), (uint8_t)(y>>8) };
  inputAbsMouse->setValue(r, 5);
  inputAbsMouse->notify();
}
void absMoveTo(int16_t x, int16_t y) { absSend(0, x, y); }
void absClick(int16_t x, int16_t y) {
  absMoveTo(x, y); delay(50);
  absSend(1, x, y); delay(50);
  absSend(0, x, y);
}

// ---- Keyboard ----
void kbSend(uint8_t mod, uint8_t keycode) {
  if (!deviceConnected) return;
  uint8_t r[8] = {mod, 0, keycode, 0,0,0,0,0};
  inputKeyboard->setValue(r, 8); inputKeyboard->notify();
  delay(mod ? 100 : 20);  // hold longer for modifier combos
  uint8_t rel[8] = {0};
  inputKeyboard->setValue(rel, 8); inputKeyboard->notify();
  delay(20);
}

void charToHID(char c, uint8_t* kc, uint8_t* mod) {
  *mod = 0; *kc = 0;
  if (c >= 'a' && c <= 'z')      *kc = 0x04 + (c - 'a');
  else if (c >= 'A' && c <= 'Z') { *kc = 0x04 + (c - 'A'); *mod = 0x02; }
  else if (c >= '1' && c <= '9') *kc = 0x1E + (c - '1');
  else if (c == '0')  *kc = 0x27;
  else if (c == ' ')  *kc = 0x2C;
  else if (c == '\n') *kc = 0x28;
  else if (c == '\t') *kc = 0x2B;
  else if (c == '!')  { *kc = 0x1E; *mod = 0x02; }
  else if (c == '@')  { *kc = 0x1F; *mod = 0x02; }
  else if (c == '#')  { *kc = 0x20; *mod = 0x02; }
  else if (c == '$')  { *kc = 0x21; *mod = 0x02; }
  else if (c == '%')  { *kc = 0x22; *mod = 0x02; }
  else if (c == '^')  { *kc = 0x23; *mod = 0x02; }
  else if (c == '&')  { *kc = 0x24; *mod = 0x02; }
  else if (c == '*')  { *kc = 0x25; *mod = 0x02; }
  else if (c == '(')  { *kc = 0x26; *mod = 0x02; }
  else if (c == ')')  { *kc = 0x27; *mod = 0x02; }
  else if (c == '-')  *kc = 0x2D;
  else if (c == '_')  { *kc = 0x2D; *mod = 0x02; }
  else if (c == '=')  *kc = 0x2E;
  else if (c == '+')  { *kc = 0x2E; *mod = 0x02; }
  else if (c == '[')  *kc = 0x2F;
  else if (c == ']')  *kc = 0x30;
  else if (c == '\\') *kc = 0x31;
  else if (c == ';')  *kc = 0x33;
  else if (c == ':')  { *kc = 0x33; *mod = 0x02; }
  else if (c == '\'') *kc = 0x34;
  else if (c == '"')  { *kc = 0x34; *mod = 0x02; }
  else if (c == ',')  *kc = 0x36;
  else if (c == '<')  { *kc = 0x36; *mod = 0x02; }
  else if (c == '.')  *kc = 0x37;
  else if (c == '>')  { *kc = 0x37; *mod = 0x02; }
  else if (c == '/')  *kc = 0x38;
  else if (c == '?')  { *kc = 0x38; *mod = 0x02; }
  else if (c == '`')  *kc = 0x35;
  else if (c == '~')  { *kc = 0x35; *mod = 0x02; }
}

void kbType(const char* text) {
  while (*text) {
    uint8_t kc, mod;
    charToHID(*text, &kc, &mod);
    if (kc) kbSend(mod, kc);
    text++;
  }
}

// ---- Media / Consumer Control (bitmap style) ----
// Each bit corresponds to a media key in the HID descriptor
#define MEDIA_NEXT_TRACK    (1 << 0)   // bit 0
#define MEDIA_PREV_TRACK    (1 << 1)   // bit 1
#define MEDIA_STOP          (1 << 2)   // bit 2
#define MEDIA_PLAY_PAUSE    (1 << 3)   // bit 3
#define MEDIA_MUTE          (1 << 4)   // bit 4
#define MEDIA_VOLUME_UP     (1 << 5)   // bit 5
#define MEDIA_VOLUME_DOWN   (1 << 6)   // bit 6
#define MEDIA_WWW_HOME      (1 << 7)   // bit 7
#define MEDIA_MY_COMPUTER   (1 << 8)   // bit 8
#define MEDIA_CALCULATOR    (1 << 9)   // bit 9
#define MEDIA_WWW_BOOKMARKS (1 << 10)  // bit 10
#define MEDIA_WWW_SEARCH    (1 << 11)  // bit 11
#define MEDIA_WWW_STOP      (1 << 12)  // bit 12
#define MEDIA_WWW_BACK      (1 << 13)  // bit 13
#define MEDIA_MEDIA_SELECT  (1 << 14)  // bit 14
#define MEDIA_MAIL          (1 << 15)  // bit 15

void mediaSend(uint16_t bits) {
  if (!deviceConnected) return;
  uint8_t r[2] = { (uint8_t)(bits & 0xff), (uint8_t)(bits >> 8) };
  inputMedia->setValue(r, 2); inputMedia->notify(); delay(100);
  uint8_t rel[2] = {0, 0};
  inputMedia->setValue(rel, 2); inputMedia->notify(); delay(20);
}

void setup() {
  Serial.begin(115200);
  Serial.println("Starting BLE HID...");

  BLEDevice::init("pilot-1");
  BLEServer* pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  hid = new BLEHIDDevice(pServer);
  inputAbsMouse = hid->inputReport(REPORT_ID_MOUSE);
  inputKeyboard = hid->inputReport(REPORT_ID_KEYBOARD);
  hid->outputReport(REPORT_ID_KEYBOARD);
  inputMedia = hid->inputReport(REPORT_ID_MEDIA);

  hid->manufacturer()->setValue("ESP32");
  hid->pnp(0x02, 0xe502, 0xa111, 0x0210);
  hid->hidInfo(0x00, 0x02);

  BLESecurity* pSecurity = new BLESecurity();
  pSecurity->setAuthenticationMode(ESP_LE_AUTH_REQ_SC_MITM_BOND);
  pSecurity->setCapability(ESP_IO_CAP_NONE);
  pSecurity->setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);

  hid->reportMap((uint8_t*)hidReportDescriptor, sizeof(hidReportDescriptor));
  hid->startServices();
  hid->setBatteryLevel(100);

  // ---- Nordic UART Service (NUS) for iOS app commands ----
  BLEService* nusService = pServer->createService(NUS_SERVICE_UUID);
  nusTx = nusService->createCharacteristic(
    NUS_TX_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  // NimBLE auto-adds 2902 descriptor for notify characteristics
  BLECharacteristic* nusRx = nusService->createCharacteristic(
    NUS_RX_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  nusRx->setCallbacks(new NUSRxCallbacks());
  nusService->start();

  BLEAdvertising* pAdvertising = pServer->getAdvertising();
  pAdvertising->setAppearance(HID_KEYBOARD);
  pAdvertising->addServiceUUID(hid->hidService()->getUUID());
  pAdvertising->addServiceUUID(NUS_SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);
  pAdvertising->start();

  Serial.println("BLE HID ready! Waiting for connection...");
}

String serialBuffer = "";

void handleCommand(String cmd) {
  cmd.trim();
  if (cmd.length() == 0) return;
  if (!deviceConnected) { nusRespond("ERR not connected"); return; }

  // ---- Mouse commands ----
  if (cmd.startsWith("click ")) {
    int sp = cmd.indexOf(' ', 6);
    if (sp < 0) { nusRespond("ERR usage: click x y"); return; }
    int x = cmd.substring(6, sp).toInt() * 100;
    int y = cmd.substring(sp + 1).toInt() * 100;
    absClick(x, y);
    nusRespond("OK click " + String(x/100) + " " + String(y/100));
  }
  else if (cmd.startsWith("move ")) {
    int sp = cmd.indexOf(' ', 5);
    if (sp < 0) { nusRespond("ERR usage: move x y"); return; }
    int x = cmd.substring(5, sp).toInt() * 100;
    int y = cmd.substring(sp + 1).toInt() * 100;
    absMoveTo(x, y);
    nusRespond("OK move " + String(x/100) + " " + String(y/100));
  }
  else if (cmd.startsWith("press ")) {
    int sp = cmd.indexOf(' ', 6);
    if (sp < 0) { nusRespond("ERR usage: press x y"); return; }
    int x = cmd.substring(6, sp).toInt() * 100;
    int y = cmd.substring(sp + 1).toInt() * 100;
    absMoveTo(x, y); delay(50); absSend(1, x, y);
    nusRespond("OK press " + String(x/100) + " " + String(y/100));
  }
  else if (cmd == "release") { absSend(0, 0, 0); nusRespond("OK release"); }

  // ---- Keyboard commands ----
  else if (cmd.startsWith("type ")) {
    String text = cmd.substring(5);
    kbType(text.c_str());
    nusRespond("OK type \"" + text + "\"");
  }
  else if (cmd.startsWith("key ")) {
    String args = cmd.substring(4); args.trim();
    uint8_t mod = 0, keycode = 0;
    while (true) {
      if (args.startsWith("ctrl+"))       { mod |= 0x01; args = args.substring(5); }
      else if (args.startsWith("shift+")) { mod |= 0x02; args = args.substring(6); }
      else if (args.startsWith("alt+"))   { mod |= 0x04; args = args.substring(4); }
      else if (args.startsWith("gui+") || args.startsWith("cmd+")) { mod |= 0x08; args = args.substring(4); }
      else break;
    }
    if      (args == "enter" || args == "return") keycode = 0x28;
    else if (args == "esc" || args == "escape")   keycode = 0x29;
    else if (args == "backspace" || args == "bs")  keycode = 0x2A;
    else if (args == "tab")       keycode = 0x2B;
    else if (args == "space")     keycode = 0x2C;
    else if (args == "delete" || args == "del") keycode = 0x4C;
    else if (args == "right")     keycode = 0x4F;
    else if (args == "left")      keycode = 0x50;
    else if (args == "down")      keycode = 0x51;
    else if (args == "up")        keycode = 0x52;
    else if (args == "home")      keycode = 0x4A;
    else if (args == "end")       keycode = 0x4D;
    else if (args == "pageup")    keycode = 0x4B;
    else if (args == "pagedown")  keycode = 0x4E;
    else if (args == "capslock")  keycode = 0x39;
    else if (args == "printscreen") keycode = 0x46;
    else if (args == "scrolllock") keycode = 0x47;
    else if (args == "pause")     keycode = 0x48;
    else if (args == "insert")    keycode = 0x49;
    else if (args.length() == 1)  { uint8_t m2; charToHID(args.charAt(0), &keycode, &m2); mod |= m2; }
    else if (args.startsWith("f") && args.length() <= 3) {
      int fn = args.substring(1).toInt();
      if (fn >= 1 && fn <= 12) keycode = 0x3A + (fn - 1);
      else if (fn >= 13 && fn <= 24) keycode = 0x68 + (fn - 13);
    }
    if (keycode) { kbSend(mod, keycode); nusRespond("OK key"); }
    else nusRespond("ERR unknown key");
  }

  // ---- Media commands ----
  else if (cmd == "play" || cmd == "pause" || cmd == "playpause") { mediaSend(MEDIA_PLAY_PAUSE); nusRespond("OK play/pause"); }
  else if (cmd == "next" || cmd == "nexttrack") { mediaSend(MEDIA_NEXT_TRACK); nusRespond("OK next"); }
  else if (cmd == "prev" || cmd == "prevtrack") { mediaSend(MEDIA_PREV_TRACK); nusRespond("OK prev"); }
  else if (cmd == "stop") { mediaSend(MEDIA_STOP); nusRespond("OK stop"); }
  else if (cmd == "volup" || cmd == "volumeup") { mediaSend(MEDIA_VOLUME_UP); nusRespond("OK volup"); }
  else if (cmd == "voldown" || cmd == "volumedown") { mediaSend(MEDIA_VOLUME_DOWN); nusRespond("OK voldown"); }
  else if (cmd == "mute") { mediaSend(MEDIA_MUTE); nusRespond("OK mute"); }
  else if (cmd == "lock" || cmd == "screenlock") { kbSend(0x09, 0x14); nusRespond("OK lock"); }

  // ---- Volume repeat ----
  else if (cmd.startsWith("volup ") || cmd.startsWith("volumeup ")) {
    int sp = cmd.lastIndexOf(' ');
    int n = cmd.substring(sp + 1).toInt();
    if (n < 1) n = 1; if (n > 100) n = 100;
    for (int i = 0; i < n && deviceConnected; i++) { mediaSend(MEDIA_VOLUME_UP); delay(30); }
    nusRespond("OK volup x" + String(n));
  }
  else if (cmd.startsWith("voldown ") || cmd.startsWith("volumedown ")) {
    int sp = cmd.lastIndexOf(' ');
    int n = cmd.substring(sp + 1).toInt();
    if (n < 1) n = 1; if (n > 100) n = 100;
    for (int i = 0; i < n && deviceConnected; i++) { mediaSend(MEDIA_VOLUME_DOWN); delay(30); }
    nusRespond("OK voldown x" + String(n));
  }

  // ---- iOS shortcuts ----
  else if (cmd == "spotlight")    { kbSend(0x08, 0x2C); nusRespond("OK spotlight"); }
  else if (cmd == "home")         { kbSend(0x08, 0x0B); nusRespond("OK home"); }
  else if (cmd == "appswitcher" || cmd == "multitask") { kbSend(0x08, 0x2B); nusRespond("OK appswitcher"); }
  else if (cmd == "screenshot")   { kbSend(0x0A, 0x20); nusRespond("OK screenshot"); }
  else if (cmd == "undo")         { kbSend(0x08, 0x1D); nusRespond("OK undo"); }
  else if (cmd == "redo")         { kbSend(0x0A, 0x1D); nusRespond("OK redo"); }
  else if (cmd == "copy")         { kbSend(0x08, 0x06); nusRespond("OK copy"); }
  else if (cmd == "paste")        { kbSend(0x08, 0x19); nusRespond("OK paste"); }
  else if (cmd == "cut")          { kbSend(0x08, 0x1B); nusRespond("OK cut"); }
  else if (cmd == "selectall")    { kbSend(0x08, 0x04); nusRespond("OK selectall"); }
  else if (cmd == "find")         { kbSend(0x08, 0x09); nusRespond("OK find"); }
  else if (cmd == "newtab")       { kbSend(0x08, 0x17); nusRespond("OK newtab"); }
  else if (cmd == "closetab")     { kbSend(0x08, 0x1A); nusRespond("OK closetab"); }
  else if (cmd == "refresh")      { kbSend(0x08, 0x15); nusRespond("OK refresh"); }
  else if (cmd == "dock")         { kbSend(0x0C, 0x07); nusRespond("OK dock"); }
  else if (cmd == "keyboard")     { kbSend(0x08, 0x0E); nusRespond("OK keyboard"); }
  else if (cmd == "siri")         { nusRespond("ERR siri not available via HID"); }

  // ---- Other ----
  else if (cmd == "status") { nusRespond(String("OK connected=") + (deviceConnected ? "yes" : "no")); }
  else if (cmd == "help")   { nusRespond("OK help: click|move|press|release|type|key|play|volup|voldown|spotlight|home|screenshot|status"); }
  else { nusRespond("ERR unknown: " + cmd); }
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (serialBuffer.length() > 0) {
        handleCommand(serialBuffer);
        serialBuffer = "";
      }
    } else {
      serialBuffer += c;
    }
  }

  if (deviceConnected && justConnected) {
    justConnected = false;
    Serial.println("READY - device connected");
  }

  delay(10);
}
