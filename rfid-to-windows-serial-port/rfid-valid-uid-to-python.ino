#include <SPI.h>
#include <MFRC522.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

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
const char *FIRMWARE_VERSION = "1.1.0";

// Floating analog pin used as an entropy source for the UUID seed.
// Leave A0 disconnected. Reading a floating pin gives noisy values
// that, while not cryptographically random, are good enough to ensure
// each device boot produces a different UUID stream.
const uint8_t ENTROPY_PIN = A0;

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
// Allowed RFID UIDs
// =====================================================================
const char *VALID_UIDS[] = {
  "AA A2 31 C4",
  "64 7D 49 BF"
};
const byte VALID_UID_COUNT = sizeof(VALID_UIDS) / sizeof(VALID_UIDS[0]);

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
MFRC522 rfid(RFID_SS_PIN, RFID_RST_PIN);

String lastUid = "";

// Forward declarations
void drawHeader();
void showAccessResult(bool isValid);
void showUid(const String &uid);
void beep(bool isValid);
String readUid();
bool isValidUid(const String &uid);
void emitEvent(const String &uid, bool isValid);
void generateEventId(char *out);

void setup() {
  Serial.begin(9600);
  SPI.begin();
  rfid.PCD_Init();

  display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDRESS);
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);

  pinMode(BUZZER_PIN, OUTPUT);

  // Seed RNG from a floating analog pin for per-boot UUID variation.
  randomSeed(analogRead(ENTROPY_PIN));

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

  String currentUid = readUid();
  bool valid = isValidUid(currentUid);

  if (currentUid != lastUid) {
    lastUid = currentUid;
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
  display.print("RFID");
  display.display();
}

void showAccessResult(bool isValid) {
  drawHeader();
  display.setTextSize(2);
  display.setCursor(isValid ? 22 : 12, 24);
  display.print(isValid ? "VALID" : "INVALID");
  display.display();
}

void showUid(const String &uid) {
  display.fillRect(0, 50, SCREEN_WIDTH, 14, SSD1306_BLACK);
  display.setTextSize(1);
  display.setCursor(0, 54);
  display.print("UID: ");
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

String readUid() {
  String uid = "";

  for (byte i = 0; i < rfid.uid.size; i++) {
    if (i > 0) {
      uid += " ";
    }

    if (rfid.uid.uidByte[i] < 0x10) {
      uid += "0";
    }

    uid += String(rfid.uid.uidByte[i], HEX);
  }

  uid.toUpperCase();
  return uid;
}

bool isValidUid(const String &uid) {
  for (byte i = 0; i < VALID_UID_COUNT; i++) {
    if (uid == VALID_UIDS[i]) {
      return true;
    }
  }

  return false;
}

// ---------------------------------------------------------------------
// Generate a UUID v4 string into out[] (must be at least 37 bytes).
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

void emitEvent(const String &uid, bool isValid) {
  char eventId[37];
  generateEventId(eventId);

  unsigned long ts = millis();

  // Order matches the documented schema. JSON is hand-built (no library)
  // to keep firmware footprint minimal and output deterministic.
  Serial.print("EVENT:{\"event_id\":\"");
  Serial.print(eventId);
  Serial.print("\",\"device_id\":\"");
  Serial.print(DEVICE_ID);
  Serial.print("\",\"firmware_version\":\"");
  Serial.print(FIRMWARE_VERSION);
  Serial.print("\",\"uid\":\"");
  Serial.print(uid);
  Serial.print("\",\"valid\":");
  Serial.print(isValid ? "true" : "false");
  Serial.print(",\"ts_device_ms\":");
  Serial.print(ts);
  Serial.println("}");
}
