#include <SPI.h>
#include <MFRC522.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <string.h>
#include <stdio.h>

// =====================================================================
// Fleet configuration
// =====================================================================
// Change DEVICE_ID per reader. Same firmware, different identity.
// Convention: "reader-NN" where NN is a zero-padded sequence.
// In a real fleet you might use the MAC address or a provisioned ID,
// but a flashed constant is sufficient and explicit for this stage.
const char *DEVICE_ID = "reader-01";

// Firmware version. Bump this on EVERY change to the sketch that affects
// what the device emits or how it behaves. Semver-style is conventional
// (MAJOR.MINOR.PATCH) but any monotonically meaningful string is fine.
// The value flows out in every event so the cloud side can tell at a
// glance which firmware produced any given event — useful for diagnosing
// "reader-12 has been weird since Tuesday" once you have a fleet.
//
// 1.2.0: removed the Arduino String class throughout. Fixed-size char
// buffers replace heap allocations to eliminate fragmentation on AVR
// (ATmega328P has only 2KB of RAM total).
const char *FIRMWARE_VERSION = "1.2.0";

// =====================================================================
// OLED configuration
// =====================================================================
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET 4
#define OLED_ADDRESS 0x3C

// =====================================================================
// RFID module pins
// =====================================================================
#define RFID_RST_PIN 9
#define RFID_SS_PIN 10

// =====================================================================
// Buzzer pin
// =====================================================================
const int BUZZER_PIN = 7;

// =====================================================================
// Buffer sizing
// =====================================================================
// MFRC522 supports UIDs up to 10 bytes. Rendered as space-separated hex
// pairs that becomes 10*3 - 1 = 29 chars + null = 30. Round up to 32.
#define UID_BUF_LEN 32

// UUID v4 in canonical 8-4-4-4-12 form: 36 chars + null = 37.
#define UUID_BUF_LEN 37

// =====================================================================
// Allowed RFID UIDs
// =====================================================================
const char *VALID_UIDS[] = {
  "AA A2 31 C4",
  "64 7D 49 BF"
};
const byte VALID_UID_COUNT = sizeof(VALID_UIDS) / sizeof(VALID_UIDS[0]);

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
MFRC522 rfid(RFID_SS_PIN, RFID_RST_PIN);

// Last UID seen, kept across loop iterations to suppress duplicate events
// while the same card is held against the reader. Static buffer, no heap.
char lastUid[UID_BUF_LEN] = "";

// Forward declarations
void drawHeader();
void showAccessResult(bool isValid);
void showUid(const char *uid);
void beep(bool isValid);
void readUid(char *out, size_t outLen);
bool isValidUid(const char *uid);
void emitEvent(const char *uid, bool isValid);
void generateEventId(char *out);
unsigned long seedFromAnalogPins();

void setup() {
  Serial.begin(9600);
  Serial.println(F("BOOT: rfid-valid-uid-to-python firmware 1.2.0"));

  SPI.begin();
  rfid.PCD_Init();

  display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDRESS);
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);

  pinMode(BUZZER_PIN, OUTPUT);

  // Seed the RNG by XOR-ing several analog reads. Any one of A0..A3 might
  // happen to be wired or driven; XOR-ing several reduces the chance of a
  // boring (constant) seed without depending on any single pin being floating.
  randomSeed(seedFromAnalogPins());

  drawHeader();
  showUid("Waiting...");
}

void loop() {
  if (!rfid.PICC_IsNewCardPresent()) {
    return;
  }

  if (!rfid.PICC_ReadCardSerial()) {
    return;
  }

  char currentUid[UID_BUF_LEN];
  readUid(currentUid, sizeof(currentUid));

  bool valid = isValidUid(currentUid);

  if (strcmp(currentUid, lastUid) != 0) {
    strncpy(lastUid, currentUid, sizeof(lastUid) - 1);
    lastUid[sizeof(lastUid) - 1] = '\0';

    showAccessResult(valid);
    showUid(currentUid);
    beep(valid);
    emitEvent(currentUid, valid);
  }

  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
}

void drawHeader() {
  display.clearDisplay();
  display.setTextSize(2);
  display.setCursor(12, 0);
  display.print(F("RFID"));
  display.display();
}

void showAccessResult(bool isValid) {
  drawHeader();
  display.setTextSize(2);
  display.setCursor(isValid ? 22 : 12, 24);
  display.print(isValid ? F("VALID") : F("INVALID"));
  display.display();
}

void showUid(const char *uid) {
  display.fillRect(0, 50, SCREEN_WIDTH, 14, SSD1306_BLACK);
  display.setTextSize(1);
  display.setCursor(0, 54);
  display.print(F("UID: "));
  display.print(uid);
  display.display();
}

void beep(bool isValid) {
  int frequency = isValid ? 2000 : 600;
  int durationMs = isValid ? 120 : 500;

  tone(BUZZER_PIN, frequency, durationMs);
  delay(durationMs);
  noTone(BUZZER_PIN);
}

// Render the just-read MFRC522 UID into out[] as space-separated, uppercase
// hex bytes. Uses snprintf into a fixed buffer — no String, no heap.
void readUid(char *out, size_t outLen) {
  if (outLen == 0) return;
  out[0] = '\0';

  size_t pos = 0;
  for (byte i = 0; i < rfid.uid.size; i++) {
    // Each iteration writes either "XX" (3 chars including space and null)
    // or " XX" (4 chars including null) into the buffer.
    int written;
    if (i == 0) {
      written = snprintf(out + pos, outLen - pos, "%02X", rfid.uid.uidByte[i]);
    } else {
      written = snprintf(out + pos, outLen - pos, " %02X", rfid.uid.uidByte[i]);
    }
    if (written < 0 || (size_t)written >= outLen - pos) {
      // Truncated — stop cleanly. Buffer already has its terminator.
      return;
    }
    pos += written;
  }
}

bool isValidUid(const char *uid) {
  for (byte i = 0; i < VALID_UID_COUNT; i++) {
    if (strcmp(uid, VALID_UIDS[i]) == 0) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------
// Generate a UUID v4 string into out[] (must be at least UUID_BUF_LEN bytes).
// Format: 8-4-4-4-12 hex chars, with version 4 and variant bits set.
// Source of randomness is Arduino's random() seeded in setup().
// Note: not cryptographically secure — fine for de-duplication / idempotency
// keys, not fine for anything that needs unpredictability against an adversary.
// ---------------------------------------------------------------------
void generateEventId(char *out) {
  uint8_t bytes[16];
  for (uint8_t i = 0; i < 16; i++) {
    bytes[i] = (uint8_t)random(0, 256);
  }

  // Set version (4) and variant (10xx) bits per RFC 4122.
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  const char *hex = "0123456789abcdef";
  uint8_t pos = 0;
  for (uint8_t i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      out[pos++] = '-';
    }
    out[pos++] = hex[(bytes[i] >> 4) & 0x0F];
    out[pos++] = hex[bytes[i] & 0x0F];
  }
  out[pos] = '\0';
}

// XOR several analog reads together for a more robust seed.
unsigned long seedFromAnalogPins() {
  unsigned long s = 0;
  s ^= (unsigned long)analogRead(A0);
  s ^= ((unsigned long)analogRead(A1)) << 8;
  s ^= ((unsigned long)analogRead(A2)) << 16;
  s ^= ((unsigned long)analogRead(A3)) << 24;
  // Mix in micros() so even a perfectly constant analog environment still
  // varies the seed slightly across boots.
  s ^= micros();
  return s;
}

void emitEvent(const char *uid, bool isValid) {
  char eventId[UUID_BUF_LEN];
  generateEventId(eventId);

  unsigned long ts = millis();

  // Order matches the documented schema. JSON is hand-built (no library)
  // to keep firmware footprint minimal and output deterministic.
  // F() macros keep string literals in flash, not RAM.
  Serial.print(F("EVENT:{\"event_id\":\""));
  Serial.print(eventId);
  Serial.print(F("\",\"device_id\":\""));
  Serial.print(DEVICE_ID);
  Serial.print(F("\",\"firmware_version\":\""));
  Serial.print(FIRMWARE_VERSION);
  Serial.print(F("\",\"uid\":\""));
  Serial.print(uid);
  Serial.print(F("\",\"valid\":"));
  Serial.print(isValid ? F("true") : F("false"));
  Serial.print(F(",\"ts_device_ms\":"));
  Serial.print(ts);
  Serial.println(F("}"));
}
