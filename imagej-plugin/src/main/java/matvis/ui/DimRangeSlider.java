package matvis.ui;

import matvis.MatVisController;

import javax.swing.*;
import java.awt.*;
import java.awt.event.*;
import java.util.Timer;
import java.util.TimerTask;

/**
 * Custom widget for one dimension: position + zoom range + play controls.
 *
 * Layout (two rows):
 *   Row 1:  [Name label] [pos field] [◀][track][▶] [▶ |▶| ▶▶] [plot □] [🔒]
 *   Row 2:  [zoomMin field] ─ [zoomMax field]  [:N frames]
 *
 * The track shows:
 *   - light-gray fill = full range
 *   - blue fill       = zoom sub-range
 *   - red marker      = current position
 */
public class DimRangeSlider extends JPanel {

    private static final Color CLR_FULL   = new Color(220, 220, 220);
    private static final Color CLR_ZOOM   = new Color(100, 160, 230, 180);
    private static final Color CLR_POS    = new Color(220, 50, 50);
    private static final Color CLR_BORDER = new Color(150, 150, 150);

    private final MatVisController ctrl;
    private final int activeDimIdx;

    // UI components - row 1
    private final JLabel     lblName;
    private final JTextField fldPos;
    private final JPanel     trackPanel;
    private final JButton    btnLeft;
    private final JButton    btnRight;
    private final JToggleButton btnPlayFull;
    private final JToggleButton btnPlayZoom;
    private final JToggleButton btnPlayShift;
    private final JCheckBox  chkPlot;
    private final JToggleButton btnLock;

    // UI components - row 2
    private final JTextField fldZoomMin;
    private final JTextField fldZoomMax;
    private final JLabel     lblZoomLen;

    // drag state
    private enum DragMode { NONE, POS, ZOOM_LEFT, ZOOM_RIGHT, ZOOM_PAN }
    private DragMode dragMode = DragMode.NONE;
    private int dragStartX;
    private int dragStartZoomMin, dragStartZoomMax;

    // play timer
    private Timer playTimer;
    private String playMode = ""; // "full" | "zoom" | "shift"
    private int tickCounter = 0;  // counts timer ticks for slow-speed pausing

    // original labels (restored when play stops)
    private static final String LBL_FULL  = "▶";      // ▶
    private static final String LBL_ZOOM  = "|▶|";    // |▶|
    private static final String LBL_SHIFT = "▶▶";// ▶▶
    private static final String LBL_PAUSE = "⏸";      // ⏸

    /**
     * Optional callback invoked (on the EDT) whenever this slider starts
     * playing. The MatVisFrame uses this to stop all other sliders so that
     * only one animation runs at a time across all dimensions.
     */
    private Runnable onPlayStart;

    /**
     * Optional callback invoked (on the EDT) when the user manually stops
     * playback (clicks the active ⏸ button). The MatVisFrame uses this to
     * re-enable all other sliders' play buttons.
     */
    private Runnable onPlayStop;

    public DimRangeSlider(MatVisController ctrl, int activeDimIdx) {
        this.ctrl = ctrl;
        this.activeDimIdx = activeDimIdx;

        setLayout(new BoxLayout(this, BoxLayout.Y_AXIS));
        setBorder(BorderFactory.createEmptyBorder(1, 4, 1, 4));

        String dimName = ctrl.getActiveDimName(activeDimIdx);

        // ---- Row 1 --------------------------------------------------------
        JPanel row1 = new JPanel(new GridBagLayout());
        row1.setOpaque(false);

        GridBagConstraints gc = new GridBagConstraints();
        gc.insets = new Insets(0, 1, 0, 1);
        gc.fill   = GridBagConstraints.HORIZONTAL;
        gc.gridy  = 0;

        // dim name
        lblName = new JLabel(dimName);
        lblName.setFont(lblName.getFont().deriveFont(Font.BOLD, 11f));
        lblName.setPreferredSize(new Dimension(28, 22));
        gc.gridx = 0; gc.weightx = 0;
        row1.add(lblName, gc);

        // position field
        fldPos = makeNumField(4);
        gc.gridx = 1; gc.weightx = 0;
        row1.add(fldPos, gc);

        // left step button
        btnLeft = makeArrowBtn("◀");
        gc.gridx = 2; gc.weightx = 0;
        row1.add(btnLeft, gc);

        // track panel (stretchy)
        trackPanel = new TrackPanel();
        trackPanel.setPreferredSize(new Dimension(60, 22));
        gc.gridx = 3; gc.weightx = 1.0;
        row1.add(trackPanel, gc);

        // right step button
        btnRight = makeArrowBtn("▶");
        gc.gridx = 4; gc.weightx = 0;
        row1.add(btnRight, gc);

        // play buttons  (NO ButtonGroup — we manage exclusivity manually so
        // clicking the active button again can stop play)
        btnPlayFull  = makePlayBtn(LBL_FULL,  "Play full range");
        btnPlayZoom  = makePlayBtn(LBL_ZOOM,  "Play within zoom");
        btnPlayShift = makePlayBtn(LBL_SHIFT, "Shift zoom window");

        gc.gridx = 5; gc.weightx = 0; row1.add(btnPlayFull,  gc);
        gc.gridx = 6;                  row1.add(btnPlayZoom,  gc);
        gc.gridx = 7;                  row1.add(btnPlayShift, gc);

        // plot checkbox
        chkPlot = new JCheckBox();
        chkPlot.setToolTipText("Show 1-D profile plot");
        chkPlot.setOpaque(false);
        gc.gridx = 8; row1.add(chkPlot, gc);

        // lock button
        btnLock = new JToggleButton("🔒");
        btnLock.setFont(btnLock.getFont().deriveFont(9f));
        btnLock.setMargin(new Insets(0, 0, 0, 0));
        btnLock.setPreferredSize(new Dimension(22, 20));
        btnLock.setToolTipText("Lock plot x-axis to zoom range");
        gc.gridx = 9; row1.add(btnLock, gc);

        // ---- Row 2 --------------------------------------------------------
        JPanel row2 = new JPanel(new FlowLayout(FlowLayout.CENTER, 2, 0));
        row2.setOpaque(false);

        fldZoomMin = makeNumField(4);
        fldZoomMax = makeNumField(4);
        lblZoomLen = new JLabel(":1");
        lblZoomLen.setFont(lblZoomLen.getFont().deriveFont(10f));
        lblZoomLen.setForeground(Color.GRAY);

        row2.add(new JLabel("  "));
        row2.add(fldZoomMin);
        row2.add(new JLabel("–"));
        row2.add(fldZoomMax);
        row2.add(lblZoomLen);

        add(row1);
        add(row2);

        // ---- Wire events --------------------------------------------------
        btnLeft.addActionListener(e -> stepPos(-1));
        btnRight.addActionListener(e -> stepPos(+1));

        btnPlayFull.addActionListener(e  -> togglePlay("full",  btnPlayFull.isSelected()));
        btnPlayZoom.addActionListener(e  -> togglePlay("zoom",  btnPlayZoom.isSelected()));
        btnPlayShift.addActionListener(e -> togglePlay("shift", btnPlayShift.isSelected()));

        chkPlot.addActionListener(e ->
            ctrl.setShowPlot(activeDimIdx, chkPlot.isSelected()));

        btnLock.addActionListener(e ->
            ctrl.setPlotLock(activeDimIdx, btnLock.isSelected()));

        fldPos.addActionListener(e -> applyPosField());
        fldZoomMin.addActionListener(e -> applyZoomFields());
        fldZoomMax.addActionListener(e -> applyZoomFields());

        // track mouse
        trackPanel.addMouseListener(new MouseAdapter() {
            public void mousePressed(MouseEvent e)  { onTrackPress(e); }
            public void mouseReleased(MouseEvent e) { dragMode = DragMode.NONE; }
        });
        trackPanel.addMouseMotionListener(new MouseMotionAdapter() {
            public void mouseDragged(MouseEvent e)  { onTrackDrag(e); }
            public void mouseMoved(MouseEvent e)    { onTrackHover(e); }
        });

        refreshUI();
    }

    // ---- UI helpers -------------------------------------------------------

    private JTextField makeNumField(int cols) {
        JTextField f = new JTextField(cols);
        f.setFont(f.getFont().deriveFont(10f));
        f.setPreferredSize(new Dimension(cols * 7, 20));
        f.setHorizontalAlignment(JTextField.RIGHT);
        return f;
    }

    private JButton makeArrowBtn(String text) {
        JButton b = new JButton(text);
        b.setFont(b.getFont().deriveFont(9f));
        b.setMargin(new Insets(0, 1, 0, 1));
        b.setPreferredSize(new Dimension(20, 20));
        return b;
    }

    private JToggleButton makePlayBtn(String text, String tip) {
        JToggleButton b = new JToggleButton(text);
        b.setFont(b.getFont().deriveFont(9f));
        b.setMargin(new Insets(0, 1, 0, 1));
        b.setPreferredSize(new Dimension(26, 20));
        b.setToolTipText(tip);
        return b;
    }

    // ---- refresh from model -----------------------------------------------

    public void refreshUI() {
        int pos    = ctrl.getCurrPos(activeDimIdx);
        int zMin   = ctrl.getZoomMin(activeDimIdx);
        int zMax   = ctrl.getZoomMax(activeDimIdx);

        fldPos.setText(String.valueOf(pos + 1));     // display 1-based
        fldZoomMin.setText(String.valueOf(zMin + 1));
        fldZoomMax.setText(String.valueOf(zMax + 1));
        lblZoomLen.setText(":" + (zMax - zMin + 1));
        chkPlot.setSelected(ctrl.getShowPlot(activeDimIdx));
        btnLock.setSelected(ctrl.getPlotLock(activeDimIdx));
        trackPanel.repaint();
    }

    // ---- position / zoom manipulation -------------------------------------

    private void stepPos(int delta) {
        int pos = ctrl.getCurrPos(activeDimIdx) + delta;
        ctrl.setCurrPos(activeDimIdx, pos);
    }

    private void applyPosField() {
        try {
            int v = Integer.parseInt(fldPos.getText().trim()) - 1;
            ctrl.setCurrPos(activeDimIdx, v);
        } catch (NumberFormatException ignored) {}
    }

    private void applyZoomFields() {
        try {
            int mn = Integer.parseInt(fldZoomMin.getText().trim()) - 1;
            int mx = Integer.parseInt(fldZoomMax.getText().trim()) - 1;
            ctrl.setZoomRange(activeDimIdx, mn, mx);
        } catch (NumberFormatException ignored) {}
    }

    // ---- track coordinate conversions -------------------------------------

    private int trackToData(int px) {
        int tw = trackPanel.getWidth();
        if (tw <= 0) return 0;
        int sz = ctrl.getActiveDimSize(activeDimIdx);
        return (int) Math.round((double) px / tw * (sz - 1));
    }

    private int dataToTrack(int data) {
        int sz = ctrl.getActiveDimSize(activeDimIdx);
        if (sz <= 1) return trackPanel.getWidth() / 2;
        int tw = trackPanel.getWidth();
        return (int) Math.round((double) data / (sz - 1) * tw);
    }

    // ---- track interactions -----------------------------------------------

    private static final int EDGE_TOL = 5; // px to detect zoom edge

    private void onTrackPress(MouseEvent e) {
        int mx   = e.getX();
        int pos  = ctrl.getCurrPos(activeDimIdx);
        int zMin = ctrl.getZoomMin(activeDimIdx);
        int zMax = ctrl.getZoomMax(activeDimIdx);

        int posX  = dataToTrack(pos);
        int zMinX = dataToTrack(zMin);
        int zMaxX = dataToTrack(zMax);

        dragStartX       = mx;
        dragStartZoomMin = zMin;
        dragStartZoomMax = zMax;

        if (Math.abs(mx - posX) <= Math.max(EDGE_TOL, (zMaxX - zMinX) / 4)) {
            dragMode = DragMode.POS;
        } else if (Math.abs(mx - zMinX) <= EDGE_TOL) {
            dragMode = DragMode.ZOOM_LEFT;
        } else if (Math.abs(mx - zMaxX) <= EDGE_TOL) {
            dragMode = DragMode.ZOOM_RIGHT;
        } else if (mx > zMinX && mx < zMaxX) {
            dragMode = DragMode.ZOOM_PAN;
        } else {
            // Click outside zoom = move position
            dragMode = DragMode.POS;
            ctrl.setCurrPos(activeDimIdx, trackToData(mx));
        }
    }

    private void onTrackDrag(MouseEvent e) {
        int mx   = e.getX();
        int sz   = ctrl.getActiveDimSize(activeDimIdx);
        int delta = trackToData(mx) - trackToData(dragStartX);

        switch (dragMode) {
            case POS:
                ctrl.setCurrPos(activeDimIdx, trackToData(mx));
                break;
            case ZOOM_LEFT: {
                int newMin = Math.max(0, Math.min(dragStartZoomMin + delta, dragStartZoomMax));
                ctrl.setZoomRange(activeDimIdx, newMin, dragStartZoomMax);
                break;
            }
            case ZOOM_RIGHT: {
                int newMax = Math.max(dragStartZoomMin, Math.min(dragStartZoomMax + delta, sz - 1));
                ctrl.setZoomRange(activeDimIdx, dragStartZoomMin, newMax);
                break;
            }
            case ZOOM_PAN: {
                int len = dragStartZoomMax - dragStartZoomMin;
                int newMin = Math.max(0, Math.min(dragStartZoomMin + delta, sz - 1 - len));
                ctrl.setZoomRange(activeDimIdx, newMin, newMin + len);
                break;
            }
            default:
                break;
        }
    }

    private void onTrackHover(MouseEvent e) {
        int mx   = e.getX();
        int zMinX = dataToTrack(ctrl.getZoomMin(activeDimIdx));
        int zMaxX = dataToTrack(ctrl.getZoomMax(activeDimIdx));
        int posX  = dataToTrack(ctrl.getCurrPos(activeDimIdx));

        Cursor c;
        if (Math.abs(mx - zMinX) <= EDGE_TOL || Math.abs(mx - zMaxX) <= EDGE_TOL)
            c = Cursor.getPredefinedCursor(Cursor.E_RESIZE_CURSOR);
        else if (Math.abs(mx - posX) <= Math.max(EDGE_TOL, (zMaxX - zMinX) / 4))
            c = Cursor.getPredefinedCursor(Cursor.CROSSHAIR_CURSOR);
        else if (mx > zMinX && mx < zMaxX)
            c = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR);
        else
            c = Cursor.getDefaultCursor();

        trackPanel.setCursor(c);
    }

    // ---- play / animation -------------------------------------------------

    /** Register a callback invoked whenever this slider starts playing. */
    public void setOnPlayStart(Runnable callback) { this.onPlayStart = callback; }

    /** Register a callback invoked when the user manually stops playback. */
    public void setOnPlayStop(Runnable callback) { this.onPlayStop = callback; }

    /**
     * Enable or disable all three play buttons on this slider.
     * Used by the MatVisFrame coordinator to grey out other sliders while
     * one animation is running.
     */
    public void setPlayButtonsEnabled(boolean enabled) {
        btnPlayFull.setEnabled(enabled);
        btnPlayZoom.setEnabled(enabled);
        btnPlayShift.setEnabled(enabled);
    }

    /**
     * Stop this slider's animation, restore all three play button labels, and
     * re-enable all three buttons (the frame coordinator may immediately
     * disable them again via setPlayButtonsEnabled if another slider is active).
     */
    public void stopPlay() {
        if (playTimer != null) { playTimer.cancel(); playTimer = null; ctrl.setPlaying(false); }
        playMode = "";
        btnPlayFull.setSelected(false);  btnPlayFull.setText(LBL_FULL);  btnPlayFull.setEnabled(true);
        btnPlayZoom.setSelected(false);  btnPlayZoom.setText(LBL_ZOOM);  btnPlayZoom.setEnabled(true);
        btnPlayShift.setSelected(false); btnPlayShift.setText(LBL_SHIFT); btnPlayShift.setEnabled(true);
    }

    private void togglePlay(String mode, boolean selected) {
        if (!selected) {
            // User clicked the active (⏸) button again → stop.
            if (playTimer != null) { playTimer.cancel(); playTimer = null; }
            ctrl.setPlaying(false);
            playMode = "";
            // Restore label and re-enable all three buttons on this slider.
            btnPlayFull.setText(LBL_FULL);  btnPlayFull.setEnabled(true);
            btnPlayZoom.setText(LBL_ZOOM);  btnPlayZoom.setEnabled(true);
            btnPlayShift.setText(LBL_SHIFT); btnPlayShift.setEnabled(true);
            // Notify the frame coordinator so it re-enables buttons on all OTHER sliders.
            if (onPlayStop != null) onPlayStop.run();
            return;
        }
        // Starting a new animation — cancel any running timer first.
        if (playTimer != null) { playTimer.cancel(); playTimer = null; }
        playMode = "";
        // Deselect, restore label, and DISABLE the other two buttons on this slider.
        if (!"full".equals(mode))  { btnPlayFull.setSelected(false);  btnPlayFull.setText(LBL_FULL);  btnPlayFull.setEnabled(false); }
        if (!"zoom".equals(mode))  { btnPlayZoom.setSelected(false);  btnPlayZoom.setText(LBL_ZOOM);  btnPlayZoom.setEnabled(false); }
        if (!"shift".equals(mode)) { btnPlayShift.setSelected(false); btnPlayShift.setText(LBL_SHIFT); btnPlayShift.setEnabled(false); }
        // Change the active button's label to pause icon.
        if ("full".equals(mode))  btnPlayFull.setText(LBL_PAUSE);
        if ("zoom".equals(mode))  btnPlayZoom.setText(LBL_PAUSE);
        if ("shift".equals(mode)) btnPlayShift.setText(LBL_PAUSE);
        // Tell the frame coordinator to stop + disable all OTHER sliders.
        if (onPlayStart != null) onPlayStart.run();
        // Start the timer.
        playMode = mode;
        tickCounter = 0;
        ctrl.setPlaying(true);
        playTimer = new Timer(true);
        playTimer.scheduleAtFixedRate(new TimerTask() {
            public void run() { SwingUtilities.invokeLater(() -> onTick()); }
        }, MatVisController.PLAY_TICK_MS, MatVisController.PLAY_TICK_MS);
    }

    /** Fires every tick; advances only on every Nth tick (slow speeds pause). */
    private void onTick() {
        if (playMode.isEmpty()) return;
        int divisor = ctrl.getPlayTickDivisor();
        if (++tickCounter < divisor) return; // pause-tick: hold the current frame
        tickCounter = 0;
        stepPlay();
    }

    private void stepPlay() {
        ctrl.recordPlayFrame();   // measure real displayed-frame rate
        int sz   = ctrl.getActiveDimSize(activeDimIdx);
        int pos  = ctrl.getCurrPos(activeDimIdx);
        int zMin = ctrl.getZoomMin(activeDimIdx);
        int zMax = ctrl.getZoomMax(activeDimIdx);
        int step = ctrl.getPlayFrameStep();   // >1 → skip frames

        switch (playMode) {
            case "full": {
                int next = pos + step;
                if (next >= sz) next = next - sz;       // wrap
                ctrl.setCurrPos(activeDimIdx, next);
                break;
            }
            case "zoom": {
                int span = zMax - zMin + 1;
                int next = pos + step;
                if (next > zMax) next = zMin + ((next - zMin) % span);
                ctrl.setCurrPos(activeDimIdx, next);
                break;
            }
            case "shift": {
                int len = zMax - zMin;
                int nMin = zMin + step;
                if (nMin + len >= sz) nMin = 0;
                ctrl.setZoomRange(activeDimIdx, nMin, nMin + len);
                ctrl.setCurrPos(activeDimIdx, nMin);
                break;
            }
            default:
                break;
        }
    }

    public void dispose() { stopPlay(); }

    // ---- inner TrackPanel -------------------------------------------------

    private class TrackPanel extends JPanel {
        TrackPanel() { setOpaque(false); }

        @Override
        protected void paintComponent(Graphics g) {
            super.paintComponent(g);
            int W = getWidth(), H = getHeight();
            if (W <= 0 || H <= 0) return;

            Graphics2D g2 = (Graphics2D) g.create();
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);

            int sz   = ctrl.getActiveDimSize(activeDimIdx);
            int pos  = ctrl.getCurrPos(activeDimIdx);
            int zMin = ctrl.getZoomMin(activeDimIdx);
            int zMax = ctrl.getZoomMax(activeDimIdx);

            // full-range background
            g2.setColor(CLR_FULL);
            g2.fillRoundRect(0, 2, W - 1, H - 5, 4, 4);
            g2.setColor(CLR_BORDER);
            g2.drawRoundRect(0, 2, W - 1, H - 5, 4, 4);

            // zoom fill
            int zMinX = dataToTrack(zMin);
            int zMaxX = dataToTrack(zMax);
            g2.setColor(CLR_ZOOM);
            g2.fillRect(zMinX, 3, Math.max(2, zMaxX - zMinX), H - 6);

            // position marker
            int posX = dataToTrack(pos);
            int mW = Math.max(3, Math.min(8, (zMaxX - zMinX) / 4));
            g2.setColor(CLR_POS);
            g2.fillRect(posX - mW / 2, 2, mW, H - 5);

            g2.dispose();
        }
    }
}
