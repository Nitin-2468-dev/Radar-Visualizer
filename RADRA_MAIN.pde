/**
 Radar Visualizer — Onion-skin fixed
 - Adds reliable sweep-complete detection and draws previous sweeps (layers)
 - Keeps prior features: interpolation, T/G text sizing, controls overlay, etc.
*/

import processing.serial.*;

// --- Serial ---
Serial myPort;
String connectedPortName = "";
String SERIAL_PORT_NAME = "";
int SERIAL_BAUD = 115200;

// --- Scan parameters ---
final int MAX_ANGLE = 180;
float maxDistanceCm = 150.0;
float[] smoothedDistances = new float[MAX_ANGLE + 1];
float smoothingAlpha = 0.18;

// --- Display interpolation ---
boolean interpEnabled = true;
float interpFactor = 0.18; // interpolation speed
float[] displayDistances = new float[MAX_ANGLE + 1];

// --- Pings & intensity ---
class Ping { int angle; float dist; int life; Ping(int a,float d){angle=a;dist=d;life=255;} }
ArrayList<Ping> pings = new ArrayList<Ping>();
float[] intensity = new float[MAX_ANGLE + 1];
float intensityDecay = 0.95;
int maxPingsLimit = 1200;

// --- UI & state ---
boolean radarView = true;
boolean glowEnabled = true;
boolean heatEnabled = true;
boolean darkMode = true;
boolean showFullCircle = true;
boolean onionSkin = false;
boolean serialPlotterMode = false;
boolean showHelpModal = false;
boolean showControlsOverlay = true;

int leftMargin = 40, rightMargin = 40, topMargin = 90, bottomMargin = 90;
int centerX, centerY;
float radiusPx;
int rings = 5;

// --- last readings ---
int lastAngle = 0;
float lastDistance = 0;
float displayedAngle = 0;
float armLerp = 0.22;
final float defaultArmLerp = 0.22;

// --- Arduino hardware speed ---
int arduinoStepDelayMs = 20;
final int defaultArduinoStepDelayMs = 20;

// --- Defaults ---
final float defaultMaxDistanceCm = 150.0;

// --- Angle mapping / calibration ---
int angleOffset = 0;
boolean angleFlip = false;

// --- Display sector calibration ---
int displayMinAngle = 0;
int displayMaxAngle = 180;

// --- Onion skin layers (fixed) ---
// each layer is a float[MAX_ANGLE+1] snapshot of displayDistances (use -1 for missing)
ArrayList<float[]> onionLayers = new ArrayList<float[]>();
int onionDepth = 12;
int onionSnapshotEvery = 1; // not used now; we snapshot on sweep complete

// --- Serial-plot buffer ---
int plotBufferSize = 1024;
float[] plotBuffer;
int plotWriteIndex = 0;

// --- Last positions trail ---
int lastPosDepth = 80;
ArrayList<PVector> lastPositions = new ArrayList<PVector>();

// --- Text scaling & spacing ---
float textScale = 1.0;      // use T / G to change reliably
final float textScaleStep = 0.08;
final float textScaleMin = 0.5;
final float textScaleMax = 2.5;

// --- Misc ---
PFont mainFont;
int plotPointSkip = 6;

// --- Sweep detection helpers ---
int prevLastAngle = 0;
int sweepDirection = 1; // 1 = increasing, -1 = decreasing (detected from incoming angles)

void setup() {
  size(1200, 820, P2D);
  surface.setResizable(true);
  smooth(8);

  String[] fonts = PFont.list();
  String chosen = (fonts.length > 0)?fonts[0]:"SansSerif";
  mainFont = createFont(chosen, 14);
  textFont(mainFont);

  for (int i=0;i<=MAX_ANGLE;i++){
    smoothedDistances[i] = -1;
    displayDistances[i] = -1;
    intensity[i] = 0;
  }

  plotBuffer = new float[plotBufferSize];
  for (int i=0;i<plotBufferSize;i++) plotBuffer[i] = Float.NaN;

  computeLayout();
  println("Ready. Press 'c' to connect. '? or /' for help. 'i' toggles interpolation.");
  printHelpConsole();
}

void draw() {
  computeLayout();
  if (darkMode) background(12); else background(236);

  // draw background & onion layers
  if (onionSkin) drawOnionBackground(); else drawSubtleBackground();

  drawUI();

  if (serialPlotterMode) drawSerialPlotter();
  else if (radarView) drawRadar();
  else drawCartesian();

  // cleanup pings
  synchronized(pings) {
    for (int i = pings.size()-1; i >= 0; i--) {
      Ping p = pings.get(i);
      p.life -= 7;
      if (p.life <= 0) pings.remove(i);
    }
  }

  for (int a=0;a<=MAX_ANGLE;a++) intensity[a] *= intensityDecay;

  // interpolation
  if (interpEnabled) {
    for (int a=0;a<=MAX_ANGLE;a++) {
      float target = smoothedDistances[a];
      if (target < 0) displayDistances[a] = lerp(displayDistances[a], -1, interpFactor);
      else {
        if (displayDistances[a] < 0) displayDistances[a] = target;
        else displayDistances[a] = lerp(displayDistances[a], target, interpFactor);
      }
    }
  } else {
    arrayCopy(smoothedDistances, displayDistances);
  }

  // sweep arm smoothing
  displayedAngle = lerp(displayedAngle, lastAngle + angleOffset, armLerp);

  // detect sweep wrap (completed pass) and snapshot
  detectSweepAndSnapshot();

  drawLastPositions();

  if (showControlsOverlay) drawControlsOverlay();
  if (showHelpModal) drawHelpModal();
}

// ---------------- Onion: snapshot detection & drawing ----------------
void detectSweepAndSnapshot() {
  // Update sweepDirection based on recent change
  int diff = lastAngle - prevLastAngle;
  if (abs(diff) > 1) {
    sweepDirection = (diff > 0) ? 1 : -1;
  }

  // Detect wrap-around: previous was high, now low = one pass finished.
  // Works for both directions. Use thresholds to avoid false triggers on jitter.
  if (sweepDirection == 1) {
    // increasing: trigger when prev near high and last is small (e.g. prev>150 && last<20)
    if (prevLastAngle > 150 && lastAngle < 20) {
      addOnionSnapshot();
    }
  } else {
    // decreasing sweep: prev near low and last high
    if (prevLastAngle < 20 && lastAngle > 150) {
      addOnionSnapshot();
    }
  }

  prevLastAngle = lastAngle;
}

void addOnionSnapshot() {
  // copy displayDistances into snapshot
  float[] snap = new float[MAX_ANGLE + 1];
  arrayCopy(displayDistances, snap);

  // optionally clip snapshot to visible sector when not full circle
  if (!showFullCircle) {
    for (int a=0; a<=MAX_ANGLE; a++) {
      if (!isAngleInRange(a)) snap[a] = -1;
    }
  }

  // push to front
  onionLayers.add(0, snap);
  // limit size
  while (onionLayers.size() > onionDepth) onionLayers.remove(onionLayers.size()-1);

  // console feedback
  println("Onion snapshot added (layers=" + onionLayers.size() + ")");
}

void drawOnionBackground() {
  pushMatrix();
  translate(centerX, centerY);

  // draw faint circular guides first
  noFill();
  strokeWeight(1);
  for (int rIdx = 1; rIdx <= rings; rIdx++) {
    float r = radiusPx * rIdx / rings;
    stroke(darkMode ? color(30) : color(200));
    ellipse(0,0,r*2,r*2);
  }

  // draw each layer as polyline (older layers drawn first -> faded)
  for (int li = onionLayers.size()-1; li >= 0; li--) {
    float[] L = onionLayers.get(li);
    float ageFactor = map(li, 0, max(1, onionLayers.size()-1), 1.0, 0.15); // 1.0 newest -> smaller oldest
    float alphaBase = 100 * ageFactor;
    strokeWeight( (li==0) ? 1.8 : 1.2 ); // newest slightly bolder
    noFill();

    beginShape();
    for (int a=0; a<=MAX_ANGLE; a++) {
      float d = L[a];
      if (d < 0 || d > maxDistanceCm) { endShape(); beginShape(); continue; }
      PVector p = polarToXY(a, d);
      float hue = map(d, 0, maxDistanceCm, 160, 20);
      stroke(hue, 200, 255, alphaBase);
      vertex(p.x, p.y);
    }
    endShape();

    // also draw faint points for this layer
    noStroke();
    for (int a=0; a<=MAX_ANGLE; a+=2) {
      float d = L[a];
      if (d < 0 || d > maxDistanceCm) continue;
      PVector p = polarToXY(a, d);
      float hue = map(d, 0, maxDistanceCm, 160, 20);
      fill(colorForTheme(hue), alphaBase * 0.9);
      ellipse(p.x, p.y, 2.5 * ageFactor, 2.5 * ageFactor);
    }
  }

  popMatrix();
}

// ---------------- UI / layout & drawing ----------------
void computeLayout(){
  int availW = width - leftMargin - rightMargin;
  int availH = height - topMargin - bottomMargin;
  radiusPx = min(availW, availH) * 0.46;
  centerX = leftMargin + availW/2;
  centerY = topMargin + availH/2;
}

void drawSubtleBackground(){
  noStroke();
  if (darkMode) {
    for (int i=0;i<6;i++){
      float t = i/5.0;
      fill(8 + i*2, 8 + i*2, 10 + i*2, 10 + (int)(t*30));
      ellipse(width/2, height/2, width*(1.6 - t*0.3), height*(1.6 - t*0.3));
    }
  } else {
    for (int i=0;i<6;i++){
      float t = i/5.0;
      fill(236 - i*6, 236 - i*6, 236 - i*6, 18 + (int)(t*20));
      ellipse(width/2, height/2, width*(1.6 - t*0.3), height*(1.6 - t*0.3));
    }
  }
}

void drawUI(){
  float base = max(12, width/80);
  float txSize = base * textScale;
  textSize(txSize);
  textLeading(txSize * 1.18);

  int pad = (int)(8 * textScale);
  int panelW = (int)(520 * textScale), panelH = (int)(140 * textScale), panelX = 8, panelY = 8;
  noStroke();
  if (darkMode) fill(8,8,8,200); else fill(255,255,255,230);
  rect(panelX, panelY, panelW, panelH, 8);

  fill(darkMode?220:22);
  textAlign(LEFT, TOP);
  text("Last: angle=" + lastAngle + "°, dist=" + nf(lastDistance,0,1) + " cm", panelX+pad, panelY+pad);
  text("Mode: " + (serialPlotterMode ? "Serial-Plotter (press 'p')" : (radarView ? "Radar (press 'v')" : "Cartesian (press 'v')")), panelX+pad, panelY+pad + (txSize+4));
  text("Serial: " + (myPort==null ? "disconnected (press 'c')" : "connected to " + connectedPortName), panelX+pad, panelY+pad + (txSize+4)*2);
  text("Range: 0 - " + int(maxDistanceCm) + " cm ( '[' / ']' )", panelX+pad, panelY+pad + (txSize+4)*3);

  text("Full circle: " + showFullCircle + "   Onion: " + onionSkin + "   Layers: " + onionLayers.size(), panelX+pad + 260*textScale, panelY+pad);
  text("Interp: " + (interpEnabled ? "on" : "off") + " (i to toggle)", panelX+pad + 260*textScale, panelY+pad + (txSize+4));
  text("Visual arm lerp: " + nf(armLerp,0,3) + "  (',' '.' )", panelX+pad + 260*textScale, panelY+pad + (txSize+4)*2);
  text("Arduino STEP_DELAY_MS: " + arduinoStepDelayMs + " ms  ('-' '=')", panelX+pad + 260*textScale, panelY+pad + (txSize+4)*3);

  textAlign(RIGHT, BOTTOM);
  fill(darkMode?180:80);
  text("Text scale: " + nf(textScale, 0, 2) + "   0:reset   s: save PNG   r: reset data   c:connect   v:toggle view", width-12, height-12);
}

void drawControlsOverlay(){
  float txSize = max(11, width/110) * textScale;
  textSize(txSize);
  textLeading(txSize * 1.18);
  int pad = (int)(10 * textScale);
  int w = (int)(360 * textScale), h = (int)(200 * textScale);
  int x = 12, y = height - h - 12;
  noStroke();
  if (darkMode) fill(8,8,8,160); else fill(255,255,255,200);
  rect(x, y, w, h, 8);
  fill(darkMode?220:30);
  textAlign(LEFT, TOP);
  String[] lines = {
    "Controls (press '?' or '/' for full help):",
    " c: connect    v: toggle view    p: serial-plotter",
    " k: onion skin  f: full/sector   q/w: set sector min/max",
    " , . : visual arm slower/faster    i: toggle interpolation",
    " - = : hw step delay (send SPD,<ms>)    0: reset defaults",
    " g: glow  h: heat  m: dark/light   s: save PNG  r: reset data",
    " T / G : increase / decrease UI text size"
  };
  int yy = y + pad;
  float lineH = txSize * 1.18 + 4;
  for (String L : lines) {
    text(L, x + pad, yy);
    yy += lineH;
  }
}

void drawHelpModal(){
  float txBase = 14 * textScale;
  textSize(txBase);
  textLeading(txBase * 1.22);

  int w = min(920, width - 120);
  int h = min(620, height - 180);
  int x = (width - w)/2;
  int y = (height - h)/2;
  noStroke();
  fill(darkMode?8:250, 230);
  rect(x, y, w, h, 12);
  fill(darkMode?220:20);
  textAlign(LEFT, TOP);

  String help = 
    "Detailed Controls (toggle with '?' or '/'): \n\n" +
    "c : connect/disconnect serial\n" +
    "v : toggle view (radar/cartesian)\n" +
    "p : toggle Serial-Plotter mode\n" +
    "k : toggle onion skin (persistent layered sweeps)\n" +
    "f : toggle full-circle vs limited sector\n" +
    "q : capture current angle as display MIN\n" +
    "w : capture current angle as display MAX\n" +
    "A / Z : nudge angleOffset +/- 1 deg\n" +
    "I : toggle angleFlip (mirror mapping)\n" +
    ", / . : slower / faster displayed arm (visual quality)\n" +
    "i : toggle interpolation (display smoothing)\n" +
    "- / = : decrease / increase Arduino STEP_DELAY_MS (sends SPD,<ms>)\n" +
    "T / G : increase / decrease UI text size\n" +
    "0 : reset all settings to defaults\n" +
    "s : save PNG     r : reset data\n\n" +
    "Tip: If you see missing sectors, use A/Z to nudge angleOffset or 'I' to flip. Use 'f' + q/w to set visible sector.";
  text(help, x + 18, y + 18, w - 36, h - 36);
}

// ---------------- Radar / Cartesian / Plot ----------------
void drawRadar(){
  pushMatrix();
  translate(centerX, centerY);

  // rings & labels
  strokeWeight(1.0);
  for (int i=1;i<=rings;i++){
    float r = radiusPx * i / rings;
    stroke(darkMode?color(70):color(170));
    noFill();
    ellipse(0,0, r*2, r*2);
    fill(darkMode?150:90);
    textAlign(LEFT, CENTER);
    textSize((12 * textScale));
    text(nf(maxDistanceCm * i / rings, 0, 0) + " cm", r + 8, -6);
  }

  // center crosshair
  stroke(darkMode?60:220);
  line(-6,0,6,0); line(0,-6,0,6);
  noStroke();
  fill(darkMode?255:0);
  ellipse(0,0,6,6);

  // smoothed/ interpolated curve
  strokeWeight(2.0);
  noFill();
  beginShape();
  for (int a=0;a<=MAX_ANGLE;a++){
    float d = displayDistances[a];
    if (d < 0 || d > maxDistanceCm) { endShape(); beginShape(); continue; }
    PVector p = polarToXY(a, d);
    float hue = map(d, 0, maxDistanceCm, 160, 20);
    stroke(hue, 200, 255, 120);
    vertex(p.x, p.y);
  }
  endShape();

  if (glowEnabled) blendMode(ADD);

  synchronized(pings) {
    for (int i=0;i<pings.size();i++){
      Ping p = pings.get(i);
      if (p.dist < 0 || p.dist > maxDistanceCm) continue;
      if (!showFullCircle && !isAngleInRange(p.angle)) continue;
      PVector pp = polarToXY(p.angle, p.dist);
      float hue = map(p.dist, 0, maxDistanceCm, 160, 20);
      for (int layer=0; layer<3; layer++){
        float s = map(p.dist,0,maxDistanceCm,8,2)*(1+layer*1.6);
        int alpha = int(p.life*(1.0 - layer*0.4));
        fill(colorForTheme(hue), alpha);
        noStroke();
        ellipse(pp.x, pp.y, s, s);
      }
    }
  }

  if (glowEnabled) blendMode(BLEND);

  if (heatEnabled) {
    noStroke();
    for (int a=0;a<=MAX_ANGLE;a++){
      float inten = constrain(intensity[a],0,255);
      if (inten < 8) continue;
      if (!showFullCircle && !isAngleInRange(a)) continue;
      float d = displayDistances[a];
      if (d < 0) continue;
      PVector hp = polarToXY(a, d);
      fill(colorForTheme(map(d,0,maxDistanceCm,160,0)), inten*0.18);
      ellipse(hp.x, hp.y, map(inten,0,255,2,16), map(inten,0,255,2,16));
    }
  }

  if (!showFullCircle) {
    float pulse = 40 + 30 * sin(frameCount * 0.12);
    int highlightColor = darkMode ? color(135, 230, 160, 200) : color(40, 120, 60, 200);
    strokeWeight(3.0);
    for (int edge = 0; edge < 2; edge++) {
      int a = (edge==0)?displayMinAngle:displayMaxAngle;
      float ar = radians(a);
      stroke(highlightColor);
      float inner = radiusPx*0.02;
      line(cos(ar)*inner, -sin(ar)*inner, cos(ar)*radiusPx, -sin(ar)*radiusPx);
      noStroke();
      fill(highlightColor);
      ellipse(cos(ar)*radiusPx, -sin(ar)*radiusPx, 8 + edge*2 + pulse*0.02, 8 + edge*2 + pulse*0.02);
    }
  }

  float armToShow = displayedAngle;
  if (!showFullCircle) armToShow = constrain(armToShow, displayMinAngle, displayMaxAngle);
  strokeWeight(3);
  stroke(darkMode?color(160,240,200):color(40,100,60));
  float aR = radians(armToShow);
  line(0,0, cos(aR)*radiusPx, -sin(aR)*radiusPx);

  popMatrix();
}

void drawCartesian(){
  int gx = leftMargin, gy = topMargin, gw = width - leftMargin - rightMargin, gh = height - topMargin - bottomMargin;
  pushMatrix();
  translate(gx, gy);
  if (darkMode) fill(0,0,0,60); else fill(255,255,255,140);
  noStroke();
  rect(-8, -12, gw+16, gh+24);

  stroke(darkMode?80:140);
  strokeWeight(1.2);
  line(0, gh, gw, gh);
  line(0, 0, 0, gh);

  fill(darkMode?170:60);
  textAlign(LEFT, BOTTOM);
  text("Angle →", gw - 80, gh + 22);
  textAlign(RIGHT, CENTER);
  text("Distance (cm)", -10, gh/2);

  strokeWeight(3);
  stroke(darkMode?color(10,160,140):color(10,90,120));
  noFill();
  beginShape();
  for (int a=0;a<=MAX_ANGLE;a++){
    float d = displayDistances[a];
    if (d < 0) { endShape(); beginShape(); continue; }
    float x = map(a, 0, MAX_ANGLE, 0, gw);
    float y = gh - map(constrain(d,0,maxDistanceCm), 0, maxDistanceCm, 0, gh);
    curveVertex(x, y);
  }
  endShape();

  noStroke();
  for (int a=0;a<=MAX_ANGLE;a++){
    float d = displayDistances[a];
    if (d < 0) continue;
    float x = map(a, 0, MAX_ANGLE, 0, gw);
    float y = gh - map(constrain(d,0,maxDistanceCm), 0, maxDistanceCm, 0, gh);
    float hue = map(d, 0, maxDistanceCm, 160, 20);
    fill(colorForTheme(hue), 200);
    ellipse(x, y, 4, 4);
  }

  popMatrix();
}

void drawSerialPlotter(){
  int gx = leftMargin, gy = topMargin, gw = width - leftMargin - rightMargin, gh = height - topMargin - bottomMargin;
  pushMatrix();
  translate(gx, gy);
  noStroke();
  if (darkMode) fill(6,6,6,120); else fill(255,255,255,180);
  rect(-8, -12, gw+16, gh+24);

  stroke(darkMode?90:150);
  strokeWeight(1.2);
  line(0, gh, gw, gy+gh); line(0, 0, 0, gh);
  stroke(darkMode?50:180); strokeWeight(0.6);
  for (int i=1;i<5;i++){
    float y = map(i,0,5,gh,0);
    line(0, y, gw, y);
  }

  noFill();
  strokeWeight(2.2);
  stroke(darkMode?color(160,220,200):color(30,110,90));
  beginShape();
  for (int i=0;i<plotBufferSize;i++){
    int idx = (plotWriteIndex + i) % plotBufferSize;
    float val = plotBuffer[idx];
    float x = map(i, 0, plotBufferSize-1, 0, gw);
    if (!Float.isNaN(val)) {
      float y = gh - map(constrain(val,0,maxDistanceCm), 0, maxDistanceCm, 0, gh);
      vertex(x, y);
    } else {
      endShape(); beginShape();
    }
  }
  endShape();

  noStroke();
  for (int i=0;i<plotBufferSize;i+=plotPointSkip){
    int idx = (plotWriteIndex + i) % plotBufferSize;
    float val = plotBuffer[idx];
    if (Float.isNaN(val)) continue;
    float x = map(i, 0, plotBufferSize-1, 0, gw);
    float y = gh - map(constrain(val,0,maxDistanceCm), 0, maxDistanceCm, 0, gh);
    fill(darkMode?color(180,255,190):color(40,120,80));
    ellipse(x, y, 3, 3);
  }
  popMatrix();
}

// ---------------- Serial parsing ----------------
void serialEvent(Serial port){
  String raw = port.readStringUntil('\n');
  if (raw == null) return;
  raw = raw.trim();
  if (raw.length() == 0) return;

  if (raw.startsWith("SPD_ACK") || raw.startsWith("ARDUINO_SWEEPER_READY") || raw.startsWith("UNK_CMD")) {
    println("Arduino -> " + raw);
    return;
  }

  String[] parts = splitTokens(raw, ",; \t");
  if (parts.length < 2) return;
  try {
    int inA = int(float(parts[0]));
    float d = float(parts[1]);

    int mapped = mapAngle(inA);
    mapped = constrain(mapped, 0, MAX_ANGLE);
    lastAngle = mapped;
    lastDistance = d;

    float prev = smoothedDistances[mapped];
    if (prev < 0) prev = d;
    smoothedDistances[mapped] = smoothingAlpha * d + (1 - smoothingAlpha) * prev;

    if (d > 0 && d <= maxDistanceCm * 1.1) {
      intensity[mapped] = min(255, intensity[mapped] + 80);
      synchronized(pings){
        pings.add(new Ping(mapped, d));
        if (pings.size() > maxPingsLimit) pings.remove(0);
      }
    }

    plotBuffer[plotWriteIndex] = d;
    plotWriteIndex = (plotWriteIndex + 1) % plotBufferSize;

    PVector pos = polarToXY(mapped, d);
    addLastPosition(pos);

  } catch (Exception e) {
    // ignore malformed
  }
}

int mapAngle(int inAngle){
  int a = inAngle + angleOffset;
  if (angleFlip) a = 180 - a;
  while (a < 0) a += 180;
  while (a > 180) a -= 180;
  return a;
}

// ---------------- keyboard / controls ----------------
void keyPressed(){
  if (key == '?' || key == '/') { showHelpModal = !showHelpModal; return; }

  if (key == 'T' || key == 't') { textScale = min(textScaleMax, textScale + textScaleStep); println("textScale -> " + nf(textScale,0,2)); return; }
  if (key == 'G' || key == 'g') { textScale = max(textScaleMin, textScale - textScaleStep); println("textScale -> " + nf(textScale,0,2)); return; }

  if (key == '+' || key == '=') { textScale = min(textScaleMax, textScale + textScaleStep); println("textScale -> " + nf(textScale,0,2)); return; }
  if (key == '-' && keyEvent != null && keyEvent.isControlDown()) { textScale = max(textScaleMin, textScale - textScaleStep); println("textScale -> " + nf(textScale,0,2)); return; }

  if (key == 'v' || key == 'V') { radarView = !radarView; serialPlotterMode = false; return; }
  if (key == 'p' || key == 'P') { serialPlotterMode = !serialPlotterMode; return; }
  if (key == 's' || key == 'S') { saveFrame("radar-####.png"); return; }
  if (key == 'r' || key == 'R') { resetData(); return; }
  if (key == 'c' || key == 'C') { tryConnect(); return; }

  if (key == '[') { maxDistanceCm = max(20, maxDistanceCm - 10); println("Range -> " + int(maxDistanceCm)); return; }
  if (key == ']') { maxDistanceCm = min(1000, maxDistanceCm + 10); println("Range -> " + int(maxDistanceCm)); return; }

  if (key == ',' ) { armLerp = max(0.02, armLerp - 0.03); println("armLerp -> " + nf(armLerp,0,3)); return; }
  if (key == '.' ) { armLerp = min(0.98, armLerp + 0.03); println("armLerp -> " + nf(armLerp,0,3)); return; }

  if (key == '-' && !(keyEvent != null && keyEvent.isControlDown())) { arduinoStepDelayMs = max(0, arduinoStepDelayMs - 10); sendArduinoSpeed(); println("arduinoStepDelayMs -> " + arduinoStepDelayMs); return; }
  if (key == '=' ) { arduinoStepDelayMs = min(1000, arduinoStepDelayMs + 10); sendArduinoSpeed(); println("arduinoStepDelayMs -> " + arduinoStepDelayMs); return; }

  if (key == 'g' || key == 'G') { glowEnabled = !glowEnabled; println("Glow -> " + glowEnabled); return; }
  if (key == 'h' || key == 'H') { heatEnabled = !heatEnabled; println("Heat -> " + heatEnabled); return; }

  if (key == 'm' || key == 'M') { darkMode = !darkMode; colorMode(HSB, 360, 255, 255, 255); println("Dark mode -> " + darkMode); return; }
  if (key == 'k' || key == 'K') { onionSkin = !onionSkin; 
    // if turning ON and layers empty, snapshot immediately to give feedback
    if (onionSkin && onionLayers.size()==0) addOnionSnapshot();
    // if turning OFF we preserve layers; if you prefer clearing on toggle-off uncomment below:
    // if (!onionSkin) onionLayers.clear();
    println("Onion -> " + onionSkin); return; 
  }
  if (key == 'f' || key == 'F') { showFullCircle = !showFullCircle; println("Full circle -> " + showFullCircle); return; }

  if (key == 'q' || key == 'Q') { displayMinAngle = lastAngle; println("displayMinAngle -> " + displayMinAngle); blinkHighlight(displayMinAngle); return; }
  if (key == 'w' || key == 'W') { displayMaxAngle = lastAngle; println("displayMaxAngle -> " + displayMaxAngle); blinkHighlight(displayMaxAngle); return; }

  if (key == 'A') { angleOffset += 1; println("angleOffset -> " + angleOffset); return; }
  if (key == 'Z') { angleOffset -= 1; println("angleOffset -> " + angleOffset); return; }
  if (key == 'I') { angleFlip = !angleFlip; println("angleFlip -> " + angleFlip); return; }

  if (key == 'i' || key == 'I') { interpEnabled = !interpEnabled; println("Interpolation -> " + interpEnabled); return; }

  if (key == '0') { resetAllToDefaults(); return; }

  if (key == 'H') printHelpConsole();
}

void resetData(){
  for (int i=0;i<=MAX_ANGLE;i++){ smoothedDistances[i] = -1; displayDistances[i] = -1; intensity[i] = 0; }
  synchronized(pings){ pings.clear(); }
  lastPositions.clear();
  onionLayers.clear();
  for (int i=0;i<plotBufferSize;i++) plotBuffer[i] = Float.NaN;
  plotWriteIndex = 0;
  println("Data reset.");
}

void resetAllToDefaults(){
  maxDistanceCm = defaultMaxDistanceCm;
  armLerp = defaultArmLerp;
  arduinoStepDelayMs = defaultArduinoStepDelayMs;
  showFullCircle = true;
  displayMinAngle = 0;
  displayMaxAngle = 180;
  darkMode = true;
  angleOffset = 0;
  angleFlip = false;
  onionSkin = false;
  serialPlotterMode = false;
  interpEnabled = true;
  textScale = 1.0;
  lastPositions.clear();
  onionLayers.clear();
  sendArduinoSpeed();
  println("All defaults restored.");
}

void tryConnect(){
  if (myPort != null){ myPort.stop(); myPort = null; connectedPortName=""; println("Disconnected."); return; }
  String[] ports = Serial.list();
  if (SERIAL_PORT_NAME != null && SERIAL_PORT_NAME.length() > 0){
    for (String p:ports) if (p.indexOf(SERIAL_PORT_NAME) >= 0) { openPort(p); return; }
    println("Specified port not found.");
  }
  if (ports.length == 0){ println("No serial ports found."); return; }
  openPort(ports[0]);
}

void openPort(String portName){
  try {
    myPort = new Serial(this, portName, SERIAL_BAUD);
    myPort.clear();
    myPort.bufferUntil('\n');
    connectedPortName = portName;
    colorMode(HSB, 360, 255, 255, 255);
    println("Connected to " + portName + " at " + SERIAL_BAUD);
    sendArduinoSpeed();
  } catch (Exception e) {
    println("Failed to open " + portName + " : " + e);
    myPort = null; connectedPortName = "";
  }
}

void sendArduinoSpeed(){
  if (myPort == null){ println("No serial port to send SPD"); return; }
  String cmd = "SPD," + arduinoStepDelayMs + "\n";
  myPort.write(cmd);
  println("Sent -> " + cmd.trim());
}

boolean isAngleInRange(int a){
  if (displayMinAngle <= displayMaxAngle) return a >= displayMinAngle && a <= displayMaxAngle;
  return a >= displayMinAngle || a <= displayMaxAngle;
}

int colorForTheme(float hue){
  if (darkMode) return color(hue, 200, 255);
  else return color(hue, 160, 190);
}

void blinkHighlight(int angle){
  synchronized(pings){
    for (int i=0;i<6;i++){
      pings.add(new Ping(angle, maxDistanceCm * (0.2f + 0.2f*i)));
    }
    if (pings.size() > maxPingsLimit) pings.subList(0, pings.size() - maxPingsLimit).clear();
  }
}

void addLastPosition(PVector p) {
  if (p == null) return;
  lastPositions.add(0, p.copy());
  if (lastPositions.size() > lastPosDepth) lastPositions.remove(lastPositions.size()-1);
}

void drawLastPositions() {
  pushMatrix();
  translate(0,0);
  noStroke();
  for (int i=0;i<lastPositions.size();i++){
    PVector p = lastPositions.get(i);
    float a = map(i, 0, lastPositions.size()-1, 255, 20);
    fill(100, 255, 160, a * (darkMode ? 1.0 : 0.8));
    ellipse(p.x, p.y, max(2, 6 - i*0.06), max(2, 6 - i*0.06));
  }
  popMatrix();
}

void printHelpConsole(){
  println("Controls summary:");
  println(" c : connect/disconnect serial");
  println(" v : toggle view (radar/cartesian)");
  println(" p : toggle Serial-Plotter mode");
  println(" k : toggle onion skin");
  println(" f : toggle full-circle vs limited sector");
  println(" q : capture current angle as display MIN");
  println(" w : capture current angle as display MAX");
  println(" A / Z : nudge angleOffset +/- 1 deg");
  println(" I : toggle angleFlip");
  println(" , . : slower / faster displayed arm (visual quality)");
  println(" i : toggle interpolation (display smoothing)");
  println(" - = : decrease / increase Arduino STEP_DELAY_MS (sends SPD,<ms>)");
  println(" T / G : increase / decrease UI text size");
  println(" 0 : reset to defaults");
  println(" s : save PNG    r : reset data");
  println(" ? or / : toggle help modal (also prints console help)");
}

// -------------------- polarToXY --------------------
PVector polarToXY(int angleDeg, float distanceCm) {
  float r = map(constrain(distanceCm, 0, maxDistanceCm), 0, maxDistanceCm, 0, radiusPx);
  float ang = radians(angleDeg);
  float x = cos(ang) * r;
  float y = -sin(ang) * r;
  return new PVector(centerX + x - centerX, centerY + y - centerY).add(new PVector(0,0));
}
