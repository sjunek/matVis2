package matvis.ui;

import matvis.MatVisController;

import javax.swing.*;
import javax.swing.border.TitledBorder;
import java.awt.*;
import java.awt.event.*;
import java.awt.image.BufferedImage;

/**
 * Contrast control panel with:
 *   - Mode toggle buttons: Global | Image | Zoom | Manual
 *   - Histogram range fields (Hist Min / Hist Max)
 *   - Interactive histogram with draggable min/max/gamma lines
 *   - Colorbar strip
 *   - Contrast min/max/gamma text fields (enabled in Manual mode only)
 *   - Colormap dropdown
 *   - Flip X / Flip Y toggles
 *   - Projection function + projection dimension dropdowns
 */
public class ContrastPanel extends JPanel {

    private final MatVisController ctrl;

    // mode buttons
    private final JToggleButton btnGlobal, btnImage, btnZoom, btnManual;

    // hist range
    private final JTextField fldHistMin, fldHistMax;
    private double histMin, histMax;

    // histogram canvas
    private final HistCanvas histCanvas;

    // manual controls
    private final JTextField fldCMin, fldCMax, fldGamma;

    // percentile controls (active in Global / Image / Zoom modes)
    private final JTextField fldPercLow, fldPercHigh;

    // colormap
    private final JComboBox<String> cbColormap;

    // flip / projection / RGB
    private final JToggleButton btnFlipX, btnFlipY;
    private final JComboBox<String> cbProjFun;
    private final JComboBox<String> cbProjDim;
    private final JComboBox<String> cbRgbDim;
    /** guard against action events fired while rebuilding combos */
    private boolean updatingCombos = false;

    public ContrastPanel(MatVisController ctrl) {
        this.ctrl = ctrl;
        setLayout(new BoxLayout(this, BoxLayout.Y_AXIS));
        setBorder(new TitledBorder("Contrast"));

        // ---- Mode buttons -----------------------------------------------
        ButtonGroup bg = new ButtonGroup();
        btnGlobal = makeMode("Global"); btnImage = makeMode("Image");
        btnZoom   = makeMode("Zoom");   btnManual = makeMode("Manual");
        bg.add(btnGlobal); bg.add(btnImage); bg.add(btnZoom); bg.add(btnManual);
        btnGlobal.setSelected(true);

        JPanel pMode = flow(btnGlobal, btnImage, btnZoom, btnManual);
        add(pMode);

        // ---- Histogram range --------------------------------------------
        histMin = ctrl.getGlobalMin();
        histMax = ctrl.getGlobalMax();

        fldHistMin = new JTextField(String.format("%.4g", histMin), 7);
        fldHistMax = new JTextField(String.format("%.4g", histMax), 7);
        fldHistMin.setFont(fldHistMin.getFont().deriveFont(10f));
        fldHistMax.setFont(fldHistMax.getFont().deriveFont(10f));

        JPanel pHRange = new JPanel(new FlowLayout(FlowLayout.LEFT, 3, 1));
        pHRange.add(new JLabel("Hist Min:")); pHRange.add(fldHistMin);
        pHRange.add(new JLabel("Hist Max:")); pHRange.add(fldHistMax);
        add(pHRange);

        // ---- Histogram canvas -------------------------------------------
        histCanvas = new HistCanvas();
        histCanvas.setPreferredSize(new Dimension(300, 110));
        histCanvas.setMaximumSize(new Dimension(Integer.MAX_VALUE, 110));
        add(histCanvas);

        // ---- Contrast min / max / gamma fields --------------------------
        fldCMin   = makeContrastField();
        fldCMax   = makeContrastField();
        fldGamma  = makeContrastField();

        // Percentile fields (placed next to gamma; active in non-Manual modes)
        fldPercLow  = makeContrastField();  fldPercLow.setEnabled(true);
        fldPercHigh = makeContrastField();  fldPercHigh.setEnabled(true);
        fldPercLow.setText(String.valueOf(ctrl.getPercLow()));
        fldPercHigh.setText(String.valueOf(ctrl.getPercHigh()));

        JPanel pContrast = new JPanel(new FlowLayout(FlowLayout.LEFT, 3, 1));
        pContrast.add(new JLabel("Min:")); pContrast.add(fldCMin);
        pContrast.add(new JLabel("Max:")); pContrast.add(fldCMax);
        pContrast.add(new JLabel("γ:"));  pContrast.add(fldGamma);
        pContrast.add(new JLabel("Lo%:")); pContrast.add(fldPercLow);
        pContrast.add(new JLabel("Hi%:")); pContrast.add(fldPercHigh);
        add(pContrast);

        // ---- Colormap ---------------------------------------------------
        cbColormap = new JComboBox<>(MatVisController.COLORMAP_NAMES);
        cbColormap.setSelectedIndex(ctrl.getColormapIdx());
        JPanel pCmap = new JPanel(new FlowLayout(FlowLayout.LEFT, 3, 1));
        pCmap.add(new JLabel("Colormap:")); pCmap.add(cbColormap);
        add(pCmap);

        // ---- Flip & Projection ------------------------------------------
        btnFlipX = new JToggleButton("Flip X"); btnFlipX.setFont(btnFlipX.getFont().deriveFont(10f));
        btnFlipY = new JToggleButton("Flip Y"); btnFlipY.setFont(btnFlipY.getFont().deriveFont(10f));

        String[] projFuns = {"none","max","min","mean","std","tile"};
        cbProjFun = new JComboBox<>(projFuns);
        cbProjFun.setFont(cbProjFun.getFont().deriveFont(10f));

        cbProjDim = new JComboBox<>();
        cbProjDim.setFont(cbProjDim.getFont().deriveFont(10f));
        cbProjDim.setEnabled(false);
        cbProjDim.setPreferredSize(new Dimension(55, 22)); // keep wide enough for dim names

        cbRgbDim = new JComboBox<>();
        cbRgbDim.setFont(cbRgbDim.getFont().deriveFont(10f));
        cbRgbDim.setPreferredSize(new Dimension(55, 22));

        rebuildProjDimCombo();
        rebuildRgbDimCombo();

        JPanel pFlipProj = new JPanel(new FlowLayout(FlowLayout.LEFT, 3, 1));
        pFlipProj.add(btnFlipX); pFlipProj.add(btnFlipY);
        pFlipProj.add(new JLabel("Proj:")); pFlipProj.add(cbProjFun); pFlipProj.add(cbProjDim);
        pFlipProj.add(new JLabel("RGB:")); pFlipProj.add(cbRgbDim);
        add(pFlipProj);

        // ---- Wire events ------------------------------------------------
        btnGlobal.addActionListener(e -> ctrl.setContrastMode("Global"));
        btnImage.addActionListener(e  -> ctrl.setContrastMode("Image"));
        btnZoom.addActionListener(e   -> ctrl.setContrastMode("Zoom"));
        btnManual.addActionListener(e -> ctrl.setContrastMode("Manual"));

        fldHistMin.addActionListener(e -> applyHistRange());
        fldHistMax.addActionListener(e -> applyHistRange());

        fldCMin.addActionListener(e  -> applyManualMin());
        fldCMax.addActionListener(e  -> applyManualMax());
        fldGamma.addActionListener(e -> applyGamma());
        fldPercLow.addActionListener(e  -> applyPercLow());
        fldPercHigh.addActionListener(e -> applyPercHigh());

        cbColormap.addActionListener(e ->
            ctrl.setColormapIdx(cbColormap.getSelectedIndex()));

        btnFlipX.addActionListener(e -> ctrl.setFlipX(btnFlipX.isSelected()));
        btnFlipY.addActionListener(e -> ctrl.setFlipY(btnFlipY.isSelected()));

        cbProjFun.addActionListener(e -> {
            if (updatingCombos) return;
            String fun = (String) cbProjFun.getSelectedItem();
            ctrl.setProjFun(fun == null ? "none" : fun);
            cbProjDim.setEnabled(!"none".equals(fun));
            // proj dim may have just been auto-selected or cleared → update RGB choices
            rebuildProjDimCombo();
            rebuildRgbDimCombo();
        });

        cbProjDim.addActionListener(e -> {
            if (updatingCombos) return;
            int selIdx = cbProjDim.getSelectedIndex();
            if (selIdx >= 0) {
                // stored as activeDimIdx in client-property
                Object tag = cbProjDim.getClientProperty("activeDims");
                if (tag instanceof int[]) {
                    int[] arr = (int[]) tag;
                    if (selIdx < arr.length)
                        ctrl.setProjActiveDim(arr[selIdx]);
                }
            }
            // exclude the newly selected proj dim from the RGB dropdown
            rebuildRgbDimCombo();
        });

        cbRgbDim.addActionListener(e -> {
            if (updatingCombos) return;
            int selIdx = cbRgbDim.getSelectedIndex();
            Object tag = cbRgbDim.getClientProperty("activeDims");
            if (selIdx >= 0 && tag instanceof int[]) {
                int[] arr = (int[]) tag;
                // entry 0 = "off" → -1; entries 1.. map to arr[selIdx-1]
                ctrl.setRgbActiveDim(selIdx == 0 ? -1 : arr[selIdx - 1]);
            }
            // exclude the newly selected RGB dim from the projection dropdown
            rebuildProjDimCombo();
        });

        refreshUI();
    }

    // ---- refresh ----------------------------------------------------------

    public void refresh() {
        refreshUI();
        histCanvas.repaint();
    }

    private void refreshUI() {
        String mode = ctrl.getContrastMode();
        btnGlobal.setSelected("Global".equals(mode));
        btnImage.setSelected("Image".equals(mode));
        btnZoom.setSelected("Zoom".equals(mode));
        btnManual.setSelected("Manual".equals(mode));

        boolean manual = "Manual".equals(mode);
        fldCMin.setEnabled(manual);
        fldCMax.setEnabled(manual);
        fldGamma.setEnabled(true);
        // Percentile fields active in all non-Manual modes
        fldPercLow.setEnabled(!manual);
        fldPercHigh.setEnabled(!manual);

        fldCMin.setText(String.format("%.4g", ctrl.getContrastMin()));
        fldCMax.setText(String.format("%.4g", ctrl.getContrastMax()));
        fldGamma.setText(String.format("%.3f", ctrl.getGamma()));
        fldPercLow.setText(String.format("%.4g", ctrl.getPercLow()));
        fldPercHigh.setText(String.format("%.4g", ctrl.getPercHigh()));

        cbColormap.setSelectedIndex(ctrl.getColormapIdx());
        btnFlipX.setSelected(ctrl.isFlipX());
        btnFlipY.setSelected(ctrl.isFlipY());
    }

    /** Nav dims (not X=0/Y=1), excluding the one used by RGB mode. */
    private void rebuildProjDimCombo() {
        updatingCombos = true;
        try {
            java.util.List<Integer> dims = new java.util.ArrayList<>();
            for (int i = 0; i < ctrl.nDims; i++) {
                int gd = ctrl.activeDimIndices[i];
                if (gd != 0 && gd != 1 && i != ctrl.getRgbActiveDim()) dims.add(i);
            }
            cbProjDim.removeAllItems();
            int[] arr = new int[dims.size()];
            int selIdx = -1;
            for (int k = 0; k < dims.size(); k++) {
                arr[k] = dims.get(k);
                cbProjDim.addItem(ctrl.getActiveDimName(dims.get(k)));
                if (dims.get(k) == ctrl.getProjActiveDim()) selIdx = k;
            }
            cbProjDim.putClientProperty("activeDims", arr);
            if (selIdx >= 0) cbProjDim.setSelectedIndex(selIdx);
        } finally {
            updatingCombos = false;
        }
    }

    /** "off" + nav dims, excluding the one used by the projection. */
    private void rebuildRgbDimCombo() {
        updatingCombos = true;
        try {
            boolean projActive = !"none".equals(ctrl.getProjFun());
            java.util.List<Integer> dims = new java.util.ArrayList<>();
            for (int i = 0; i < ctrl.nDims; i++) {
                int gd = ctrl.activeDimIndices[i];
                if (gd != 0 && gd != 1 && !(projActive && i == ctrl.getProjActiveDim()))
                    dims.add(i);
            }
            cbRgbDim.removeAllItems();
            cbRgbDim.addItem("off");
            int[] arr = new int[dims.size()];
            int selIdx = 0; // default "off"
            for (int k = 0; k < dims.size(); k++) {
                arr[k] = dims.get(k);
                cbRgbDim.addItem(ctrl.getActiveDimName(dims.get(k)));
                if (dims.get(k) == ctrl.getRgbActiveDim()) selIdx = k + 1;
            }
            cbRgbDim.putClientProperty("activeDims", arr);
            cbRgbDim.setSelectedIndex(selIdx);
            // If the previously selected RGB dim was just excluded, sync the model
            if (selIdx == 0 && ctrl.getRgbActiveDim() >= 0) ctrl.setRgbActiveDim(-1);
        } finally {
            updatingCombos = false;
        }
    }

    // ---- field application ------------------------------------------------

    private void applyHistRange() {
        try {
            histMin = Double.parseDouble(fldHistMin.getText().trim());
            histMax = Double.parseDouble(fldHistMax.getText().trim());
            if (histMin >= histMax) histMax = histMin + 1;
            histCanvas.repaint();
        } catch (NumberFormatException ignored) {}
    }

    private void applyManualMin() {
        try { ctrl.setContrastMin(Double.parseDouble(fldCMin.getText().trim())); }
        catch (NumberFormatException ignored) {}
    }

    private void applyManualMax() {
        try { ctrl.setContrastMax(Double.parseDouble(fldCMax.getText().trim())); }
        catch (NumberFormatException ignored) {}
    }

    private void applyGamma() {
        try { ctrl.setGamma(Double.parseDouble(fldGamma.getText().trim())); }
        catch (NumberFormatException ignored) {}
    }

    private void applyPercLow() {
        try { ctrl.setPercLow(Double.parseDouble(fldPercLow.getText().trim())); }
        catch (NumberFormatException ignored) {}
    }

    private void applyPercHigh() {
        try { ctrl.setPercHigh(Double.parseDouble(fldPercHigh.getText().trim())); }
        catch (NumberFormatException ignored) {}
    }

    // ---- UI helpers -------------------------------------------------------

    private JToggleButton makeMode(String text) {
        JToggleButton b = new JToggleButton(text);
        b.setFont(b.getFont().deriveFont(10f));
        b.setMargin(new Insets(1, 4, 1, 4));
        return b;
    }

    private JTextField makeContrastField() {
        JTextField f = new JTextField(6);
        f.setFont(f.getFont().deriveFont(10f));
        f.setEnabled(false);
        return f;
    }

    private JPanel flow(Component... comps) {
        JPanel p = new JPanel(new FlowLayout(FlowLayout.LEFT, 2, 2));
        for (Component c : comps) p.add(c);
        return p;
    }

    // ---- Histogram canvas -------------------------------------------------

    private class HistCanvas extends JPanel {

        // drag state: 0=none, 1=min line, 2=max line, 3=gamma dot
        private static final int DRAG_NONE      = 0;
        private static final int DRAG_MIN_LINE  = 1;
        private static final int DRAG_MAX_LINE  = 2;
        private static final int DRAG_GAMMA_DOT = 3;
        private int drag = DRAG_NONE;

        HistCanvas() {
            setBackground(Color.WHITE);
            setBorder(BorderFactory.createLineBorder(Color.GRAY));

            MouseAdapter ma = new MouseAdapter() {
                public void mousePressed(MouseEvent e)  { onHPress(e); }
                public void mouseDragged(MouseEvent e)  { onHDrag(e); }
                public void mouseReleased(MouseEvent e) { drag = DRAG_NONE; }
                public void mouseMoved(MouseEvent e)    { onHHover(e); }
            };
            addMouseListener(ma);
            addMouseMotionListener(ma);
        }

        @Override
        protected void paintComponent(Graphics g) {
            super.paintComponent(g);
            Graphics2D g2 = (Graphics2D) g.create();
            int W = getWidth(), H = getHeight();
            int BAR_H = 12; // colorbar height at bottom
            int HIST_H = H - BAR_H - 2;

            // ---- Draw histograms ----------------------------------------
            // Use already-cached slices (populated by imagePanel.refresh() earlier).
            // Call getCurrentSlice() / getZoomSlice() only as fallback — they do NOT
            // fire listeners so calling them from paintComponent is safe.
            float[][] imgData  = ctrl.getCachedImageSlice();
            float[][] zoomData = ctrl.getCachedZoomSlice();
            if (imgData  == null) imgData  = ctrl.getCurrentSlice();
            if (zoomData == null) zoomData = ctrl.getZoomSlice();
            if (imgData  == null) imgData  = new float[0][];
            if (zoomData == null) zoomData = new float[0][];

            // use hist range
            double hMin = histMin, hMax = histMax;

            drawHistogram(g2, imgData,  hMin, hMax, W, HIST_H,
                    new Color(160, 160, 160, 200));
            drawHistogram(g2, zoomData, hMin, hMax, W, HIST_H,
                    new Color(80,  80,  80,  200));

            // ---- Contrast min/max lines ----------------------------------
            double cMin = ctrl.getEffectiveContrastMinCached();
            double cMax = ctrl.getEffectiveContrastMaxCached();
            double range = hMax - hMin;
            if (range == 0) range = 1;

            int minX = (int) ((cMin - hMin) / range * W);
            int maxX = (int) ((cMax - hMin) / range * W);
            minX = Math.max(0, Math.min(W, minX));
            maxX = Math.max(0, Math.min(W, maxX));

            g2.setStroke(new BasicStroke(1.5f));
            g2.setColor(new Color(200, 30, 30));
            g2.drawLine(minX, 0, minX, HIST_H);
            g2.setColor(new Color(30, 80, 200));
            g2.drawLine(maxX, 0, maxX, HIST_H);

            // ---- Gamma curve --------------------------------------------
            double gamma = ctrl.getGamma();
            g2.setColor(new Color(120, 120, 120, 180));
            g2.setStroke(new BasicStroke(1f));
            int prevPy = HIST_H - 1;
            for (int x = minX; x <= maxX; x++) {
                double norm = (double)(x - minX) / Math.max(1, maxX - minX);
                double gval = Math.pow(norm, gamma);
                int py = (int)((1 - gval) * (HIST_H - 1));
                if (x > minX) g2.drawLine(x - 1, prevPy, x, py);
                prevPy = py;
            }

            // gamma handle dot at midpoint
            double midNorm = Math.pow(0.5, gamma);
            int dotX = (minX + maxX) / 2;
            int dotY = (int)((1 - midNorm) * (HIST_H - 1));
            g2.setColor(new Color(80, 80, 80));
            g2.fillOval(dotX - 4, dotY - 4, 8, 8);
            g2.setColor(Color.WHITE);
            g2.drawOval(dotX - 4, dotY - 4, 8, 8);

            // ---- Colorbar -----------------------------------------------
            int[][] lut = MatVisController.buildColormap(ctrl.getColormapIdx(), W);
            for (int x = 0; x < W; x++) {
                int[] rgb = lut[Math.min(lut.length - 1, x * lut.length / W)];
                g2.setColor(new Color(rgb[0], rgb[1], rgb[2]));
                g2.fillRect(x, HIST_H + 2, 1, BAR_H);
            }

            g2.dispose();
        }

        private void drawHistogram(Graphics2D g2, float[][] data,
                                   double hMin, double hMax, int W, int H, Color color) {
            if (data == null || data.length == 0) return;
            int nBins = W;
            int[] hist = ctrl.computeHistogram(data, hMin, hMax, nBins);
            int maxCount = 1;
            for (int v : hist) maxCount = Math.max(maxCount, v);

            g2.setColor(color);
            for (int b = 0; b < nBins; b++) {
                int barH = (int) ((double) hist[b] / maxCount * H);
                g2.fillRect(b, H - barH, 1, barH);
            }
        }

        // ---- drag on histogram ------------------------------------------

        private void onHPress(MouseEvent e) {
            if (!"Manual".equals(ctrl.getContrastMode())) return;
            int mx = e.getX(), my = e.getY();
            int W  = getWidth(), H = getHeight() - 14;
            double hRange = histMax - histMin;
            if (hRange == 0) return;

            double cMin = ctrl.getContrastMin();
            double cMax = ctrl.getContrastMax();
            int minX = (int)((cMin - histMin) / hRange * W);
            int maxX = (int)((cMax - histMin) / hRange * W);

            // gamma dot
            double gamma = ctrl.getGamma();
            int dotX = (minX + maxX) / 2;
            int dotY = (int)((1 - Math.pow(0.5, gamma)) * (H - 1));
            if (Math.hypot(mx - dotX, my - dotY) <= 8) { drag = DRAG_GAMMA_DOT; return; }

            if (Math.abs(mx - minX) <= 5) { drag = DRAG_MIN_LINE; return; }
            if (Math.abs(mx - maxX) <= 5) { drag = DRAG_MAX_LINE; return; }
        }

        private void onHDrag(MouseEvent e) {
            if (drag == DRAG_NONE) return;
            int mx = e.getX(), my = e.getY();
            int W  = getWidth(), H = getHeight() - 14;
            double hRange = histMax - histMin;
            if (hRange == 0) return;

            double val = histMin + (double) mx / W * hRange;

            if (drag == DRAG_MIN_LINE) {
                ctrl.setContrastMin(Math.min(val, ctrl.getContrastMax() - 1e-9));
            } else if (drag == DRAG_MAX_LINE) {
                ctrl.setContrastMax(Math.max(val, ctrl.getContrastMin() + 1e-9));
            } else if (drag == DRAG_GAMMA_DOT) {
                double yNorm = 1.0 - (double) my / (H - 1);
                yNorm = Math.max(1e-6, Math.min(1 - 1e-6, yNorm));
                double g = Math.log(yNorm) / Math.log(0.5);
                ctrl.setGamma(g);
            }
        }

        private void onHHover(MouseEvent e) {
            if (!"Manual".equals(ctrl.getContrastMode())) { setCursor(Cursor.getDefaultCursor()); return; }
            int mx = e.getX(), my = e.getY();
            int W  = getWidth(), H = getHeight() - 14;
            double hRange = histMax - histMin;
            if (hRange == 0) return;

            double cMin = ctrl.getContrastMin(), cMax = ctrl.getContrastMax();
            int minX = (int)((cMin - histMin) / hRange * W);
            int maxX = (int)((cMax - histMin) / hRange * W);
            double gamma = ctrl.getGamma();
            int dotX = (minX + maxX) / 2;
            int dotY = (int)((1 - Math.pow(0.5, gamma)) * (H - 1));

            if (Math.hypot(mx - dotX, my - dotY) <= 8)
                setCursor(Cursor.getPredefinedCursor(Cursor.N_RESIZE_CURSOR));
            else if (Math.abs(mx - minX) <= 5 || Math.abs(mx - maxX) <= 5)
                setCursor(Cursor.getPredefinedCursor(Cursor.E_RESIZE_CURSOR));
            else
                setCursor(Cursor.getDefaultCursor());
        }
    }
}
