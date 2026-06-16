package matvis.ui;

import matvis.MatVisController;

import ij.gui.OvalRoi;
import ij.gui.PolygonRoi;
import ij.gui.Roi;
import ij.process.FloatPolygon;

import javax.swing.*;
import java.awt.*;
import java.awt.event.*;
import java.awt.image.BufferedImage;

/**
 * Full-image display panel with overlays:
 *   - white dashed crosshair at (xPos, yPos)
 *   - red dashed rectangle showing the zoom sub-region
 *   - yellow drag-to-select rectangle while rubber-banding a new zoom
 *
 * Mouse interactions:
 *   - Left-drag on crosshair lines   → move position
 *   - Left-drag on zoom rect edges   → pan/resize zoom
 *   - Left-drag elsewhere            → rubber-band new zoom selection
 *   - Right-click                    → reset zoom to full range
 *   - Scroll wheel                   → zoom in/out centred on cursor
 */
public class ImageDisplayPanel extends JPanel {

    private final MatVisController ctrl;

    // indices into ctrl for X and Y active-dim indices
    private int xActiveIdx = -1;
    private int yActiveIdx = -1;

    // cached render
    private BufferedImage currentImage;

    // image-in-panel geometry (letterboxed)
    private int imgX, imgY, imgW, imgH; // pixel coords of the image rectangle in the panel

    // drag state
    private enum DragMode { NONE, POS_X, POS_Y, POS_XY, ZOOM_PAN, RUBBER_BAND }
    private DragMode dragMode = DragMode.NONE;
    private int rubberX0, rubberY0, rubberX1, rubberY1; // image-pixel coords during drag

    private static final int HIT_TOL = 6; // px to detect crosshair / zoom rect

    // ROI drawing mode (set from the main-frame toolbar)
    private boolean roiDrawMode = false;
    private String  roiShape = "Rectangle"; // "Rectangle" | "Oval" | "Polygon"

    // in-progress polygon vertices (data coords) + current mouse pos (panel coords)
    private final java.util.List<Point> polyPts = new java.util.ArrayList<>();
    private int polyMouseX = -1, polyMouseY = -1;

    public void setRoiDrawMode(boolean v) {
        roiDrawMode = v;
        if (!v) { polyPts.clear(); repaint(); }
    }
    public void setRoiShape(String s) {
        roiShape = s;
        polyPts.clear();
        repaint();
    }

    private boolean polygonMode() { return roiDrawMode && "Polygon".equals(roiShape); }

    /** Finish the in-progress polygon into an ROI (needs ≥3 vertices). */
    private void finishPolygon() {
        if (polyPts.size() >= 3) {
            int n = polyPts.size();
            float[] xs = new float[n], ys = new float[n];
            for (int i = 0; i < n; i++) { xs[i] = polyPts.get(i).x; ys[i] = polyPts.get(i).y; }
            ctrl.addRoi(new PolygonRoi(xs, ys, n, Roi.POLYGON));
        }
        polyPts.clear();
        repaint();
    }

    public ImageDisplayPanel(MatVisController ctrl) {
        this.ctrl = ctrl;
        setBackground(new Color(28, 38, 58));   // dark unsaturated blue
        setPreferredSize(new Dimension(400, 300));

        // xActiveIdx / yActiveIdx are updated in refresh() via display-dim getters.

        MouseAdapter ma = new MouseAdapter() {
            public void mousePressed(MouseEvent e)  { onPress(e); }
            public void mouseDragged(MouseEvent e)  { onDrag(e); }
            public void mouseReleased(MouseEvent e) { onRelease(e); }
            public void mouseMoved(MouseEvent e)    { onMove(e); }
            public void mouseWheelMoved(MouseWheelEvent e) { onWheel(e); }
            public void mouseClicked(MouseEvent e) {
                if (polygonMode() && e.getButton() == MouseEvent.BUTTON1
                        && inImageRect(e.getX(), e.getY())) {
                    // Polygon drawing: single click adds a vertex, double-click closes
                    if (e.getClickCount() >= 2) {
                        finishPolygon();
                    } else {
                        polyPts.add(new Point(panelToData(e.getX(), true),
                                              panelToData(e.getY(), false)));
                        repaint();
                    }
                    return;
                }
                if (polygonMode() && e.getButton() == MouseEvent.BUTTON3) {
                    // Right-click cancels an in-progress polygon
                    if (!polyPts.isEmpty()) { polyPts.clear(); repaint(); return; }
                }
                if (e.getButton() == MouseEvent.BUTTON1 && !roiDrawMode
                        && ctrl.isShowRois() && ctrl.isNativeDisplayPlane()
                        && inImageRect(e.getX(), e.getY())) {
                    // Plain click: select the ROI under the cursor (or deselect)
                    int dx = panelToData(e.getX(), true);
                    int dy = panelToData(e.getY(), false);
                    Roi[] rois = ctrl.getRois();
                    int hit = -1;
                    for (int i = 0; i < rois.length; i++) {
                        if (rois[i].contains(dx, dy)) { hit = i; break; }
                    }
                    if (hit != ctrl.getSelectedRoiIdx()) ctrl.setSelectedRoiIdx(hit);
                } else if (e.getButton() == MouseEvent.BUTTON3) {
                    resetZoom();
                } else if (e.getButton() == MouseEvent.BUTTON2) {
                    // Middle-click: move the position crosshair to the clicked data coordinate
                    if (inImageRect(e.getX(), e.getY())) {
                        if (xActiveIdx >= 0) ctrl.setCurrPos(xActiveIdx, panelToData(e.getX(), true));
                        if (yActiveIdx >= 0) ctrl.setCurrPos(yActiveIdx, panelToData(e.getY(), false));
                    }
                }
            }
        };
        addMouseListener(ma);
        addMouseMotionListener(ma);
        addMouseWheelListener(ma);
    }

    // ---- refresh -----------------------------------------------------------

    public void refresh() {
        // Re-read which dims are mapped to the display axes (may have been changed by user).
        xActiveIdx = ctrl.getXDisplayActiveDim();
        yActiveIdx = ctrl.getYDisplayActiveDim();
        if (ctrl.isRGB()) {
            currentImage = ctrl.renderCurrentRGBImage();
        } else {
            currentImage = ctrl.renderImage(ctrl.getCurrentSlice());
        }
        repaint();
    }

    // ---- painting ----------------------------------------------------------

    @Override
    protected void paintComponent(Graphics g) {
        super.paintComponent(g);
        if (currentImage == null) return;

        Graphics2D g2 = (Graphics2D) g.create();
        g2.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);

        // compute letterboxed image rect
        int PW = getWidth(), PH = getHeight();
        int IW = currentImage.getWidth(), IH = currentImage.getHeight();
        double scaleX = (double) PW / IW, scaleY = (double) PH / IH;
        double scale  = Math.min(scaleX, scaleY);
        imgW = (int) (IW * scale);
        imgH = (int) (IH * scale);
        imgX = (PW - imgW) / 2;
        imgY = (PH - imgH) / 2;

        g2.drawImage(currentImage, imgX, imgY, imgW, imgH, null);

        // ---- zoom rectangle + crosshair (suppressed in tile projection mode) -
        if (!ctrl.isProjectingTiled() && xActiveIdx >= 0 && yActiveIdx >= 0) {
            int zxMin = ctrl.getZoomMin(xActiveIdx);
            int zxMax = ctrl.getZoomMax(xActiveIdx);
            int zyMin = ctrl.getZoomMin(yActiveIdx);
            int zyMax = ctrl.getZoomMax(yActiveIdx);

            int rx0 = dataToPanel(zxMin, true);
            int rx1 = dataToPanel(zxMax + 1, true);
            int ry0 = dataToPanel(zyMin, false);
            int ry1 = dataToPanel(zyMax + 1, false);

            boolean fullX = (zxMin == 0 && zxMax == ctrl.getActiveDimSize(xActiveIdx) - 1);
            boolean fullY = (zyMin == 0 && zyMax == ctrl.getActiveDimSize(yActiveIdx) - 1);
            if (!fullX || !fullY) {
                g2.setColor(new Color(220, 60, 60));
                g2.setStroke(new BasicStroke(1.5f, BasicStroke.CAP_BUTT, BasicStroke.JOIN_BEVEL,
                        0, new float[]{5, 4}, 0));
                g2.drawRect(rx0, ry0, rx1 - rx0, ry1 - ry0);
            }
        }

        // ---- crosshair (also suppressed in tile mode) ----------------------
        if (!ctrl.isProjectingTiled() && xActiveIdx >= 0 && yActiveIdx >= 0) {
            int px = dataToPanel(ctrl.getCurrPos(xActiveIdx), true);
            int py = dataToPanel(ctrl.getCurrPos(yActiveIdx), false);

            g2.setColor(Color.WHITE);
            g2.setStroke(new BasicStroke(1f, BasicStroke.CAP_BUTT, BasicStroke.JOIN_BEVEL,
                    0, new float[]{4, 4}, 0));
            g2.drawLine(px, imgY, px, imgY + imgH);
            g2.drawLine(imgX, py, imgX + imgW, py);
        }

        // ---- ROI overlays (native X/Y plane only, not in tile mode) --------
        if (ctrl.isShowRois() && ctrl.isNativeDisplayPlane() && !ctrl.isProjectingTiled()) {
            Roi[] rois = ctrl.getRois();
            for (int i = 0; i < rois.length; i++) {
                boolean sel = ctrl.isRoiSelected(i);
                g2.setColor(MatVisController.roiColor(i));
                g2.setStroke(new BasicStroke(sel ? 3.2f : 1.2f));
                drawRoiOutline(g2, rois[i]);
            }
        }

        // ---- in-progress polygon ROI ----------------------------------------
        if (!polyPts.isEmpty()) {
            g2.setColor(new Color(255, 200, 0));
            g2.setStroke(new BasicStroke(1.5f));
            int prevX = -1, prevY = -1;
            for (Point p : polyPts) {
                int px = dataToPanel(p.x, true);
                int py = dataToPanel(p.y, false);
                if (prevX >= 0) g2.drawLine(prevX, prevY, px, py);
                g2.fillRect(px - 2, py - 2, 5, 5);
                prevX = px; prevY = py;
            }
            // preview segment to current mouse position
            if (polyMouseX >= 0) {
                g2.setColor(new Color(255, 200, 0, 140));
                g2.drawLine(prevX, prevY, polyMouseX, polyMouseY);
            }
        }

        // ---- rubber-band selection ----------------------------------------
        if (dragMode == DragMode.RUBBER_BAND) {
            int rx = Math.min(rubberX0, rubberX1);
            int ry = Math.min(rubberY0, rubberY1);
            int rw = Math.abs(rubberX1 - rubberX0);
            int rh = Math.abs(rubberY1 - rubberY0);
            g2.setColor(new Color(255, 220, 0, 120));
            g2.fillRect(rx, ry, rw, rh);
            g2.setColor(new Color(255, 200, 0));
            g2.setStroke(new BasicStroke(1.5f));
            g2.drawRect(rx, ry, rw, rh);
        }

        g2.dispose();
    }

    /** Draw an ROI outline mapped from data coords to panel coords. */
    private void drawRoiOutline(Graphics2D g2, Roi roi) {
        FloatPolygon fp = roi.getFloatPolygon();
        if (fp == null || fp.npoints < 2) return;
        int W = ctrl.dimSizes[0], H = ctrl.dimSizes[1];
        int n = fp.npoints;
        int[] xs = new int[n], ys = new int[n];
        for (int i = 0; i < n; i++) {
            xs[i] = imgX + (int) (fp.xpoints[i] / W * imgW);
            ys[i] = imgY + (int) (fp.ypoints[i] / H * imgH);
        }
        g2.drawPolygon(xs, ys, n);
    }

    // ---- coordinate conversion --------------------------------------------

    /** Image pixel coordinate → panel pixel x or y. */
    private int dataToPanel(int dataCoord, boolean isX) {
        if (isX) {
            int W = (xActiveIdx >= 0) ? ctrl.getActiveDimSize(xActiveIdx) : 1;
            return imgX + (int) ((double) dataCoord / W * imgW);
        } else {
            int H = (yActiveIdx >= 0) ? ctrl.getActiveDimSize(yActiveIdx) : 1;
            return imgY + (int) ((double) dataCoord / H * imgH);
        }
    }

    /** Panel pixel → image pixel x or y (clamped). */
    private int panelToData(int panelCoord, boolean isX) {
        if (isX) {
            int W = (xActiveIdx >= 0) ? ctrl.getActiveDimSize(xActiveIdx) : 1;
            double d = (double) (panelCoord - imgX) / imgW * W;
            return (int) Math.max(0, Math.min(W - 1, d));
        } else {
            int H = (yActiveIdx >= 0) ? ctrl.getActiveDimSize(yActiveIdx) : 1;
            double d = (double) (panelCoord - imgY) / imgH * H;
            return (int) Math.max(0, Math.min(H - 1, d));
        }
    }

    // ---- mouse handling ---------------------------------------------------

    private void onPress(MouseEvent e) {
        if (e.getButton() != MouseEvent.BUTTON1) return;
        if (polygonMode()) { dragMode = DragMode.NONE; return; } // clicks only
        int mx = e.getX(), my = e.getY();
        if (!inImageRect(mx, my)) return;

        if (xActiveIdx < 0 || yActiveIdx < 0) { dragMode = DragMode.RUBBER_BAND; return; }

        int px = dataToPanel(ctrl.getCurrPos(xActiveIdx), true);
        int py = dataToPanel(ctrl.getCurrPos(yActiveIdx), false);

        boolean nearX = Math.abs(mx - px) <= HIT_TOL;
        boolean nearY = Math.abs(my - py) <= HIT_TOL;

        if (nearX && nearY)  { dragMode = DragMode.POS_XY; }
        else if (nearX)       { dragMode = DragMode.POS_X; }
        else if (nearY)       { dragMode = DragMode.POS_Y; }
        else {
            // near zoom rect edge → pan; else rubber-band
            dragMode = DragMode.RUBBER_BAND;
            rubberX0 = rubberX1 = mx;
            rubberY0 = rubberY1 = my;
        }
    }

    private void onDrag(MouseEvent e) {
        int mx = e.getX(), my = e.getY();
        if (dragMode == DragMode.POS_X || dragMode == DragMode.POS_XY) {
            if (xActiveIdx >= 0)
                ctrl.setCurrPos(xActiveIdx, panelToData(mx, true));
        }
        if (dragMode == DragMode.POS_Y || dragMode == DragMode.POS_XY) {
            if (yActiveIdx >= 0)
                ctrl.setCurrPos(yActiveIdx, panelToData(my, false));
        }
        if (dragMode == DragMode.RUBBER_BAND) {
            rubberX1 = mx;
            rubberY1 = my;
            repaint();
        }
    }

    private void onRelease(MouseEvent e) {
        if (dragMode == DragMode.RUBBER_BAND && xActiveIdx >= 0 && yActiveIdx >= 0) {
            int x0 = panelToData(Math.min(rubberX0, rubberX1), true);
            int x1 = panelToData(Math.max(rubberX0, rubberX1), true);
            int y0 = panelToData(Math.min(rubberY0, rubberY1), false);
            int y1 = panelToData(Math.max(rubberY0, rubberY1), false);
            if (x1 > x0 && y1 > y0) {
                if (roiDrawMode && ctrl.isNativeDisplayPlane()) {
                    // Draw mode: rubber band creates a new ROI in the RoiManager
                    Roi roi = "Oval".equals(roiShape)
                            ? new OvalRoi(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
                            : new Roi(x0, y0, x1 - x0 + 1, y1 - y0 + 1);
                    ctrl.addRoi(roi);
                } else {
                    ctrl.setZoomRange(xActiveIdx, x0, x1);
                    ctrl.setZoomRange(yActiveIdx, y0, y1);
                }
            }
        }
        dragMode = DragMode.NONE;
        repaint();
    }

    private void onMove(MouseEvent e) {
        if (polygonMode()) {
            polyMouseX = e.getX();
            polyMouseY = e.getY();
            setCursor(Cursor.getPredefinedCursor(Cursor.CROSSHAIR_CURSOR));
            if (!polyPts.isEmpty()) repaint();
            return;
        }
        if (xActiveIdx < 0 || yActiveIdx < 0) return;
        int mx = e.getX(), my = e.getY();
        int px = dataToPanel(ctrl.getCurrPos(xActiveIdx), true);
        int py = dataToPanel(ctrl.getCurrPos(yActiveIdx), false);
        boolean nearX = Math.abs(mx - px) <= HIT_TOL;
        boolean nearY = Math.abs(my - py) <= HIT_TOL;

        if (nearX && nearY)
            setCursor(Cursor.getPredefinedCursor(Cursor.MOVE_CURSOR));
        else if (nearX)
            setCursor(Cursor.getPredefinedCursor(Cursor.E_RESIZE_CURSOR));
        else if (nearY)
            setCursor(Cursor.getPredefinedCursor(Cursor.N_RESIZE_CURSOR));
        else
            setCursor(Cursor.getPredefinedCursor(Cursor.CROSSHAIR_CURSOR));
    }

    private void onWheel(MouseWheelEvent e) {
        if (xActiveIdx < 0 || yActiveIdx < 0) return;
        double factor = e.getWheelRotation() > 0 ? 1.25 : 1.0 / 1.25;

        int cx = panelToData(e.getX(), true);
        int cy = panelToData(e.getY(), false);

        zoomAroundPoint(xActiveIdx, cx, factor, ctrl.dimSizes[0]);
        zoomAroundPoint(yActiveIdx, cy, factor, ctrl.dimSizes[1]);
    }

    private void zoomAroundPoint(int activeIdx, int centre, double factor, int totalSize) {
        int oldMin = ctrl.getZoomMin(activeIdx);
        int oldMax = ctrl.getZoomMax(activeIdx);
        int oldLen = oldMax - oldMin + 1;
        int newLen = (int) Math.max(1, Math.min(totalSize, oldLen * factor));

        int newMin = centre - (int) ((centre - oldMin) * (double) newLen / oldLen);
        int newMax = newMin + newLen - 1;

        if (newMin < 0) { newMax -= newMin; newMin = 0; }
        if (newMax >= totalSize) { newMin -= (newMax - totalSize + 1); newMax = totalSize - 1; }
        newMin = Math.max(0, newMin);

        ctrl.setZoomRange(activeIdx, newMin, newMax);
    }

    private boolean inImageRect(int mx, int my) {
        return mx >= imgX && mx <= imgX + imgW && my >= imgY && my <= imgY + imgH;
    }

    private void resetZoom() {
        if (xActiveIdx >= 0)
            ctrl.setZoomRange(xActiveIdx, 0, ctrl.getActiveDimSize(xActiveIdx) - 1);
        if (yActiveIdx >= 0)
            ctrl.setZoomRange(yActiveIdx, 0, ctrl.getActiveDimSize(yActiveIdx) - 1);
    }
}
