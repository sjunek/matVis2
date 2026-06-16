# MatVis ImageJ Plugin — Build Instructions

## Prerequisites

- **Java JDK 11+** (e.g. Eclipse Temurin / Adoptium)
- **Maven 3.8+** (or use the included wrapper below)
- **Fiji** (https://fiji.sc) for running the plugin

## Quick build

```bash
# from the imagej-plugin/ directory:
mvn package -DskipTests
```

The output JAR is at `target/matvis-imagej-1.0.0.jar`.

## Install into Fiji

Copy the JAR into Fiji's plugin folder:

```
cp target/matvis-imagej-1.0.0.jar /path/to/Fiji.app/plugins/
```

On Windows: drag-and-drop the JAR into `Fiji.app\plugins\`.

Then restart Fiji. The plugin appears under **Plugins ▶ MatVis ▶ Navigate**.

Alternatively, in Fiji: **Plugins ▶ Install Plugin...** → select the JAR.

## Run without installing (drag & drop)

In Fiji: drag the JAR onto the Fiji window. When prompted whether to install,
choose **No** (just runs once).

## Manual build (no Maven)

If Maven is unavailable:

1. Download `ij.jar` from https://imagej.net/ij/upgrade/ij.jar
2. Compile:
   ```
   javac -cp ij.jar -d target/classes \
       src/main/java/matvis/*.java \
       src/main/java/matvis/ui/*.java
   ```
3. Package:
   ```
   jar cfm target/matvis-imagej-1.0.0.jar \
       src/main/resources/META-INF/MANIFEST.MF \
       -C target/classes .
   ```

## Usage

1. Open any image or hyperstack in ImageJ/Fiji.
2. Run **Plugins ▶ MatVis ▶ Navigate** (or drag the JAR onto Fiji).
3. The MatVis window opens, showing:
   - **Per-dimension sliders** (position + zoom range + play animation)
   - **Full image** with white crosshair and red zoom rectangle
   - **Zoom window** showing the cropped sub-region
   - **Contrast panel** with interactive histogram (draggable min/max/gamma)
   - **1-D profile plots** (enable per-dimension via the ☑ checkbox)

## Features

| Feature | Description |
|---------|-------------|
| Dimension sliders | Position + zoom range per dim; ◀▶ step; ▶ / \|▶\| / ▶▶ play modes |
| Image display | Full slice with white crosshair + red dashed zoom rect; drag to move position |
| Zoom display | Cropped sub-region scaled to fill window; own crosshair + rubber-band sub-zoom |
| Contrast modes | Global / Image / Zoom / Manual |
| Histogram | Interactive; drag red/blue lines (min/max); drag gamma dot vertically |
| Gamma | 0.1–5.0; drag dot in histogram or type value |
| Colormaps | 25 built-in: Grays, Fire, Viridis, Plasma, Inferno, Magma, Jet, … |
| Projection | max / min / mean / std along any non-XY dimension |
| Flip | Flip X / Flip Y buttons |
| 1-D profiles | One plot per enabled dimension; draggable position line; rubber-band zoom |
| Scroll wheel | Zoom in/out centred on cursor in image window |
| Right-click | Reset zoom to full range |
