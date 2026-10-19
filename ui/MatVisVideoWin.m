function vw = MatVisVideoWin(model, cbs)
% MatVisVideoWin  Video generator panel for matVis 2.0.
%
%   vw = MatVisVideoWin(model, cbs)
%     cbs.computeDisplay - @(ds) -> display struct (mw.ComputeDisplay), so the
%                          movie uses the same contrast/gamma/filter pipeline
%                          as the live windows
%     cbs.liveRender     - @() re-render the live windows (mw.Render)
%     cbs.onHide         - @() called when the window is closed
%     cbs.setZoom        - @(zoomRange) apply a new zoom box to the live
%                          windows ("Even pixels" button)
%     cbs.get3DView      - @() -> struct with az / el / zoom / dims / style
%                          of an open 3-D window, or [] — the
%                          "3D win -> start/end" buttons
%     cbs.histRange      - @() -> [lo hi] for the histogram panel's x axis,
%                          so it is framed like the main window's own
%
%   vw.fig     - uifigure handle (created hidden)
%   vw.Show()  - show and refresh
%   vw.Refresh()
%
%   A movie is a list of SEQUENCES played back to back.  Layout, frame size
%   and output settings belong to the movie (left column); what changes from
%   sequence to sequence is the sweep, the contrast window and the 3-D camera
%   (right column).  That split is what lets one file step through a time
%   series at one contrast and then orbit a still volume at another — neither
%   of which a single global "sweep this dimension" can express.
%
%   The 3-D panel is a projection computed from the data
%   (MatVisVolumeProjector), not a capture of the interactive 3-D window: a
%   viewer3d cannot be grabbed at a usable speed and deadlocks while hidden.
%
%   The preview is the composer's own figure — it is the exact thing that
%   gets captured, so it cannot disagree with the result.  It stays open
%   while settings change: the frame slider picks which frame of the selected
%   sequence it shows, so dragging it scrubs the animation and its far end is
%   the sequence's end camera.  The play buttons drive the same figure
%   through the real timeline, skipping only the capture.

if nargin < 2, cbs = struct(); end
for fld_ = {'computeDisplay', 'liveRender', 'onHide', 'setZoom', ...
            'get3DView', 'histRange'}
    if ~isfield(cbs, fld_{1}), cbs.(fld_{1}) = []; end
end

LAYOUTS = MatVisFrameComposer.LayoutKinds();
SIZES   = {'1280 x 720', '1920 x 1080', '960 x 540', '640 x 360', 'Custom'};
SIZEVAL = [1280 720; 1920 1080; 960 540; 640 360; NaN NaN];

nDims  = numel(model.Size);
MAXVOX = 4e6;          % same interactive voxel budget as MatVis3DWin

composer  = [];
cancelReq = false;
rendering = false;
playing   = false;
scrubbing = false;
painting  = false;
playTic   = tic;
syncing   = false;
dims3     = MatVisFrameComposer.defaultDims3(model);
seqs      = newSequence();
selIdx    = 1;

fig = uifigure('Name', 'Video Generator', 'NumberTitle', 'off', ...
               'Position', [120 120 684 788], 'Resize', 'on', ...
               'AutoResizeChildren', 'off', 'Visible', 'off');
fig.CloseRequestFcn = @(~,~) onClose();

root = uigridlayout(fig, [2 1]);
root.RowHeight   = {'1x', 132};
root.ColumnWidth = {'1x'};
root.Padding     = [8 8 8 8];
root.RowSpacing  = 6;

cols = uigridlayout(root, [1 2]);
cols.Layout.Row     = 1;
cols.ColumnWidth    = {'1x', 300};
cols.Padding        = [0 0 0 0];
cols.ColumnSpacing  = 6;

% Left: what the whole movie looks like, plus the sequence list and output.
left = uigridlayout(cols, [4 1]);
left.Layout.Column = 1;
left.RowHeight     = {186, 132, 162, 132};
left.ColumnWidth   = {'1x'};
left.Padding       = [0 0 0 0];
left.RowSpacing    = 6;
left.Scrollable    = 'on';

% Right: everything that belongs to the selected sequence, then the 3-D
% panel's own (movie-wide) setup right under the camera that drives it.
right = uigridlayout(cols, [4 1]);
right.Layout.Column = 2;
right.RowHeight     = {128, 158, 158, 158};
right.ColumnWidth   = {'1x'};
right.Padding       = [0 0 0 0];
right.RowSpacing    = 6;
right.Scrollable    = 'on';

%% ---- Content (movie) ---------------------------------------------------
pContent = uipanel(left, 'Title', 'Content (whole movie)');
matVisShadePanelTitle(pContent);
gc = uigridlayout(pContent, [6 3]);
gc.RowHeight     = {22, 22, 22, 22, 22, 22};
gc.ColumnWidth   = {80, '1x', 86};
gc.Padding       = [8 6 8 6];
gc.RowSpacing    = 4;
gc.ColumnSpacing = 4;

addLabel(gc, 'Layout:', 1, 1);
ddLayout = uidropdown(gc, 'Items', LAYOUTS, 'Value', 'image+zoom', ...
    'ValueChangedFcn', @(~,~) onLayoutChanged());
place(ddLayout, 1, [2 3]);

addLabel(gc, 'Title:', 2, 1);
edtTitle = uieditfield(gc, 'text', 'Value', '', ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(edtTitle, 2, [2 3]);

addLabel(gc, 'Annotations:', 3, 1);
cbTime = uicheckbox(gc, 'Text', 'Time label', 'Value', false, ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(cbTime, 3, 2);
cbBar  = uicheckbox(gc, 'Text', 'Scale bar', 'Value', false, ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(cbBar, 3, 3);

addLabel(gc, 'Overlays:', 4, 1);
cbRois = uicheckbox(gc, 'Text', 'ROIs / profiles', 'Value', false, ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(cbRois, 4, 2);
cbCross = uicheckbox(gc, 'Text', 'Crosshair', 'Value', false, ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(cbCross, 4, 3);

addLabel(gc, 'Histogram:', 5, 1);
ddHist = uidropdown(gc, 'Items', {'Off', 'Bottom strip', 'Right column'}, ...
    'ItemsData', {'off', 'bottom', 'right'}, 'Value', 'off', ...
    'Tooltip', ['Whole dataset, current image and current zoom crop, with' newline ...
                'the contrast window, the gamma curve and the colour ramp.'], ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(ddHist, 5, 2);
cbHistLog = uicheckbox(gc, 'Text', 'log y', 'Value', false, ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(cbHistLog, 5, 3);

addLabel(gc, 'Zoom panel:', 6, 1);
cbFillZoom = uicheckbox(gc, 'Text', 'Fill zoom', 'Value', false, ...
    'Tooltip', ['A fixed aspect ratio letterboxes the zoom crop inside its' newline ...
                'panel.  On: the crop is widened (never shrunk, never past' newline ...
                'the data edge) until it fills the panel.  The movie only —' newline ...
                'the shared zoom box and the live windows are left alone.'], ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(cbFillZoom, 6, [2 3]);

%% ---- Frame (movie) ----------------------------------------------------
pFrame = uipanel(left, 'Title', 'Frame (whole movie)');
matVisShadePanelTitle(pFrame);
gf = uigridlayout(pFrame, [4 4]);
gf.RowHeight     = {22, 22, 22, 22};
gf.ColumnWidth   = {80, '1x', 34, 86};
gf.Padding       = [8 6 8 6];
gf.RowSpacing    = 4;
gf.ColumnSpacing = 4;

addLabel(gf, 'Size:', 1, 1);
ddSize = uidropdown(gf, 'Items', SIZES, 'Value', SIZES{1}, ...
    'ValueChangedFcn', @(~,~) onSizePreset());
place(ddSize, 1, [2 4]);

addLabel(gf, 'Pixels:', 2, 1);
edtW = uispinner(gf, 'Limits', [32 4096], 'Value', 1280, 'Step', 2, ...
    'RoundFractionalValues', 'on', 'ValueChangedFcn', @(~,~) onSizeEdit());
place(edtW, 2, 2);
addLabel(gf, 'x', 2, 3, 'center');
edtH = uispinner(gf, 'Limits', [32 4096], 'Value', 720, 'Step', 2, ...
    'RoundFractionalValues', 'on', 'ValueChangedFcn', @(~,~) onSizeEdit());
place(edtH, 2, 4);

addLabel(gf, 'Back / text:', 3, 1);
ddBg = uidropdown(gf, 'Items', {'White', 'Black'}, 'Value', 'White', ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(ddBg, 3, [2 3]);
% Annotations are drawn over the image panels, not over the frame
% background, so their colour is a separate choice — white by default
% because image data is usually dark.
ddText = uidropdown(gf, 'Items', {'White', 'Black'}, 'Value', 'White', ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(ddText, 3, 4);

% Most codecs reject odd frame sizes, so offer a one-click fix: shrink the
% live zoom box to even side lengths and take the frame size from it.
btnEven = uibutton(gf, 'Text', 'Even pixels', 'ButtonPushedFcn', @(~,~) onEvenPixels());
place(btnEven, 4, [3 4]);

%% ---- Sequences --------------------------------------------------------
pSeq = uipanel(left, 'Title', 'Sequences');
matVisShadePanelTitle(pSeq);
gq = uigridlayout(pSeq, [3 1]);
gq.RowHeight   = {'1x', 24, 18};
gq.ColumnWidth = {'1x'};
gq.Padding     = [8 6 8 4];
gq.RowSpacing  = 4;

lbSeq = uilistbox(gq, 'Items', {''}, 'ItemsData', 1, 'Value', 1, ...
    'FontSize', 11, 'Tooltip', ...
    ['The movie is these sequences in order.' newline ...
     'Selecting one shows its sweep, contrast and camera on the right.'], ...
    'ValueChangedFcn', @(src, ~) onSeqSelected(src.Value));
lbSeq.Layout.Row = 1;

gqb = uigridlayout(gq, [1 5]);
gqb.Layout.Row    = 2;
gqb.RowHeight     = {22};
gqb.ColumnWidth   = {'1x', '1x', '1x', 26, 26};
gqb.Padding       = [0 0 0 0];
gqb.ColumnSpacing = 3;
uibutton(gqb, 'Text', 'Add', 'Tooltip', 'Insert a copy of the selected sequence', ...
    'ButtonPushedFcn', @(~,~) onSeqAdd());
uibutton(gqb, 'Text', 'New', 'Tooltip', 'Append a sequence with default settings', ...
    'ButtonPushedFcn', @(~,~) onSeqNew());
btnSeqDel = uibutton(gqb, 'Text', 'Delete', ...
    'ButtonPushedFcn', @(~,~) onSeqDelete());
btnSeqUp  = uibutton(gqb, 'Text', '▲', 'Tooltip', 'Move earlier', ...
    'ButtonPushedFcn', @(~,~) onSeqMove(-1));
btnSeqDn  = uibutton(gqb, 'Text', '▼', 'Tooltip', 'Move later', ...
    'ButtonPushedFcn', @(~,~) onSeqMove(+1));

lblTotal = uilabel(gq, 'Text', '', 'FontSize', 10);
lblTotal.Layout.Row = 3;

%% ---- Output -----------------------------------------------------------
pOut = uipanel(left, 'Title', 'Output');
matVisShadePanelTitle(pOut);
go = uigridlayout(pOut, [4 4]);
go.RowHeight     = {22, 22, 22, 22};
go.ColumnWidth   = {80, '1x', 50, 86};
go.Padding       = [8 6 8 6];
go.RowSpacing    = 4;
go.ColumnSpacing = 4;

addLabel(go, 'Folder:', 1, 1);
edtDir = uieditfield(go, 'text', 'Value', pwd);
place(edtDir, 1, [2 3]);
btnBrowse = uibutton(go, 'Text', 'Browse...', 'ButtonPushedFcn', @(~,~) onBrowse());
place(btnBrowse, 1, 4);

addLabel(go, 'File name:', 2, 1);
edtName = uieditfield(go, 'text', 'Value', defaultName());
place(edtName, 2, [2 4]);

addLabel(go, 'Format:', 3, 1);
fmtKeys  = MatVisVideoWriter.AvailableFormats();
fmtAll   = MatVisVideoWriter.Formats();
fmtAll   = fmtAll(ismember({fmtAll.key}, fmtKeys));
ddFormat = uidropdown(go, 'Items', {fmtAll.label}, 'ItemsData', {fmtAll.key}, ...
    'ValueChangedFcn', @(~,~) onFormatChanged());
place(ddFormat, 3, [2 4]);
if ismember('mp4', fmtKeys), ddFormat.Value = 'mp4'; end

addLabel(go, 'fps / quality:', 4, 1);
spFps = uispinner(go, 'Limits', [1 240], 'Value', 25, ...
    'RoundFractionalValues', 'on', 'ValueChangedFcn', @(~,~) updateEstimate());
place(spFps, 4, 2);
spQual = uispinner(go, 'Limits', [1 100], 'Value', 80, ...
    'RoundFractionalValues', 'on');
place(spQual, 4, [3 4]);

%% ---- Sweep (per sequence) ----------------------------------------------
pSweep = uipanel(right, 'Title', 'Sweep (this sequence)');
matVisShadePanelTitle(pSweep);
gs = uigridlayout(pSweep, [4 4]);
gs.RowHeight      = {22, 22, 22, 18};
gs.ColumnWidth    = {58, '1x', 50, '1x'};
gs.Padding        = [8 6 8 6];
gs.RowSpacing     = 4;
gs.ColumnSpacing  = 4;

addLabel(gs, 'Dim:', 1, 1);
ddDim = uidropdown(gs, 'Items', dimItems(true), 'ItemsData', [0, 1:nDims], ...
    'Value', seqs(1).dim, 'Tooltip', ...
    ['"hold" navigates nothing: the sequence stays on one position for' newline ...
     'Frames frames, which is how a 3-D camera move over a still volume' newline ...
     'is expressed.'], ...
    'ValueChangedFcn', @(src, ~) onDimChanged(src.Value));
place(ddDim, 1, [2 4]);

addLabel(gs, 'From/To:', 2, 1);
spFrom = uispinner(gs, 'Limits', [1 Inf], 'Value', 1, ...
    'RoundFractionalValues', 'on', 'ValueChangedFcn', @(~,~) onSweepEdit());
place(spFrom, 2, 2);
addLabel(gs, 'to', 2, 3, 'center');
spTo = uispinner(gs, 'Limits', [1 Inf], 'Value', 1, ...
    'RoundFractionalValues', 'on', 'ValueChangedFcn', @(~,~) onSweepEdit());
place(spTo, 2, 4);

addLabel(gs, 'Step:', 3, 1);
spStep = uispinner(gs, 'Limits', [1 Inf], 'Value', 1, ...
    'RoundFractionalValues', 'on', 'ValueChangedFcn', @(~,~) onSweepEdit());
place(spStep, 3, 2);
addLabel(gs, 'Frames:', 3, 3, 'right');
spFrames = uispinner(gs, 'Limits', [1 100000], 'Value', 25, ...
    'RoundFractionalValues', 'on', 'Tooltip', 'Length of a "hold" sequence', ...
    'ValueChangedFcn', @(~,~) onSweepEdit());
place(spFrames, 3, 4);

lblEstimate = uilabel(gs, 'Text', '', 'FontSize', 10);
place(lblEstimate, 4, [1 4]);

%% ---- Contrast (per sequence) -------------------------------------------
pCon = uipanel(right, 'Title', 'Contrast (this sequence)');
matVisShadePanelTitle(pCon);
gcn = uigridlayout(pCon, [5 4]);
gcn.RowHeight     = {22, 22, 22, 22, 22};
gcn.ColumnWidth   = {58, '1x', 24, '1x'};
gcn.Padding       = [8 6 8 6];
gcn.RowSpacing    = 4;
gcn.ColumnSpacing = 4;

addLabel(gcn, 'Mode:', 1, 1);
ddCMode = uidropdown(gcn, ...
    'Items', {'Follow main window', 'Global', 'Image (auto)', 'Zoom (auto)', 'Manual'}, ...
    'ItemsData', {'follow', 'Global', 'Image', 'Zoom', 'manual'}, ...
    'Value', 'follow', 'Tooltip', ...
    ['Anything but "Follow" pins the contrast for this sequence and locks' newline ...
     'it across datasets, so the others are scaled from the active one —' newline ...
     'the main window''s locked behaviour.'], ...
    'ValueChangedFcn', @(~,~) onContrastEdit());
place(ddCMode, 1, [2 4]);

% Start -> end, like the camera above: the values are walked frame by
% frame, so a window that opens or a gamma that lifts does it smoothly
% instead of jumping at the sequence boundary.
addLabel(gcn, 'Min:', 2, 1);
spCMin0 = uispinner(gcn, 'Value', 0, 'ValueChangedFcn', @(~,~) onContrastEdit());
place(spCMin0, 2, 2);
addLabel(gcn, '→', 2, 3, 'center');
spCMin1 = uispinner(gcn, 'Value', 0, 'ValueChangedFcn', @(~,~) onContrastEdit());
place(spCMin1, 2, 4);

addLabel(gcn, 'Max:', 3, 1);
spCMax0 = uispinner(gcn, 'Value', 1, 'ValueChangedFcn', @(~,~) onContrastEdit());
place(spCMax0, 3, 2);
addLabel(gcn, '→', 3, 3, 'center');
spCMax1 = uispinner(gcn, 'Value', 1, 'ValueChangedFcn', @(~,~) onContrastEdit());
place(spCMax1, 3, 4);

addLabel(gcn, 'Gamma:', 4, 1);
spGam0 = uispinner(gcn, 'Limits', [0.1 5], 'Value', 1, 'Step', 0.1, ...
    'ValueChangedFcn', @(~,~) onContrastEdit());
place(spGam0, 4, 2);
addLabel(gcn, '→', 4, 3, 'center');
spGam1 = uispinner(gcn, 'Limits', [0.1 5], 'Value', 1, 'Step', 0.1, ...
    'ValueChangedFcn', @(~,~) onContrastEdit());
place(spGam1, 4, 4);

gFrom = uigridlayout(gcn, [1 2]);
place(gFrom, 5, [1 4]);
gFrom.RowHeight     = {22};
gFrom.ColumnWidth   = {'1x', '1x'};
gFrom.Padding       = [0 0 0 0];
gFrom.ColumnSpacing = 4;
btnFromCurrent = uibutton(gFrom, 'Text', 'Main win → start', ...
    'Tooltip', 'Copy the contrast the live windows are showing into the start', ...
    'ButtonPushedFcn', @(~,~) onContrastFromCurrent(false));
btnFromCurrentEnd = uibutton(gFrom, 'Text', 'Main win → end', ...
    'Tooltip', 'Copy the contrast the live windows are showing into the end', ...
    'ButtonPushedFcn', @(~,~) onContrastFromCurrent(true));

%% ---- 3-D camera (per sequence) -----------------------------------------
pCam = uipanel(right, 'Title', '3D camera (this sequence)');
matVisShadePanelTitle(pCam);
gcm = uigridlayout(pCam, [5 4]);
gcm.RowHeight     = {22, 22, 22, 22, 22};
gcm.ColumnWidth   = {58, '1x', 24, '1x'};
gcm.Padding       = [8 6 8 6];
gcm.RowSpacing    = 4;
gcm.ColumnSpacing = 4;

addLabel(gcm, 'Azimuth:', 1, 1);
spAz0 = uispinner(gcm, 'Limits', [-720 720], 'Value', -37.5, 'Step', 5, ...
    'ValueChangedFcn', @(~,~) onCameraEdit());
place(spAz0, 1, 2);
addLabel(gcm, '→', 1, 3, 'center');
spAz1 = uispinner(gcm, 'Limits', [-720 720], 'Value', -37.5, 'Step', 5, ...
    'ValueChangedFcn', @(~,~) onCameraEdit());
place(spAz1, 1, 4);

addLabel(gcm, 'Elevation:', 2, 1);
spEl0 = uispinner(gcm, 'Limits', [-89 89], 'Value', 30, 'Step', 5, ...
    'ValueChangedFcn', @(~,~) onCameraEdit());
place(spEl0, 2, 2);
addLabel(gcm, '→', 2, 3, 'center');
spEl1 = uispinner(gcm, 'Limits', [-89 89], 'Value', 30, 'Step', 5, ...
    'ValueChangedFcn', @(~,~) onCameraEdit());
place(spEl1, 2, 4);

addLabel(gcm, 'Zoom:', 3, 1);
spZ0 = uispinner(gcm, 'Limits', [0.05 50], 'Value', 1, 'Step', 0.1, ...
    'ValueChangedFcn', @(~,~) onCameraEdit());
place(spZ0, 3, 2);
addLabel(gcm, '→', 3, 3, 'center');
spZ1 = uispinner(gcm, 'Limits', [0.05 50], 'Value', 1, 'Step', 0.1, ...
    'ValueChangedFcn', @(~,~) onCameraEdit());
place(spZ1, 3, 4);

gGrab = uigridlayout(gcm, [1 2]);
place(gGrab, 4, [1 4]);
gGrab.RowHeight     = {22};
gGrab.ColumnWidth   = {'1x', '1x'};
gGrab.Padding       = [0 0 0 0];
gGrab.ColumnSpacing = 4;
btnGrab0 = uibutton(gGrab, 'Text', '3D win → start', ...
    'Tooltip', 'Copy the open 3-D window''s camera into the start values', ...
    'ButtonPushedFcn', @(~,~) onGrabCamera(0));
btnGrab1 = uibutton(gGrab, 'Text', '3D win → end', ...
    'Tooltip', 'Copy the open 3-D window''s camera into the end values', ...
    'ButtonPushedFcn', @(~,~) onGrabCamera(1));

gcb = uigridlayout(gcm, [1 2]);
place(gcb, 5, [1 4]);
gcb.RowHeight     = {22};
gcb.ColumnWidth   = {'1x', '1x'};
gcb.Padding       = [0 0 0 0];
gcb.ColumnSpacing = 4;
btnHoldCam = uibutton(gcb, 'Text', 'Hold (no move)', ...
    'Tooltip', 'Set every end value equal to its start', ...
    'ButtonPushedFcn', @(~,~) onCameraHold());
btnSpin = uibutton(gcb, 'Text', 'Spin 360°', ...
    'Tooltip', 'One full turn in azimuth over this sequence', ...
    'ButtonPushedFcn', @(~,~) onCameraSpin());

%% ---- 3-D panel (movie) ------------------------------------------------
p3D = uipanel(right, 'Title', '3D panel (whole movie)');
matVisShadePanelTitle(p3D);
g3 = uigridlayout(p3D, [5 4]);
g3.RowHeight     = {22, 22, 22, 22, 22};
g3.ColumnWidth   = {62, '1x', '1x', '1x'};
g3.Padding       = [8 6 8 6];
g3.RowSpacing    = 4;
g3.ColumnSpacing = 4;

addLabel(g3, 'Dims:', 1, 1);
dd3Dim = gobjects(1, 3);
for kSlot_ = 1:3
    dd3Dim(kSlot_) = uidropdown(g3, 'Items', dimNames(), 'ItemsData', 1:nDims, ...
        'Value', dims3(kSlot_), 'Tooltip', 'Volume X / Y / Z', ...
        'ValueChangedFcn', @(src, ~) on3DDimChanged(kSlot_, src.Value));
    place(dd3Dim(kSlot_), 1, kSlot_ + 1);
end

addLabel(g3, 'Style:', 2, 1);
dd3Style = uidropdown(g3, 'Items', {'Max intensity', 'Min intensity'}, ...
    'ItemsData', {'max', 'min'}, 'Value', 'max', ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(dd3Style, 2, [2 4]);

addLabel(g3, 'Extent:', 3, 1);
dd3Extent = uidropdown(g3, 'Items', {'Full dimensions', 'Main-window zoom'}, ...
    'ItemsData', {'full', 'zoom'}, 'Value', 'full', ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(dd3Extent, 3, [2 4]);

cb3Box = uicheckbox(g3, 'Text', 'Bounding box', 'Value', true, ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(cb3Box, 4, [1 2]);
cb3Lab = uicheckbox(g3, 'Text', 'Axis labels', 'Value', true, ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(cb3Lab, 4, [3 4]);

addLabel(g3, 'Voxels:', 5, 1);
sp3Vox = uispinner(g3, 'Limits', [0.1 512], 'Value', MAXVOX / 1e6, 'Step', 1, ...
    'Tooltip', ['Millions of voxels handed to the projection. The sub-volume' newline ...
                'is strided down to fit, trading detail for render time.'], ...
    'ValueChangedFcn', @(~,~) settingsChanged());
place(sp3Vox, 5, 2);
lbl3Info = uilabel(g3, 'Text', '', 'FontSize', 10);
place(lbl3Info, 5, [3 4]);

%% ---- Actions -----------------------------------------------------------
bottom = uigridlayout(root, [4 1]);
bottom.Layout.Row  = 2;
bottom.RowHeight   = {32, 26, 26, '1x'};
bottom.ColumnWidth = {'1x'};
bottom.Padding     = [0 0 0 0];
bottom.RowSpacing  = 4;

gprev = uigridlayout(bottom, [1 3]);
gprev.Layout.Row    = 1;
gprev.RowHeight     = {'1x'};
gprev.ColumnWidth   = {128, '1x', 96};
gprev.Padding       = [0 0 0 0];
gprev.ColumnSpacing = 8;
btnPreview = uibutton(gprev, 'Text', 'Preview frame', ...
    'Tooltip', 'Show the slider''s frame of the selected sequence', ...
    'ButtonPushedFcn', @(~,~) onPreview());
% ValueChangingFcn as well as ValueChangedFcn, so dragging scrubs the
% animation rather than only jumping when the knob is released.
sldFrame = uislider(gprev, 'Limits', [1 2], 'Value', 1, ...
    'MajorTicks', [], 'MinorTicks', [], ...
    'Tooltip', ['Which frame of the selected sequence the preview shows.' newline ...
                'The far end is that sequence''s end camera and contrast.'], ...
    'ValueChangingFcn', @(~, evt) onScrub(evt.Value), ...
    'ValueChangedFcn',  @(src, ~) onScrub(src.Value));
lblFrame = uilabel(gprev, 'Text', '', 'FontSize', 10, ...
    'HorizontalAlignment', 'right');

gact = uigridlayout(bottom, [1 3]);
gact.Layout.Row    = 2;
gact.RowHeight     = {'1x'};
gact.ColumnWidth   = {'1x', '1x', '1x'};
gact.Padding       = [0 0 0 0];
gact.ColumnSpacing = 4;
btnPlaySeq = uibutton(gact, 'Text', '▶ Sequence', ...
    'ButtonPushedFcn', @(~,~) onPlay(false));
btnPlayAll = uibutton(gact, 'Text', '▶ Whole movie', ...
    'ButtonPushedFcn', @(~,~) onPlay(true));
btnStop = uibutton(gact, 'Text', 'Stop', 'Enable', 'off', ...
    'ButtonPushedFcn', @(~,~) onCancel());

btnRender = uibutton(bottom, 'Text', 'Render to file', ...
    'ButtonPushedFcn', @(~,~) onRender());
btnRender.Layout.Row = 3;

lblStatus = uilabel(bottom, 'Text', 'Ready.', 'WordWrap', 'on');
lblStatus.Layout.Row = 4;

syncSeqList();
syncSeqControls();

%% ---- Public interface --------------------------------------------------
vw.fig     = fig;
vw.Show    = @showWin;
vw.Refresh = @refresh;
vw.Render  = @onRender;    % same action as the button, for scripts and tests
vw.Preview = @onPreview;
vw.Play    = @onPlay;
% Sequence list as data, so a script or test does not have to drive five
% widgets to set one up.  Function handles, not values: an anonymous
% function would freeze today's list.
vw.Sequences    = @getSequences;
vw.SetSequences = @setSequences;
vw.NewSequence  = @newSequence;
% Widget handles so a test can drive the panel the way a user would.
vw.controls = struct('layout', ddLayout, 'title', edtTitle, ...
    'timeLabel', cbTime, 'scaleBar', cbBar, 'rois', cbRois, ...
    'crosshair', cbCross, 'histogram', ddHist, 'histLog', cbHistLog, ...
    'fillZoom', cbFillZoom, ...
    'sizePreset', ddSize, 'width', edtW, 'height', edtH, ...
    'evenPixels', btnEven, 'background', ddBg, 'textColor', ddText, ...
    'seqList', lbSeq, 'seqDelete', btnSeqDel, 'seqUp', btnSeqUp, ...
    'seqDown', btnSeqDn, 'total', lblTotal, ...
    'dim', ddDim, 'from', spFrom, 'to', spTo, 'step', spStep, ...
    'frames', spFrames, 'estimate', lblEstimate, ...
    'contrastMode', ddCMode, ...
    'contrastMin0', spCMin0, 'contrastMin1', spCMin1, ...
    'contrastMax0', spCMax0, 'contrastMax1', spCMax1, ...
    'gamma0', spGam0, 'gamma1', spGam1, ...
    'contrastFromCurrent', btnFromCurrent, ...
    'contrastFromCurrentEnd', btnFromCurrentEnd, ...
    'az0', spAz0, 'az1', spAz1, 'el0', spEl0, 'el1', spEl1, ...
    'zoom0', spZ0, 'zoom1', spZ1, 'holdCamera', btnHoldCam, 'spin', btnSpin, ...
    'grabStart', btnGrab0, 'grabEnd', btnGrab1, ...
    'dim3', dd3Dim, 'style3', dd3Style, 'extent3', dd3Extent, ...
    'box3', cb3Box, 'labels3', cb3Lab, 'maxVox3', sp3Vox, 'info3', lbl3Info, ...
    'folder', edtDir, 'name', edtName, 'format', ddFormat, 'fps', spFps, ...
    'quality', spQual, 'status', lblStatus, ...
    'frameSlider', sldFrame, 'frameLabel', lblFrame, ...
    'btnPreview', btnPreview, 'btnPlaySeq', btnPlaySeq, ...
    'btnPlayAll', btnPlayAll, 'btnRender', btnRender, 'btnStop', btnStop);

% =========================================================================
%  Window
% =========================================================================
    function showWin()
        refresh();
        fig.Visible = 'on';
        figure(fig);
    end

    function refresh()
        items = dimItems(true);
        if ~isequal(ddDim.Items, items)
            ddDim.Items     = items;
            ddDim.ItemsData = [0, 1:numel(model.Size)];
            names = dimNames();
            for kR_ = 1:3
                dd3Dim(kR_).Items     = names;
                dd3Dim(kR_).ItemsData = 1:numel(model.Size);
                dd3Dim(kR_).Value     = dims3(kR_);
            end
        end
        clampSequences();
        syncSeqList();
        syncSeqControls();
    end

    function onClose()
        cancelReq = true;
        % Never drop the composer out from under a running render — the
        % recorder is holding it and would fail on the next frame.
        if ~busy(), dropComposer(); end
        fig.Visible = 'off';
        if ~isempty(cbs.onHide)
            try; cbs.onHide(); catch; end
        end
    end

% =========================================================================
%  Layout helpers
% =========================================================================
    function h = addLabel(parent, txt, row, col, align)
        if nargin < 5, align = 'left'; end
        h = uilabel(parent, 'Text', txt, 'HorizontalAlignment', align);
        place(h, row, col);
    end

    function place(h, row, col)
        h.Layout.Row    = row;
        h.Layout.Column = col;
    end

    function setEnable(hs, tf)
        % Enable/disable a mixed bag of components.  A cell array, not a
        % handle array: concatenating dropdowns, checkboxes and spinners
        % into one array is not something set() can be relied on to take.
        st = onOff_(tf);
        for kN_ = 1:numel(hs)
            h = hs{kN_};
            for kO_ = 1:numel(h)
                h(kO_).Enable = st;
            end
        end
    end

    function s = onOff_(tf)
        s = matlab.lang.OnOffSwitchState(logical(tf));
    end

% =========================================================================
%  Sequences
% =========================================================================
    function s = newSequence()
        d = MatVisFrameComposer.firstFreeDim(model);
        if isempty(d)
            d = 0;  n = 1;
        else
            n = model.Size(d);
        end
        ads = model.ActiveDataset;
        if isempty(ads), ads = 1; end
        lo = model.AllDataMins(ads);
        hi = model.AllDataMaxs(ads);
        s = struct('dim', d, 'from', 1, 'to', n, 'step', 1, 'frames', 25, ...
                   'cmode', 'follow', ...
                   'cmin0', lo, 'cmin1', lo, 'cmax0', hi, 'cmax1', hi, ...
                   'gamma0', model.Gamma, 'gamma1', model.Gamma, ...
                   'az0', -37.5, 'az1', -37.5, 'el0', 30, 'el1', 30, ...
                   'zoom0', 1, 'zoom1', 1);
    end

    function s = getSequences()
        s = seqs;
    end

    function setSequences(newSeqs)
        if isempty(newSeqs), newSeqs = newSequence(); end
        seqs   = newSeqs;
        selIdx = 1;
        clampSequences();
        syncSeqList();
        syncSeqControls();
        refreshPreview();
    end

    function clampSequences()
        % Keep every sequence inside the dataset it refers to — which dims
        % exist and how long they are can change under us.
        for kC_ = 1:numel(seqs)
            s = seqs(kC_);
            if s.dim > nDims, s.dim = 0; end
            if s.dim >= 1
                N = model.Size(s.dim);
                s.from = max(1, min(N, round(s.from)));
                s.to   = max(1, min(N, round(s.to)));
                s.step = max(1, min(max(1, N), round(s.step)));
            end
            s.frames = max(1, round(s.frames));
            if s.cmax0 <= s.cmin0, s.cmax0 = s.cmin0 + 1; end
            if s.cmax1 <= s.cmin1, s.cmax1 = s.cmin1 + 1; end
            s.gamma0 = max(0.1, min(5, s.gamma0));
            s.gamma1 = max(0.1, min(5, s.gamma1));
            seqs(kC_) = s;
        end
        selIdx = max(1, min(numel(seqs), selIdx));
    end

    function onSeqSelected(idx)
        if syncing, return; end
        selIdx = max(1, min(numel(seqs), idx));
        syncSeqControls();
        syncSeqList();
        refreshPreview();
    end

    function onSeqAdd()
        seqs   = [seqs(1:selIdx), seqs(selIdx), seqs(selIdx+1:end)];
        selIdx = selIdx + 1;
        afterSeqChange();
    end

    function onSeqNew()
        seqs   = [seqs, newSequence()];
        selIdx = numel(seqs);
        afterSeqChange();
    end

    function onSeqDelete()
        if numel(seqs) <= 1
            lblStatus.Text = 'A movie needs at least one sequence.';
            return;
        end
        seqs(selIdx) = [];
        selIdx = max(1, min(numel(seqs), selIdx));
        afterSeqChange();
    end

    function onSeqMove(delta)
        j = selIdx + delta;
        if j < 1 || j > numel(seqs), return; end
        seqs([selIdx j]) = seqs([j selIdx]);
        selIdx = j;
        afterSeqChange();
    end

    function afterSeqChange()
        syncSeqList();
        syncSeqControls();
        % The time-label dimension comes from the first sweeping sequence,
        % so adding, deleting or reordering can change the layout.
        settingsChanged();
    end

    function syncSeqList()
        syncing = true;
        n = numel(seqs);
        labels = cell(1, n);
        for kL_ = 1:n
            labels{kL_} = seqLabel(kL_);
        end
        lbSeq.Items     = labels;
        lbSeq.ItemsData = 1:n;
        lbSeq.Value     = max(1, min(n, selIdx));
        btnSeqDel.Enable = onOff_(n > 1);
        btnSeqUp.Enable  = onOff_(selIdx > 1);
        btnSeqDn.Enable  = onOff_(selIdx < n);
        syncing = false;
        updateEstimate();
    end

    function txt = seqLabel(idx)
        s = seqs(idx);
        if s.dim >= 1
            what = sprintf('%s %g→%g', dimName(s.dim), s.from, s.to);
            if s.step > 1, what = sprintf('%s /%g', what, s.step); end
        else
            what = 'hold';
        end
        extra = '';
        if ~strcmp(s.cmode, 'follow')
            extra = [extra ' · ' contrastTag(s)];
        end
        if cameraMoves(s)
            extra = [extra ' · cam'];
        end
        txt = sprintf('%d. %s (%d f)%s', idx, what, seqFrames(s), extra);
    end

    function t = contrastTag(s)
        if strcmp(s.cmode, 'manual')
            if s.cmin0 == s.cmin1 && s.cmax0 == s.cmax1
                t = sprintf('%.4g..%.4g', s.cmin0, s.cmax0);
            else
                t = sprintf('%.4g..%.4g→%.4g..%.4g', ...
                    s.cmin0, s.cmax0, s.cmin1, s.cmax1);
            end
        else
            t = s.cmode;
        end
        if s.gamma0 == s.gamma1
            t = sprintf('%s g%.2g', t, s.gamma0);
        else
            t = sprintf('%s g%.2g→%.2g', t, s.gamma0, s.gamma1);
        end
    end

    function tf = cameraMoves(s)
        tf = s.az0 ~= s.az1 || s.el0 ~= s.el1 || s.zoom0 ~= s.zoom1;
    end

    function syncSeqControls()
        syncing = true;
        s = seqs(selIdx);

        ddDim.Value = s.dim;
        if s.dim >= 1
            N = model.Size(s.dim);
            setSpinner(spFrom, [1 N], s.from);
            setSpinner(spTo,   [1 N], s.to);
            setSpinner(spStep, [1 max(1, N)], s.step);
        end
        sweeping = s.dim >= 1;
        setEnable({spFrom, spTo, spStep}, sweeping);
        setEnable({spFrames}, ~sweeping);
        spFrames.Value = s.frames;

        ddCMode.Value  = s.cmode;
        spCMin0.Value  = s.cmin0;
        spCMin1.Value  = s.cmin1;
        spCMax0.Value  = s.cmax0;
        spCMax1.Value  = s.cmax1;
        spGam0.Value   = max(0.1, min(5, s.gamma0));
        spGam1.Value   = max(0.1, min(5, s.gamma1));
        manual = strcmp(s.cmode, 'manual');
        setEnable({spCMin0, spCMin1, spCMax0, spCMax1}, manual);
        setEnable({spGam0, spGam1}, ~strcmp(s.cmode, 'follow'));
        setEnable({btnFromCurrent, btnFromCurrentEnd}, true);

        spAz0.Value = s.az0;   spAz1.Value = s.az1;
        spEl0.Value = s.el0;   spEl1.Value = s.el1;
        spZ0.Value  = s.zoom0; spZ1.Value  = s.zoom1;

        % The camera and 3-D panels only mean anything when a 3-D panel is
        % actually in frame.
        has3D = layoutHas3D();
        setEnable({spAz0, spAz1, spEl0, spEl1, spZ0, spZ1, ...
                   btnHoldCam, btnSpin, btnGrab0, btnGrab1, ...
                   dd3Dim, dd3Style, dd3Extent, cb3Box, cb3Lab, sp3Vox}, has3D);

        syncing = false;
        syncFrameSlider();
        updateEstimate();
        update3DInfo();
    end

    function setSpinner(h, lims, val)
        % Limits and Value in either order safely: a Value outside the new
        % Limits would otherwise be rejected.
        val = max(lims(1), min(lims(2), val));
        cur = h.Limits;
        if val < cur(1) || val > cur(2)
            h.Limits = [-Inf Inf];
        end
        h.Limits = lims;
        h.Value  = val;
    end

% =========================================================================
%  Per-sequence edits
% =========================================================================
    function onDimChanged(d)
        if syncing, return; end
        s = seqs(selIdx);
        s.dim = d;
        if d >= 1
            N = model.Size(d);
            s.from = 1;
            s.to   = N;
            s.step = min(max(1, s.step), max(1, N));
        end
        seqs(selIdx) = s;
        syncSeqControls();
        syncSeqList();
        settingsChanged();          % the time label follows the swept dim
    end

    function onSweepEdit()
        if syncing, return; end
        s = seqs(selIdx);
        if s.dim >= 1
            s.from = spFrom.Value;
            s.to   = spTo.Value;
            s.step = max(1, spStep.Value);
        end
        s.frames = max(1, spFrames.Value);
        seqs(selIdx) = s;
        syncSeqList();
        syncFrameSlider();
        refreshPreview();
    end

    function onContrastEdit()
        if syncing, return; end
        s = seqs(selIdx);
        s.cmode  = ddCMode.Value;
        s.cmin0  = spCMin0.Value;
        s.cmin1  = spCMin1.Value;
        s.cmax0  = spCMax0.Value;
        s.cmax1  = spCMax1.Value;
        s.gamma0 = spGam0.Value;
        s.gamma1 = spGam1.Value;
        % Both ends must be a real window, or the frames in between
        % interpolate through an inverted one.
        if s.cmax0 <= s.cmin0, s.cmax0 = s.cmin0 + 1; end
        if s.cmax1 <= s.cmin1, s.cmax1 = s.cmin1 + 1; end
        seqs(selIdx) = s;
        syncSeqControls();
        syncSeqList();
        refreshPreview();
    end

    function onContrastFromCurrent(toEnd)
        s = seqs(selIdx);
        ads = model.ActiveDataset;
        if isempty(ads), ads = 1; end
        lo = model.ContrastMin;
        hi = model.ContrastMax;
        gm = model.Gamma;
        if ~isempty(cbs.computeDisplay)
            try
                dsp = cbs.computeDisplay(ads);
                lo  = dsp.cmin;
                hi  = dsp.cmax;
                gm  = dsp.gamma;
            catch
            end
        end
        if hi <= lo, hi = lo + 1; end
        if toEnd
            s.cmin1 = lo;  s.cmax1 = hi;  s.gamma1 = max(0.1, min(5, gm));
        else
            s.cmin0 = lo;  s.cmax0 = hi;  s.gamma0 = max(0.1, min(5, gm));
        end
        s.cmode = 'manual';
        seqs(selIdx) = s;
        syncSeqControls();
        syncSeqList();
        refreshPreview();
    end

    function onCameraEdit()
        if syncing, return; end
        s = seqs(selIdx);
        s.az0 = spAz0.Value;   s.az1 = spAz1.Value;
        s.el0 = spEl0.Value;   s.el1 = spEl1.Value;
        s.zoom0 = spZ0.Value;  s.zoom1 = spZ1.Value;
        seqs(selIdx) = s;
        syncSeqList();
        % A camera change needs no rebuild: it goes through the composer's
        % View3D, which owns no graphics objects.
        refreshPreview();
    end

    function onCameraHold()
        s = seqs(selIdx);
        s.az1 = s.az0;  s.el1 = s.el0;  s.zoom1 = s.zoom0;
        seqs(selIdx) = s;
        syncSeqControls();
        syncSeqList();
        refreshPreview();
    end

    function onCameraSpin()
        s = seqs(selIdx);
        s.az1 = s.az0 + 360;
        s.el1 = s.el0;
        seqs(selIdx) = s;
        syncSeqControls();
        syncSeqList();
        refreshPreview();
    end

    function onGrabCamera(toEnd)
        % Copy what the live 3-D window is showing, so a view found by
        % dragging there becomes a movie keyframe without reading angles off
        % its spinners by hand.  The camera goes into the end the button
        % names; the dimension triple and the style belong to the whole
        % movie, so either button syncs those.
        v = [];
        if ~isempty(cbs.get3DView)
            try; v = cbs.get3DView(); catch; end
        end
        if isempty(v) || ~isstruct(v)
            lblStatus.Text = ['No 3-D window to copy from — open one from ' ...
                              'the main window''s "3D" button first.'];
            return;
        end

        done = {};
        if isfield(v, 'az') && isfield(v, 'el') && isfield(v, 'zoom') && ...
                all(isfinite([v.az, v.el, v.zoom]))
            az = max(-720, min(720, v.az));
            el = max(-89,  min(89,  v.el));
            zm = max(0.05, min(50,  v.zoom));
            s = seqs(selIdx);
            if toEnd
                s.az1 = az;  s.el1 = el;  s.zoom1 = zm;
                where = 'end';
            else
                s.az0 = az;  s.el0 = el;  s.zoom0 = zm;
                where = 'start';
            end
            seqs(selIdx) = s;
            done{end+1} = sprintf('az %.1f, el %.1f, zoom %.2f into the %s', ...
                az, el, zm, where);
        end

        d = grabbedDims(v);
        if ~isempty(d) && ~isequal(d, dims3)
            dims3 = d;
            syncing = true;
            for kG_ = 1:3
                dd3Dim(kG_).Value = dims3(kG_);
            end
            syncing = false;
            done{end+1} = sprintf('dims %s/%s/%s', ...
                dimName(d(1)), dimName(d(2)), dimName(d(3)));
        end

        [st, note] = grabbedStyle(v);
        if ~isempty(st) && ~strcmp(dd3Style.Value, st)
            dd3Style.Value = st;
            done{end+1} = ['style ' styleLabel(st)];
        end

        syncSeqControls();
        syncSeqList();
        settingsChanged();      % dims and style change what the panel draws

        if isempty(done)
            msg = 'Nothing new to copy from the 3-D window.';
        else
            msg = ['Copied ' strjoin(done, ', ') ' from the 3-D window.'];
        end
        lblStatus.Text = [msg note];
    end

    function d = grabbedDims(v)
        d = [];
        if ~isfield(v, 'dims') || isempty(v.dims), return; end
        c = round(double(v.dims(:)'));
        if numel(c) ~= 3 || any(c < 1) || any(c > nDims) || numel(unique(c)) < 3
            return;
        end
        d = c;
    end

    function [st, note] = grabbedStyle(v)
        % The offscreen projection does maximum and minimum intensity.  The
        % interactive window's other styles (volume rendering, isosurface,
        % gradient opacity, slice planes) need the toolbox renderer and have
        % no offscreen equivalent, so they arrive as a maximum projection
        % and the status line says so rather than quietly substituting.
        st   = '';
        note = '';
        if ~isfield(v, 'style') || isempty(v.style), return; end
        raw = char(v.style);
        switch raw
            case 'MaximumIntensityProjection', st = 'max';
            case 'MinimumIntensityProjection', st = 'min';
            case {'max', 'min'},               st = raw;
            otherwise
                st   = 'max';
                note = sprintf([' The 3-D window''s "%s" has no offscreen ' ...
                    'equivalent, so the movie uses a maximum projection.'], raw);
        end
    end

    function lbl = styleLabel(st)
        if strcmp(st, 'min')
            lbl = 'Min intensity';
        else
            lbl = 'Max intensity';
        end
    end

% =========================================================================
%  Frame counts and the preview frame slider
% =========================================================================
    function n = seqFrames(s)
        if s.dim < 1
            n = max(1, round(s.frames));
            return;
        end
        N    = model.Size(s.dim);
        from = max(1, min(N, round(s.from)));
        to   = max(1, min(N, round(s.to)));
        step = max(1, round(s.step));
        if to >= from
            n = numel(from:step:to);
        else
            n = numel(from:-step:to);
        end
        n = max(1, n);
    end

    function n = totalFrames()
        n = 0;
        for kT_ = 1:numel(seqs)
            n = n + seqFrames(seqs(kT_));
        end
    end

    function updateEstimate()
        fps = max(1, spFps.Value);
        nS  = seqFrames(seqs(selIdx));
        nT  = totalFrames();
        lblEstimate.Text = sprintf('This sequence: %d frames, %.1f s', nS, nS / fps);
        lblTotal.Text    = sprintf('%d sequence(s), %d frames, %.1f s total', ...
            numel(seqs), nT, nT / fps);
    end

    function idx = previewFrame()
        idx = max(1, min(seqFrames(seqs(selIdx)), round(sldFrame.Value)));
    end

    function syncFrameSlider()
        % A slider needs Limits(2) > Limits(1) and a Value inside them, so a
        % one-frame sequence gets a disabled dummy range rather than an error.
        n = seqFrames(seqs(selIdx));
        v = max(1, min(n, round(sldFrame.Value)));
        if n < 2
            sldFrame.Value  = 1;
            sldFrame.Limits = [1 2];
            sldFrame.Value  = 1;
            sldFrame.Enable = 'off';
        else
            sldFrame.Value  = min(sldFrame.Value, n);   % before shrinking
            sldFrame.Limits = [1 n];
            sldFrame.Value  = v;
            sldFrame.Enable = 'on';
        end
        lblFrame.Text = sprintf('frame %d / %d', v, n);
    end

    function onScrub(v)
        % Dragging only repaints an already-open preview: a slider should
        % not conjure a window the user has not asked for.
        if busy() || scrubbing, return; end
        n   = seqFrames(seqs(selIdx));
        idx = max(1, min(n, round(v)));
        lblFrame.Text = sprintf('frame %d / %d', idx, n);
        if ~previewOpen(), return; end
        scrubbing = true;
        try
            showFrame(idx);
        catch me
            lblStatus.Text = ['Preview failed: ' me.message];
        end
        scrubbing = false;
    end

% =========================================================================
%  Shared settings
% =========================================================================
    function items = dimItems(withHold)
        n = numel(model.Size);
        items = cell(1, n);
        for kI_ = 1:n
            items{kI_} = sprintf('%d: %s (%d)', kI_, dimName(kI_), model.Size(kI_));
        end
        if withHold
            items = [{'0: hold (no sweep)'}, items];
        end
    end

    function items = dimNames()
        n = numel(model.Size);
        items = cell(1, n);
        for kM_ = 1:n
            items{kM_} = dimName(kM_);
        end
    end

    function s = dimName(d)
        if d >= 1 && d <= numel(model.DimNames)
            s = model.DimNames{d};
        else
            s = sprintf('dim%d', d);
        end
    end

    function tf = layoutHas3D()
        tf = contains(ddLayout.Value, '3d');
    end

    function d = timeLabelDim()
        % The dimension the time label reports: the first one any sequence
        % actually sweeps.  Shared across sequences, so selecting a
        % different one does not change the layout.
        d = 0;
        for kD_ = 1:numel(seqs)
            if seqs(kD_).dim >= 1
                d = seqs(kD_).dim;
                return;
            end
        end
        f = MatVisFrameComposer.firstFreeDim(model);
        if ~isempty(f), d = f; end
    end

    function on3DDimChanged(slot, newDim)
        clash = find(dims3 == newDim & (1:3) ~= slot, 1);
        if ~isempty(clash)
            dims3(clash) = dims3(slot);      % swap, so the slots stay distinct
        end
        dims3(slot) = newDim;
        syncing = true;
        for kW_ = 1:3
            dd3Dim(kW_).Value = dims3(kW_);
        end
        syncing = false;
        settingsChanged();
    end

    function onLayoutChanged()
        % A pure zoom movie defaults to the zoom region's own pixel size, so
        % the frame neither up- nor downsamples the data.
        if strcmp(ddLayout.Value, 'zoom')
            sizeFromZoom();
        end
        syncSeqControls();
        settingsChanged();
    end

    function sizeFromZoom()
        zr = model.ZoomRange;
        w  = zr(model.XDim, 2) - zr(model.XDim, 1) + 1;
        h  = zr(model.YDim, 2) - zr(model.YDim, 1) + 1;
        % Round up to even — MP4 and friends reject odd frame sizes.
        edtW.Value = clampEven(w, edtW.Limits);
        edtH.Value = clampEven(h, edtH.Limits);
        ddSize.Value = 'Custom';
    end

    function onEvenPixels()
        % Trim the live zoom box to even side lengths (drop the last row /
        % column when the extent is odd) so the capture needs no rounding.
        zr   = model.ZoomRange;
        dims = [model.XDim, model.YDim];
        for kZ_ = 1:numel(dims)
            d = dims(kZ_);
            n = zr(d, 2) - zr(d, 1) + 1;
            if mod(n, 2) && n > 1
                zr(d, 2) = zr(d, 2) - 1;
            end
        end
        if ~isequal(zr, model.ZoomRange)
            if ~isempty(cbs.setZoom)
                cbs.setZoom(zr);      % keeps the sliders and live windows in step
            else
                model.ZoomRange = zr;
                if ~isempty(cbs.liveRender), cbs.liveRender(); end
            end
        end
        if strcmp(ddLayout.Value, 'zoom')
            sizeFromZoom();
        end
        settingsChanged();
        zr = model.ZoomRange;
        lblStatus.Text = sprintf('Zoom is %d x %d px.', ...
            zr(model.XDim, 2) - zr(model.XDim, 1) + 1, ...
            zr(model.YDim, 2) - zr(model.YDim, 1) + 1);
    end

    function v = clampEven(v, lims)
        v = 2 * ceil(v / 2);
        v = min(max(v, 2 * ceil(lims(1) / 2)), 2 * floor(lims(2) / 2));
    end

    function onSizePreset()
        i = find(strcmp(SIZES, ddSize.Value), 1);
        if isempty(i) || any(isnan(SIZEVAL(i, :))), return; end
        edtW.Value = SIZEVAL(i, 1);
        edtH.Value = SIZEVAL(i, 2);
        settingsChanged();
    end

    function onSizeEdit()
        ddSize.Value = 'Custom';
        settingsChanged();
    end

    function onFormatChanged()
        fmt = MatVisVideoWriter.FormatByKey(ddFormat.Value);
        [~, stem] = fileparts(edtName.Value);
        edtName.Value = [stem fmt.ext];
        spQual.Enable = matlab.lang.OnOffSwitchState(~isempty(fmt.qualityField));
    end

    function n = defaultName()
        n = 'matVisMovie.mp4';
    end

    function p = outputPath()
        d = strtrim(edtDir.Value);
        n = strtrim(edtName.Value);
        if isempty(d), d = pwd; end
        p = fullfile(d, n);
    end

    function onBrowse()
        filters = MatVisVideoWriter.FileFilters(ddFormat.Value);
        [fn, pth, idx] = uiputfile(filters, 'Save movie as', outputPath());
        if isequal(fn, 0), return; end
        edtDir.Value  = char(pth);
        edtName.Value = char(fn);
        % Keep the format dropdown consistent with the chosen filter.
        keys = MatVisVideoWriter.AvailableFormats();
        if idx >= 1 && idx <= numel(keys)
            all = MatVisVideoWriter.Formats();
            all = all(ismember({all.key}, keys));
            ddFormat.Value = all(idx).key;
            onFormatChanged();
        end
        figure(fig);
    end

% =========================================================================
%  Composer
% =========================================================================
    function dropComposer()
        if ~isempty(composer)
            try; delete(composer); catch; end
            composer = [];
        end
    end

    function settingsChanged()
        % Push the panel's settings into the composer and, if the preview is
        % up, repaint it.  The composer decides for itself whether the change
        % needs its figure rebuilt (a layout or frame-size change does; an
        % overlay or 3-D style toggle does not), which is why this no longer
        % throws the composer away — doing that closed the preview window
        % every time a checkbox moved.
        update3DInfo();
        if isempty(composer) || ~isvalid(composer), return; end
        wasOpen = previewOpen();
        composer.SetLayout(buildLayout());
        composer.SetBackColor(backColor());
        composer.SetFrameSize([edtW.Value, edtH.Value]);
        if wasOpen && ~busy()
            try
                showFrame(previewFrame());
            catch me
                lblStatus.Text = ['Preview failed: ' me.message];
            end
        end
    end

    function refreshPreview()
        % Per-sequence change: the composer needs no new settings, only a
        % repaint of whichever frame the slider is on.
        if busy() || ~previewOpen(), return; end
        try
            showFrame(previewFrame());
        catch me
            lblStatus.Text = ['Preview failed: ' me.message];
        end
    end

    function tf = previewOpen()
        tf = ~isempty(composer) && isvalid(composer) && ...
             ~isempty(composer.Fig) && isvalid(composer.Fig) && ...
             strcmp(composer.Fig.Visible, 'on');
    end

    function bg = backColor()
        if strcmp(ddBg.Value, 'Black'), bg = [0 0 0]; else, bg = [1 1 1]; end
    end

    function col = annotColor()
        if strcmp(ddText.Value, 'Black'), col = [0 0 0]; else, col = [1 1 1]; end
    end

    function ads = activeDataset()
        ads = model.ActiveDataset;
        if isempty(ads), ads = 1; end
    end

    function layout = buildLayout()
        base   = MatVisFrameComposer.DefaultLayout(ddLayout.Value, model);
        txtCol = annotColor();

        for kP_ = 1:numel(base)
            switch base(kP_).type
                case {'image', 'zoom'}
                    % Overlay switches apply to every image/zoom panel.
                    base(kP_).overlays.rois      = cbRois.Value;
                    base(kP_).overlays.profiles  = cbRois.Value;
                    base(kP_).overlays.crosshair = cbCross.Value;
                    base(kP_).fillZoom           = cbFillZoom.Value;
                case 'volume'
                    base(kP_).dims3      = dims3;
                    base(kP_).extent     = dd3Extent.Value;
                    base(kP_).style      = dd3Style.Value;
                    base(kP_).maxVox     = sp3Vox.Value * 1e6;
                    base(kP_).box        = cb3Box.Value;
                    base(kP_).showLabels = cb3Lab.Value;
                    base(kP_).dataset    = activeDataset();
            end
        end

        % Time label and scale bar ride on the first image/zoom panel, drawn
        % in its data coordinates so they always land on the picture.  A 3-D
        % panel can carry the label when there is no 2-D panel, but not the
        % scale bar: a projection has no single pixel size.
        for kA_ = 1:numel(base)
            if ismember(base(kA_).type, {'image', 'zoom', 'volume'})
                if cbTime.Value
                    base(kA_).timeDim = timeLabelDim();
                else
                    base(kA_).timeDim = 0;
                end
                base(kA_).scaleBar   = cbBar.Value && ~strcmp(base(kA_).type, 'volume');
                base(kA_).annotColor = txtCol;
                break;
            end
        end

        % Reserve a strip for the histogram and squeeze the rest into what is
        % left, so every arrangement gets the option without a second set of
        % hard-coded positions.
        content = [0 0 1 1];
        hrect   = [];
        switch ddHist.Value
            case 'bottom'
                hrect   = [0 0 1 0.22];
                content = [0 0.22 1 0.78];
            case 'right'
                hrect   = [0.70 0 0.30 1];
                content = [0 0 0.70 1];
        end
        layout = MatVisFrameComposer.ScaleInto(base, content);

        if ~isempty(hrect)
            h = MatVisFrameComposer.panel('histogram', hrect, []);
            h.dataset  = activeDataset();
            h.histLog  = cbHistLog.Value;
            h.fontSize = 13;
            layout     = [layout, h];
        end

        if ~isempty(strtrim(edtTitle.Value))
            p = MatVisFrameComposer.panel('title', [0.02 0.925 0.96 0.065], []);
            p.text     = strtrim(edtTitle.Value);
            p.fontSize = 15;
            p.color    = txtCol;
            layout     = [layout, p];
        end
    end

    function c = ensureComposer()
        if isempty(composer) || ~isvalid(composer)
            composer = MatVisFrameComposer(model, buildLayout(), ...
                'FrameSize',  [edtW.Value, edtH.Value], ...
                'BackColor',  backColor(), ...
                'DisplayFcn', cbs.computeDisplay);
            composer.HistRangeFcn = cbs.histRange;
            s = seqs(selIdx);
            composer.View3D = struct('az', s.az0, 'el', s.el0, 'zoom', s.zoom0);
        else
            composer.SetLayout(buildLayout());
            composer.SetBackColor(backColor());
            composer.SetFrameSize([edtW.Value, edtH.Value]);
        end
        c = composer;
    end

% =========================================================================
%  Timeline
% =========================================================================
    function sp = seqSpec(s, frameIdx)
        % One sequence as a recorder spec.  The contrast goes in as model
        % state (the recorder restores it afterwards); the camera goes in as
        % a ramp the recorder pushes into the composer frame by frame.
        % FRAMEIDX >= 1 narrows it to that single frame, which is how the
        % preview shows any point along a sequence rather than only its start.
        if nargin < 2, frameIdx = 0; end
        % The mode is a name, so it is held; the numbers are ramped.
        st  = struct();
        rmp = struct();
        switch s.cmode
            case 'follow'
                % Whatever the live windows are showing.
            case 'manual'
                st.ContrastLocked  = true;
                st.ContrastMode    = 'Manual';
                rmp.ContrastMin    = [s.cmin0 s.cmin1];
                rmp.ContrastMax    = [s.cmax0 s.cmax1];
                rmp.Gamma          = [s.gamma0 s.gamma1];
            otherwise
                st.ContrastLocked  = true;
                st.ContrastMode    = s.cmode;   % 'Global' | 'Image' | 'Zoom'
                rmp.Gamma          = [s.gamma0 s.gamma1];
        end

        nF   = seqFrames(s);
        ramp = struct('az', [s.az0 s.az1], 'el', [s.el0 s.el1], ...
                      'zoom', [s.zoom0 s.zoom1]);
        one  = frameIdx >= 1;
        if one
            % Collapse both ramps to this frame's values — a one-frame
            % sequence would otherwise always report the start.
            k = max(1, min(nF, round(frameIdx)));
            v   = MatVisRecorder.rampView(ramp, k, nF);
            rmp = MatVisRecorder.rampStruct(rmp, k, nF);
            if isempty(rmp), rmp = struct(); end
        else
            v = ramp;
        end

        if s.dim < 1
            if one, nF = 1; end
            sp = MatVisRecorder.SweepSpec(0, 'Frames', nF, ...
                'State', st, 'StateRamp', rmp, 'View3D', v);
        elseif one
            step = max(1, round(s.step));
            if s.to >= s.from
                pos = s.from + (k - 1) * step;
            else
                pos = s.from - (k - 1) * step;
            end
            pos = max(1, min(model.Size(s.dim), pos));
            sp = MatVisRecorder.SweepSpec(s.dim, 'From', pos, 'To', pos, ...
                'Step', 1, 'State', st, 'StateRamp', rmp, 'View3D', v);
        else
            sp = MatVisRecorder.SweepSpec(s.dim, 'From', s.from, 'To', s.to, ...
                'Step', s.step, 'State', st, 'StateRamp', rmp, 'View3D', v);
        end
    end

    function sp = buildSweeps(scope, frameIdx)
        % SCOPE is 'all', 'selected' or 'frame' (FRAMEIDX of the selection).
        if nargin < 2, frameIdx = 1; end
        switch scope
            case 'selected'
                sp = seqSpec(seqs(selIdx));
            case 'frame'
                sp = seqSpec(seqs(selIdx), max(1, frameIdx));
            otherwise
                sp = seqSpec(seqs(1));
                for kB_ = 2:numel(seqs)
                    sp(kB_) = seqSpec(seqs(kB_));
                end
        end
    end

    function rec = makeRecorder(c, scope, writer, frameIdx)
        if nargin < 4, frameIdx = 1; end
        rec = MatVisRecorder(model, c, writer);
        rec.Sweep         = buildSweeps(scope, frameIdx);
        rec.LiveRenderFcn = cbs.liveRender;
    end

    function showComposerFig(c)
        % The composer owns Fig read-only, so take the handle out first:
        % "c.Fig.Name = x" is a write to the Fig property itself, which is
        % rejected, not a write to the figure it points at.
        pf = c.Fig;
        if isempty(pf) || ~isvalid(pf), return; end
        pf.Name    = sprintf('Movie preview — %d x %d', edtW.Value, edtH.Value);
        pf.Visible = 'on';
    end

    function showFrame(idx)
        % Paint one frame of the selected sequence into the composer figure
        % and leave it visible.  Raising the window is the caller's business:
        % a scrub must not steal focus on every drag event.
        %
        % Painting ends in a drawnow, which services the event queue and can
        % re-enter here through another widget callback.  One repaint at a
        % time: the second would interleave with the first's model state.
        if painting, return; end
        painting = true;
        try
            c   = ensureComposer();
            rec = makeRecorder(c, 'frame', [], idx);
            rec.PreviewOnly = true;
            rec.Render();
            showComposerFig(c);
        catch me
            painting = false;
            rethrow(me);
        end
        painting = false;
    end

% =========================================================================
%  Preview / play / render
% =========================================================================
    function onPreview()
        if busy(), return; end
        try
            lblStatus.Text = 'Rendering preview...';
            drawnow;
            idx = previewFrame();
            showFrame(idx);
            figure(composer.Fig);
            lblStatus.Text = sprintf(['Preview: %d x %d, sequence %d ' ...
                'frame %d of %d. This is exactly what gets captured.'], ...
                edtW.Value, edtH.Value, selIdx, idx, seqFrames(seqs(selIdx)));
        catch me
            lblStatus.Text = ['Preview failed: ' me.message];
            alert(me.message, 'Preview failed');
        end
    end

    function onPlay(wholeMovie)
        if busy(), return; end
        if nargin < 1, wholeMovie = false; end
        playing   = true;
        cancelReq = false;
        setBusy(true);
        try
            c = ensureComposer();
            c.PaintFrame();          % build it before showing, so nothing flashes
            showComposerFig(c);
            figure(c.Fig);

            if wholeMovie, scope = 'all'; else, scope = 'selected'; end
            rec = makeRecorder(c, scope, []);
            rec.PreviewOnly = true;
            rec.OnProgress  = @onPlayProgress;
            playTic = tic;
            info = rec.Render();

            if info.cancelled
                lblStatus.Text = sprintf('Stopped after %d of %d frames.', ...
                    info.frames, info.requested);
            else
                lblStatus.Text = sprintf('Played %d frames in %.1f s (%.0f ms/frame).', ...
                    info.frames, info.elapsed, info.msPerFrame);
            end
        catch me
            lblStatus.Text = ['Playback failed: ' me.message];
            alert(me.message, 'Playback failed');
        end
        setBusy(false);
        playing = false;
        refreshPreview();
    end

    function keepGoing = onPlayProgress(i, n)
        keepGoing = ~cancelReq;
        lblStatus.Text = sprintf('Playing frame %d of %d...', i, n);
        % PaintFrame has already run a full drawnow, so Stop has been
        % serviced; this only paces the animation to the chosen frame rate.
        dt = 1 / max(1, spFps.Value);
        el = toc(playTic);
        if el < dt
            pause(dt - el);
        else
            drawnow limitrate;
        end
        playTic = tic;
    end

    function onRender()
        if busy(), return; end
        if isempty(strtrim(edtName.Value))
            alert('Enter an output file name first.', 'Video Generator');
            return;
        end
        outFile = outputPath();
        outDir  = fileparts(outFile);
        if ~isfolder(outDir)
            alert(sprintf('Folder does not exist:\n%s', outDir), 'Video Generator');
            return;
        end
        if isfile(outFile)
            answer = uiconfirm(fig, sprintf('Overwrite "%s"?', outFile), ...
                'Video Generator', 'Options', {'Overwrite', 'Cancel'}, ...
                'DefaultOption', 2, 'CancelOption', 2);
            if ~strcmp(answer, 'Overwrite'), return; end
        end

        rendering = true;
        cancelReq = false;
        setBusy(true);
        writer = [];
        try
            c = ensureComposer();
            writer = MatVisVideoWriter(outFile, ddFormat.Value, ...
                'FrameRate', spFps.Value, 'Quality', spQual.Value);

            rec = makeRecorder(c, 'all', writer);
            rec.OnProgress = @onProgress;

            info = rec.Render();

            if info.cancelled
                lblStatus.Text = sprintf('Cancelled after %d of %d frames. Partial file: %s', ...
                    info.frames, info.requested, info.file);
            else
                lblStatus.Text = sprintf('Wrote %d frames in %.1f s (%.0f ms/frame): %s', ...
                    info.frames, info.elapsed, info.msPerFrame, info.file);
            end
            fprintf('[matVis2] %s\n', lblStatus.Text);
        catch me
            try; if ~isempty(writer), writer.Close(); end; catch; end
            lblStatus.Text = ['Render failed: ' me.message];
            alert(me.message, 'Render failed');
        end
        setBusy(false);
        rendering = false;
        refreshPreview();
    end

    function keepGoing = onProgress(i, n)
        lblStatus.Text = sprintf('Rendering frame %d of %d...', i, n);
        drawnow limitrate;
        keepGoing = ~cancelReq;
    end

    function onCancel()
        cancelReq = true;
        lblStatus.Text = 'Stopping...';
    end

    function update3DInfo()
        if ~layoutHas3D()
            lbl3Info.Text = '';
            return;
        end
        r = [ones(3, 1), reshape(model.Size(dims3), [], 1)];
        if strcmp(dd3Extent.Value, 'zoom')
            r = model.ZoomRange(dims3(:), :);
        end
        [~, n, strides] = MatVisVolumeView.planSampling(double(r), sp3Vox.Value * 1e6);
        nv = prod(ceil(n ./ strides));
        if any(strides > 1)
            lbl3Info.Text = sprintf('%.2f M vox, stride %d/%d/%d', ...
                nv / 1e6, strides(1), strides(2), strides(3));
        else
            lbl3Info.Text = sprintf('%.2f M vox', nv / 1e6);
        end
    end

    function alert(msg, title)
        % uialert refuses a hidden figure, and a movie can be driven from a
        % script with the panel never shown — so never let reporting a
        % failure fail in a way that hides the failure itself.
        if strcmp(fig.Visible, 'on')
            try
                uialert(fig, msg, title);
                return;
            catch
            end
        end
        warning('matVis2:videoGenerator', '%s: %s', title, msg);
    end

    function tf = busy()
        tf = rendering || playing;
    end

    function setBusy(tf)
        state = matlab.lang.OnOffSwitchState(~tf);
        set([btnPreview, btnPlaySeq, btnPlayAll, btnRender], 'Enable', state);
        sldFrame.Enable = matlab.lang.OnOffSwitchState( ...
            ~tf && seqFrames(seqs(selIdx)) > 1);
        btnStop.Enable  = matlab.lang.OnOffSwitchState(tf);
    end
end
