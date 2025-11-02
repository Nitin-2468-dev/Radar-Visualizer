# RADRA_MAIN — Ultrasonic Radar Visualizer

**RADRA_MAIN** is a Processing (Java) visualization for a single-axis ultrasonic scanner (HC-SR04 + servo).
It reads `angle,distance` lines from serial and shows a polished radar, Cartesian and serial-plotter view, with features like interpolation, onion-skin (previous sweeps), heat/glow, last-positions trail, interactive controls and Arduino hardware speed control.

---

## Table of contents

1. Features
2. Hardware wiring (HC-SR04 + SG90)
3. Serial protocol (input & commands)
4. Quick start (install & run)
5. Controls / Keys (complete)
6. UI features explained
7. Troubleshooting & tips
8. Customization & dev notes
9. License & credits

---

## 1 — Features

* Radar and Cartesian visualizations, plus a Serial Plotter mode.
* Interpolation / smoothing of displayed distances.
* Visual sweep arm with adjustable follow speed (visual quality).
* Onion-skin: store and render previous sweeps as faded layers.
* Heat/glow and ping trails for nicer visuals.
* Last positions trail (recent measured points).
* Change UI text size (T / G or +/-), light/dark mode, adjustable range.
* Send hardware speed command to Arduino (`SPD,<ms>\n`) to change servo step delay.
* Works with any Arduino/servo that sends `angle,distance` lines (0–180, cm).

---

## 2 — Hardware wiring

**HC-SR04**

| Sensor | Arduino |
| ------ | ------: |
| VCC    |      5V |
| GND    |     GND |
| TRIG   |  pin 10 |
| ECHO   |  pin 11 |

**SG90 (servo)**

| Wire            | Arduino |
| --------------- | ------: |
| Orange (Signal) |  pin 12 |
| Red (VCC)       |      5V |
| Brown (GND)     |     GND |

> ⚠️ IMPORTANT: servo and HC-SR04 **must share common ground** with the Arduino.

---

## 3 — Serial protocol

### Input (from Arduino → PC)

Each line must be ASCII text ending with `\n` and contain angle and distance:

```
<angle>,<distance>\n
```

* `angle`: integer or float, degrees (0–180)
* `distance`: float, centimeters (out-of-range can be `-1` or large/NaN — the visualizer ignores invalid distances)

**Example**

```
72,29.4
0,120.0
```

### Commands (from PC → Arduino)

The app sends hardware control commands over the same serial port:

* `SPD,<ms>\n` — set Arduino servo step delay (milliseconds). The Arduino sketch should parse `SPD,<number>` and apply it. The app sends this when you press `-` or `=` or when connecting.

* The Arduino may send back `SPD_ACK` or other text messages (the app logs them).

---

## 4 — Quick start

1. Install Processing 3.x or 4.x.
2. Open the RADRA_MAIN sketch file in Processing (replace the sketch with the provided `.pde` file versions in the repo).
3. Connect your Arduino to the PC via USB and upload an Arduino sketch that:

   * sweeps the servo and pings HC-SR04,
   * prints `angle,distance\n` to Serial at each measurement,
   * optionally accepts `SPD,<ms>` commands to change sweep speed.
     *(A sample Arduino sketch is provided separately / recommended.)*
4. In the app press `c` to connect (auto connects to the first serial port if none configured). The available ports are printed in the console.
5. Use the UI keys below to change views, speed and appearance.

---

## 5 — Controls / Keys (summary)

> Shortcut keys are case-insensitive unless noted.

### Connection & basic

* `c` — connect / disconnect serial
* `v` — toggle view (Radar / Cartesian)
* `p` — toggle Serial-Plotter mode
* `s` — save PNG of the canvas
* `r` — reset data
* `0` — reset all settings to defaults

### Visual & UI controls

* `,` (comma) — slower visual arm (visual lerp ↓)
* `.` (period) — faster visual arm (visual lerp ↑)
* `T` — increase UI text size
* `G` — decrease UI text size
* `+` / `=` — increase text scale (alternative)
* `Ctrl` + `-` — decrease text scale (alternative)

### Data / smoothing

* `i` — toggle interpolation (display smoothing on/off)
* `[` / `]` — decrease / increase max distance range (±10 cm steps)

### Onion skin / sectors / heat

* `k` — toggle onion skin (show previous sweeps)
* `f` — toggle full circle vs limited sector
* `q` — set the current angle as display **MIN** of sector
* `w` — set the current angle as display **MAX** of sector
* `g` — toggle glow
* `h` — toggle heat

### Arduino hardware speed control

* `-` — decrease `STEP_DELAY_MS` (sends `SPD,<ms>\n` to Arduino)
* `=` — increase `STEP_DELAY_MS` (sends `SPD,<ms>\n` to Arduino)

### Calibration & misc

* `A` / `Z` — nudge `angleOffset` ±1° (useful if you see missing sectors)
* `I` — toggle `angleFlip` (mirror mapping)
* `?` or `/` — toggle help modal (detailed control list)
* `H` — print help in console

---

## 6 — UI features explained

* **Visual arm lerp** — controls how fast the displayed sweep arm follows the incoming angle. This is purely visual; it does not change hardware speed. Use `,` and `.` to change.

* **Arduino STEP_DELAY_MS (hardware)** — controls the servo stepping delay on the Arduino. The app sends `SPD,<ms>\n` when you press `-` or `=`; the Arduino must implement receiving and applying this.

* **Interpolation** — when `i` is on, the app smoothly interpolates the displayed distances each frame (reduces jitter). When off, the display copies raw smoothed distances immediately.

* **Onion skin** — the app detects when a sweep completes (angle wraps from near 180 → 0 or the reverse) and automatically adds a snapshot of the most recent sweep into a fading layer stack. Useful for visualizing persistent objects across passes. Toggle with `k`. You can also clear onion layers by resetting data (`r`) or resetting all defaults `0`.

* **Serial Plotter mode** — simple plot (like Arduino IDE Serial Plotter) that draws the most recent stream of distances left→right.

* **Last positions trail** — shows the latest N measured points as a small fading trail.

---

## 7 — Troubleshooting & tips

* **No serial ports listed**: ensure Arduino is connected and drivers are installed. Reboot PC or replug USB if necessary.

* **App prints `ConcurrentModificationException` (older versions)**: fixed in current build by synchronizing access to shared ping lists.

* **Missing / broken sectors (no output between 120–180)**:

  * Check Arduino: is it sending angles in the expected 0–180 range? The app normalizes angles; if the servo uses a different mapping, use `A`/`Z` to nudge `angleOffset` or press `I` to flip mapping.
  * Open the help modal (`?`) and use `q`/`w` to set visible sector when using limited sector mode.

* **Text too small / overlapping**: press `T` to increase text scale or `G` to decrease. The UI is responsive to window resize.

* **If the sweep arm “lags” hardware**: increase visual lerp speed (press `.`) to make the visual arm follow incoming angles more quickly. To change the actual servo speed, press `-`/`=` to send `SPD` values to Arduino.

* **Onion-skin not showing**: ensure `k` is toggled on and that sweeps are completing (i.e., angle wraps 180→0 or reverse). The app snapshots on sweep completion; if your hardware never wraps (e.g. servo limited to part of range), toggle full circle `f` or manually press `k` after a pass.

---

## 8 — Customization & dev notes

* **Serial format**: any device that prints `angle,distance\n` will work (angles in degrees, distances in cm).

* **Arduino integration**: implement an `SPD,<ms>` command handler so the app can control hardware sweep speed. The Arduino may ACK with `SPD_ACK` for visibility.

* **UI tweaks**:

  * On-screen sliders (mouse) can be added for `armLerp`, `interpFactor`, `STEP_DELAY_MS`.
  * Add clickable buttons for T/G text size, onion snapshot clearing, or toggles.

* **Performance**: large onion layer depth or large ping lists can affect framerate. Default limits are conservative.

---

## 9 — License & credits

* This project is provided as-is for experimentation and prototyping. Use, modify, and redistribute under the MIT License (include a copy if you redistribute).
* Credits: original visual design and iterative fixes by the project author (you), with enhancements for interpolation, onion-skin, and UI polish.

---

## Example Arduino snippet (pseudo)

(The app expects these strings. Put this in your README or upload a full sketch with your repo.)

```cpp
// PSEUDO (Arduino):
// Send lines like: Serial.println(String(angle) + "," + String(distance));
// Listen for: SPD,<ms> and set step delay accordingly.

void loop() {
  // measure distance, angle...
  Serial.print(angle);
  Serial.print(",");
  Serial.println(distance_cm);
  delay(step_delay_ms); // hardware sweep pacing
}

// Serial command handling (in loop):
if (Serial.available()) {
  String s = Serial.readStringUntil('\n');
  s.trim();
  if (s.startsWith("SPD,")) {
    int ms = s.substring(4).toInt();
    step_delay_ms = constrain(ms, 0, 1000);
    Serial.println("SPD_ACK," + String(step_delay_ms));
  }
}
```

---

If you want, I can:

* Add a clickable UI (sliders & buttons) for arm lerp, interpolation and STEP_DELAY_MS.
* Write a complete Arduino sketch that implements sweeping, HC-SR04 distance measurement and `SPD` command handling.
* Add an export option that saves onion snapshots as PNG files or a CSV log.

Which do you want next?
