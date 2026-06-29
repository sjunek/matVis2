package matvis;

import ij.ImagePlus;
import ij.gui.Roi;
import ij.plugin.frame.RoiManager;
import ij.process.ImageProcessor;
import ij.process.ImageStatistics;
import ij.measure.Measurements;

import java.awt.*;
import java.awt.image.BufferedImage;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Central model for the MatVis plugin.
 *
 * Dimensions are indexed as:
 *   0 = X  (image width)
 *   1 = Y  (image height)
 *   2 = Z  (slices)
 *   3 = C  (channels)
 *   4 = T  (frames)
 *
 * "navDims" = dims 2..4 that appear as sliders (only if size > 1).
 * X and Y always appear (they control the zoom rectangle + crosshair).
 *
 * All positions are 0-based internally; ImageJ stack indices are 1-based
 * and converted at the boundary.
 */
public class MatVisController {

    // ---- data source --------------------------------------------------------
    private final ImagePlus imp;

    // ---- dimension metadata ------------------------------------------------
    /** Sizes: [W, H, nZ, nC, nT]. */
    public final int[] dimSizes;
    public final String[] dimNames = {"X", "Y", "Z", "C", "T"};
    /** Number of "real" dims (size > 1, including X and Y). */
    public final int nDims;
    /** Indices into the full 5-dim array that are active (size > 1 or X/Y). */
    public final int[] activeDimIndices;

    // ---- navigation state --------------------------------------------------
    /** Current position per active dim (0-based). */
    private final int[] currPos;
    /** Zoom range [min, max] per active dim (0-based, inclusive). */
    private final int[] zoomMin;
    private final int[] zoomMax;

    // ---- display axes ------------------------------------------------------
    /** Active-dim index used as the horizontal (X) display axis. Default = 0 (global X). */
    private int xDisplayActiveDim;
    /** Active-dim index used as the vertical (Y) display axis. Default = 1 (global Y). */
    private int yDisplayActiveDim;

    // Projection along a nav dim (index into activeDimIndices), -1 = none.
    private int projActiveDim = -1;
    private String projFun = "none"; // "max"|"min"|"mean"|"std"|"tile"
    private boolean flipX = false;
    private boolean flipY = false;

    // ---- contrast ----------------------------------------------------------
    private double globalMin, globalMax;
    private double contrastMin, contrastMax;
    private double gamma = 1.0;
    /** "Global" | "Image" | "Zoom" | "Manual" */
    private String contrastMode = "Global";
    private int colormapIdx = 0;

    // ---- plot state --------------------------------------------------------
    /** Which active dims show a 1-D profile plot. */
    private final boolean[] showPlot;
    /** Lock plot x-axis to zoom range. */
    private final boolean[] plotLock;

    // ---- colormaps ---------------------------------------------------------
    public static final String[] COLORMAP_NAMES = {
        "Grays", "Fire", "Red Hot", "Ice", "Spectrum",
        "Red", "Green", "Blue", "Cyan", "Magenta", "Yellow",
        "Viridis", "Plasma", "Inferno", "Magma",
        "Hot", "Cool", "Spring", "Summer", "Autumn", "Winter",
        "Jet", "HSV", "Parula", "Turbo"
    };

    // cache for rendered images
    private float[][] cachedImageSlice;
    private float[][] cachedZoomSlice;

    // global histogram (1024 bins, computed once at init for percentile use)
    private long[] globalHistogram;
    private static final int HIST_BINS = 1024;

    // percentile-based contrast bounds (applied in Global/Image/Zoom modes)
    private double percLow  = 0.1;   // %  (0 = pure min)
    private double percHigh = 99.9;  // %  (100 = pure max)

    // RGB mode: active-dim index whose first ≤3 entries map to R/G/B, -1 = off
    private int rgbActiveDim = -1;

    // plot y-axis scaling: auto (follow displayed contrast) or fixed min/max
    private boolean plotAutoScale = true;
    private double plotScaleMin, plotScaleMax;

    // ---- plot local-averaging mode -----------------------------------------
    // Single-pixel profiles can instead average over an XY neighborhood around
    // the current position, mirroring the Matlab avgMode:
    //   0 = single pixel, 1 = 3x3, 2 = 5x5, 3 = full zoom XY region.
    public static final int PLOT_AVG_PIXEL = 0;
    public static final int PLOT_AVG_3X3   = 1;
    public static final int PLOT_AVG_5X5   = 2;
    public static final int PLOT_AVG_ZOOM  = 3;
    /** Human-readable labels for the plot-averaging modes (indexed by mode). */
    public static final String[] PLOT_AVG_NAMES = {"Pixel", "3×3", "5×5", "Zoom region"};
    private int plotAvgMode = PLOT_AVG_PIXEL;

    // location of the brightest pixel, found during computeGlobalMinMax
    private int brightX, brightY, brightZ, brightC, brightT;

    // ---- ROI state (backed by Fiji's RoiManager) ----------------------------
    private boolean showRois = true;
    private int selectedRoiIdx = -1;

    /**
     * Shared ROI color palette: ROI k (index in the RoiManager) is always
     * drawn with ROI_COLORS[k % length] — both as outline in the image/zoom
     * displays and as trace color in the plots.
     */
    public static final Color[] ROI_COLORS = {
        new Color(30, 100, 220),  // blue
        new Color(220, 60, 50),   // red
        new Color(40, 160, 60),   // green
        new Color(200, 60, 200),  // magenta
        new Color(240, 150, 20),  // orange
        new Color(0, 170, 170),   // teal
        new Color(140, 90, 40),   // brown
        new Color(240, 220, 40),  // yellow
    };

    /** Color assigned to ROI index k (consistent across views). */
    public static Color roiColor(int k) { return ROI_COLORS[k % ROI_COLORS.length]; }

    // ---- listeners ---------------------------------------------------------
    private final List<MatVisListener> listeners = new ArrayList<>();

    // ========================================================================
    public MatVisController(ImagePlus imp) {
        this.imp = imp;

        int W = imp.getWidth();
        int H = imp.getHeight();
        int nZ = imp.getNSlices();
        int nC = imp.getNChannels();
        int nT = imp.getNFrames();
        dimSizes = new int[]{W, H, nZ, nC, nT};

        // Build active-dims list: X and Y always active; Z/C/T if size > 1
        List<Integer> active = new ArrayList<>();
        active.add(0); // X
        active.add(1); // Y
        if (nZ > 1) active.add(2);
        if (nC > 1) active.add(3);
        if (nT > 1) active.add(4);
        nDims = active.size();
        activeDimIndices = active.stream().mapToInt(i -> i).toArray();

        currPos = new int[nDims];
        zoomMin = new int[nDims];
        zoomMax = new int[nDims];
        showPlot = new boolean[nDims];
        plotLock = new boolean[nDims];

        for (int i = 0; i < nDims; i++) {
            int sz = dimSizes[activeDimIndices[i]];
            currPos[i] = 0;
            zoomMin[i] = 0;
            zoomMax[i] = sz - 1;
            // Show plots by default for all non-spatial dims (not X=0 or Y=1)
            int gd = activeDimIndices[i];
            showPlot[i] = (gd != 0 && gd != 1);
        }

        // Default display dims: active-dim index for global X (0) and Y (1).
        // They are always the first two entries because the constructor adds them first.
        xDisplayActiveDim = 0;
        yDisplayActiveDim = 1;

        computeGlobalMinMax();
        contrastMin = globalMin;
        contrastMax = globalMax;
        plotScaleMin = globalMin;
        plotScaleMax = globalMax;

        // Start at the brightest pixel found during the global scan.
        for (int i = 0; i < nDims; i++) {
            switch (activeDimIndices[i]) {
                case 0: currPos[i] = brightX; break;
                case 1: currPos[i] = brightY; break;
                case 2: currPos[i] = brightZ; break;
                case 3: currPos[i] = brightC; break;
                case 4: currPos[i] = brightT; break;
            }
        }
    }

    // ---- global stats ------------------------------------------------------
    private void computeGlobalMinMax() {
        // Pass 1: fast min/max via ImageJ processor cache
        int n = imp.getStackSize();
        double mn = Double.MAX_VALUE, mx = -Double.MAX_VALUE;
        for (int s = 1; s <= n; s++) {
            ImageProcessor ip = imp.getStack().getProcessor(s);
            ip.resetMinAndMax();
            mn = Math.min(mn, ip.getMin());
            mx = Math.max(mx, ip.getMax());
        }
        globalMin = mn; globalMax = mx;
        if (globalMin == globalMax) globalMax = globalMin + 1;

        // Pass 2: build global histogram for percentile computation, and
        // locate the brightest pixel (used as the initial position).
        globalHistogram = new long[HIST_BINS];
        double range = globalMax - globalMin;
        float bestVal = Float.NEGATIVE_INFINITY;
        int bestX = 0, bestY = 0, bestSlice = 1;
        for (int s = 1; s <= n; s++) {
            ImageProcessor ip = imp.getStack().getProcessor(s);
            int W = ip.getWidth(), H = ip.getHeight();
            for (int y = 0; y < H; y++) {
                for (int x = 0; x < W; x++) {
                    float v = ip.getf(x, y);
                    int b = (int) ((v - globalMin) / range * HIST_BINS);
                    globalHistogram[Math.max(0, Math.min(HIST_BINS - 1, b))]++;
                    if (v > bestVal) { bestVal = v; bestX = x; bestY = y; bestSlice = s; }
                }
            }
        }
        brightX = bestX;
        brightY = bestY;
        int[] czt = imp.convertIndexToPosition(bestSlice); // 1-based {c, z, t}
        brightC = czt[0] - 1;
        brightZ = czt[1] - 1;
        brightT = czt[2] - 1;
    }

    /** Percentile from the pre-built global histogram (fast, O(HIST_BINS)). */
    private double globalPercentile(double perc) {
        long total = 0;
        for (long c : globalHistogram) total += c;
        long target = Math.max(0, Math.min(total - 1, (long) (perc / 100.0 * total)));
        long cum = 0;
        double range = globalMax - globalMin;
        for (int b = 0; b < HIST_BINS; b++) {
            cum += globalHistogram[b];
            if (cum > target)
                return globalMin + (b + 0.5) / HIST_BINS * range;
        }
        return globalMax;
    }

    /** Percentile from a 2-D slice array (sorts a copy — O(N log N)). */
    private double slicePercentile(float[][] data, double perc) {
        int total = 0;
        for (float[] row : data) total += row.length;
        if (total == 0) return 0;
        float[] flat = new float[total];
        int idx = 0;
        for (float[] row : data) { System.arraycopy(row, 0, flat, idx, row.length); idx += row.length; }
        Arrays.sort(flat);
        int k = (int) Math.round(perc / 100.0 * (total - 1));
        return flat[Math.max(0, Math.min(total - 1, k))];
    }

    // ---- data extraction ---------------------------------------------------

    /**
     * Returns the current 2-D slice as float[row][col], applying projection
     * if configured. Caches result for histogram use.
     */
    public float[][] getCurrentSlice() {
        cachedImageSlice = extractSlice(false);
        return cachedImageSlice;
    }

    /**
     * Returns the zoomed 2-D region (displayX/displayY zoom range) as float[row][col].
     * In tile mode the zoom crop doesn't apply, so the full tiled image is returned.
     */
    public float[][] getZoomSlice() {
        if ("tile".equals(projFun) && isNativePlane()) {
            cachedZoomSlice = cachedImageSlice != null ? cachedImageSlice : getCurrentSlice();
            return cachedZoomSlice;
        }
        float[][] full = cachedImageSlice != null ? cachedImageSlice : extractSlice(false);
        int x0 = zoomMin[xDisplayActiveDim], x1 = zoomMax[xDisplayActiveDim];
        int y0 = zoomMin[yDisplayActiveDim], y1 = zoomMax[yDisplayActiveDim];
        int rows = y1 - y0 + 1, cols = x1 - x0 + 1;
        float[][] zoom = new float[rows][cols];
        for (int r = 0; r < rows; r++)
            System.arraycopy(full[y0 + r], x0, zoom[r], 0, cols);
        cachedZoomSlice = zoom;
        return zoom;
    }

    /** Index of globalDim d in activeDimIndices array (fallback = 0). */
    private int activeDim(int globalDim) {
        for (int i = 0; i < nDims; i++)
            if (activeDimIndices[i] == globalDim) return i;
        return 0;
    }

    /** True when the display axes are the native image X (0) and Y (1) dims. */
    private boolean isNativePlane() {
        return activeDimIndices[xDisplayActiveDim] == 0
            && activeDimIndices[yDisplayActiveDim] == 1;
    }

    private float[][] extractSlice(boolean forceNoProj) {
        int W = getActiveDimSize(xDisplayActiveDim);
        int H = getActiveDimSize(yDisplayActiveDim);
        int z = getNavCurrPos(2), c = getNavCurrPos(3), t = getNavCurrPos(4);

        // Projection only makes sense on the native X-Y image plane
        if (!forceNoProj && isNativePlane() && projActiveDim >= 0 && !projFun.equals("none")) {
            return extractProjected(z, c, t, W, H);
        }

        // Fast path: native X-Y plane
        if (isNativePlane()) {
            int stackIdx = imp.getStackIndex(c + 1, z + 1, t + 1);
            ImageProcessor ip = imp.getStack().getProcessor(stackIdx);
            float[][] data = new float[H][W];
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                    data[y][x] = ip.getf(x, y);
            applyFlip(data, W, H);
            return data;
        }

        // Generic path: any two active dims as display axes
        float[][] data = new float[H][W];
        int[] pos = Arrays.copyOf(currPos, nDims);
        for (int iy = 0; iy < H; iy++) {
            pos[yDisplayActiveDim] = iy;
            for (int ix = 0; ix < W; ix++) {
                pos[xDisplayActiveDim] = ix;
                data[iy][ix] = getValueAt(pos);
            }
        }
        applyFlip(data, W, H);
        return data;
    }

    /** Read the pixel value at the given per-active-dim position array. */
    private float getValueAt(int[] pos) {
        int xp = 0, yp = 0, z = 0, c = 0, t = 0;
        for (int i = 0; i < nDims; i++) {
            int gd = activeDimIndices[i];
            int p  = pos[i];
            if      (gd == 0) xp = p;
            else if (gd == 1) yp = p;
            else if (gd == 2) z  = p;
            else if (gd == 3) c  = p;
            else if (gd == 4) t  = p;
        }
        return imp.getStack().getProcessor(imp.getStackIndex(c + 1, z + 1, t + 1)).getf(xp, yp);
    }

    private float[][] extractProjected(int z0, int c0, int t0, int W, int H) {
        // ---- tile projection -----------------------------------------------
        if ("tile".equals(projFun)) {
            int globalProjDim = activeDimIndices[projActiveDim];
            int N  = dimSizes[globalProjDim];
            int nC = (int) Math.ceil(Math.sqrt(N));
            int nR = (int) Math.ceil((double) N / nC);
            float[][] tiled = new float[H * nR][W * nC];
            for (float[] row : tiled) Arrays.fill(row, (float) globalMin);
            for (int k = 0; k < N; k++) {
                int z = globalProjDim == 2 ? k : z0;
                int c = globalProjDim == 3 ? k : c0;
                int t = globalProjDim == 4 ? k : t0;
                ImageProcessor ip = imp.getStack().getProcessor(
                        imp.getStackIndex(c + 1, z + 1, t + 1));
                int rowOff = (k / nC) * H;
                int colOff = (k % nC) * W;
                for (int y = 0; y < H; y++)
                    for (int x = 0; x < W; x++)
                        tiled[rowOff + y][colOff + x] = ip.getf(x, y);
            }
            applyFlip(tiled, W * nC, H * nR);
            return tiled;
        }

        // ---- statistical projections (max/min/mean/std/var) ----------------
        int globalProjDim = activeDimIndices[projActiveDim];
        int projSize = dimSizes[globalProjDim];

        float[][] acc = null;
        float[][] acc2 = null; // for std/var
        int count = projSize;

        for (int p = 0; p < projSize; p++) {
            int z = globalProjDim == 2 ? p : z0;
            int c = globalProjDim == 3 ? p : c0;
            int t = globalProjDim == 4 ? p : t0;
            int stackIdx = imp.getStackIndex(c + 1, z + 1, t + 1);
            ImageProcessor ip = imp.getStack().getProcessor(stackIdx);

            if (acc == null) {
                acc = new float[H][W];
                if (projFun.equals("std") || projFun.equals("var"))
                    acc2 = new float[H][W];
                if (projFun.equals("max") || projFun.equals("min")) {
                    for (int y = 0; y < H; y++)
                        for (int x = 0; x < W; x++)
                            acc[y][x] = ip.getf(x, y);
                    continue;
                }
            }

            for (int y = 0; y < H; y++) {
                for (int x = 0; x < W; x++) {
                    float v = ip.getf(x, y);
                    switch (projFun) {
                        case "max": acc[y][x] = Math.max(acc[y][x], v); break;
                        case "min": acc[y][x] = Math.min(acc[y][x], v); break;
                        default:    // mean, std, var
                            acc[y][x] += v;
                            if (acc2 != null) acc2[y][x] += v * v;
                            break;
                    }
                }
            }
        }
        if (acc == null) return new float[H][W];

        if (projFun.equals("mean") || projFun.equals("std") || projFun.equals("var")) {
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++) {
                    acc[y][x] /= count;
                    if (acc2 != null) {
                        float mean = acc[y][x];
                        float var = acc2[y][x] / count - mean * mean;
                        acc[y][x] = projFun.equals("std") ? (float) Math.sqrt(Math.max(0, var)) : var;
                    }
                }
        }
        applyFlip(acc, W, H);
        return acc;
    }

    private void applyFlip(float[][] data, int W, int H) {
        if (flipX) {
            for (float[] row : data) {
                for (int x = 0; x < W / 2; x++) {
                    float tmp = row[x]; row[x] = row[W - 1 - x]; row[W - 1 - x] = tmp;
                }
            }
        }
        if (flipY) {
            for (int y = 0; y < H / 2; y++) {
                float[] tmp = data[y]; data[y] = data[H - 1 - y]; data[H - 1 - y] = tmp;
            }
        }
    }

    /** Position of a global dimension (0=X,1=Y,2=Z,3=C,4=T), 0-based. */
    private int getNavCurrPos(int globalDim) {
        for (int i = 0; i < nDims; i++)
            if (activeDimIndices[i] == globalDim) return currPos[i];
        return 0;
    }

    // ---- profile extraction ------------------------------------------------

    /**
     * Returns a 1-D profile along active dim [activeDimIdx] at the current
     * position. Length = dimSize of that dimension.
     *
     * When {@link #getPlotAvgMode()} is not {@code PLOT_AVG_PIXEL}, the value at
     * each step is the mean over an XY neighborhood around the current X/Y
     * position (3×3, 5×5, or the full zoom rectangle). Only the non-profile
     * axes are widened — e.g. an X profile averages over a Y band but still
     * varies along X. This mirrors the Matlab avgMode behaviour.
     */
    public float[] getProfile(int activeDimIdx) {
        int globalDim = activeDimIndices[activeDimIdx];
        int sz = dimSizes[globalDim];
        float[] profile = new float[sz];

        int z0 = getNavCurrPos(2);
        int c0 = getNavCurrPos(3);
        int t0 = getNavCurrPos(4);

        // If an ROI is selected, nav-dim profiles average over the ROI pixels.
        java.awt.Point[] roiPts = null;
        if (globalDim >= 2) {
            Roi roi = getSelectedRoi();
            if (roi != null) roiPts = roiPoints(roi);
        }

        // Plot-averaging neighborhood in native image X/Y (single pixel in
        // PLOT_AVG_PIXEL mode). The profile axis itself is never widened.
        int[] xr = avgRange(0);
        int[] yr = avgRange(1);

        for (int p = 0; p < sz; p++) {
            int z = globalDim == 2 ? p : z0;
            int c = globalDim == 3 ? p : c0;
            int t = globalDim == 4 ? p : t0;

            if (globalDim == 0) {
                // X profile: vary x at column p, average over the Y band
                ImageProcessor ip = imp.getStack().getProcessor(imp.getStackIndex(c0 + 1, z0 + 1, t0 + 1));
                profile[p] = meanOverNeighborhood(ip, p, p, yr[0], yr[1]);
            } else if (globalDim == 1) {
                // Y profile: vary y at row p, average over the X band
                ImageProcessor ip = imp.getStack().getProcessor(imp.getStackIndex(c0 + 1, z0 + 1, t0 + 1));
                profile[p] = meanOverNeighborhood(ip, xr[0], xr[1], p, p);
            } else {
                ImageProcessor ip = imp.getStack().getProcessor(imp.getStackIndex(c + 1, z + 1, t + 1));
                if (roiPts != null) {
                    double sum = 0;
                    for (java.awt.Point pt : roiPts) sum += ip.getf(pt.x, pt.y);
                    profile[p] = (float) (sum / roiPts.length);
                } else {
                    profile[p] = meanOverNeighborhood(ip, xr[0], xr[1], yr[0], yr[1]);
                }
            }
        }
        return profile;
    }

    /**
     * Inclusive [min,max] index range of the plot-averaging neighborhood along
     * native dim {@code globalXY} (0 = X, 1 = Y), clamped to the image bounds.
     * In PLOT_AVG_PIXEL mode this is the single current position.
     */
    private int[] avgRange(int globalXY) {
        int size = dimSizes[globalXY];
        if (plotAvgMode == PLOT_AVG_ZOOM) {
            int ad = activeDim(globalXY);
            return new int[]{ zoomMin[ad], zoomMax[ad] };
        }
        int hw = plotAvgMode; // 0 (pixel), 1 (3x3) or 2 (5x5)
        int c  = getNavCurrPos(globalXY);
        return new int[]{ Math.max(0, c - hw), Math.min(size - 1, c + hw) };
    }

    /** Mean of ip over the inclusive pixel rectangle [x0..x1] × [y0..y1]. */
    private static float meanOverNeighborhood(ImageProcessor ip, int x0, int x1, int y0, int y1) {
        if (x0 == x1 && y0 == y1) return ip.getf(x0, y0);
        double sum = 0;
        int n = 0;
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++) { sum += ip.getf(x, y); n++; }
        return n > 0 ? (float) (sum / n) : 0f;
    }

    /**
     * In-bounds contained points of an ROI, subsampled to ≤~5000 for speed.
     * Returns null if the ROI covers no valid pixels.
     */
    private java.awt.Point[] roiPoints(Roi roi) {
        java.awt.Point[] all = roi.getContainedPoints();
        java.util.List<java.awt.Point> kept = new ArrayList<>();
        int stride = Math.max(1, all.length / 5000);
        for (int i = 0; i < all.length; i += stride) {
            java.awt.Point pt = all[i];
            if (pt.x >= 0 && pt.x < dimSizes[0] && pt.y >= 0 && pt.y < dimSizes[1])
                kept.add(pt);
        }
        return kept.isEmpty() ? null : kept.toArray(new java.awt.Point[0]);
    }

    /**
     * ROI-averaged profile along a nav dim (Z/C/T) for the given ROI.
     * Other nav dims stay at their current positions.
     */
    public float[] getRoiProfile(int activeDimIdx, Roi roi) {
        int globalDim = activeDimIndices[activeDimIdx];
        int sz = dimSizes[globalDim];
        float[] profile = new float[sz];
        java.awt.Point[] pts = roiPoints(roi);
        if (pts == null) return profile;

        int z0 = getNavCurrPos(2), c0 = getNavCurrPos(3), t0 = getNavCurrPos(4);
        for (int p = 0; p < sz; p++) {
            int z = globalDim == 2 ? p : z0;
            int c = globalDim == 3 ? p : c0;
            int t = globalDim == 4 ? p : t0;
            ImageProcessor ip = imp.getStack().getProcessor(
                    imp.getStackIndex(c + 1, z + 1, t + 1));
            double sum = 0;
            for (java.awt.Point pt : pts) sum += ip.getf(pt.x, pt.y);
            profile[p] = (float) (sum / pts.length);
        }
        return profile;
    }

    // ---- ROI management (delegates to Fiji's RoiManager) --------------------

    /** Returns the open RoiManager, or null if none exists yet. */
    private static RoiManager roiManager() { return RoiManager.getInstance(); }

    /** All ROIs currently in the RoiManager (empty array if none / not open). */
    public Roi[] getRois() {
        RoiManager rm = roiManager();
        return rm == null ? new Roi[0] : rm.getRoisAsArray();
    }

    public boolean isShowRois() { return showRois; }
    public void setShowRois(boolean v) { showRois = v; fireUpdate(); }

    public int getSelectedRoiIdx() { return selectedRoiIdx; }

    /** Indexes of all ROIs currently selected in the RoiManager table. */
    public int[] getSelectedRoiIndexes() {
        RoiManager rm = roiManager();
        if (rm == null) return new int[0];
        int[] sel = rm.getSelectedIndexes();
        return sel == null ? new int[0] : sel;
    }

    /** True if ROI index k is part of the RoiManager table selection. */
    public boolean isRoiSelected(int k) {
        for (int s : getSelectedRoiIndexes()) if (s == k) return true;
        return false;
    }

    /** Currently selected ROI, or null. */
    public Roi getSelectedRoi() {
        Roi[] rois = getRois();
        return (selectedRoiIdx >= 0 && selectedRoiIdx < rois.length)
                ? rois[selectedRoiIdx] : null;
    }

    /** Select an ROI (or -1 = none) and mirror the selection in the RoiManager. */
    public void setSelectedRoiIdx(int idx) {
        selectedRoiIdx = idx;
        RoiManager rm = roiManager();
        if (rm != null) {
            try {
                if (idx >= 0 && idx < rm.getCount()) rm.select(idx);
                else rm.deselect();   // keep manager in sync so polling doesn't re-select
            } catch (Exception ignored) {}
        }
        fireUpdate();
    }

    /** Update the selection from outside (RoiManager window) without echoing back. */
    public void syncSelectedRoiIdx(int idx) {
        if (idx != selectedRoiIdx) {
            selectedRoiIdx = idx;
            fireUpdate();
        }
    }

    /** Add an ROI to the RoiManager (opening it if needed) and select it. */
    public void addRoi(Roi roi) {
        RoiManager rm = roiManager();
        if (rm == null) rm = new RoiManager();
        rm.addRoi(roi);
        rm.setVisible(true);
        selectedRoiIdx = rm.getCount() - 1;
        fireUpdate();
    }

    /** Open (or bring forward) the RoiManager window. */
    public void openRoiManager() {
        RoiManager rm = roiManager();
        if (rm == null) rm = new RoiManager();
        rm.setVisible(true);
        rm.toFront();
    }

    /** True when display axes are native X/Y (ROIs only render on that plane). */
    public boolean isNativeDisplayPlane() { return isNativePlane(); }

    // ---- rendering ---------------------------------------------------------

    /**
     * Renders float[row][col] data into a BufferedImage using the current
     * contrast settings and colormap.
     */
    public BufferedImage renderImage(float[][] data) {
        if (data == null || data.length == 0) return null;
        int H = data.length, W = data[0].length;

        double cMin = getEffectiveContrastMin(data);
        double cMax = getEffectiveContrastMax(data);
        double range = cMax - cMin;
        if (range == 0) range = 1;

        int[][] lut = buildColormap(colormapIdx, 256);

        BufferedImage img = new BufferedImage(W, H, BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < H; y++) {
            for (int x = 0; x < W; x++) {
                double norm = (data[y][x] - cMin) / range;
                norm = Math.max(0, Math.min(1, norm));
                // gamma
                if (gamma != 1.0) norm = Math.pow(norm, gamma);
                int idx = (int) (norm * 255);
                int[] rgb = lut[idx];
                img.setRGB(x, y, (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]);
            }
        }
        return img;
    }

    // ---- RGB rendering ------------------------------------------------------

    /** True when RGB compositing is active. */
    public boolean isRGB() { return rgbActiveDim >= 0; }

    /**
     * Renders the full image with the first ≤3 entries of the RGB dim mapped
     * to the red/green/blue channels. Also caches the slice for histograms.
     */
    public BufferedImage renderCurrentRGBImage() {
        float[][][] ch = extractRGBChannels();
        cachedImageSlice = firstNonNull(ch);
        return compositeRGB(ch);
    }

    /** Renders the zoomed region in RGB mode. */
    public BufferedImage renderZoomRGBImage() {
        float[][][] ch = extractRGBChannels();
        if (isProjectingTiled()) {
            // tiled output is larger than the data plane — zoom crop doesn't apply
            cachedZoomSlice = firstNonNull(ch);
            return compositeRGB(ch);
        }
        int x0 = zoomMin[xDisplayActiveDim], x1 = zoomMax[xDisplayActiveDim];
        int y0 = zoomMin[yDisplayActiveDim], y1 = zoomMax[yDisplayActiveDim];
        int rows = y1 - y0 + 1, cols = x1 - x0 + 1;
        float[][][] crop = new float[3][][];
        for (int k = 0; k < 3; k++) {
            if (ch[k] == null) continue;
            crop[k] = new float[rows][cols];
            for (int r = 0; r < rows; r++)
                System.arraycopy(ch[k][y0 + r], x0, crop[k][r], 0, cols);
        }
        cachedZoomSlice = firstNonNull(crop);
        return compositeRGB(crop);
    }

    private static float[][] firstNonNull(float[][][] ch) {
        for (float[][] c : ch) if (c != null) return c;
        return new float[0][];
    }

    /**
     * Extract up to 3 slices along the RGB dim (entries 0,1,2 → R,G,B) by
     * temporarily overriding the current position of that dim. Projection on
     * a different dim still applies via the normal extractSlice path.
     */
    private float[][][] extractRGBChannels() {
        // Three consecutive positions of the RGB dimension, centered on the
        // current position, map to R/G/B with wraparound at the edges:
        //   red   = current - 1
        //   green = current
        //   blue  = current + 1
        float[][][] ch = new float[3][][];
        int sz    = getActiveDimSize(rgbActiveDim);
        int saved = currPos[rgbActiveDim];
        int[] offsets = { -1, 0, +1 };   // ch[0]=R, ch[1]=G, ch[2]=B
        for (int k = 0; k < 3; k++) {
            int p = ((saved + offsets[k]) % sz + sz) % sz;   // wrap into [0, sz)
            currPos[rgbActiveDim] = p;
            ch[k] = extractSlice(false);
        }
        currPos[rgbActiveDim] = saved;
        return ch;
    }

    /** Composite ≤3 channel slices into one RGB image, per-channel contrast. */
    private BufferedImage compositeRGB(float[][][] ch) {
        float[][] base = firstNonNull(ch);
        if (base.length == 0) return null;
        int H = base.length, W = base[0].length;

        int[][] bytes = new int[3][];
        for (int k = 0; k < 3; k++) {
            bytes[k] = new int[W * H];
            if (ch[k] == null) continue;
            double cMin = getEffectiveContrastMin(ch[k]);
            double cMax = getEffectiveContrastMax(ch[k]);
            double rng = cMax - cMin;
            if (rng == 0) rng = 1;
            for (int y = 0; y < H; y++) {
                for (int x = 0; x < W; x++) {
                    double norm = (ch[k][y][x] - cMin) / rng;
                    norm = Math.max(0, Math.min(1, norm));
                    if (gamma != 1.0) norm = Math.pow(norm, gamma);
                    bytes[k][y * W + x] = (int) (norm * 255);
                }
            }
        }

        BufferedImage img = new BufferedImage(W, H, BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                int i = y * W + x;
                img.setRGB(x, y, (bytes[0][i] << 16) | (bytes[1][i] << 8) | bytes[2][i]);
            }
        return img;
    }

    private double getEffectiveContrastMin(float[][] data) {
        switch (contrastMode) {
            case "Manual": return contrastMin;
            case "Global": return globalPercentile(percLow);
            default:       return slicePercentile(data, percLow);
        }
    }

    private double getEffectiveContrastMax(float[][] data) {
        switch (contrastMode) {
            case "Manual": return contrastMax;
            case "Global": return globalPercentile(percHigh);
            default:       return slicePercentile(data, percHigh);
        }
    }

    private static double sliceMin(float[][] data) {
        double m = Double.MAX_VALUE;
        for (float[] row : data) for (float v : row) m = Math.min(m, v);
        return m;
    }

    private static double sliceMax(float[][] data) {
        double m = -Double.MAX_VALUE;
        for (float[] row : data) for (float v : row) m = Math.max(m, v);
        return m == m ? m : 1; // NaN guard
    }

    // ---- histogram ---------------------------------------------------------

    /** Compute histogram of data over [histMin, histMax] with nBins bins. */
    public int[] computeHistogram(float[][] data, double histMin, double histMax, int nBins) {
        int[] hist = new int[nBins];
        double range = histMax - histMin;
        if (range <= 0) range = 1;
        for (float[] row : data) {
            for (float v : row) {
                int b = (int) ((v - histMin) / range * nBins);
                b = Math.max(0, Math.min(nBins - 1, b));
                hist[b]++;
            }
        }
        return hist;
    }

    // ---- colormap builder --------------------------------------------------

    /**
     * Returns a 256-entry RGB LUT for the given colormap index.
     * Each entry is int[3] = {r, g, b} in [0, 255].
     */
    public static int[][] buildColormap(int idx, int n) {
        int[][] lut = new int[n][3];
        String name = idx >= 0 && idx < COLORMAP_NAMES.length
                ? COLORMAP_NAMES[idx] : "Grays";

        for (int i = 0; i < n; i++) {
            double t = (double) i / (n - 1);
            int[] rgb;
            switch (name) {
                case "Grays":   rgb = gray(t);    break;
                case "Fire":    rgb = fire(t);    break;
                case "Red Hot": rgb = redHot(t);  break;
                case "Ice":     rgb = ice(t);     break;
                case "Spectrum":
                case "Jet":     rgb = jet(t);     break;
                case "Red":     rgb = new int[]{(int)(t*255), 0, 0};              break;
                case "Green":   rgb = new int[]{0, (int)(t*255), 0};              break;
                case "Blue":    rgb = new int[]{0, 0, (int)(t*255)};              break;
                case "Cyan":    rgb = new int[]{0, (int)(t*255), (int)(t*255)};   break;
                case "Magenta": rgb = new int[]{(int)(t*255), 0, (int)(t*255)};   break;
                case "Yellow":  rgb = new int[]{(int)(t*255), (int)(t*255), 0};   break;
                case "Viridis": rgb = viridis(t); break;
                case "Plasma":  rgb = plasma(t);  break;
                case "Inferno": rgb = inferno(t); break;
                case "Magma":   rgb = magma(t);   break;
                case "Hot":     rgb = hot(t);     break;
                case "Cool":    rgb = cool(t);    break;
                case "Spring":  rgb = spring(t);  break;
                case "Summer":  rgb = summer(t);  break;
                case "Autumn":  rgb = autumn(t);  break;
                case "Winter":  rgb = winter(t);  break;
                case "HSV":     rgb = hsv(t);     break;
                case "Parula":  rgb = parula(t);  break;
                case "Turbo":   rgb = turbo(t);   break;
                default:        rgb = gray(t);    break;
            }
            lut[i] = rgb;
        }
        return lut;
    }

    // ---- colormap helpers (sampled from well-known LUTs) -------------------

    private static int[] gray(double t)    { int v=(int)(t*255); return new int[]{v,v,v}; }
    private static int[] cool(double t)    { return new int[]{(int)(t*255),(int)((1-t)*255),255}; }
    private static int[] spring(double t)  { return new int[]{255,(int)(t*255),(int)((1-t)*255)}; }
    private static int[] summer(double t)  { return new int[]{(int)(t*255),(int)(128+t*127),102}; }
    private static int[] autumn(double t)  { return new int[]{255,(int)(t*255),0}; }
    private static int[] winter(double t)  { return new int[]{0,(int)(t*255),(int)((1-t/2)*255)}; }

    private static int[] hot(double t) {
        int r = (int) Math.min(255, t * 3 * 255);
        int g = (int) Math.min(255, Math.max(0, (t * 3 - 1) * 255));
        int b = (int) Math.min(255, Math.max(0, (t * 3 - 2) * 255));
        return new int[]{r, g, b};
    }

    private static int[] fire(double t) {
        // ImageJ Fire: black->blue->red->yellow->white
        double[] r = {0,0,.5,1,1,1};
        double[] g = {0,0,0,0,.5,1};
        double[] b = {0,.5,.5,0,0,1};
        return interp5(t, r, g, b);
    }

    private static int[] redHot(double t) {
        double[] r = {0,1,1,1};
        double[] g = {0,0,1,1};
        double[] b = {0,0,0,1};
        return interp3(t, r, g, b);
    }

    private static int[] ice(double t) {
        double[] r = {0,0,0,.5,1};
        double[] g = {0,.3,.7,1,1};
        double[] b = {.3,1,1,.8,1};
        return interp4(t, r, g, b);
    }

    private static int[] jet(double t) {
        int r = clamp255((int)(255*Math.min(Math.max(1.5-Math.abs(4*t-3),0),1)));
        int g = clamp255((int)(255*Math.min(Math.max(1.5-Math.abs(4*t-2),0),1)));
        int b = clamp255((int)(255*Math.min(Math.max(1.5-Math.abs(4*t-1),0),1)));
        return new int[]{r, g, b};
    }

    private static int[] hsv(double t) {
        int packed = Color.HSBtoRGB((float)t, 1f, 1f);
        return new int[]{(packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF};
    }

    // Viridis, Plasma, Inferno, Magma, Parula, Turbo — piecewise linear
    private static int[] viridis(double t) {
        double[] r = {.267,.283,.263,.212,.154,.122,.157,.290,.430,.548,.678,.799,.888,.961,.993};
        double[] g = {.005,.102,.185,.264,.339,.407,.476,.545,.600,.643,.693,.754,.812,.867,.906};
        double[] b = {.329,.420,.470,.497,.498,.472,.423,.358,.291,.224,.168,.123,.090,.063,.143};
        return interp(t, r, g, b);
    }

    private static int[] plasma(double t) {
        double[] r = {.050,.285,.476,.628,.748,.841,.906,.944,.962,.958,.943,.908,.851,.778,.940};
        double[] g = {.030,.012,.025,.084,.172,.279,.398,.525,.644,.742,.823,.885,.929,.963,.975};
        double[] b = {.530,.576,.560,.494,.387,.269,.167,.098,.062,.049,.059,.081,.113,.149,.131};
        return interp(t, r, g, b);
    }

    private static int[] inferno(double t) {
        double[] r = {0,.033,.128,.277,.450,.618,.764,.877,.953,.987,.998,.994,.960,.868,.988};
        double[] g = {0,.011,.025,.056,.107,.167,.237,.327,.437,.549,.662,.773,.875,.955,.998};
        double[] b = {.014,.105,.240,.359,.403,.392,.344,.275,.196,.125,.066,.020,.003,.015,.012};
        return interp(t, r, g, b);
    }

    private static int[] magma(double t) {
        double[] r = {0,.028,.107,.236,.387,.542,.680,.800,.898,.962,.993,.992,.972,.938,.988};
        double[] g = {0,.009,.021,.050,.091,.141,.198,.264,.344,.440,.558,.673,.779,.873,.992};
        double[] b = {.014,.097,.218,.344,.427,.472,.482,.471,.444,.406,.367,.318,.257,.189,.145};
        return interp(t, r, g, b);
    }

    private static int[] parula(double t) {
        double[] r = {.208,.232,.259,.315,.362,.402,.412,.424,.480,.564,.644,.729,.832,.925,.972};
        double[] g = {.166,.240,.319,.414,.499,.565,.616,.665,.729,.787,.842,.891,.936,.966,.984};
        double[] b = {.529,.538,.518,.480,.441,.390,.323,.257,.194,.152,.136,.139,.142,.153,.145};
        return interp(t, r, g, b);
    }

    private static int[] turbo(double t) {
        double[] r = {.189,.396,.554,.678,.778,.847,.896,.916,.904,.851,.760,.636,.493,.339,.300};
        double[] g = {.071,.287,.502,.694,.843,.939,.972,.972,.934,.860,.757,.625,.476,.311,.291};
        double[] b = {.242,.503,.680,.755,.745,.653,.504,.330,.188,.096,.056,.056,.078,.108,.357};
        return interp(t, r, g, b);
    }

    // ---- interpolation helpers ---------------------------------------------

    private static int[] interp(double t, double[] r, double[] g, double[] b) {
        int n = r.length;
        double pos = t * (n - 1);
        int i = Math.max(0, Math.min(n - 2, (int) pos));
        double f = pos - i;
        return new int[]{
            clamp255((int) ((r[i] + f * (r[i+1] - r[i])) * 255)),
            clamp255((int) ((g[i] + f * (g[i+1] - g[i])) * 255)),
            clamp255((int) ((b[i] + f * (b[i+1] - b[i])) * 255))
        };
    }

    private static int[] interp3(double t, double[] r, double[] g, double[] b) {
        return interp(t, r, g, b);
    }

    private static int[] interp4(double t, double[] r, double[] g, double[] b) {
        return interp(t, r, g, b);
    }

    private static int[] interp5(double t, double[] r, double[] g, double[] b) {
        return interp(t, r, g, b);
    }

    private static int clamp255(int v) { return Math.max(0, Math.min(255, v)); }

    // ---- listeners ---------------------------------------------------------

    public void addListener(MatVisListener l) { listeners.add(l); }
    public void removeListener(MatVisListener l) { listeners.remove(l); }

    public void fireUpdate() {
        cachedImageSlice = null;
        cachedZoomSlice = null;
        for (MatVisListener l : listeners) l.onUpdate();
    }

    // ---- getters / setters -------------------------------------------------

    public ImagePlus getImagePlus() { return imp; }

    public int getActiveDimSize(int activeDimIdx) {
        return dimSizes[activeDimIndices[activeDimIdx]];
    }

    public String getActiveDimName(int activeDimIdx) {
        return dimNames[activeDimIndices[activeDimIdx]];
    }

    public int getCurrPos(int activeDimIdx)   { return currPos[activeDimIdx]; }
    public int getZoomMin(int activeDimIdx)   { return zoomMin[activeDimIdx]; }
    public int getZoomMax(int activeDimIdx)   { return zoomMax[activeDimIdx]; }

    public void setCurrPos(int activeDimIdx, int pos) {
        int sz = getActiveDimSize(activeDimIdx);
        currPos[activeDimIdx] = Math.max(0, Math.min(sz - 1, pos));
        fireUpdate();
    }

    public void setZoomRange(int activeDimIdx, int min, int max) {
        int sz = getActiveDimSize(activeDimIdx);
        zoomMin[activeDimIdx] = Math.max(0, Math.min(sz - 1, min));
        zoomMax[activeDimIdx] = Math.max(zoomMin[activeDimIdx], Math.min(sz - 1, max));
        fireUpdate();
    }

    public boolean isFlipX() { return flipX; }
    public boolean isFlipY() { return flipY; }
    public void setFlipX(boolean v) { flipX = v; fireUpdate(); }
    public void setFlipY(boolean v) { flipY = v; fireUpdate(); }

    public String getProjFun() { return projFun; }
    public int getProjActiveDim() { return projActiveDim; }

    public void setProjFun(String fun) {
        projFun = fun;
        if (fun.equals("none")) {
            projActiveDim = -1;
        } else if (projActiveDim < 0) {
            // Auto-select first non-spatial (non-X/Y) dim not used by RGB mode.
            projActiveDim = 0;
            for (int i = 0; i < nDims; i++) {
                if (activeDimIndices[i] >= 2 && i != rgbActiveDim) { projActiveDim = i; break; }
            }
        }
        fireUpdate();
    }

    public void setProjActiveDim(int activeDimIdx) {
        if (activeDimIdx >= 0 && activeDimIdx == rgbActiveDim) return; // mutually exclusive
        projActiveDim = activeDimIdx;
        fireUpdate();
    }

    public String getContrastMode() { return contrastMode; }
    public void setContrastMode(String mode) { contrastMode = mode; fireUpdate(); }

    public double getContrastMin() { return contrastMin; }
    public double getContrastMax() { return contrastMax; }
    public double getGamma()       { return gamma; }
    public double getGlobalMin()   { return globalMin; }
    public double getGlobalMax()   { return globalMax; }

    public void setContrastMin(double v) { contrastMin = v; fireUpdate(); }
    public void setContrastMax(double v) { contrastMax = v; fireUpdate(); }
    public void setGamma(double v)       { gamma = Math.max(0.1, Math.min(5.0, v)); fireUpdate(); }

    public int getColormapIdx() { return colormapIdx; }
    public void setColormapIdx(int idx) { colormapIdx = idx; fireUpdate(); }

    public boolean getShowPlot(int activeDimIdx) { return showPlot[activeDimIdx]; }
    public boolean getPlotLock(int activeDimIdx) { return plotLock[activeDimIdx]; }

    public void setShowPlot(int activeDimIdx, boolean v) { showPlot[activeDimIdx] = v; fireUpdate(); }
    public void setPlotLock(int activeDimIdx, boolean v) { plotLock[activeDimIdx] = v; fireUpdate(); }

    /** Returns the cached full-image slice (may be null before first render). */
    public float[][] getCachedImageSlice() { return cachedImageSlice; }
    /** Returns the cached zoom slice (may be null before first render). */
    public float[][] getCachedZoomSlice()  { return cachedZoomSlice;  }

    /** Current effective contrast minimum, using percentile bounds where applicable. */
    public double getEffectiveContrastMinCached() {
        switch (contrastMode) {
            case "Manual": return contrastMin;
            case "Global": return globalPercentile(percLow);
            case "Image":  return cachedImageSlice != null
                    ? slicePercentile(cachedImageSlice, percLow) : globalPercentile(percLow);
            case "Zoom":   return cachedZoomSlice  != null
                    ? slicePercentile(cachedZoomSlice,  percLow) : globalPercentile(percLow);
            default:       return globalMin;
        }
    }

    /** Current effective contrast maximum, using percentile bounds where applicable. */
    public double getEffectiveContrastMaxCached() {
        switch (contrastMode) {
            case "Manual": return contrastMax;
            case "Global": return globalPercentile(percHigh);
            case "Image":  return cachedImageSlice != null
                    ? slicePercentile(cachedImageSlice, percHigh) : globalPercentile(percHigh);
            case "Zoom":   return cachedZoomSlice  != null
                    ? slicePercentile(cachedZoomSlice,  percHigh) : globalPercentile(percHigh);
            default:       return globalMax;
        }
    }

    // ---- percentile getters / setters --------------------------------------

    public double getPercLow()  { return percLow;  }
    public double getPercHigh() { return percHigh; }

    // ---- RGB getters / setters ----------------------------------------------

    public int getRgbActiveDim() { return rgbActiveDim; }

    /** Set the RGB dim (active-dim index) or -1 to turn RGB mode off. */
    public void setRgbActiveDim(int activeDimIdx) {
        if (activeDimIdx >= 0 && activeDimIdx == projActiveDim) return; // mutually exclusive
        rgbActiveDim = activeDimIdx;
        fireUpdate();
    }

    // ---- playback speed -----------------------------------------------------

    /** Timer tick interval used by the play animation (ms). */
    public static final int    PLAY_TICK_MS  = 60;
    /** Frames-per-second at speed 1.0 (one frame per tick). */
    public static final double PLAY_BASE_FPS = 1000.0 / PLAY_TICK_MS;

    /** Playback speed multiplier (1.0 = one frame per tick). */
    private double playSpeed = 1.0;

    // measured (real) playback rate, updated by the playing DimRangeSlider
    private volatile boolean playing = false;
    private long   lastFrameNanos = 0;
    private double measuredFps     = 0;

    public double getPlaySpeed() { return playSpeed; }

    public boolean isPlaying() { return playing; }

    /** Mark playback start/stop; resets the measured-rate estimate on start. */
    public void setPlaying(boolean v) {
        playing = v;
        lastFrameNanos = 0;
        measuredFps = 0;
    }

    /**
     * Called each time a frame is actually displayed during playback; updates
     * an exponentially-smoothed estimate of the real frame rate (frames/sec),
     * accounting for both pause-ticks and rendering lag.
     */
    public void recordPlayFrame() {
        long now = System.nanoTime();
        if (lastFrameNanos > 0) {
            double dt = (now - lastFrameNanos) / 1e9;
            if (dt > 0) {
                double inst = 1.0 / dt;
                measuredFps = (measuredFps <= 0) ? inst : 0.6 * measuredFps + 0.4 * inst;
            }
        }
        lastFrameNanos = now;
    }

    /** Latest smoothed measured frame rate (0 until enough samples). */
    public double getMeasuredFps() { return measuredFps; }

    /** Set the playback speed (clamped to a sane range). */
    public void setPlaySpeed(double v) {
        playSpeed = Math.max(0.05, Math.min(50.0, v));
        fireUpdate();
    }

    /**
     * Frames advanced per displayed tick. For speed ≥ 1 this is round(speed)
     * (so frames are skipped); for speed &lt; 1 it stays 1.
     */
    public int getPlayFrameStep() {
        return playSpeed >= 1.0 ? Math.max(1, (int) Math.round(playSpeed)) : 1;
    }

    /**
     * Number of timer ticks between displayed frames. For speed &lt; 1 this is
     * round(1/speed) (inserting pause-ticks); for speed ≥ 1 it stays 1.
     */
    public int getPlayTickDivisor() {
        return playSpeed < 1.0 ? Math.max(1, (int) Math.round(1.0 / playSpeed)) : 1;
    }

    /** Frames skipped per displayed step (0 when not skipping). */
    public int getPlayFramesSkipped() { return getPlayFrameStep() - 1; }

    /** Actual achieved playback rate in frames/second given the rounding. */
    public double getActualPlayFps() {
        return PLAY_BASE_FPS * getPlayFrameStep() / getPlayTickDivisor();
    }

    // ---- plot scale getters / setters -----------------------------------------

    public boolean isPlotAutoScale() { return plotAutoScale; }
    public double getPlotScaleMin()  { return plotScaleMin; }
    public double getPlotScaleMax()  { return plotScaleMax; }

    public void setPlotAutoScale(boolean v) { plotAutoScale = v; fireUpdate(); }

    public void setPlotScale(double min, double max) {
        if (min < max) { plotScaleMin = min; plotScaleMax = max; }
        fireUpdate();
    }

    public void setPercLow(double v)  { percLow  = Math.max(0, Math.min(100, v)); fireUpdate(); }
    public void setPercHigh(double v) { percHigh = Math.max(0, Math.min(100, v)); fireUpdate(); }

    // ---- plot averaging-mode getters / setters -----------------------------

    public int getPlotAvgMode() { return plotAvgMode; }

    /** Current plot-averaging mode as a label ("Pixel" | "3×3" | "5×5" | "Zoom region"). */
    public String getPlotAvgName() { return PLOT_AVG_NAMES[plotAvgMode]; }

    /** Set the local-averaging mode for single-pixel plot profiles. */
    public void setPlotAvgMode(int mode) {
        plotAvgMode = Math.max(PLOT_AVG_PIXEL, Math.min(PLOT_AVG_ZOOM, mode));
        fireUpdate();
    }

    /** True when tile projection is active (crosshairs/zoom rect are suppressed). */
    public boolean isProjectingTiled() { return isNativePlane() && "tile".equals(projFun) && projActiveDim >= 0; }

    // ---- display-dim getters / setters -------------------------------------

    public int getXDisplayActiveDim() { return xDisplayActiveDim; }
    public int getYDisplayActiveDim() { return yDisplayActiveDim; }

    public void setXDisplayActiveDim(int activeDimIdx) {
        if (activeDimIdx != yDisplayActiveDim) {
            xDisplayActiveDim = activeDimIdx;
            fireUpdate();
        }
    }

    public void setYDisplayActiveDim(int activeDimIdx) {
        if (activeDimIdx != xDisplayActiveDim) {
            yDisplayActiveDim = activeDimIdx;
            fireUpdate();
        }
    }
}
