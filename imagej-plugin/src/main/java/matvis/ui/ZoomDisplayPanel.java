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
 * Zoomed-crop display panel.
 * Shows only the (xZoomRange × yZoomRange) sub-region, stretched to fill the panel.
 * Overlays a white crosshair in local (zoom-relative) coordinates.
 * Mouse interactions mirror ImageDisplayPanel but in zoom-space.
 */
public class ZoomDisplayPanel extends JPanel {

    private final MatVisController ctrl;
    private int xActiveIdx = -1;
    private int yActiveIdx = -1;
    private BufferedImage currentImage;
    private int imgX, imgY, imgW, imgH;

    private enum DragMode { NONE, POS_X, POS_Y, POS_XY, RUBBER_BAND }
    private DragMode dragMode = DragMode.NONE;
    private int rubberX0, rubberY0, rubberX1, rubberY1;
    private static final int HIT_TOL = 6;

    // ROI drawing mode (set from the main-frame toolbar, mirrors ImageDisplayPanel)
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

    public ZoomDisplayPanel(MatVisController ctrl) {
        this.ctrl = ctrl;
        setBackground(new Color(28, 38, 58));   // dark unsaturated blue
        setPreferredSize(new Dimension(300, 250));

        // xActiveIdx / yActiveIdx are refreshed in refresh() via display-dim getters.

        MouseAdapter ma = new MouseAdapter() {
            public void mousePressed(MouseEvent e)  { onPress(e); }
            public void mouseDragged(MouseEvent e)  { onDrag(e); }
            public void mouseReleased(MouseEvent e) { onRelease(e); }
            public void mouseMoved(MouseEvent e)    { onMove(e); }
            public void mouseClicked(MouseEvent e) {
                if (polygonMode() && e.getButton() == MouseEvent.BUTTON1) {
                    // Polygon drawing: single click adds a vertex, double-click closes
                    if (e.getClickCount() >= 2) {
                        finishPolygon();
                    } else {
                        polyPts.add(new Point(panelToZoomData(e.getX(), true),
                                              panelToZoomData(e.getY(), false)));
                        repaint();
                    }
                    return;
                }
                if (polygonMode() && e.getButton() == MouseEvent.BUTTON3
                        && !polyPts.isEmpty()) {
                    // Right-click cancels an in-progress polygon
                    polyPts.clear();
                    repaint();
                    return;
                }
                if (e.getButton() == MouseEvent.BUTTON3) {
                    // Right-click → reset X and Y zoom to full range
                    if (xActiveIdx >= 0)
                        ctrl.setZoomRange(xActiveIdx, 0, ctrl.getActiveDimSize(xActiveIdx) - 1);
                    if (yActiveIdx >= 0)
                        ctrl.setZoomRange(yActiveIdx, 0, ctrl.getActiveDimSize(yActiveIdx) - 1);
                } else if (e.getButton() == MouseEvent.BUTTON2) {
                    // Middle-click → set position to clicked data coordinate (zoom-space)
                    if (xActiveIdx >= 0) ctrl.setCurrPos(xActiveIdx, panelToZoomData(e.getX(), true));
                    if (yActiveIdx >= 0) ctrl.setCurrPos(yActiveIdx, panelToZoomData(e.getY(), false));
                }
            }
        };
        addMouseListener(ma);
        addMouseMotionListener(ma);
    }

    public void refresh() {
        // Re-read which dims are mapped to the display axes.
        xActiveIdx = ctrl.getXDisplayActiveDim();
        yActiveIdx = ctrl.getYDisplayActiveDim();
        if (ctrl.isRGB()) {
            currentImage = ctrl.renderZoomRGBImage();
        } else {
            currentImage = ctrl.renderImage(ctrl.getZoomSlice());
        }
        repaint();
    }

    @Override
    protected void paintComponent(Graphics g) {
        super.paintComponent(g);
        if (currentImage == null || currentImage.getWidth() == 0) return;

        Graphics2D g2 = (Graphics2D) g.create();
        g2.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);

        int PW = getWidth(), PH = getHeight();
        int IW = currentImage.getWidth(), IH = currentImage.getHeight();
        double scale = Math.min((double) PW / IW, (double) PH / IH);
        imgW = (int) (IW * scale);
        imgH = (int) (IH * scale);
        imgX = (PW - imgW) / 2;
        imgY = (PH - imgH) / 2;

        g2.drawImage(currentImage, imgX, imgY, imgW, imgH, null);

        // crosshair in zoom-local coords
        if (xActiveIdx >= 0 && yActiveIdx >= 0) {
            int zxMin = ctrl.getZoomMin(xActiveIdx);
            int zyMin = ctrl.getZoomMin(yActiveIdx);
            int zxMax = ctrl.getZoomMax(xActiveIdx);
            int zyMax = ctrl.getZoomMax(yActiveIdx);
            int zW = zxMax - zxMin + 1;
            int zH = zyMax - zyMin + 1;

            int localX = ctrl.getCurrPos(xActiveIdx) - zxMin;
            int localY = ctrl.getCurrPos(yActiveIdx) - zyMin;

            int px = imgX + (int) ((double) localX / zW * imgW);
            int py = imgY + (int) ((double) localY / zH * imgH);

            g2.setColor(Color.WHITE);
            g2.setStroke(new BasicStroke(1f, BasicStroke.CAP_BUTT, BasicStroke.JOIN_BEVEL,
                    0, new float[]{4, 4}, 0));
            g2.drawLine(px, imgY, px, imgY + imgH);
            g2.drawLine(imgX, py, imgX + imgW, py);
        }

        // ROI overlays (zoom-space mapping; native X/Y plane only)
        if (ctrl.isShowRois() && ctrl.isNativeDisplayPlane() && !ctrl.isProjectingTiled()
                && xActiveIdx >= 0 && yActiveIdx >= 0) {
            int zxMin = ctrl.getZoomMin(xActiveIdx);
            int zyMin = ctrl.getZoomMin(yActiveIdx);
            int zW = ctrl.getZoomMax(xActiveIdx) - zxMin + 1;
            int zH = ctrl.getZoomMax(yActiveIdx) - zyMin + 1;
            Roi[] rois = ctrl.getRois();
            Shape oldClip = g2.getClip();
            g2.setClip(imgX, imgY, imgW, imgH);
            for (int i = 0; i < rois.length; i++) {
                FloatPolygon fp = rois[i].getFloatPolygon();
                if (fp == null || fp.npoints < 2) continue;
                int n = fp.npoints;
                int[] xs = new int[n], ys = new int[n];
                for (int k = 0; k < n; k++) {
                    xs[k] = imgX + (int) ((fp.xpoints[k] - zxMin) / zW * imgW);
                    ys[k] = imgY + (int) ((fp.ypoints[k] - zyMin) / zH * imgH);
                }
                boolean sel = ctrl.isRoiSelected(i);
                g2.setColor(MatVisController.roiColor(i));
                g2.setStroke(new BasicStroke(sel ? 3.2f : 1.2f));
                g2.drawPolygon(xs, ys, n);
            }
            g2.setClip(oldClip);
        }

        // in-progress polygon ROI (vertices stored in data coords)
        if (!polyPts.isEmpty()) {
            g2.setColor(new Color(255, 200, 0));
            g2.setStroke(new BasicStroke(1.5f));
            int prevX = -1, prevY = -1;
            for (Point p : polyPts) {
                int px = dataToZoomPanel(p.x, true);
                int py = dataToZoomPanel(p.y, false);
                if (prevX >= 0) g2.drawLine(prevX, prevY, px, py);
                g2.fillRect(px - 2, py - 2, 5, 5);
                prevX = px; prevY = py;
            }
            if (polyMouseX >= 0) {
                g2.setColor(new Color(255, 200, 0, 140));
                g2.drawLine(prevX, prevY, polyMouseX, polyMouseY);
            }
        }

        // rubber band
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

    // ---- coord helpers ----------------------------------------------------

    private int panelToZoomData(int panelCoord, boolean isX) {
        if (xActiveIdx < 0 || yActiveIdx < 0) return 0;
        if (isX) {
            int zxMin = ctrl.getZoomMin(xActiveIdx);
            int zxMax = ctrl.getZoomMax(xActiveIdx);
            int zW = zxMax - zxMin + 1;
            double d = (double) (panelCoord - imgX) / imgW * zW + zxMin;
            int maxVal = ctrl.getActiveDimSize(xActiveIdx) - 1;
            return (int) Math.max(0, Math.min(maxVal, d));
        } else {
            int zyMin = ctrl.getZoomMin(yActiveIdx);
            int zyMax = ctrl.getZoomMax(yActiveIdx);
            int zH = zyMax - zyMin + 1;
            double d = (double) (panelCoord - imgY) / imgH * zH + zyMin;
            int maxVal = ctrl.getActiveDimSize(yActiveIdx) - 1;
            return (int) Math.max(0, Math.min(maxVal, d));
        }
    }

    private int dataToZoomPanel(int dataCoord, boolean isX) {
        if (xActiveIdx < 0 || yActiveIdx < 0) return 0;
        if (isX) {
            int zxMin = ctrl.getZoomMin(xActiveIdx);
            int zxMax = ctrl.getZoomMax(xActiveIdx);
            int zW = zxMax - zxMin + 1;
            return imgX + (int) ((double) (dataCoord - zxMin) / zW * imgW);
        } else {
            int zyMin = ctrl.getZoomMin(yActiveIdx);
            int zyMax = ctrl.getZoomMax(yActiveIdx);
            int zH = zyMax - zyMin + 1;
            return imgY + (int) ((double) (dataCoord - zyMin) / zH * imgH);
        }
    }

    // ---- mouse ------------------------------------------------------------

    private void onPress(MouseEvent e) {
        if (e.getButton() != MouseEvent.BUTTON1) return;
        if (polygonMode()) { dragMode = DragMode.NONE; return; } // clicks only
        if (xActiveIdx < 0 || yActiveIdx < 0) return;

        int mx = e.getX(), my = e.getY();
        int px = dataToZoomPanel(ctrl.getCurrPos(xActiveIdx), true);
        int py = dataToZoomPanel(ctrl.getCurrPos(yActiveIdx), false);

        boolean nearX = Math.abs(mx - px) <= HIT_TOL;
        boolean nearY = Math.abs(my - py) <= HIT_TOL;

        if (nearX && nearY)  dragMode = DragMode.POS_XY;
        else if (nearX)       dragMode = DragMode.POS_X;
        else if (nearY)       dragMode = DragMode.POS_Y;
        else {
            dragMode = DragMode.RUBBER_BAND;
            rubberX0 = rubberX1 = mx;
            rubberY0 = rubberY1 = my;
        }
    }

    private void onDrag(MouseEvent e) {
        int mx = e.getX(), my = e.getY();
        if (dragMode == DragMode.POS_X || dragMode == DragMode.POS_XY)
            ctrl.setCurrPos(xActiveIdx, panelToZoomData(mx, true));
        if (dragMode == DragMode.POS_Y || dragMode == DragMode.POS_XY)
            ctrl.setCurrPos(yActiveIdx, panelToZoomData(my, false));
        if (dragMode == DragMode.RUBBER_BAND) {
            rubberX1 = mx; rubberY1 = my; repaint();
        }
    }

    private void onRelease(MouseEvent e) {
        if (dragMode == DragMode.RUBBER_BAND && xActiveIdx >= 0 && yActiveIdx >= 0) {
            int x0 = panelToZoomData(Math.min(rubberX0, rubberX1), true);
            int x1 = panelToZoomData(Math.max(rubberX0, rubberX1), true);
            int y0 = panelToZoomData(Math.min(rubberY0, rubberY1), false);
            int y1 = panelToZoomData(Math.max(rubberY0, rubberY1), false);
            if (x1 > x0 && y1 > y0) {
                if (roiDrawMode && ctrl.isNativeDisplayPlane()) {
                    // Draw mode: rubber band creates a new ROI (zoom drawing disabled)
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
        int px = dataToZoomPanel(ctrl.getCurrPos(xActiveIdx), true);
        int py = dataToZoomPanel(ctrl.getCurrPos(yActiveIdx), false);
        boolean nearX = Math.abs(mx - px) <= HIT_TOL;
        boolean nearY = Math.abs(my - py) <= HIT_TOL;

        if (nearX && nearY) setCursor(Cursor.getPredefinedCursor(Cursor.MOVE_CURSOR));
        else if (nearX)      setCursor(Cursor.getPredefinedCursor(Cursor.E_RESIZE_CURSOR));
        else if (nearY)      setCursor(Cursor.getPredefinedCursor(Cursor.N_RESIZE_CURSOR));
        else                 setCursor(Cursor.getPredefinedCursor(Cursor.CROSSHAIR_CURSOR));
    }
}
