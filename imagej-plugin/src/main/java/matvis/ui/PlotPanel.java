package matvis.ui;

import matvis.MatVisController;

import ij.gui.Roi;

import javax.swing.*;
import java.awt.*;
import java.awt.event.*;

/**
 * 1-D profile plot panel.
 * Shows one row per active dimension that has ShowPlot = true.
 * Each row contains a line profile at the current position, a draggable
 * red position line, and a blue rubber-band zoom selection.
 */
public class PlotPanel extends JPanel {

    private final MatVisController ctrl;
    private final PlotRow[] rows;

    public PlotPanel(MatVisController ctrl) {
        this.ctrl = ctrl;
        setLayout(new GridLayout(1, 1));
        setBackground(Color.WHITE);

        rows = new PlotRow[ctrl.nDims];
        for (int i = 0; i < ctrl.nDims; i++) {
            rows[i] = new PlotRow(i);
        }
        refresh();
    }

    public void refresh() {
        removeAll();
        int count = 0;
        for (int i = 0; i < ctrl.nDims; i++) {
            if (ctrl.getShowPlot(i)) {
                add(rows[i]);
                rows[i].repaint();
                count++;
            }
        }
        if (count > 0) {
            ((GridLayout) getLayout()).setRows(count);
        }
        revalidate();
        repaint();
    }

    // ---- Inner PlotRow ---------------------------------------------------

    private class PlotRow extends JPanel {
        final int activeDimIdx;

        // drag state
        private boolean draggingPos   = false;
        private boolean draggingZoom  = false;
        private int     rubberX0, rubberX1;

        private static final int ROW_H = 70;
        private static final int MARGIN_LEFT  = 30;
        private static final int MARGIN_RIGHT = 8;
        private static final int MARGIN_TOP   = 4;
        private static final int MARGIN_BOT   = 16;
        private static final int HIT_TOL      = 5;

        PlotRow(int activeDimIdx) {
            this.activeDimIdx = activeDimIdx;
            setBackground(Color.WHITE);
            setMinimumSize(new Dimension(60, 40));

            setBorder(BorderFactory.createMatteBorder(0, 0, 1, 0, new Color(200, 200, 200)));

            MouseAdapter ma = new MouseAdapter() {
                public void mousePressed(MouseEvent e)  { onPress(e); }
                public void mouseDragged(MouseEvent e)  { onDrag(e); }
                public void mouseReleased(MouseEvent e) { onRelease(e); }
                public void mouseMoved(MouseEvent e)    { onHover(e); }
            };
            addMouseListener(ma);
            addMouseMotionListener(ma);
        }

        @Override
        protected void paintComponent(Graphics g) {
            super.paintComponent(g);
            Graphics2D g2 = (Graphics2D) g.create();
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING,
                    RenderingHints.VALUE_ANTIALIAS_ON);

            int W = getWidth(), H = getHeight();
            int plotW = W - MARGIN_LEFT - MARGIN_RIGHT;
            int plotH = H - MARGIN_TOP - MARGIN_BOT;

            // background
            g2.setColor(new Color(248, 248, 248));
            g2.fillRect(MARGIN_LEFT, MARGIN_TOP, plotW, plotH);
            g2.setColor(new Color(200, 200, 200));
            g2.drawRect(MARGIN_LEFT, MARGIN_TOP, plotW, plotH);

            // dim label (left side); note ROI-mean mode for nav dims
            g2.setFont(g2.getFont().deriveFont(Font.BOLD, 10f));
            g2.setColor(Color.DARK_GRAY);
            String dimLabel = ctrl.getActiveDimName(activeDimIdx);
            g2.drawString(dimLabel, 2, MARGIN_TOP + plotH / 2 + 4);
            // nav dims (Z/C/T) plot one ROI-averaged trace per SELECTED ROI
            int gdim = ctrl.activeDimIndices[activeDimIdx];
            Roi[] rois = ctrl.getRois();
            int[] selIdxs = (gdim >= 2 && rois.length > 0)
                    ? ctrl.getSelectedRoiIndexes() : new int[0];
            if (selIdxs.length > 0) {
                g2.setFont(g2.getFont().deriveFont(Font.PLAIN, 9f));
                g2.setColor(new Color(0, 150, 150));
                String note = selIdxs.length == 1 ? "ROI mean" : selIdxs.length + " ROI means";
                g2.drawString(note, MARGIN_LEFT + 4, MARGIN_TOP + 10);
            }

            // profile data
            int sz = ctrl.getActiveDimSize(activeDimIdx);
            if (sz <= 0) { g2.dispose(); return; }

            // determine x range to display
            boolean lock = ctrl.getPlotLock(activeDimIdx);
            int xMin = lock ? ctrl.getZoomMin(activeDimIdx) : 0;
            int xMax = lock ? ctrl.getZoomMax(activeDimIdx) : sz - 1;
            int xRange = xMax - xMin;
            if (xRange <= 0) xRange = 1;

            // y range: auto = follow displayed contrast; manual = fixed user values
            double cMin, cMax;
            if (ctrl.isPlotAutoScale()) {
                cMin = ctrl.getEffectiveContrastMinCached();
                cMax = ctrl.getEffectiveContrastMaxCached();
            } else {
                cMin = ctrl.getPlotScaleMin();
                cMax = ctrl.getPlotScaleMax();
            }
            double cRange = cMax - cMin;
            if (cRange == 0) cRange = 1;

            // draw zoom shading (blue patch)
            int zMin = ctrl.getZoomMin(activeDimIdx);
            int zMax = ctrl.getZoomMax(activeDimIdx);
            int zx0 = dataToPlotX(Math.max(zMin, xMin), xMin, xRange, plotW);
            int zx1 = dataToPlotX(Math.min(zMax, xMax), xMin, xRange, plotW);
            if (zx1 > zx0) {
                g2.setColor(new Color(100, 160, 230, 60));
                g2.fillRect(MARGIN_LEFT + zx0, MARGIN_TOP, zx1 - zx0, plotH);
            }

            // rubber-band preview
            if (draggingZoom) {
                int rx = Math.min(rubberX0, rubberX1);
                int rw = Math.abs(rubberX1 - rubberX0);
                g2.setColor(new Color(100, 160, 230, 100));
                g2.fillRect(rx, MARGIN_TOP, rw, plotH);
                g2.setColor(new Color(60, 120, 200));
                g2.setStroke(new BasicStroke(1f));
                g2.drawRect(rx, MARGIN_TOP, rw, plotH);
            }

            // profile traces: one per selected ROI, colored to match its outline;
            // fall back to the single-pixel profile when nothing is selected.
            if (selIdxs.length > 0) {
                for (int ri : selIdxs) {
                    if (ri < 0 || ri >= rois.length) continue;
                    float[] prof = ctrl.getRoiProfile(activeDimIdx, rois[ri]);
                    g2.setColor(MatVisController.roiColor(ri));
                    g2.setStroke(new BasicStroke(1.6f));
                    drawTrace(g2, prof, xMin, xMax, xRange, plotW, plotH, cMin, cRange);
                }
            } else {
                g2.setColor(new Color(30, 100, 220));
                g2.setStroke(new BasicStroke(1.2f));
                drawTrace(g2, ctrl.getProfile(activeDimIdx), xMin, xMax, xRange, plotW, plotH, cMin, cRange);
            }

            // position line (red)
            int pos = ctrl.getCurrPos(activeDimIdx);
            int posX = MARGIN_LEFT + dataToPlotX(pos, xMin, xRange, plotW);
            g2.setColor(new Color(200, 40, 40));
            g2.setStroke(new BasicStroke(1.5f));
            g2.drawLine(posX, MARGIN_TOP, posX, MARGIN_TOP + plotH);

            // x-axis ticks (simple)
            g2.setColor(Color.DARK_GRAY);
            g2.setFont(g2.getFont().deriveFont(9f));
            g2.setStroke(new BasicStroke(1f));
            int tickCount = 5;
            for (int k = 0; k <= tickCount; k++) {
                int d = xMin + k * xRange / tickCount;
                int tx = MARGIN_LEFT + dataToPlotX(d, xMin, xRange, plotW);
                g2.drawLine(tx, MARGIN_TOP + plotH, tx, MARGIN_TOP + plotH + 3);
                g2.drawString(String.valueOf(d + 1), tx - 8, H - 2);
            }

            g2.dispose();
        }

        /** Draw one profile trace with the current color/stroke of g2. */
        private void drawTrace(Graphics2D g2, float[] prof, int xMin, int xMax,
                               int xRange, int plotW, int plotH, double cMin, double cRange) {
            int prevPx = -1, prevPy = -1;
            for (int d = xMin; d <= xMax; d++) {
                if (d < 0 || d >= prof.length) continue;
                double norm = (prof[d] - cMin) / cRange;
                int px = MARGIN_LEFT + dataToPlotX(d, xMin, xRange, plotW);
                int py = MARGIN_TOP + plotH - 1 - (int)(norm * (plotH - 1));
                py = Math.max(MARGIN_TOP, Math.min(MARGIN_TOP + plotH - 1, py));
                if (prevPx >= 0) g2.drawLine(prevPx, prevPy, px, py);
                prevPx = px; prevPy = py;
            }
        }

        private int dataToPlotX(int d, int xMin, int xRange, int plotW) {
            return (int)((double)(d - xMin) / xRange * (plotW - 1));
        }

        private int plotXToData(int px, int xMin, int xRange, int plotW) {
            double d = (double)(px - MARGIN_LEFT) / (plotW - 1) * xRange + xMin;
            return (int) Math.max(0, Math.min(ctrl.getActiveDimSize(activeDimIdx) - 1, d));
        }

        private boolean nearPosLine(int mx) {
            int plotW = getWidth() - MARGIN_LEFT - MARGIN_RIGHT;
            boolean lock = ctrl.getPlotLock(activeDimIdx);
            int xMin = lock ? ctrl.getZoomMin(activeDimIdx) : 0;
            int xMax = lock ? ctrl.getZoomMax(activeDimIdx) : ctrl.getActiveDimSize(activeDimIdx) - 1;
            int xRange = xMax - xMin;
            int pos  = ctrl.getCurrPos(activeDimIdx);
            int posX = MARGIN_LEFT + dataToPlotX(pos, xMin, Math.max(1, xRange), plotW);
            return Math.abs(mx - posX) <= HIT_TOL;
        }

        private void onPress(MouseEvent e) {
            if (e.getButton() == MouseEvent.BUTTON3) {
                // Right-click: reset zoom for this dimension to full range
                ctrl.setZoomRange(activeDimIdx, 0, ctrl.getActiveDimSize(activeDimIdx) - 1);
                return;
            }
            int mx = e.getX();
            if (nearPosLine(mx)) {
                draggingPos = true;
            } else {
                draggingZoom = true;
                rubberX0 = rubberX1 = mx;
            }
        }

        private void onDrag(MouseEvent e) {
            int mx = e.getX();
            int plotW = getWidth() - MARGIN_LEFT - MARGIN_RIGHT;
            boolean lock = ctrl.getPlotLock(activeDimIdx);
            int xMin  = lock ? ctrl.getZoomMin(activeDimIdx) : 0;
            int xMax  = lock ? ctrl.getZoomMax(activeDimIdx) : ctrl.getActiveDimSize(activeDimIdx) - 1;
            int xRange = Math.max(1, xMax - xMin);

            if (draggingPos) {
                int d = plotXToData(mx, xMin, xRange, plotW);
                ctrl.setCurrPos(activeDimIdx, d);
            }
            if (draggingZoom) {
                rubberX1 = mx;
                repaint();
            }
        }

        private void onRelease(MouseEvent e) {
            if (draggingZoom) {
                int plotW = getWidth() - MARGIN_LEFT - MARGIN_RIGHT;
                boolean lock = ctrl.getPlotLock(activeDimIdx);
                int xMin  = lock ? ctrl.getZoomMin(activeDimIdx) : 0;
                int xMax  = lock ? ctrl.getZoomMax(activeDimIdx) : ctrl.getActiveDimSize(activeDimIdx) - 1;
                int xRange = Math.max(1, xMax - xMin);

                int d0 = plotXToData(Math.min(rubberX0, rubberX1), xMin, xRange, plotW);
                int d1 = plotXToData(Math.max(rubberX0, rubberX1), xMin, xRange, plotW);
                if (d1 > d0) ctrl.setZoomRange(activeDimIdx, d0, d1);
            }
            draggingPos  = false;
            draggingZoom = false;
            repaint();
        }

        private void onHover(MouseEvent e) {
            if (nearPosLine(e.getX()))
                setCursor(Cursor.getPredefinedCursor(Cursor.E_RESIZE_CURSOR));
            else
                setCursor(Cursor.getDefaultCursor());
        }
    }
}
