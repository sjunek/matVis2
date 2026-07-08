function rm = MatVisRoiWin(model, cb)
% MatVisRoiWin  ROI Manager window for matVis 2.0.
%
%   rm = MatVisRoiWin(model, cb)
%
%   model - MatVisModel handle (owns the ROI list, see model.RoiList)
%   cb    - struct of callbacks provided by MatVisMainWindow:
%       .setRoiMode(mode, modeCb)  engage/release ROI mouse mode on all
%                                  image and zoom windows
%       .applyPosition(pos, zoom)  jump navigation state to an ROI's
%                                  stored position/zoom
%       .onHide()                  notify that the window was closed
%                                  (untoggles the main-window ROI button)
%
%   rm.fig      - uifigure handle (created hidden)
%   rm.Refresh  - @() refresh listbox/stats from the model
%
% Tools:
%   Rect / Ellipse / Polygon : draw new ROIs in any image or zoom window.
%       Drag for a sized shape, plain click for a 1-click ROI of the
%       configured size.  Polygon: click for vertices, hold and drag for
%       freehand, double-click or right-click to close.  Right-click
%       (outside an open polygon) exits the tool.
%   Shift / Rotate / Scale   : drag in any image or zoom window to
%       transform the selected ROI(s).
%   Arrow keys (in this window): shift selected ROI(s) by 1 px
%       (Ctrl ×5, Shift ×10, Alt ×20).

if nargin < 2, cb = struct(); end
if ~isfield(cb, 'setRoiMode'),    cb.setRoiMode    = @(varargin) []; end
if ~isfield(cb, 'applyPosition'), cb.applyPosition = @(varargin) []; end
if ~isfield(cb, 'onHide'),        cb.onHide        = @() [];        end
if ~isfield(cb, 'onActivate'),    cb.onActivate    = @() [];        end

%% ---- Local state --------------------------------------------------------
activeTool   = '';      % '', 'rect','ellipse','poly','shift','rotate','scale'
newRoiSize   = 5;       % half-size (px) of 1-click ROIs
jumpToRoiPos = false;   % jump navigation to ROI's stored position on select
snapCorners  = {};      % corner snapshots during a mouse transform
snapP0       = [];      % drag start point (data coords)
snapCenter   = [];      % transform center
snapBBox     = [];      % combined bounding box [x0 y0 x1 y1]
snapSel      = [];      % ROI indices being transformed

%% ---- Figure & layout ----------------------------------------------------
fig = uifigure('Name', 'ROI Manager', 'NumberTitle', 'off', ...
    'MenuBar', 'none', 'Resize', 'off', 'Visible', 'off');
fig.Position(3:4) = [380, 600];
fig.CloseRequestFcn = @(~,~) onCloseRequest();
fig.KeyPressFcn     = @(~,evt) onKeyPress(evt);

mainGrid = uigridlayout(fig, [4, 1]);
mainGrid.RowHeight  = {'1x', 60, 88, 190};
mainGrid.ColumnWidth = {'1x'};
mainGrid.Padding    = [8 8 8 8];
mainGrid.RowSpacing = 6;

%% ---- Row 1: ROI list + action buttons -----------------------------------
listGrid = uigridlayout(mainGrid, [1, 2]);
listGrid.Layout.Row    = 1;
listGrid.ColumnWidth   = {'1x', 96};
listGrid.RowHeight     = {'1x'};
listGrid.Padding       = [0 0 0 0];
listGrid.ColumnSpacing = 6;

lst = uilistbox(listGrid, ...
    'Items', {}, 'ItemsData', [], 'Multiselect', 'on', ...
    'FontSize', 11, ...
    'Tooltip', 'ROI list. Ctrl/Shift-click for multiple selection.', ...
    'ValueChangedFcn', @(src,~) onListSelection(src));
lst.Layout.Column = 1;

btnGrid = uigridlayout(listGrid, [7, 1]);
btnGrid.Layout.Column = 2;
btnGrid.RowHeight   = repmat({26}, 1, 7);
btnGrid.ColumnWidth = {'1x'};
btnGrid.Padding     = [0 0 0 0];
btnGrid.RowSpacing  = 4;

btnDelete = uibutton(btnGrid, 'Text', 'Delete', 'FontSize', 11, ...
    'Tooltip', 'Delete selected ROI(s)', ...
    'ButtonPushedFcn', @(~,~) onDelete());
btnCopy = uibutton(btnGrid, 'Text', 'Copy', 'FontSize', 11, ...
    'Tooltip', 'Duplicate selected ROI(s)', ...
    'ButtonPushedFcn', @(~,~) onCopy());
btnRename = uibutton(btnGrid, 'Text', 'Rename', 'FontSize', 11, ...
    'Tooltip', 'Rename the selected ROI', ...
    'ButtonPushedFcn', @(~,~) onRename());
btnReplace = uibutton(btnGrid, 'state', 'Text', 'Replace', 'FontSize', 11, ...
    'Tooltip', ['When active, drawing a new shape replaces the geometry ' ...
    'of the selected ROI (name and list position are kept).']);
btnExport = uibutton(btnGrid, 'Text', 'Export...', 'FontSize', 11, ...
    'Tooltip', 'Save all ROIs to a .mat file (matVis ROI format)', ...
    'ButtonPushedFcn', @(~,~) onExportRois());
btnImport = uibutton(btnGrid, 'Text', 'Import...', 'FontSize', 11, ...
    'Tooltip', 'Load ROIs from a .mat file (matVis ROI format)', ...
    'ButtonPushedFcn', @(~,~) onImportRois());
btnShowNames = uibutton(btnGrid, 'state', 'Text', 'Names', 'FontSize', 11, ...
    'Value', model.RoiShowNames, ...
    'Tooltip', 'Show/hide ROI name labels in image and zoom windows', ...
    'ValueChangedFcn', @(src,~) onShowNames(src));

%% ---- Row 2: drawing / transform tools -----------------------------------
toolPanel = uipanel(mainGrid, 'Title', 'Tools', 'FontSize', 11, ...
    'BorderType', 'line');
toolPanel.Layout.Row = 2;

toolGrid = uigridlayout(toolPanel, [1, 6]);
toolGrid.ColumnWidth   = repmat({'1x'}, 1, 6);
toolGrid.RowHeight     = {'1x'};
toolGrid.Padding       = [4 4 4 4];
toolGrid.ColumnSpacing = 3;

toolDefs = { ...
    'rect',    'Rect',  'Draw rectangle ROIs (drag, or click for a 1-click ROI). Right-click to exit.'; ...
    'ellipse', 'Ellip', 'Draw ellipse ROIs (drag, or click for a 1-click ROI). Right-click to exit.'; ...
    'poly',    'Poly',  'Draw polygon/freehand ROIs: click for vertices, hold for freehand, double/right-click to close.'; ...
    'shift',   'Shift', 'Drag in an image/zoom window to move the selected ROI(s). Arrow keys work here too.'; ...
    'rotate',  'Rot',   'Drag in an image/zoom window to rotate the selected ROI(s) around their center.'; ...
    'scale',   'Scale', 'Drag in an image/zoom window to scale the selected ROI(s).'};
toolButtons = struct();
for t = 1:size(toolDefs, 1)
    key = toolDefs{t, 1};
    b = uibutton(toolGrid, 'state', 'Text', toolDefs{t, 2}, 'FontSize', 11, ...
        'Tooltip', toolDefs{t, 3}, ...
        'ValueChangedFcn', @(src,~) onToolToggled(key, src)); %#ok<NASGU> key captured per loop
    b.Layout.Column = t;
    toolButtons.(key) = b;
end

%% ---- Row 3: settings + trace export --------------------------------------
setPanel = uipanel(mainGrid, 'Title', 'Settings / trace export', ...
    'FontSize', 11, 'BorderType', 'line');
setPanel.Layout.Row = 3;

setGrid = uigridlayout(setPanel, [2, 4]);
setGrid.RowHeight     = {24, 24};
setGrid.ColumnWidth   = {'1x', 64, '1x', 64};
setGrid.Padding       = [4 4 4 4];
setGrid.RowSpacing    = 4;
setGrid.ColumnSpacing = 4;

cbJump = uicheckbox(setGrid, 'Text', 'Jump to ROI pos.', 'FontSize', 10, ...
    'Tooltip', ['When a single ROI is selected, jump position and zoom to ' ...
    'the state stored when the ROI was created.'], ...
    'ValueChangedFcn', @(src,~) onJumpChanged(src));
cbJump.Layout.Row = 1;  cbJump.Layout.Column = [1, 2];

lblLW = uilabel(setGrid, 'Text', 'Line width:', 'FontSize', 10, ...
    'HorizontalAlignment', 'right');
lblLW.Layout.Row = 1;  lblLW.Layout.Column = 3;
edtLineWidth = uieditfield(setGrid, 'numeric', 'Value', model.RoiLineWidth, ...
    'Limits', [0.5, 10], 'FontSize', 10, ...
    'ValueChangedFcn', @(src,~) onLineWidth(src));
edtLineWidth.Layout.Row = 1;  edtLineWidth.Layout.Column = 4;

lblSz = uilabel(setGrid, 'Text', '1-click size (px):', 'FontSize', 10, ...
    'HorizontalAlignment', 'right');
lblSz.Layout.Row = 2;  lblSz.Layout.Column = 1;
edtClickSize = uieditfield(setGrid, 'numeric', 'Value', newRoiSize, ...
    'Limits', [1, 1000], 'RoundFractionalValues', true, 'FontSize', 10, ...
    'Tooltip', 'Half-size of ROIs created by a single click (side = 2*size+1)', ...
    'ValueChangedFcn', @(src,~) setClickSize(src));
edtClickSize.Layout.Row = 2;  edtClickSize.Layout.Column = 2;

dropExportDim = uidropdown(setGrid, 'Items', {''}, 'ItemsData', 0, ...
    'FontSize', 10, 'Tooltip', 'Dimension along which ROI traces are exported');
dropExportDim.Layout.Row = 2;  dropExportDim.Layout.Column = 3;

btnExportData = uibutton(setGrid, 'Text', 'Exp. traces', 'FontSize', 10, ...
    'Tooltip', ['Export mean trace of the selected ROI(s) (all ROIs when ' ...
    'none selected) along the chosen dimension to the base workspace.'], ...
    'ButtonPushedFcn', @(~,~) onExportData());
btnExportData.Layout.Row = 2;  btnExportData.Layout.Column = 4;

%% ---- Row 4: selected-ROI info panel ---------------------------------------
infoPanel = uipanel(mainGrid, 'Title', 'Selected ROI', 'FontSize', 11, ...
    'BorderType', 'line');
infoPanel.Layout.Row = 4;

infoGrid = uigridlayout(infoPanel, [1, 2]);
infoGrid.ColumnWidth   = {130, '1x'};
infoGrid.RowHeight     = {'1x'};
infoGrid.Padding       = [4 4 4 4];
infoGrid.ColumnSpacing = 6;

lblStats = uilabel(infoGrid, 'Text', 'No ROI selected', 'FontSize', 10, ...
    'VerticalAlignment', 'top', 'WordWrap', 'on');
lblStats.Layout.Column = 1;

histAx = uiaxes(infoGrid);
histAx.Layout.Column = 2;
disableDefaultInteractivity(histAx);
try; histAx.Toolbar = []; catch; end   % remove toolbar + R2026a chevron
histAx.FontSize = 8;
histAx.YTick = [];
title(histAx, 'Pixel value histogram', 'FontSize', 9);

%% ---- Model listener -------------------------------------------------------
roiListener = addlistener(model, 'RoiChanged', @(~,~) refreshUI());
fig.DeleteFcn = @(~,~) onFigureDeleted();

%% ---- Output ---------------------------------------------------------------
rm.fig             = fig;
rm.Refresh         = @refreshUI;
rm.DeactivateTools = @deactivateTool;

refreshUI();

%% =========================================================================
%  Nested functions
%% =========================================================================

    function onCloseRequest()
        deactivateTool();
        fig.Visible = 'off';
        try; cb.onHide(); catch; end
    end

    function onFigureDeleted()
        if ~isempty(roiListener) && isvalid(roiListener)
            delete(roiListener);
        end
    end

    % ------------------------------------------------------------------
    %  Refresh listbox, buttons, stats
    % ------------------------------------------------------------------
    function refreshUI()
        if ~isvalid(fig)
            onFigureDeleted();
            return;
        end

        n = numel(model.RoiList);
        items = cell(1, n);
        for k = 1:n
            items{k} = sprintf('%03d: %s', k, model.RoiList(k).name);
        end
        lst.Items     = items;
        lst.ItemsData = 1:n;
        sel = model.RoiSelection;
        sel = sel(sel >= 1 & sel <= n);
        if isempty(sel)
            lst.Value = {};
        else
            lst.Value = sel;
        end

        hasRois = n > 0;
        nSel    = numel(sel);
        btnDelete.Enable  = hasRois && nSel >= 1;
        btnCopy.Enable    = hasRois && nSel >= 1;
        btnRename.Enable  = nSel == 1;
        btnReplace.Enable = nSel == 1;
        btnExport.Enable  = hasRois;
        toolButtons.shift.Enable  = nSel >= 1;
        toolButtons.rotate.Enable = nSel >= 1;
        toolButtons.scale.Enable  = nSel >= 1;

        refreshExportDims();
        updateStats(sel);
    end

    function refreshExportDims()
        nD    = numel(model.Size);
        dims  = setdiff(1:nD, [model.XDim, model.YDim]);
        dims  = dims(model.Size(dims) > 1);
        if isempty(dims)
            dropExportDim.Items     = {'(none)'};
            dropExportDim.ItemsData = 0;
            btnExportData.Enable    = false;
        else
            names = cell(1, numel(dims));
            for k = 1:numel(dims)
                names{k} = model.DimNames{dims(k)};
            end
            prev = dropExportDim.Value;
            dropExportDim.Items     = names;
            dropExportDim.ItemsData = dims;
            if ismember(prev, dims), dropExportDim.Value = prev; end
            btnExportData.Enable = numel(model.RoiList) > 0;
        end
    end

    function updateStats(sel)
        cla(histAx);
        visSel = sel(ismember(sel, model.VisibleRoiIndices()));
        if isempty(visSel)
            if isempty(sel)
                lblStats.Text = 'No ROI selected';
            else
                lblStats.Text = sprintf(['Selected ROI(s) belong to a ' ...
                    'different XY display plane.']);
            end
            return;
        end

        % Pool pixel values of all selected (visible) ROIs in the current slice
        vals = [];
        for k = visSel
            vals = [vals; MatVisRender.getRoiValuesFromData(model, model.Data, ...
                model.RoiList(k))]; %#ok<AGROW>
        end
        if isempty(vals)
            lblStats.Text = 'ROI mask is empty';
            return;
        end

        if numel(visSel) == 1
            nameStr = model.RoiList(visSel).name;
        else
            nameStr = sprintf('%d ROIs', numel(visSel));
        end
        lblStats.Text = sprintf(['%s\n# pixels: %d\nmean: %.4g\nstd: %.4g\n' ...
            'min: %.4g\nmax: %.4g'], nameStr, numel(vals), ...
            mean(vals, 'omitnan'), std(vals, 'omitnan'), ...
            min(vals), max(vals));

        [counts, edges] = histcounts(vals, min(50, max(10, round(sqrt(numel(vals))))));
        centers = edges(1:end-1) + diff(edges)/2;
        plot(histAx, centers, counts, '-', 'Color', [0.2 0.2 0.2], 'LineWidth', 1);
        histAx.YTick = [];
        histAx.XLim  = [edges(1), max(edges(end), edges(1) + eps(edges(1)) + 1e-12)];
    end

    % ------------------------------------------------------------------
    %  Listbox selection
    % ------------------------------------------------------------------
    function onListSelection(src)
        sel = src.Value;
        if iscell(sel), sel = []; end
        model.SetRoiSelection(sel);
        if jumpToRoiPos && numel(sel) == 1
            s = model.RoiList(sel).settings;
            try; cb.applyPosition(s.position, s.zoomVal); catch; end
        end
    end

    % ------------------------------------------------------------------
    %  Tool activation / mouse mode routing
    % ------------------------------------------------------------------
    function onToolToggled(toolName, src)
        if src.Value
            % Deactivate all other tool buttons
            keys = fieldnames(toolButtons);
            for k = 1:numel(keys)
                if ~strcmp(keys{k}, toolName)
                    toolButtons.(keys{k}).Value = false;
                end
            end

            isTransform = ismember(toolName, {'shift', 'rotate', 'scale'});
            if isTransform && isempty(model.RoiSelection)
                src.Value = false;
                uialert(fig, 'Select at least one ROI first.', 'ROI Manager');
                return;
            end

            try; cb.onActivate(); catch; end   % release profile tools
            activeTool = toolName;
            if isTransform
                cb.setRoiMode('drag', @onDragEvent);
            else
                cb.setRoiMode(toolName, @onShapeEvent);
            end
        else
            deactivateTool();
        end
    end

    function deactivateTool()
        activeTool = '';
        keys = fieldnames(toolButtons);
        for k = 1:numel(keys)
            toolButtons.(keys{k}).Value = false;
        end
        cb.setRoiMode('', []);
    end

    % ------------------------------------------------------------------
    %  New-shape events from image/zoom windows
    % ------------------------------------------------------------------
    function onShapeEvent(phase, pts)
        switch phase
            case 'shape'
                corners = expandClickRoi(pts);
                sel = model.RoiSelection;
                if btnReplace.Value && numel(sel) == 1
                    model.ReplaceRoiGeometry(sel, corners);
                else
                    model.AddRoi(corners);
                end
            case 'exit'
                deactivateTool();
        end
    end

    function corners = expandClickRoi(pts)
        % A plain click produces a ~1×1 px shape — expand it to the
        % configured 1-click ROI size, keeping the active shape type.
        corners = pts;
        w = max(pts(1,:)) - min(pts(1,:));
        h = max(pts(2,:)) - min(pts(2,:));
        if w > 1.5 || h > 1.5, return; end
        c = [mean(pts(1,:)), mean(pts(2,:))];
        r = newRoiSize + 0.5;
        if strcmp(activeTool, 'ellipse')
            t = linspace(0, 2*pi, max(24, ceil(4*r)));
            corners = [c(1) + r*sin(t); c(2) + r*cos(t)];
            corners(:, end) = corners(:, 1);
        else
            x1 = round(c(1)) - r;  x2 = round(c(1)) + r;
            y1 = round(c(2)) - r;  y2 = round(c(2)) + r;
            corners = [x1 x1 x2 x2 x1; y1 y2 y2 y1 y1];
        end
    end

    % ------------------------------------------------------------------
    %  Shift / rotate / scale via mouse drag
    % ------------------------------------------------------------------
    function onDragEvent(phase, pt)
        switch phase
            case 'start'
                snapSel = model.RoiSelection;
                snapSel = snapSel(snapSel >= 1 & snapSel <= numel(model.RoiList));
                if isempty(snapSel), return; end
                snapCorners = cell(1, numel(snapSel));
                allC = [];
                for k = 1:numel(snapSel)
                    snapCorners{k} = model.RoiList(snapSel(k)).corners;
                    allC = [allC, snapCorners{k}]; %#ok<AGROW>
                end
                snapP0     = pt;
                snapBBox   = [min(allC(1,:)), min(allC(2,:)), ...
                              max(allC(1,:)), max(allC(2,:))];
                snapCenter = [(snapBBox(1)+snapBBox(3))/2, ...
                              (snapBBox(2)+snapBBox(4))/2];

            case 'move'
                if isempty(snapSel), return; end
                applyTransform(pt);
                model.TouchRois();

            case 'end'
                if isempty(snapSel), return; end
                applyTransform(pt);
                model.RecomputeRoiGeometry(snapSel);
                snapSel = [];

            case 'exit'
                snapSel = [];
                deactivateTool();
        end
    end

    function applyTransform(pt)
        for k = 1:numel(snapSel)
            c0 = snapCorners{k};
            switch activeTool
                case 'shift'
                    d = round(pt - snapP0);
                    cNew = c0 + d(:);

                case 'rotate'
                    cx = snapCenter(1);  cy = snapCenter(2);
                    a0 = atan2(snapP0(2) - cy, snapP0(1) - cx);
                    a1 = atan2(pt(2) - cy,     pt(1) - cx);
                    dA = a1 - a0;
                    R  = [cos(dA), -sin(dA); sin(dA), cos(dA)];
                    cNew = R * (c0 - [cx; cy]) + [cx; cy];

                case 'scale'
                    w  = max(snapBBox(3) - snapBBox(1), 1);
                    h  = max(snapBBox(4) - snapBBox(2), 1);
                    sx = min(max(1 + (pt(1) - snapP0(1)) / w, 0.05), 20);
                    sy = min(max(1 + (pt(2) - snapP0(2)) / h, 0.05), 20);
                    cNew = (c0 - snapCenter(:)) .* [sx; sy] + snapCenter(:);

                otherwise
                    cNew = c0;
            end
            model.RoiList(snapSel(k)).corners         = cNew;
            model.RoiList(snapSel(k)).cornersPixelDim = cNew;
        end
    end

    % ------------------------------------------------------------------
    %  Keyboard shifting (arrow keys, with modifiers)
    % ------------------------------------------------------------------
    function onKeyPress(evt)
        switch evt.Key
            case 'uparrow',    d = [0, -1];
            case 'downarrow',  d = [0,  1];
            case 'leftarrow',  d = [-1, 0];
            case 'rightarrow', d = [1,  0];
            otherwise, return;
        end
        mult = 1;
        if ismember('control', evt.Modifier), mult = 5;  end
        if ismember('shift',   evt.Modifier), mult = 10; end
        if ismember('alt',     evt.Modifier), mult = 20; end
        sel = model.RoiSelection;
        sel = sel(sel >= 1 & sel <= numel(model.RoiList));
        if isempty(sel), return; end
        for k = sel
            c = model.RoiList(k).corners + mult * d(:);
            model.RoiList(k).corners         = c;
            model.RoiList(k).cornersPixelDim = c;
        end
        model.RecomputeRoiGeometry(sel);
    end

    % ------------------------------------------------------------------
    %  ROI list operations
    % ------------------------------------------------------------------
    function onDelete()
        model.DeleteRois(model.RoiSelection);
    end

    function onCopy()
        model.CopyRois(model.RoiSelection);
    end

    function onRename()
        sel = model.RoiSelection;
        if numel(sel) ~= 1, return; end
        answer = inputdlg('ROI name:', 'Rename ROI', 1, {model.RoiList(sel).name});
        if isempty(answer) || isempty(strtrim(answer{1})), return; end
        model.RenameRoi(sel, strtrim(answer{1}));
    end

    % ------------------------------------------------------------------
    %  Settings
    % ------------------------------------------------------------------
    function onShowNames(src)
        model.RoiShowNames = logical(src.Value);
        model.TouchRois();
    end

    function onJumpChanged(src)
        jumpToRoiPos = logical(src.Value);
    end

    function onLineWidth(src)
        model.RoiLineWidth = src.Value;
        model.TouchRois();
    end

    function setClickSize(src)
        newRoiSize = round(src.Value);
    end

    % ------------------------------------------------------------------
    %  ROI export / import (.mat, original matVis format)
    % ------------------------------------------------------------------
    function onExportRois()
        if isempty(model.RoiList), return; end
        [fName, fPath] = uiputfile('*.mat', 'Export ROIs', 'matVisRois.mat');
        figure(fig);   % refocus after the modal dialog
        if isequal(fName, 0), return; end
        matVisRoiExport = model.RoiList; %#ok<NASGU> saved below
        try
            save(fullfile(fPath, fName), 'matVisRoiExport');
            assignin('base', 'matVisRoiExport', model.RoiList);
            fprintf('[matVis2] Exported %d ROI(s) to %s (and workspace variable "matVisRoiExport")\n', ...
                numel(model.RoiList), fullfile(fPath, fName));
        catch me
            uialert(fig, sprintf('Export failed: %s', me.message), 'ROI Export');
        end
    end

    function onImportRois()
        [fName, fPath] = uigetfile('*.mat', 'Import ROIs');
        figure(fig);
        if isequal(fName, 0), return; end
        try
            S = load(fullfile(fPath, fName));
        catch me
            uialert(fig, sprintf('Could not read file: %s', me.message), 'ROI Import');
            return;
        end

        rois = [];
        if isfield(S, 'matVisRoiExport')
            rois = S.matVisRoiExport;
        else
            fn = fieldnames(S);
            for k = 1:numel(fn)
                v = S.(fn{k});
                if isstruct(v) && isfield(v, 'mask') && ...
                   (isfield(v, 'corners') || isfield(v, 'cornersPixelDim'))
                    rois = v;
                    break;
                end
            end
        end
        if isempty(rois)
            uialert(fig, 'No matVis ROI data found in this file.', 'ROI Import');
            return;
        end

        append = true;
        if ~isempty(model.RoiList)
            choice = uiconfirm(fig, ...
                'Append imported ROIs to the existing list, or replace it?', ...
                'ROI Import', 'Options', {'Append', 'Replace', 'Cancel'}, ...
                'DefaultOption', 1, 'CancelOption', 3);
            if strcmp(choice, 'Cancel'), return; end
            append = strcmp(choice, 'Append');
        end

        nImp = model.ImportRois(rois, append);
        if nImp == 0
            uialert(fig, ['No ROIs could be imported (empty masks after ' ...
                'clipping to the current data size?).'], 'ROI Import');
        else
            fprintf('[matVis2] Imported %d ROI(s) from %s\n', nImp, ...
                fullfile(fPath, fName));
        end
    end

    % ------------------------------------------------------------------
    %  Trace export to workspace
    % ------------------------------------------------------------------
    function onExportData()
        dimIdx = dropExportDim.Value;
        if isempty(dimIdx) || dimIdx == 0, return; end
        if dimIdx == model.XDim || dimIdx == model.YDim
            uialert(fig, 'Cannot export along a display (XY) dimension.', ...
                'ROI Trace Export');
            return;
        end

        sel = model.RoiSelection;
        sel = sel(ismember(sel, model.VisibleRoiIndices()));
        if isempty(sel)
            sel = model.VisibleRoiIndices();
        end
        if isempty(sel)
            uialert(fig, 'No ROIs in the current XY display plane.', ...
                'ROI Trace Export');
            return;
        end

        nT     = model.Size(dimIdx);
        traces = NaN(nT, numel(sel));
        names  = cell(1, numel(sel));
        for k = 1:numel(sel)
            p = MatVisRender.renderRoiProfileFromData(model, model.Data, ...
                dimIdx, model.RoiList(sel(k)), false);
            if ~isempty(p), traces(:, k) = p; end
            names{k} = model.RoiList(sel(k)).name;
        end

        suffix  = matlab.lang.makeValidName(model.DimNames{dimIdx});
        varData = sprintf('roiData_%s', suffix);
        varName = sprintf('roiDataNames_%s', suffix);
        assignin('base', varData, traces);
        assignin('base', varName, names);
        fprintf(['[matVis2] Exported ROI traces: "%s" (%d x %d, steps x ROIs) ' ...
            'and "%s" to the base workspace\n'], varData, nT, numel(sel), varName);
    end

end % MatVisRoiWin
