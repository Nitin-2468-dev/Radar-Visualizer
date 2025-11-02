/*
  Full Arduino sketch — Servo sweep + HC-SR04 + runtime speed control

  Wiring:
    HC-SR04:
      VCC -> 5V
      GND -> GND
      TRIG -> pin 10
      ECHO -> pin 11
    SG90 servo:
      Signal (orange) -> pin 12
      VCC (red) -> 5V  (or external 5V)
      GND (brown) -> GND  (common ground with Arduino)

  Serial protocol:
    - Output: "angle,distance\n"  (distance in cm; -1 if no echo)
    - Input:  "SPD,<ms>\n"         (set per-angle step delay to <ms> milliseconds)
    - Response: "SPD_ACK,<ms>\n"  (acknowledgement after processing SPD)
*/

#include <Servo.h>

const int TRIG_PIN = 10;
const int ECHO_PIN = 11;
const int SERVO_PIN = 12;

Servo sweepSer;

// Sweep params (can be tuned)
const int ANGLE_MIN = 0;
const int ANGLE_MAX = 180;
const int ANGLE_STEP = 1;               // degrees per measurement
volatile unsigned long STEP_DELAY_MS = 20UL; // ms to wait after moving servo (modifiable via SPD command)

// HC-SR04 timing
const unsigned long PULSE_TIMEOUT_US = 30000UL; // 30 ms timeout (~5 m ceiling)

// Simple serial command buffer
String cmdBuf = "";
const unsigned int CMD_BUF_MAX = 128;

void setup() {
  Serial.begin(115200);
  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  digitalWrite(TRIG_PIN, LOW);

  sweepSer.attach(SERVO_PIN);
  sweepSer.write(ANGLE_MIN);
  delay(200);

  Serial.println("ARDUINO_SWEEPER_READY");
}

void loop() {
  // 1) handle incoming serial bytes (non-blocking)
  handleSerialCommands();

  // 2) sweep up
  for (int a = ANGLE_MIN; a <= ANGLE_MAX; a += ANGLE_STEP) {
    doMeasurementAtAngle(a);
    // also check serial while waiting for the servo delay
    checkSerialWhileWaiting(STEP_DELAY_MS);
  }
  // 3) sweep down
  for (int a = ANGLE_MAX; a >= ANGLE_MIN; a -= ANGLE_STEP) {
    doMeasurementAtAngle(a);
    checkSerialWhileWaiting(STEP_DELAY_MS);
  }
}

// Move servo, wait small delay for settling, read ultrasonic and print
void doMeasurementAtAngle(int angle) {
  sweepSer.write(angle);
  // small settle delay handled in caller using checkSerialWhileWaiting to remain responsive
  float dist = readUltrasonicCM();
  if (dist < 0.0) {
    Serial.print(angle);
    Serial.print(',');
    Serial.println(-1);
  } else {
    Serial.print(angle);
    Serial.print(',');
    Serial.println((int)round(dist));
  }
}

// read ultrasonic sensor; returns distance in cm or -1 if timeout/no echo
float readUltrasonicCM() {
  // trigger a 10 microsecond pulse
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  unsigned long duration = pulseIn(ECHO_PIN, HIGH, PULSE_TIMEOUT_US);
  if (duration == 0UL) {
    return -1.0;
  }
  float distanceCm = (float)duration / 58.0; // approximate conversion
  return distanceCm;
}

// Non-blocking serial handling: accumulate bytes until newline, then process
void handleSerialCommands() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    // ignore carriage returns, treat newline as end-of-command
    if (c == '\r') continue;
    if (c == '\n') {
      if (cmdBuf.length() > 0) {
        processCommand(cmdBuf);
        cmdBuf = "";
      }
    } else {
      // protect from buffer overflow
      if (cmdBuf.length() < CMD_BUF_MAX) cmdBuf += c;
      else cmdBuf = ""; // drop if too long (safety)
    }
  }
}

// While waiting ms milliseconds, poll serial and process small chunks so we stay responsive.
// This replaces a single blocking delay(STEP_DELAY_MS).
void checkSerialWhileWaiting(unsigned long ms) {
  unsigned long start = millis();
  while (millis() - start < ms) {
    handleSerialCommands();
    // a tiny yield so we don't starve CPU (and let background tasks run)
    delay(1);
  }
}

// Process a single command line (without trailing newline)
void processCommand(const String &cmdLine) {
  String s = cmdLine;
  s.trim();
  if (s.length() == 0) return;

  // Simple command: SPD,<ms>
  if (s.startsWith("SPD,")) {
    String val = s.substring(4);
    val.trim();
    int ms = val.toInt();
    if (ms < 0) ms = 0;
    if (ms > 1000) ms = 1000; // clamp
    STEP_DELAY_MS = (unsigned long)ms;
    // send ack
    Serial.print("SPD_ACK,");
    Serial.println(ms);
    return;
  }

  // you may add more commands here later
  // fallback: echo unknown command for debugging
  Serial.print("UNK_CMD,");
  Serial.println(s);
}
