/**
 * ----------------------------------------------------------------------------
 * This is a MFRC522 Example By Arsalan Saleem
 * 
 * 
 *
 * NOTE: The library Uses MFRC522 Module
 * Authentication By Key A and Showing Name Postion and UID in OLED SCREEN AND Buzzer on inValid and Valid Cards
 *
 *
 */

#include <SPI.h>
#include <MFRC522.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

//Display Settings
#define OLED_RESET 4
Adafruit_SSD1306 display(OLED_RESET);


#define RST_PIN         9           // Configurable, see typical pin layout above
#define SS_PIN          10          // Configurable, see typical pin layout above

MFRC522 mfrc522(SS_PIN, RST_PIN);   // Create MFRC522 instance.
MFRC522::MIFARE_Key key;

/**
 * Initialize.
*/
const int buzzer = 7; //buzzer to arduino pin 7
String UID;
String Name;
String Position;
void setup() {
    Serial.begin(9600); // Initialize serial communications with the PC
    while (!Serial);    // Do nothing if no serial port is opened (added for Arduinos based on ATMEGA32U4)
    SPI.begin();        // Init SPI bus
    mfrc522.PCD_Init(); // Init MFRC522 card
  
    //LCD Initialization 
    display.begin(SSD1306_SWITCHCAPVCC, 0x3C);
    display.clearDisplay();
    display.display();
    display.setTextColor(WHITE); // or BLACK);
    display.setTextSize(2);
    display.setCursor(10,0); 
    display.print("RFID LOCK");
    display.display();
    
    //Key A Defined
    key.keyByte[0] = 0xAA ; 
    key.keyByte[1] = 0x01 ; 
    key.keyByte[2] = 0xFF ; 
    key.keyByte[3] = 0xFF ; 
    key.keyByte[4] = 0xFF ;
    key.keyByte[5] = 0xFF ;
   
    // Buzzer Initialization   
    pinMode(buzzer, OUTPUT);

    //Serial Display
    Serial.println(F("Scan a MIFARE Classic"));
    Serial.print(F("Authentication By Key A"));
    Serial.println();

    
}

/**
 * Main loop.
 */
void loop() {
    // Reset the loop if no new card present on the sensor/reader. This saves the entire process when idle.
    if ( ! mfrc522.PICC_IsNewCardPresent()){
        return;
    }
    // Select one of the cards
    if ( ! mfrc522.PICC_ReadCardSerial()){
       
        return;
    }

        
    if(getUID()!=UID){
      ClearData("RFID LOCK",10,0,2);
      ClearData(UID,40,0,1);
      
      UID=getUID();
      
      PrintData("UID: ",10,0,1);
      UID.toUpperCase();
      PrintData(UID,40,0,1);
     
    }

    // Show some details of the PICC (that is: the tag/card)
    
    dump_byte_array(mfrc522.uid.uidByte, mfrc522.uid.size);
    Serial.println();
    Serial.print(F("PICC type: "));
    MFRC522::PICC_Type piccType = mfrc522.PICC_GetType(mfrc522.uid.sak);
    Serial.println(mfrc522.PICC_GetTypeName(piccType));

    // Check for compatibility
    if (    piccType != MFRC522::PICC_TYPE_MIFARE_MINI
        &&  piccType != MFRC522::PICC_TYPE_MIFARE_1K
        &&  piccType != MFRC522::PICC_TYPE_MIFARE_4K) {
        Serial.println(F("This sample only works with MIFARE Classic cards."));
        return;
    }

   
    // that is: sector #9, covering block #36, 37 and Sector Trailer block #39
    byte sector       =  9;
    byte NameBlk      = 36;
    byte PositionBlk  = 37;
    byte trailerBlock = 39;
    
    MFRC522::StatusCode status;
    byte buffer[18];
    byte size = sizeof(buffer);

    // Authenticate using key A
    Serial.println(F("Authenticating using key A..."));
    status = (MFRC522::StatusCode) mfrc522.PCD_Authenticate(MFRC522::PICC_CMD_MF_AUTH_KEY_A, trailerBlock, &key, &(mfrc522.uid));
    if (status != MFRC522::STATUS_OK) {
        Serial.print(F("PCD_Authenticate() failed: "));
        Serial.println(mfrc522.GetStatusCodeName(status));
        ClearData(Name,40,10,1);
        ClearData(Position,10,20,1);
        ClearData("Name: ",10,10,1);
        PrintData("InValid",10,10,2);
        tone(buzzer, 300);delay(1000);noTone(buzzer);
        return;
    }else{
        ClearData(Name,40,10,1);
        ClearData(Position,10,20,1);
        ClearData("Name: ",10,10,1);
        ClearData("InValid",10,10,2);
        tone(buzzer, 100);delay(100);noTone(buzzer);
    }

    // Show the whole sector as it currently is
    Serial.println(F("Current data in sector:"));
    mfrc522.PICC_DumpMifareClassicSectorToSerial(&(mfrc522.uid), &key, sector);
    Serial.println();

    // Read data from the block
    Serial.print(F("Reading data from block ")); Serial.print(NameBlk);
    Serial.println(F(" ..."));
    status = (MFRC522::StatusCode) mfrc522.MIFARE_Read(NameBlk, buffer, &size);
    if (status != MFRC522::STATUS_OK) {
        Serial.print(F("MIFARE_Read() failed: "));
        Serial.println(mfrc522.GetStatusCodeName(status));
        
    }
    Serial.print(F("Data in block ")); Serial.print(NameBlk); Serial.println(F(":"));
    dump_byte_array(buffer, 16); Serial.println();

      ClearData(Name,40,10,1);
      Name = dump_byte_array_string(buffer, 16);
      PrintData("Name: ",10,10,1);
      PrintData(Name,40,10,1);
      Serial.println();
   
     // Read data from the block
    Serial.print(F("Reading data from block ")); Serial.print(PositionBlk);
    Serial.println(F(" ..."));
    status = (MFRC522::StatusCode) mfrc522.MIFARE_Read(PositionBlk, buffer, &size);
    if (status != MFRC522::STATUS_OK) {
        Serial.print(F("MIFARE_Read() failed: "));
        Serial.println(mfrc522.GetStatusCodeName(status));
    }
    Serial.print(F("Data in block ")); Serial.print(PositionBlk); Serial.println(F(":"));

      ClearData(Position,10,20,1);
      Position = dump_byte_array_string(buffer, 16);
      PrintData(Position,10,20,1);
      Serial.println();
  

    
    // Halt PICC
    mfrc522.PICC_HaltA();
    // Stop encryption on PCD
    mfrc522.PCD_StopCrypto1();
    

 
   
}

/**
 * Helper routine to dump a byte array as hex values to Serial.
 */
void dump_byte_array(byte *buffer, byte bufferSize) {
    for (byte i = 0; i < bufferSize; i++) {
       // Serial.print(buffer[i] < 0x10 ? " 0" : " ");
       // Serial.print(buffer[i], HEX);
        String stringOne = String(buffer[i],HEX); 
         Serial.print((char)buffer[i]);
        
    }
}
String dump_byte_array_string(byte *buffer, byte bufferSize) {
    String stringOne;
    for (byte i = 0; i < bufferSize; i++) {
       // Serial.print(buffer[i] < 0x10 ? " 0" : " ");
       // Serial.print(buffer[i], HEX);
        // stringOne = String(buffer[i],HEX); 
         Serial.print((char)buffer[i]);
         stringOne.concat((char)buffer[i]); 
    }
    return stringOne;
}

String getUID(){
  //Converting UID to Hex
  String content= "";
  byte letter;
  for (byte i = 0; i < mfrc522.uid.size; i++) 
  {
    
     content.concat(String(mfrc522.uid.uidByte[i] < 0x10 ? " 0" : " "));
     content.concat(String(mfrc522.uid.uidByte[i], HEX));
  }  
   return content.substring(1);
}
void ClearData(String Data,int x, int y,int textsize){
    display.setTextColor(BLACK); // or BLACK);
    display.setTextSize(textsize);
    display.setCursor(x,y); 
    display.print(Data);
    display.display();
}

void PrintData(String Data,int x, int y,int textsize){
    display.setTextColor(WHITE); // or BLACK);
    display.setTextSize(textsize);
    display.setCursor(x,y); 
    display.print(Data);
    display.display();
}
