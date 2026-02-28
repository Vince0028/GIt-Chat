// ═══════════════════════════════════════════════════════════════
//  GitChat Signal Tower — Arduino UNO R4 WiFi
//  BLE Mesh Bridge & Relay for GitChat
// ═══════════════════════════════════════════════════════════════
//
//  PURPOSE:
//    Acts as a BLE relay tower between GitChat phones.
//    When Phone A loses direct Nearby Connections range to Phone B,
//    this Arduino bridges them via BLE characteristics.
//
//  LED MATRIX DISPLAY:
//    - Idle:       scrolls "GITCHAT TOWER" + antenna icon
//    - Connected:  shows peer count and scrolls last relayed message
//    - No peers:   shows "0" with a waiting animation
//
//  HARDWARE:  Arduino UNO R4 WiFi (built-in BLE + 12x8 LED matrix)
//  LIBRARIES: ArduinoBLE, Arduino_LED_Matrix, ArduinoGraphics
//
//  BLE PROTOCOL:
//    Service UUID:  19B10000-E8F2-537E-4F6C-D104768A1214
//    Characteristics:
//      MSG_CHAR  (19B10001-...)  Write+Notify  — chat messages (JSON)
//      PEER_CHAR (19B10002-...)  Read+Notify   — peer count (uint8)
//      CMD_CHAR  (19B10003-...)  Write         — commands from phone
//
// ═══════════════════════════════════════════════════════════════

#include <ArduinoBLE.h>
#include "Arduino_LED_Matrix.h"
#include <ArduinoGraphics.h>

// ── BLE UUIDs ────────────────────────────────────────────────
#define SERVICE_UUID     "19B10000-E8F2-537E-4F6C-D104768A1214"
#define MSG_CHAR_UUID    "19B10001-E8F2-537E-4F6C-D104768A1214"
#define PEER_CHAR_UUID   "19B10002-E8F2-537E-4F6C-D104768A1214"
#define CMD_CHAR_UUID    "19B10003-E8F2-537E-4F6C-D104768A1214"

// ── Config ───────────────────────────────────────────────────
#define TOWER_NAME       "GITCHAT-TOWER"
#define MAX_PEERS        7       // BLE central limit on R4
#define MSG_BUFFER_SIZE  512     // max bytes per message
#define SCROLL_SPEED     50      // LED text scroll speed (ms)
#define IDLE_SCROLL_MS   5000    // re-scroll idle text every 5s
#define MATRIX_ROWS      8
#define MATRIX_COLS      12

// ── BLE objects ──────────────────────────────────────────────
BLEService          gitChatService(SERVICE_UUID);
BLEStringCharacteristic msgChar(MSG_CHAR_UUID,
                                BLERead | BLEWrite | BLENotify,
                                MSG_BUFFER_SIZE);
BLEByteCharacteristic   peerChar(PEER_CHAR_UUID,
                                 BLERead | BLENotify);
BLEStringCharacteristic cmdChar(CMD_CHAR_UUID,
                                BLEWrite, 64);

ArduinoLEDMatrix matrix;

// ── State ────────────────────────────────────────────────────
uint8_t  peerCount       = 0;
String   lastMessage      = "";
bool     hasNewMessage    = false;
unsigned long lastScrollMs = 0;
unsigned long lastBlinkMs  = 0;
bool     ledOn            = true;

// Track connected centrals by address
String connectedPeers[MAX_PEERS];

// ── LED Matrix Icons (12x8 bitmaps) ─────────────────────────
// Antenna / tower icon for idle state
const uint32_t ICON_TOWER[] = {
  0x00600600,
  0x60006006,
  0x00600600,
  0x06000000
};

// Checkmark icon for connected state
const uint32_t ICON_CONNECTED[] = {
  0x00000000,
  0x10020060,
  0x0C003000,
  0x00000000
};

// ═════════════════════════════════════════════════════════════
//  SETUP
// ═════════════════════════════════════════════════════════════
void setup() {
  Serial.begin(115200);
  delay(1000);  // let serial settle

  Serial.println("╔══════════════════════════════════════╗");
  Serial.println("║   GitChat Signal Tower — R4 WiFi     ║");
  Serial.println("╚══════════════════════════════════════╝");

  // ── Init LED Matrix ──
  matrix.begin();
  Serial.println("[MATRIX] LED matrix initialised");

  // ── Init BLE ──
  if (!BLE.begin()) {
    Serial.println("[BLE] FATAL: BLE init failed!");
    showError();
    while (1);  // halt
  }

  // Configure BLE
  BLE.setLocalName(TOWER_NAME);
  BLE.setDeviceName(TOWER_NAME);
  BLE.setAdvertisedService(gitChatService);

  // Add characteristics to service
  gitChatService.addCharacteristic(msgChar);
  gitChatService.addCharacteristic(peerChar);
  gitChatService.addCharacteristic(cmdChar);

  // Add service
  BLE.addService(gitChatService);

  // Set initial values
  peerChar.writeValue(0);
  msgChar.writeValue("TOWER_READY");

  // Set event handlers
  BLE.setEventHandler(BLEConnected, onPeerConnected);
  BLE.setEventHandler(BLEDisconnected, onPeerDisconnected);
  msgChar.setEventHandler(BLEWritten, onMessageReceived);
  cmdChar.setEventHandler(BLEWritten, onCommandReceived);

  // Start advertising
  BLE.advertise();

  Serial.println("[BLE] Advertising as: " TOWER_NAME);
  Serial.println("[BLE] Service UUID: " SERVICE_UUID);
  Serial.println("[TOWER] Ready — waiting for GitChat peers...");
  Serial.println();

  // Show startup animation
  showStartup();
}

// ═════════════════════════════════════════════════════════════
//  MAIN LOOP
// ═════════════════════════════════════════════════════════════
void loop() {
  // Poll BLE events
  BLE.poll();

  unsigned long now = millis();

  // ── Relay new messages to all other peers ──
  if (hasNewMessage) {
    relayMessage(lastMessage);
    hasNewMessage = false;
  }

  // ── Update LED display ──
  if (peerCount == 0) {
    // Idle mode: blink tower icon + scroll name
    if (now - lastScrollMs > IDLE_SCROLL_MS) {
      showIdleScroll();
      lastScrollMs = now;
    }
  } else {
    // Connected mode: show peer count
    if (now - lastBlinkMs > 1000) {
      showPeerCount();
      lastBlinkMs = now;
    }
  }
}

// ═════════════════════════════════════════════════════════════
//  BLE EVENT HANDLERS
// ═════════════════════════════════════════════════════════════

void onPeerConnected(BLEDevice central) {
  // Store peer address
  String addr = central.address();
  for (int i = 0; i < MAX_PEERS; i++) {
    if (connectedPeers[i].length() == 0) {
      connectedPeers[i] = addr;
      break;
    }
  }
  peerCount++;
  if (peerCount > MAX_PEERS) peerCount = MAX_PEERS;

  // Update BLE characteristic
  peerChar.writeValue(peerCount);

  Serial.print("[PEER+] Connected: ");
  Serial.print(addr);
  Serial.print(" | Total peers: ");
  Serial.println(peerCount);

  // Flash the matrix to acknowledge
  showPeerCount();
}

void onPeerDisconnected(BLEDevice central) {
  // Remove peer address
  String addr = central.address();
  for (int i = 0; i < MAX_PEERS; i++) {
    if (connectedPeers[i] == addr) {
      connectedPeers[i] = "";
      break;
    }
  }
  if (peerCount > 0) peerCount--;

  // Update BLE characteristic
  peerChar.writeValue(peerCount);

  Serial.print("[PEER-] Disconnected: ");
  Serial.print(addr);
  Serial.print(" | Total peers: ");
  Serial.println(peerCount);

  // Resume advertising so new peers can connect
  BLE.advertise();

  showPeerCount();
}

void onMessageReceived(BLEDevice central, BLECharacteristic characteristic) {
  String msg = msgChar.value();
  if (msg.length() == 0) return;

  lastMessage = msg;
  hasNewMessage = true;

  Serial.print("[MSG] From ");
  Serial.print(central.address());
  Serial.print(": ");
  Serial.println(msg);

  // Scroll the message on the LED matrix
  scrollText(msg);
}

void onCommandReceived(BLEDevice central, BLECharacteristic characteristic) {
  String cmd = cmdChar.value();

  Serial.print("[CMD] From ");
  Serial.print(central.address());
  Serial.print(": ");
  Serial.println(cmd);

  if (cmd == "STATUS") {
    // Respond with peer count in message char
    String status = "TOWER:" + String(peerCount) + " peers";
    msgChar.writeValue(status);
    Serial.println("[CMD] Sent status: " + status);
  }
  else if (cmd == "PING") {
    msgChar.writeValue("PONG");
    Serial.println("[CMD] Sent PONG");
  }
  else if (cmd == "RESET") {
    Serial.println("[CMD] Reset requested — restarting BLE...");
    BLE.stopAdvertise();
    delay(500);
    BLE.advertise();
    Serial.println("[CMD] BLE re-advertising");
  }
}

// ═════════════════════════════════════════════════════════════
//  MESSAGE RELAY
// ═════════════════════════════════════════════════════════════

void relayMessage(String msg) {
  // Write to the characteristic — all subscribed peers get notified
  msgChar.writeValue(msg);

  Serial.print("[RELAY] Broadcasting to ");
  Serial.print(peerCount);
  Serial.print(" peer(s): ");

  // Truncate for serial log readability
  if (msg.length() > 60) {
    Serial.println(msg.substring(0, 60) + "...");
  } else {
    Serial.println(msg);
  }
}

// ═════════════════════════════════════════════════════════════
//  LED MATRIX DISPLAY
// ═════════════════════════════════════════════════════════════

void showStartup() {
  // Quick flash animation
  for (int i = 0; i < 3; i++) {
    matrix.loadFrame(ICON_TOWER);
    delay(300);
    clearMatrix();
    delay(200);
  }

  // Scroll tower name
  scrollText("GITCHAT TOWER READY");
}

void showIdleScroll() {
  // Show tower icon briefly then scroll
  matrix.loadFrame(ICON_TOWER);
  delay(800);
  scrollText("Waiting...");
}

void showPeerCount() {
  // Display peer count as a large number on the matrix
  // with a small "P" prefix: e.g. "P3"
  matrix.beginDraw();
  matrix.stroke(0xFFFFFFFF);
  matrix.textFont(Font_5x7);
  matrix.beginText(1, 1, 0xFFFFFF);

  if (peerCount == 0) {
    matrix.print("P:0");
  } else {
    matrix.print("P:" + String(peerCount));
  }

  matrix.endText();
  matrix.endDraw();
}

void showError() {
  // Show "ERR" on matrix
  matrix.beginDraw();
  matrix.stroke(0xFFFFFFFF);
  matrix.textFont(Font_5x7);
  matrix.beginText(0, 1, 0xFFFFFF);
  matrix.print("ERR");
  matrix.endText();
  matrix.endDraw();
}

void scrollText(String text) {
  matrix.beginDraw();
  matrix.stroke(0xFFFFFFFF);
  matrix.textFont(Font_5x7);
  matrix.textScrollSpeed(SCROLL_SPEED);
  matrix.beginText(0, 1, 0xFFFFFF);
  matrix.print(text);
  matrix.endText(SCROLL_LEFT);
  matrix.endDraw();
}

void clearMatrix() {
  // Turn off all LEDs
  uint8_t frame[MATRIX_ROWS][MATRIX_COLS] = {0};
  matrix.renderBitmap(frame, MATRIX_ROWS, MATRIX_COLS);
}
