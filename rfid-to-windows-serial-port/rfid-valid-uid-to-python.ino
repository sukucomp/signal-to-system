#include <SPI.h>
#include <MFRC522.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// OLED configuration
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET 4
#define OLED_ADDRESS 0x3C

// RFID module pins
#define RFID_RST_PIN 9
#define RFID_SS_PIN 10

// Buzzer pin
const int BUZZER_PIN = 7;

// Allowed RFID UIDs
const char *VALID_UIDS[] = {
  "AA A2 31 C4",
  "64 7D 49 BF"
};
const byte VALID_UID_COUNT = sizeof(VALID_UIDS) / sizeof(VALID_UIDS[0]);

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
MFRC522 rfid(RFID_SS_PIN, RFID_RST_PIN);

String lastUid = "";

void drawHeader();
void showAccessResult(bool isValid);
void showUid(const String &uid);
void beep(bool isValid);
String readUid();
bool isValidUid(const String &uid);
void emitEvent(const String &uid, bool isValid);

void setup() {
  Serial.begin(9600);
  SPI.begin();
  rfid.PCD_Init();

  display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDRESS);
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);

  pinMode(BUZZER_PIN, OUTPUT);

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

void emitEvent(const String &uid, bool isValid) {
  Serial.print("EVENT:{\"uid\":\"");
  Serial.print(uid);
  Serial.print("\",\"valid\":");
  Serial.print(isValid ? "true" : "false");
  Serial.println("}");
}
