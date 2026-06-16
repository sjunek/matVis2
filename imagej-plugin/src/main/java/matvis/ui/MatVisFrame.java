package matvis.ui;

import matvis.MatVisController;
import matvis.MatVisListener;

import javax.swing.*;
import java.awt.*;
import java.awt.event.*;

/**
 * Main MatVis window.
 *
 * Layout (vertical split using JSplitPane):
 *
 *   ┌──────────────────────────────────────────┐
 *   │  [Image window]    [Zoom window]          │
 *   │  (ImageDisplayPanel) (ZoomDisplayPanel)   │
 *   ├──────────────────────────────────────────┤
 *   │  Control panel (right side)               │
 *   │   ┌────────────────────────────────────┐  │
 *   │   │ Per-dim sliders (DimRangeSlider×N) │  │
 *   │   ├────────────────────────────────────┤  │
 *   │   │ ContrastPanel                      │  │
 *   │   └────────────────────────────────────┘  │
 *   ├──────────────────────────────────────────┤
 *   │  PlotPanel (collapsible, below images)    │
 *   └──────────────────────────────────────────┘
 *
 * The image area and control panel sit side-by-side (horizontal split).
 * The plot panel sits below the image area in a vertical split.
 */
public class MatVisFrame extends JFrame implements MatVisListener {

    private final MatVisController ctrl;

    private final ImageDisplayPanel imagePanel;
    private final ZoomDisplayPanel  zoomPanel;
    private final ContrastPanel     contrastPanel;
    private final PlotPanel         plotPanel;
    private final JPanel imgContainer; // image + zoom, side by side
    private final DimRangeSlider[]  dimSliders;

    private final JToggleButton btnShowImage;
    private final JToggleButton btnShowZoom;
    private final JToggleButton btnShowPlots;

    private JLabel lblPlaySpeed; // shows actual fps + frames skipped

    public MatVisFrame(MatVisController ctrl) {
        super("MatVis – " + ctrl.getImagePlus().getTitle());
        this.ctrl = ctrl;

        setDefaultCloseOperation(JFrame.DISPOSE_ON_CLOSE);
        setLayout(new BorderLayout());

        // ---- Build display panels ----------------------------------------
        imagePanel    = new ImageDisplayPanel(ctrl);
        zoomPanel     = new ZoomDisplayPanel(ctrl);
        contrastPanel = new ContrastPanel(ctrl);
        plotPanel     = new PlotPanel(ctrl);
        // 4-pixel white gap between image and zoom panels
        imgContainer  = new JPanel(new GridLayout(1, 0, 4, 0));
        imgContainer.setBackground(Color.WHITE);

        // ---- Build dimension sliders -------------------------------------
        JPanel sliderBox = new JPanel();
        sliderBox.setLayout(new BoxLayout(sliderBox, BoxLayout.Y_AXIS));
        sliderBox.setBorder(BorderFactory.createTitledBorder("Dimensions"));
        dimSliders = new DimRangeSlider[ctrl.nDims];
        for (int i = 0; i < ctrl.nDims; i++) {
            dimSliders[i] = new DimRangeSlider(ctrl, i);
            sliderBox.add(dimSliders[i]);
        }

        // ---- Playback speed control (shared, below the play buttons) ------
        final JTextField fldPlaySpeed = new JTextField(String.format("%.2g", ctrl.getPlaySpeed()), 4);
        fldPlaySpeed.setFont(fldPlaySpeed.getFont().deriveFont(10f));
        fldPlaySpeed.setToolTipText("Playback speed multiplier (1 = normal; <1 slows via pauses, >1 skips frames)");
        lblPlaySpeed = new JLabel();
        lblPlaySpeed.setFont(lblPlaySpeed.getFont().deriveFont(10f));
        lblPlaySpeed.setForeground(new Color(0, 110, 0));
        fldPlaySpeed.addActionListener(e -> {
            try { ctrl.setPlaySpeed(Double.parseDouble(fldPlaySpeed.getText().trim())); }
            catch (NumberFormatException ignored) {}
            fldPlaySpeed.setText(String.format("%.2g", ctrl.getPlaySpeed()));
        });
        JPanel speedRow = new JPanel(new FlowLayout(FlowLayout.LEFT, 4, 1));
        speedRow.setBorder(BorderFactory.createMatteBorder(1, 0, 0, 0, Color.LIGHT_GRAY));
        speedRow.add(new JLabel("Play speed:"));
        speedRow.add(fldPlaySpeed);
        speedRow.add(lblPlaySpeed);
        speedRow.setAlignmentX(Component.LEFT_ALIGNMENT);
        speedRow.setMaximumSize(new Dimension(Integer.MAX_VALUE, 26));
        sliderBox.add(speedRow);

        // ---- Play coordinator: when any slider starts, stop + disable others;
        //      when it manually stops, re-enable all. ---
        for (int i = 0; i < ctrl.nDims; i++) {
            final int startingIdx = i;
            dimSliders[i].setOnPlayStart(() -> {
                for (int j = 0; j < ctrl.nDims; j++) {
                    if (j != startingIdx) {
                        dimSliders[j].stopPlay();
                        dimSliders[j].setPlayButtonsEnabled(false);
                    }
                }
            });
            dimSliders[i].setOnPlayStop(() -> {
                for (int j = 0; j < ctrl.nDims; j++) {
                    dimSliders[j].setPlayButtonsEnabled(true);
                }
            });
        }

        // ---- Control panel (right) = sliders + contrast ------------------
        JPanel controlPanel = new JPanel(new BorderLayout());
        controlPanel.setPreferredSize(new Dimension(430, 600));

        JScrollPane sliderScroll = new JScrollPane(sliderBox,
                JScrollPane.VERTICAL_SCROLLBAR_AS_NEEDED,
                JScrollPane.HORIZONTAL_SCROLLBAR_NEVER);
        sliderScroll.setBorder(null);
        sliderScroll.setPreferredSize(new Dimension(430, ctrl.nDims * 56 + 20));

        JScrollPane contrastScroll = new JScrollPane(contrastPanel,
                JScrollPane.VERTICAL_SCROLLBAR_AS_NEEDED,
                JScrollPane.HORIZONTAL_SCROLLBAR_NEVER);
        contrastScroll.setBorder(null);

        JSplitPane ctrlSplit = new JSplitPane(JSplitPane.VERTICAL_SPLIT,
                sliderScroll, contrastScroll);
        ctrlSplit.setResizeWeight(0.35);
        ctrlSplit.setBorder(null);
        controlPanel.add(ctrlSplit, BorderLayout.CENTER);

        // ---- Bottom toolbar (toggle visibility) --------------------------
        btnShowImage = new JToggleButton("Image", true);
        btnShowZoom  = new JToggleButton("Zoom",  true);
        btnShowPlots = new JToggleButton("Plots", true);

        btnShowImage.addActionListener(e -> updateVisibility());
        btnShowZoom.addActionListener(e  -> updateVisibility());
        btnShowPlots.addActionListener(e -> updateVisibility());

        // Plot y-axis scale controls
        final JToggleButton btnPlotAuto = new JToggleButton("Auto", ctrl.isPlotAutoScale());
        btnPlotAuto.setFont(btnPlotAuto.getFont().deriveFont(10f));
        btnPlotAuto.setMargin(new Insets(1, 4, 1, 4));
        btnPlotAuto.setToolTipText("Auto: plot y-axis follows displayed contrast; off: fixed min/max");
        final JTextField fldPlotMin = new JTextField(String.format("%.4g", ctrl.getPlotScaleMin()), 6);
        final JTextField fldPlotMax = new JTextField(String.format("%.4g", ctrl.getPlotScaleMax()), 6);
        fldPlotMin.setFont(fldPlotMin.getFont().deriveFont(10f));
        fldPlotMax.setFont(fldPlotMax.getFont().deriveFont(10f));
        fldPlotMin.setEnabled(!ctrl.isPlotAutoScale());
        fldPlotMax.setEnabled(!ctrl.isPlotAutoScale());

        btnPlotAuto.addActionListener(e -> {
            boolean auto = btnPlotAuto.isSelected();
            fldPlotMin.setEnabled(!auto);
            fldPlotMax.setEnabled(!auto);
            ctrl.setPlotAutoScale(auto);
        });
        java.awt.event.ActionListener applyPlotScale = e -> {
            try {
                double mn = Double.parseDouble(fldPlotMin.getText().trim());
                double mx = Double.parseDouble(fldPlotMax.getText().trim());
                ctrl.setPlotScale(mn, mx);
            } catch (NumberFormatException ignored) {}
        };
        fldPlotMin.addActionListener(applyPlotScale);
        fldPlotMax.addActionListener(applyPlotScale);

        // ROI controls
        final JToggleButton btnShowRois = new JToggleButton("ROIs", ctrl.isShowRois());
        btnShowRois.setFont(btnShowRois.getFont().deriveFont(10f));
        btnShowRois.setMargin(new Insets(1, 4, 1, 4));
        btnShowRois.setToolTipText("Show/hide ROI overlays");
        final JToggleButton btnDrawRoi = new JToggleButton("Draw ROI");
        btnDrawRoi.setFont(btnDrawRoi.getFont().deriveFont(10f));
        btnDrawRoi.setMargin(new Insets(1, 4, 1, 4));
        btnDrawRoi.setToolTipText("When active, drag in the image/zoom creates a new ROI instead of zooming; Polygon: click vertices, double-click to close, right-click to cancel");
        final JComboBox<String> cmbRoiShape = new JComboBox<>(new String[]{"Rectangle", "Oval", "Polygon"});
        cmbRoiShape.setFont(cmbRoiShape.getFont().deriveFont(10f));
        final JButton btnRoiMgr = new JButton("ROI Mgr");
        btnRoiMgr.setFont(btnRoiMgr.getFont().deriveFont(10f));
        btnRoiMgr.setMargin(new Insets(1, 4, 1, 4));
        btnRoiMgr.setToolTipText("Open Fiji's ROI Manager window");

        btnShowRois.addActionListener(e -> ctrl.setShowRois(btnShowRois.isSelected()));
        btnDrawRoi.addActionListener(e -> {
            boolean draw = btnDrawRoi.isSelected();
            imagePanel.setRoiDrawMode(draw);
            zoomPanel.setRoiDrawMode(draw);
        });
        cmbRoiShape.addActionListener(e -> {
            String shape = (String) cmbRoiShape.getSelectedItem();
            imagePanel.setRoiShape(shape);
            zoomPanel.setRoiShape(shape);
        });
        btnRoiMgr.addActionListener(e -> ctrl.openRoiManager());

        JPanel toolbar = new JPanel(new FlowLayout(FlowLayout.LEFT, 4, 2));
        toolbar.add(new JLabel("Show:"));
        toolbar.add(btnShowImage);
        toolbar.add(btnShowZoom);
        toolbar.add(btnShowPlots);
        toolbar.add(new JLabel("   Plot scale:"));
        toolbar.add(btnPlotAuto);
        toolbar.add(new JLabel("Min:"));
        toolbar.add(fldPlotMin);
        toolbar.add(new JLabel("Max:"));
        toolbar.add(fldPlotMax);
        toolbar.add(new JLabel("   ROI:"));
        toolbar.add(btnShowRois);
        toolbar.add(btnDrawRoi);
        toolbar.add(cmbRoiShape);
        toolbar.add(btnRoiMgr);
        toolbar.setBorder(BorderFactory.createMatteBorder(1, 0, 0, 0, Color.LIGHT_GRAY));

        // ---- Axis selector bar (X/Y display dimension combos) ------------
        String[] dimLabels = new String[ctrl.nDims];
        for (int i = 0; i < ctrl.nDims; i++) dimLabels[i] = ctrl.getActiveDimName(i);
        final JComboBox<String> cmbXDim = new JComboBox<String>(dimLabels);
        final JComboBox<String> cmbYDim = new JComboBox<String>(dimLabels);
        cmbXDim.setSelectedIndex(ctrl.getXDisplayActiveDim());
        cmbYDim.setSelectedIndex(ctrl.getYDisplayActiveDim());
        cmbXDim.setFont(cmbXDim.getFont().deriveFont(11f));
        cmbYDim.setFont(cmbYDim.getFont().deriveFont(11f));
        cmbXDim.addActionListener(new java.awt.event.ActionListener() {
            public void actionPerformed(java.awt.event.ActionEvent e) {
                ctrl.setXDisplayActiveDim(cmbXDim.getSelectedIndex());
            }
        });
        cmbYDim.addActionListener(new java.awt.event.ActionListener() {
            public void actionPerformed(java.awt.event.ActionEvent e) {
                ctrl.setYDisplayActiveDim(cmbYDim.getSelectedIndex());
            }
        });
        JPanel axisBar = new JPanel(new FlowLayout(FlowLayout.LEFT, 6, 2));
        axisBar.setBorder(BorderFactory.createMatteBorder(0, 0, 1, 0, Color.LIGHT_GRAY));
        axisBar.add(new JLabel("X axis:"));
        axisBar.add(cmbXDim);
        axisBar.add(new JLabel("  Y axis:"));
        axisBar.add(cmbYDim);

        // Wrap imgContainer + axisBar in an image area panel
        JPanel imageAreaPanel = new JPanel(new BorderLayout());
        imageAreaPanel.add(axisBar, BorderLayout.NORTH);
        imageAreaPanel.add(imgContainer, BorderLayout.CENTER);

        // ---- Image area + plots (vertical split) -------------------------
        JScrollPane plotScroll = new JScrollPane(plotPanel,
                JScrollPane.VERTICAL_SCROLLBAR_AS_NEEDED,
                JScrollPane.HORIZONTAL_SCROLLBAR_NEVER);
        plotScroll.setPreferredSize(new Dimension(300, 200));

        JSplitPane imgPlotSplit = new JSplitPane(JSplitPane.VERTICAL_SPLIT,
                imageAreaPanel, plotScroll);
        imgPlotSplit.setResizeWeight(0.7);
        imgPlotSplit.setBorder(null);
        imgPlotSplit.setDividerSize(6);

        // ---- Main horizontal split: image area | control panel -----------
        JSplitPane mainSplit = new JSplitPane(JSplitPane.HORIZONTAL_SPLIT,
                imgPlotSplit, controlPanel);
        mainSplit.setResizeWeight(0.65);
        mainSplit.setBorder(null);

        add(mainSplit, BorderLayout.CENTER);
        add(toolbar,   BorderLayout.SOUTH);

        // ---- Register as model listener ----------------------------------
        ctrl.addListener(this);

        // ---- Initial render ----------------------------------------------
        updateVisibility();
        onUpdate();

        pack();
        setLocationRelativeTo(null);
        setMinimumSize(new Dimension(700, 500));

        // ---- RoiManager sync: poll for changes made in the RoiManager window
        final javax.swing.Timer roiSyncTimer = new javax.swing.Timer(500, null);
        roiSyncTimer.addActionListener(new ActionListener() {
            private int lastCount = -1;
            private int[] lastSel = new int[0];
            public void actionPerformed(ActionEvent e) {
                ij.plugin.frame.RoiManager rm = ij.plugin.frame.RoiManager.getInstance();
                if (rm == null) return;
                int count = rm.getCount();
                int[] sel = rm.getSelectedIndexes();
                if (sel == null) sel = new int[0];
                boolean changed = (count != lastCount) || !java.util.Arrays.equals(sel, lastSel);
                if (changed) {
                    lastCount = count;
                    lastSel = sel;
                    // keep single-selection state coherent for click-select logic
                    ctrl.syncSelectedRoiIdx(rm.getSelectedIndex());
                    ctrl.fireUpdate();   // repaint overlays + plots
                }
            }
        });
        roiSyncTimer.start();

        addWindowListener(new WindowAdapter() {
            public void windowClosing(WindowEvent e) {
                roiSyncTimer.stop();
                ctrl.removeListener(MatVisFrame.this);
                for (DimRangeSlider s : dimSliders) s.dispose();
            }
        });
    }

    // ---- MatVisListener --------------------------------------------------

    @Override
    public void onUpdate() {
        // Must run on EDT
        if (!SwingUtilities.isEventDispatchThread()) {
            SwingUtilities.invokeLater(this::onUpdate);
            return;
        }

        // Refresh display panels
        imagePanel.refresh();
        if (btnShowZoom.isSelected()) zoomPanel.refresh();
        if (btnShowPlots.isSelected()) plotPanel.refresh();

        // Refresh sliders
        for (DimRangeSlider s : dimSliders) s.refreshUI();

        // Refresh contrast panel
        contrastPanel.refresh();

        // Refresh playback-speed status
        updatePlaySpeedLabel();
    }

    private void updatePlaySpeedLabel() {
        if (lblPlaySpeed == null) return;
        int skip = ctrl.getPlayFramesSkipped();
        String txt;
        if (ctrl.isPlaying() && ctrl.getMeasuredFps() > 0) {
            // live: actual measured displayed-frame rate
            txt = String.format("(%.1f fps", ctrl.getMeasuredFps());
        } else {
            // idle: target rate given the speed setting
            txt = String.format("(target %.1f fps", ctrl.getActualPlayFps());
        }
        if (skip > 0) txt += ", skip " + skip;
        txt += ")";
        lblPlaySpeed.setText(txt);
    }

    // ---- Visibility management -------------------------------------------

    private void updateVisibility() {
        // Rebuild imgContainer with only the visible panels.
        // Using GridLayout(1,0) means each visible panel shares equal width.
        imgContainer.removeAll();
        if (btnShowImage.isSelected()) imgContainer.add(imagePanel);
        if (btnShowZoom.isSelected())  imgContainer.add(zoomPanel);
        imgContainer.revalidate();
        imgContainer.repaint();

        // Plot panel lives in a scroll pane — simple show/hide works there.
        plotPanel.setVisible(btnShowPlots.isSelected());

        // Trigger renders when panels become visible.
        if (btnShowZoom.isSelected())  zoomPanel.refresh();
        if (btnShowPlots.isSelected()) plotPanel.refresh();

        revalidate();
        repaint();
    }
}
