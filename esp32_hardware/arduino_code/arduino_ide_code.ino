#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <driver/i2s.h>
#include "arduinoFFT.h"
#include <math.h>

// --- BLE SETUP ---
#define SERVICE_UUID           "4fafc201-1fb5-459e-8fcc-c5c9c331914b" 
#define CHARACTERISTIC_UUID_TX "beb5483e-36e1-4688-b7f5-ea07361b26a8" 

BLEServer *pServer = NULL;
BLECharacteristic *pTxCharacteristic;
bool deviceConnected = false;

// --- MICROPHONE SETUP ---
#define I2S_WS 15
#define I2S_SCK 14
#define I2S_SD 32
#define I2S_PORT I2S_NUM_0

// --- FFT MATH SETUP ---
#define SAMPLES 1024              
#define SAMPLING_FREQUENCY 8000   
double vReal[SAMPLES];
double vImag[SAMPLES];
int32_t sBuffer[SAMPLES]; 

ArduinoFFT<double> FFT = ArduinoFFT<double>(vReal, vImag, SAMPLES, SAMPLING_FREQUENCY);

// --- VOLUME THRESHOLD ---
// Minimum magnitude required to register as a valid "Note On" rather than background noise
const double NOISE_THRESHOLD = 50000.0; 
bool isNoteCurrentlyPlaying = false;

// --- BLE CALLBACKS ---
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      Serial.println("App Connected! Listening to Microphone...");
    };
    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("App Disconnected!");
      pServer->getAdvertising()->start();
    }
};

void i2s_install() {
  const i2s_config_t i2s_config = {
    .mode = i2s_mode_t(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = SAMPLING_FREQUENCY,
    .bits_per_sample = i2s_bits_per_sample_t(32), 
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = i2s_comm_format_t(I2S_COMM_FORMAT_STAND_I2S),
    .intr_alloc_flags = 0,
    .dma_buf_count = 8,
    .dma_buf_len = SAMPLES,
    .use_apll = false
  };
  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
}

void i2s_setpin() {
  const i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_SCK,
    .ws_io_num = I2S_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_SD
  };
  i2s_set_pin(I2S_PORT, &pin_config);
}

void setup() {
  Serial.begin(115200);

  i2s_install();
  i2s_setpin();
  i2s_start(I2S_PORT);

  // Device name matches Flutter scanner
  BLEDevice::init("Phase_Shift_Mic"); 
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pService = pServer->createService(SERVICE_UUID);

  pTxCharacteristic = pService->createCharacteristic(
                        CHARACTERISTIC_UUID_TX,
                        BLECharacteristic::PROPERTY_NOTIFY
                      );
  pTxCharacteristic->addDescriptor(new BLE2902());

  pService->start();
  pServer->getAdvertising()->start();
  Serial.println("Tuner is ready. Waiting for app...");
}

void loop() {
  if (deviceConnected) {
    size_t bytesIn = 0;
    esp_err_t result = i2s_read(I2S_PORT, &sBuffer, sizeof(sBuffer), &bytesIn, portMAX_DELAY);

    if (result == ESP_OK) {
      if (sBuffer[0] == 0 && sBuffer[100] == 0) {
         Serial.println("WARNING: Microphone is dead silent. Check wires!");
         delay(1000);
         return; 
      }

      // 1. Fill the FFT arrays
      for (uint16_t i = 0; i < SAMPLES; i++) {
        vReal[i] = (double)(sBuffer[i] >> 14); 
        vImag[i] = 0.0;        
      }

      // 2. Perform the Math
      FFT.windowing(FFTWindow::Hamming, FFTDirection::Forward);
      FFT.compute(FFTDirection::Forward);
      FFT.complexToMagnitude();

      // 3. Find the loudest pitch and its magnitude (volume)
      double peakFrequency = 0;
      double peakMagnitude = 0;
      FFT.majorPeak(&peakFrequency, &peakMagnitude);

      // 4. Process and send over BLE
      // Check if the sound is loud enough to be considered a real note
      if (peakMagnitude > NOISE_THRESHOLD && peakFrequency > 20.0 && peakFrequency < 4000.0) {
        
        isNoteCurrentlyPlaying = true;

        // Calculate exact continuous MIDI pitch
        double exactMidi = 69.0 + 12.0 * log2(peakFrequency / 440.0);
        
        // Round to nearest integer for standard MIDI note
        int midiNote = round(exactMidi);
        
        // Ensure standard bounds (0-127)
        if (midiNote < 0) midiNote = 0;
        if (midiNote > 127) midiNote = 127;

        // Calculate deviation in cents (-50 to +50)
        int cents = round((exactMidi - midiNote) * 100.0);
        if (cents < -50) cents = -50;
        if (cents > 50) cents = 50;

        // Map magnitude to a 0-127 MIDI Velocity (Rough approximation)
        int velocity = map((long)peakMagnitude, (long)NOISE_THRESHOLD, 500000, 50, 127);
        if (velocity > 127) velocity = 127;

        // Pack the 4 bytes for Flutter: [NoteOn(1), MidiNote, Velocity, Cents]
        uint8_t payload[4];
        payload[0] = 1; 
        payload[1] = (uint8_t)midiNote;
        payload[2] = (uint8_t)velocity;
        
        // Typecast signed integer to uint8_t. Flutter's `.toSigned(8)` handles decoding it back to negative.
        payload[3] = (uint8_t)((int8_t)cents); 

        pTxCharacteristic->setValue(payload, 4);
        pTxCharacteristic->notify();

        Serial.printf("Note ON: Freq: %.1f Hz | MIDI: %d | Cents: %d | Vel: %d\n", peakFrequency, midiNote, cents, velocity);

      } else if (isNoteCurrentlyPlaying) {
        // If the sound falls below threshold, send a "Note Off" command to clear the app screen
        isNoteCurrentlyPlaying = false;
        
        uint8_t payload[4] = {0, 0, 0, 0}; // NoteOn = 0
        pTxCharacteristic->setValue(payload, 4);
        pTxCharacteristic->notify();
        
        Serial.println("Note OFF sent.");
      }
    }
    delay(50); // Small delay to prevent flooding BLE buffer
  }
}
