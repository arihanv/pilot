#include <SQUIDHID.h>
#include <NimBLEDevice.h>

// ── Device identity ──────────────────────────────────────────────────────────
static const char* DEVICE_NAME    = "PilotAI";
static const char* DEVICE_MFR     = "Seeed";

// ── iPhone logical screen size (points) ──────────────────────────────────────
// Digitizer.cpp scales: hidX = (x * 32767) / _screenWidth
// So passing screen-point values works once we setDigitizerRange to this size.
static const uint16_t SCREEN_W    = 402;
static const uint16_t SCREEN_H    = 874;

// ── Nordic UART Service (NUS) UUIDs — iOS app connects to these ──────────────
static const char* NUS_SVC_UUID   = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static const char* NUS_RX_UUID    = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // iOS writes
static const char* NUS_TX_UUID    = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // ESP32 notifies

// ── Globals ───────────────────────────────────────────────────────────────────
SQUIDHID esp(DEVICE_NAME, DEVICE_MFR, 100);

static NimBLECharacteristic* nusTxChar = nullptr;

// Virtual cursor (screen points) — used to anchor relative swipes
static int curX = SCREEN_W / 2;
static int curY = SCREEN_H / 2;

// Command queue: written by BLE callback task, consumed in loop()
static volatile bool  cmdPending = false;
static char           cmdBuf[256];
static portMUX_TYPE   cmdMux = portMUX_INITIALIZER_UNLOCKED;

// ── BLE response helper ───────────────────────────────────────────────────────
static void bleRespond(const char* text) {
    if (!nusTxChar) return;
    nusTxChar->setValue((uint8_t*)text, strlen(text));
    nusTxChar->notify();
}

// ── BLE security callbacks — auto-accept pairing on headless device ───────────
class BLESecurityCallback : public NimBLESecurityCallbacks {
    // iOS uses Numeric Comparison for SC pairing: auto-confirm on our side
    bool onConfirmPIN(uint32_t pin) override {
        Serial.printf("[BLE] Confirm PIN %06lu — auto YES\n", (unsigned long)pin);
        return true;
    }
    uint32_t onPassKeyRequest() override { return 0; }
    void onPassKeyNotify(uint32_t pk) override {
        Serial.printf("[BLE] PassKey notify: %06lu\n", (unsigned long)pk);
    }
    bool onSecurityRequest() override { return true; }
    void onAuthenticationComplete(ble_gap_conn_desc* desc) override {
        if (desc->sec_state.encrypted) {
            Serial.println("[BLE] Paired and encrypted OK");
        } else {
            Serial.println("[BLE] Pairing FAILED — not encrypted");
        }
    }
};
static BLESecurityCallback bleSecCb;

// ── NUS RX callback ───────────────────────────────────────────────────────────
class NUSRxCallback : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c) override {
        std::string v = c->getValue();
        if (v.empty()) return;
        portENTER_CRITICAL(&cmdMux);
        size_t len = v.size() < sizeof(cmdBuf) - 1 ? v.size() : sizeof(cmdBuf) - 1;
        memcpy(cmdBuf, v.data(), len);
        cmdBuf[len] = '\0';
        cmdPending = true;
        portEXIT_CRITICAL(&cmdMux);
    }
};
static NUSRxCallback nusRxCb;

// ── Digitizer swipe helper ────────────────────────────────────────────────────
static void doSwipe(int ox1, int oy1, int ox2, int oy2, int steps) {
    if (steps < 2) steps = 12;
    int sx = constrain(curX + ox1, 0, (int)SCREEN_W);
    int sy = constrain(curY + oy1, 0, (int)SCREEN_H);
    int ex = constrain(curX + ox2, 0, (int)SCREEN_W);
    int ey = constrain(curY + oy2, 0, (int)SCREEN_H);

    esp.beginStroke((uint16_t)sx, (uint16_t)sy, 120);
    delay(30);
    for (int i = 1; i <= steps; i++) {
        int px = sx + ((ex - sx) * i) / steps;
        int py = sy + ((ey - sy) * i) / steps;
        esp.updateStroke((uint16_t)px, (uint16_t)py, 100);
        delay(15);
    }
    esp.endStroke((uint16_t)ex, (uint16_t)ey);
    curX = ex;
    curY = ey;
}

// ── Command dispatcher ────────────────────────────────────────────────────────
static void executeCommand(const char* raw) {
    // Strip leading non-printable
    while (*raw && ((uint8_t)*raw < 32 || (uint8_t)*raw > 126)) raw++;
    if (!*raw) { bleRespond("ERR:EMPTY"); return; }

    Serial.printf("[CMD] %s\n", raw);

    // Upper-case copy for keyword matching
    char up[256];
    size_t i = 0;
    while (raw[i] && i < sizeof(up) - 1) { up[i] = toupper((uint8_t)raw[i]); i++; }
    up[i] = '\0';

    // ── STATUS ────────────────────────────────────────────────────────────────
    if (strcmp(up, "STATUS") == 0) {
        bleRespond(esp.isConnected() ? "OK:CONNECTED" : "OK:DISCONNECTED");
        return;
    }

    // ── CLICK_AT x y — absolute digitizer tap (screen points) ────────────────
    if (strncmp(up, "CLICK_AT ", 9) == 0) {
        int x = 0, y = 0;
        if (sscanf(up + 9, "%d %d", &x, &y) == 2) {
            x = constrain(x, 0, (int)SCREEN_W);
            y = constrain(y, 0, (int)SCREEN_H);
            esp.click((uint16_t)x, (uint16_t)y, DI_BTN1);
            curX = x; curY = y;
            bleRespond("OK");
        } else {
            bleRespond("ERR:BAD_ARGS");
        }
        return;
    }

    // ── TYPE <text> ───────────────────────────────────────────────────────────
    if (strncmp(up, "TYPE ", 5) == 0) {
        const char* text = raw + 5;
        for (const char* p = text; *p; ++p) {
            esp.write((uint8_t)*p);
            delay(40);
        }
        delay(80);
        bleRespond("OK");
        return;
    }

    // ── SWIPE x1 y1 x2 y2 [steps] — relative drag from virtual cursor ────────
    if (strncmp(up, "SWIPE ", 6) == 0) {
        int x1=0, y1=0, x2=0, y2=0, steps=15;
        int n = sscanf(up + 6, "%d %d %d %d %d", &x1, &y1, &x2, &y2, &steps);
        if (n >= 4) {
            doSwipe(x1, y1, x2, y2, steps);
            bleRespond("OK");
        } else {
            bleRespond("ERR:BAD_ARGS");
        }
        return;
    }

    // ── SCROLL value — positive=down, negative=up ─────────────────────────────
    if (strncmp(up, "SCROLL ", 7) == 0) {
        int value = 0;
        if (sscanf(up + 7, "%d", &value) == 1) {
            // Each unit ≈ 5 screen-point drag; cap at reasonable range
            int delta = constrain(value * 5, -200, 200);
            doSwipe(0, 0, 0, -delta, 14);
            bleRespond("OK");
        } else {
            bleRespond("ERR:BAD_ARGS");
        }
        return;
    }

    // ── Single-key shortcuts ──────────────────────────────────────────────────
    if (strcmp(up, "ENTER")     == 0) { esp.write(KC_ENT);  bleRespond("OK"); return; }
    if (strcmp(up, "BACKSPACE") == 0) { esp.write(KC_BSPC); bleRespond("OK"); return; }
    if (strcmp(up, "TAB")       == 0) { esp.write(KC_TAB);  bleRespond("OK"); return; }
    if (strcmp(up, "ESC")       == 0) { esp.write(KC_ESC);  bleRespond("OK"); return; }
    if (strcmp(up, "SPACE")     == 0) { esp.write(KC_SPC);  bleRespond("OK"); return; }
    if (strcmp(up, "UP")        == 0) { esp.write(KC_UP);   bleRespond("OK"); return; }
    if (strcmp(up, "DOWN")      == 0) { esp.write(KC_DOWN); bleRespond("OK"); return; }
    if (strcmp(up, "LEFT")      == 0) { esp.write(KC_LEFT); bleRespond("OK"); return; }
    if (strcmp(up, "RIGHT")     == 0) { esp.write(KC_RGHT); bleRespond("OK"); return; }
    if (strcmp(up, "DELETE")    == 0) { esp.write(KC_DEL);  bleRespond("OK"); return; }
    if (strcmp(up, "PAGE_UP")   == 0) { esp.write(KC_PGUP); bleRespond("OK"); return; }
    if (strcmp(up, "PAGE_DOWN") == 0) { esp.write(KC_PGDN); bleRespond("OK"); return; }

    // ── iOS modifier combos ───────────────────────────────────────────────────
    if (strcmp(up, "HOME") == 0) {
        esp.press(KC_LGUI); esp.press(KC_H); delay(50); esp.releaseAll();
        bleRespond("OK"); return;
    }
    if (strcmp(up, "LOCK") == 0) {
        esp.press(KC_LGUI); esp.press(KC_L); delay(50); esp.releaseAll();
        bleRespond("OK"); return;
    }
    if (strcmp(up, "SPOTLIGHT") == 0) {
        esp.press(KC_LGUI); esp.press(KC_SPC); delay(50); esp.releaseAll();
        bleRespond("OK"); return;
    }
    if (strcmp(up, "APPSWITCHER") == 0) {
        esp.press(KC_LGUI); esp.press(KC_TAB); delay(50); esp.releaseAll();
        bleRespond("OK"); return;
    }

    bleRespond("ERR:UNKNOWN");
}

// ─────────────────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(500);
    Serial.println("[PILOT] XIAO ESP32S3 booting...");

    // ── Step 1: Init NimBLE ourselves first ───────────────────────────────────
    // SQUIDHID's begin() calls NimBLEDevice::init() internally, but if the
    // stack is already initialised it's a no-op.  By calling init() here first
    // we can register the NUS service BEFORE SQUIDHID calls
    // hidDevice->startServices(), which seals the GATT database.  Adding a
    // service after the GATT is sealed causes a NimBLE assertion / stack crash,
    // which is why connecting was resetting the ESP32 BLE radio.
    NimBLEDevice::init(DEVICE_NAME);

    // ── Step 2: Create NUS service on the singleton server ───────────────────
    {
        NimBLEServer*  pServer = NimBLEDevice::createServer();
        NimBLEService* nusSvc  = pServer->createService(NUS_SVC_UUID);

        nusTxChar = nusSvc->createCharacteristic(
            NUS_TX_UUID, NIMBLE_PROPERTY::NOTIFY);

        NimBLECharacteristic* nusRx = nusSvc->createCharacteristic(
            NUS_RX_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
        nusRx->setCallbacks(&nusRxCb);

        nusSvc->start(); // queues NUS in GATT — not sealed yet
    }

    // ── Step 3: Start SQUIDHID ────────────────────────────────────────────────
    // NimBLEDevice::init() is a no-op now; createServer() returns the same
    // singleton that already has NUS on it.  HID service is added alongside NUS
    // and then the GATT is sealed when advertising starts.
    esp.setAppearance(CYCLING_COMPUTER);
    esp.setDigitizerRange(SCREEN_W, SCREEN_H);
    esp.begin();

    // ── Step 4: Fix security ──────────────────────────────────────────────────
    // Register callbacks so NimBLE can auto-confirm Numeric Comparison pairing
    // (iOS SC pairing shows a 6-digit number and waits for device confirmation —
    // without a callback NimBLE never confirms and iOS times out / disconnects).
    NimBLEDevice::setSecurityCallbacks(&bleSecCb);
    // Bonding + SC, no MITM required.  With NoInputNoOutput IO cap this becomes
    // "Just Works" SC — no PIN, no number shown, single tap on iPhone/Mac.
    NimBLEDevice::setSecurityAuth(true, false, true); // bonding + SC, no MITM
    NimBLEDevice::setSecurityIOCap(3);                // 3 = NoInputNoOutput

    // ── Step 5: Restart advertising with both service UUIDs ──────────────────
    NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
    pAdv->stop();
    delay(50);

    NimBLEAdvertisementData advData;
    advData.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
    advData.setAppearance(CYCLING_COMPUTER);
    advData.setCompleteServices(NimBLEUUID((uint16_t)0x1812)); // HID → Settings pairs this

    NimBLEAdvertisementData scanRsp;
    scanRsp.setName(DEVICE_NAME);
    scanRsp.setCompleteServices(NimBLEUUID(NUS_SVC_UUID)); // NUS → app scan finds this

    pAdv->setAdvertisementData(advData);
    pAdv->setScanResponseData(scanRsp);
    pAdv->start();

    Serial.printf("[PILOT] Ready — advertising as '%s'\n", DEVICE_NAME);
    Serial.println("[PILOT] Pair in Bluetooth Settings (no PIN required)");
}

void loop() {
    esp.update();

    // Print connection state changes
    static bool lastConnected = false;
    bool nowConnected = esp.isConnected();
    if (nowConnected != lastConnected) {
        lastConnected = nowConnected;
        Serial.println(nowConnected ? "[BLE] HID connected!" : "[BLE] HID disconnected.");
    }

    if (cmdPending) {
        char local[256];
        portENTER_CRITICAL(&cmdMux);
        memcpy(local, cmdBuf, sizeof(local));
        cmdPending = false;
        portEXIT_CRITICAL(&cmdMux);
        executeCommand(local);
    }

    delay(5);
}
