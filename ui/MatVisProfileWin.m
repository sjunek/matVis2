function pm = MatVisProfileWin(model, cb)
% MatVisProfileWin  Profile Manager window for matVis 2.0.
%
%   pm = MatVisProfileWin(model, cb)
%
%   model - MatVisModel handle (owns the profile list, see model.ProfileList)
%   cb    - struct of callbacks provided by MatVisMainWindow:
%       .setRoiMode(mode, modeCb)  engage/release a mouse mode on all image
%                                  and zoom windows (shared with the ROI
%                                  manager; profiles use the 'profile' and
%                                  'drag' modes)
%       .applyPosition(pos, zoom)  jump navigation state to a profile's
%                                  stored position/zoom
%       .onHide()                  notify that the window was closed
%                                  (untoggles the main-window Prof button)
%       .onActivate()              notify that a profile tool was engaged
%                                  (lets the main window release ROI tools)
%
%   pm.fig             - uifigure handle (created hidden)
%   pm.Refresh         - @() refresh list / view from the model
%   pm.DeactivateTools - @() release any active profile tool
%
% A profile is a poly-line trace through the image.  matVis samples the
% data perpendicular to the line over a configurable width and shows both a
% straightened 2-D image of the sampled band and a 1-D projection of it
% (Mean/Sum/Max/Min across the width).
%
% Tools:
%   Draw  : click to place vertices (hold and drag for freehand), double- or
%           right-click to finish.  Right-click (empty path) exits the tool.
%   Shift : drag in any image/zoom window to move the selected profile(s).
%   Arrow keys (in this window): shift selected profile(s) by 1 px
%       (Ctrl ×5, Shift ×10, Alt ×20).

if nargin < 2, cb = struct(); end
if ~isfield(cb, 'setRoiMode'),    cb.setRoiMode    = @(varargin) []; end
if ~isfield(cb, 'applyPosition'), cb.applyPosition = @(varargin) []; end
if ~isfield(cb, 'onHide'),        cb.onHide        = @() [];        end
if ~isfield(cb, 'onActivate'),    cb.onActivate    = @() [];        end

%% ---- Local state --------------------------------------------------------
activeTool = '';     % '', 'draw', 'shift'
jumpToPos  = false;  % jump navigation to profile's stored position on select
snapPts    = {};     % vertex snapshots during a mouse shift
snapP0     = [];     % drag start point (data coords)
snapSel    = [];     % profile indices being shifted

%% ---- Figure & layout ----------------------------------------------------
fig = uifigure('Name', 'Profile Manager', 'NumberTitle', 'off', ...
    'MenuBar', 'none', 'Resize', 'off', 'Visible', 'off');
fig.Position(3:4) = [400, 620];
fig.CloseRequestFcn = @(~,~) onCloseRequest();
fig.KeyPressFcn     = @(~,evt) onKeyPress(evt);

mainGrid = uigridlayout(fig, [4, 1]);
mainGrid.RowHeight  = {'1x', 56, 84, 300};
mainGrid.ColumnWidth = {'1x'};
mainGrid.Padding    = [8 8 8 8];
mainGrid.RowSpacing = 6;

%% ---- Row 1: profile list + action buttons -------------------------------
listGrid = uigridlayout(mainGrid, [1, 2]);
listGrid.Layout.Row    = 1;
listGrid.ColumnWidth   = {'1x', 96};
listGrid.RowHeight     = {'1x'};
listGrid.Padding       = [0 0 0 0];
listGrid.ColumnSpacing = 6;

lst = uilistbox(listGrid, ...
    'Items', {}, 'ItemsData', [], 'Multiselect', 'on', ...
    'FontSize', 11, ...
    'Tooltip', 'Profile list. Ctrl/Shift-click for multiple selection.', ...
    'ValueChangedFcn', @(src,~) onListSelection(src));
lst.Layout.Column = 1;

btnGrid = uigridlayout(listGrid, [7, 1]);
btnGrid.Layout.Column = 2;
btnGrid.RowHeight   = repmat({26}, 1, 7);
btnGrid.ColumnWidth = {'1x'};
btnGrid.Padding     = [0 0 0 0];
btnGrid.RowSpacing  = 4;

btnDelete = uibutton(btnGrid, 'Text', 'Delete', 'FontSize', 11, ...
    'Tooltip', 'Delete selected profile(s)', ...
    'ButtonPushedFcn', @(~,~) onDelete());
btnCopy = uibutton(btnGrid, 'Text', 'Copy', 'FontSize', 11, ...
    'Tooltip', 'Duplicate selected profile(s)', ...
    'ButtonPushedFcn', @(~,~) onCopy());
btnRename = uibutton(btnGrid, 'Text', 'Rename', 'FontSize', 11, ...
    'Tooltip', 'Rename the selected profile', ...
    'ButtonPushedFcn', @(~,~) onRename());
btnReplace = uibutton(btnGrid, 'state', 'Text', 'Replace', 'FontSize', 11, ...
    'Tooltip', ['When active, drawing a new line replaces the geometry of ' ...
    'the selected profile (name and list position are kept).']);
btnExport = uibutton(btnGrid, 'Text', 'Export...', 'FontSize', 11, ...
    'Tooltip', 'Save all profiles to a .mat file (matVis profile format)', ...
    'ButtonPushedFcn', @(~,~) onExportProfiles());
btnImport = uibutton(btnGrid, 'Text', 'Import...', 'FontSize', 11, ...
    'Tooltip', 'Load profiles from a .mat file (matVis profile format)', ...
    'ButtonPushedFcn', @(~,~) onImportProfiles());
btnShowNames = uibutton(btnGrid, 'state', 'Text', 'Names', 'FontSize', 11, ...
    'Value', model.ProfileShowNames, ...
    'Tooltip', 'Show/hide profile name labels in image and zoom windows', ...
    'ValueChangedFcn', @(src,~) onShowNames(src));

%% ---- Row 2: drawing / transform tools -----------------------------------
toolPanel = uipanel(mainGrid, 'Title', 'Tools', 'FontSize', 11, ...
    'BorderType', 'line');
toolPanel.Layout.Row = 2;

toolGrid = uigridlayout(toolPanel, [1, 3]);
toolGrid.ColumnWidth   = {'1x', '1x', '1x'};
toolGrid.RowHeight     = {'1x'};
toolGrid.Padding       = [4 4 4 4];
toolGrid.ColumnSpacing = 3;

toolDefs = { ...
    'draw',  'Draw',  'Draw a profile line: click for vertices, hold for freehand, double/right-click to finish.'; ...
    'shift', 'Shift', 'Drag in an image/zoom window to move the selected profile(s). Arrow keys work here too.'; ...
    'dir',   'Arrow', 'Show/hide the direction arrow at the end of each profile.'};
toolButtons = struct();
for t = 1:size(toolDefs, 1)
    key = toolDefs{t, 1};
    b = uibutton(toolGrid, 'state', 'Text', toolDefs{t, 2}, 'FontSize', 11, ...
        'Tooltip', toolDefs{t, 3});
    b.Layout.Column = t;
    toolButtons.(key) = b;
end
toolButtons.draw.ValueChangedFcn  = @(src,~) onToolToggled('draw', src);
toolButtons.shift.ValueChangedFcn = @(src,~) onToolToggled('shift', src);
toolButtons.dir.Value             = model.ProfileShowDir;
toolButtons.dir.ValueChangedFcn   = @(src,~) onShowDir(src);

%% ---- Row 3: settings + data export --------------------------------------
setPanel = uipanel(mainGrid, 'Title', 'Settings / data export', ...
    'FontSize', 11, 'BorderType', 'line');
setPanel.Layout.Row = 3;

setGrid = uigridlayout(setPanel, [2, 4]);
setGrid.RowHeight     = {24, 24};
setGrid.ColumnWidth   = {'1x', 64, '1x', 64};
setGrid.Padding       = [4 4 4 4];
setGrid.RowSpacing    = 4;
setGrid.ColumnSpacing = 4;

cbJump = uicheckbox(setGrid, 'Text', 'Jump to position', 'FontSize', 10, ...
    'Tooltip', ['When a single profile is selected, jump position and zoom ' ...
    'to the state stored when the profile was created.'], ...
    'ValueChangedFcn', @(src,~) onJumpChanged(src));
cbJump.Layout.Row = 1;  cbJump.Layout.Column = [1, 2];

lblProj = uilabel(setGrid, 'Text', 'Projection:', 'FontSize', 10, ...
    'HorizontalAlignment', 'right');
lblProj.Layout.Row = 1;  lblProj.Layout.Column = 3;
dropProj = uidropdown(setGrid, 'Items', {'Mean', 'Sum', 'Max', 'Min'}, ...
    'Value', model.ProfileProjection, 'FontSize', 10, ...
    'Tooltip', 'How the sampled width is reduced to the 1-D profile', ...
    'ValueChangedFcn', @(src,~) onProjection(src));
dropProj.Layout.Row = 1;  dropProj.Layout.Column = 4;

lblW = uilabel(setGrid, 'Text', 'Width (px):', 'FontSize', 10, ...
    'HorizontalAlignment', 'right');
lblW.Layout.Row = 2;  lblW.Layout.Column = 1;
edtWidth = uieditfield(setGrid, 'numeric', 'Value', model.ProfileWidth, ...
    'Limits', [1, 1000], 'RoundFractionalValues', true, 'FontSize', 10, ...
    'Tooltip', 'Perpendicular sampling width of the profile band', ...
    'ValueChangedFcn', @(src,~) onWidth(src));
edtWidth.Layout.Row = 2;  edtWidth.Layout.Column = 2;

dropExportDim = uidropdown(setGrid, 'Items', {''}, 'ItemsData', 0, ...
    'FontSize', 10, 'Tooltip', 'Dimension along which profile data is exported');
dropExportDim.Layout.Row = 2;  dropExportDim.Layout.Column = 3;

btnExportData = uibutton(setGrid, 'Text', 'Exp. data', 'FontSize', 10, ...
    'Tooltip', ['Export the projected profile of the selected profile(s) ' ...
    'along the chosen dimension to the base workspace.'], ...
    'ButtonPushedFcn', @(~,~) onExportData());
btnExportData.Layout.Row = 2;  btnExportData.Layout.Column = 4;

%% ---- Row 4: profile view (1-D plot + straightened image) -----------------
viewPanel = uipanel(mainGrid, 'Title', 'Profile view', 'FontSize', 11, ...
    'BorderType', 'line');
viewPanel.Layout.Row = 4;

viewGrid = uigridlayout(viewPanel, [3, 1]);
viewGrid.RowHeight  = {18, '2x', '1x'};
viewGrid.ColumnWidth = {'1x'};
viewGrid.Padding    = [4 4 4 4];
viewGrid.RowSpacing = 4;

lblLen = uilabel(viewGrid, 'Text', 'Length: --', 'FontSize', 10);
lblLen.Layout.Row = 1;

profAx = uiaxes(viewGrid);
profAx.Layout.Row = 2;
disableDefaultInteractivity(profAx);
try; profAx.Toolbar = []; catch; end   % remove toolbar + R2026a chevron
profAx.FontSize = 8;
title(profAx, 'Profile', 'FontSize', 9);

imgAx = uiaxes(viewGrid);
imgAx.Layout.Row = 3;
disableDefaultInteractivity(imgAx);
try; imgAx.Toolbar = []; catch; end   % remove toolbar + R2026a chevron
imgAx.FontSize = 8;
title(imgAx, 'Straightened band', 'FontSize', 9);

%% ---- Model listener -------------------------------------------------------
profListener = addlistener(model, 'ProfileChanged', @(~,~) refreshUI());
fig.DeleteFcn = @(~,~) onFigureDeleted();

%% ---- Output ---------------------------------------------------------------
pm.fig             = fig;
pm.Refresh         = @refreshUI;
pm.DeactivateTools = @deactivateTool;

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
        if ~isempty(profListener) && isvalid(profListener)
            delete(profListener);
        end
    end

    % ------------------------------------------------------------------
    %  Refresh listbox, buttons, view
    % ------------------------------------------------------------------
    function refreshUI()
        if ~isvalid(fig)
            onFigureDeleted();
            return;
        end

        n = numel(model.ProfileList);
        items = cell(1, n);
        for k = 1:n
            items{k} = sprintf('%03d: %s', k, model.ProfileList(k).name);
        end
        lst.Items     = items;
        lst.ItemsData = 1:n;
        sel = model.ProfileSelection;
        sel = sel(sel >= 1 & sel <= n);
        if isempty(sel)
            lst.Value = {};
        else
            lst.Value = sel;
        end

        hasProf = n > 0;
        nSel    = numel(sel);
        btnDelete.Enable  = hasProf && nSel >= 1;
        btnCopy.Enable    = hasProf && nSel >= 1;
        btnRename.Enable  = nSel == 1;
        btnReplace.Enable = nSel == 1;
        btnExport.Enable  = hasProf;
        toolButtons.shift.Enable = nSel >= 1;

        refreshExportDims();
        refreshProfileView();
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
            btnExportData.Enable = numel(model.ProfileList) > 0;
        end
    end

    function refreshProfileView()
        cla(profAx);  cla(imgAx);
        title(profAx, 'Profile', 'FontSize', 9);
        title(imgAx, 'Straightened band', 'FontSize', 9);
        sel    = model.ProfileSelection;
        visSel = sel(ismember(sel, model.VisibleProfileIndices()));
        if isempty(visSel)
            if isempty(sel)
                lblLen.Text = 'Length: --';
            else
                lblLen.Text = 'Selected profile(s) belong to a different plane.';
            end
            return;
        end

        cols = MatVisRender.roiColors(numel(visSel));
        maxLen = 0;
        hold(profAx, 'on');
        for j = 1:numel(visSel)
            idx = visSel(j);
            img = MatVisRender.sampleProfileImage(model, model.Data, ...
                model.ProfileList(idx));
            p = MatVisRender.profileProject(img, model.ProfileProjection);
            if isempty(p), continue; end
            plot(profAx, 1:numel(p), p, '-', 'Color', cols(j,:), 'LineWidth', 1);
            maxLen = max(maxLen, numel(p));
        end
        hold(profAx, 'off');
        if maxLen > 1, profAx.XLim = [1, maxLen]; end
        xlabel(profAx, 'Position along profile (px)', 'FontSize', 8);

        % Straightened band of the primary (last) selected profile
        primary = visSel(end);
        img = MatVisRender.sampleProfileImage(model, model.Data, ...
            model.ProfileList(primary));
        if ~isempty(img)
            imagesc(imgAx, img);
            colormap(imgAx, gray(256));
            imgAx.YDir = 'reverse';
            axis(imgAx, 'tight');
            ylabel(imgAx, 'Width', 'FontSize', 8);
        end
        lblLen.Text = sprintf('Length: %.1f px (%s)', ...
            model.ProfileList(primary).length, model.ProfileList(primary).name);
    end

    % ------------------------------------------------------------------
    %  Listbox selection
    % ------------------------------------------------------------------
    function onListSelection(src)
        sel = src.Value;
        if iscell(sel), sel = []; end
        model.SetProfileSelection(sel);
        if jumpToPos && numel(sel) == 1
            s = model.ProfileList(sel).settings;
            try; cb.applyPosition(s.position, s.zoomVal); catch; end
        end
    end

    % ------------------------------------------------------------------
    %  Tool activation / mouse mode routing
    % ------------------------------------------------------------------
    function onToolToggled(toolName, src)
        if src.Value
            % Deactivate the other (non-toggle) tool button
            keys = {'draw', 'shift'};
            for k = 1:numel(keys)
                if ~strcmp(keys{k}, toolName)
                    toolButtons.(keys{k}).Value = false;
                end
            end

            if strcmp(toolName, 'shift') && isempty(model.ProfileSelection)
                src.Value = false;
                uialert(fig, 'Select at least one profile first.', 'Profile Manager');
                return;
            end

            try; cb.onActivate(); catch; end   % release ROI tools
            activeTool = toolName;
            if strcmp(toolName, 'shift')
                cb.setRoiMode('drag', @onDragEvent);
            else
                cb.setRoiMode('profile', @onShapeEvent);
            end
        else
            deactivateTool();
        end
    end

    function deactivateTool()
        activeTool = '';
        if isfield(toolButtons, 'draw'),  toolButtons.draw.Value  = false; end
        if isfield(toolButtons, 'shift'), toolButtons.shift.Value = false; end
        cb.setRoiMode('', []);
    end

    % ------------------------------------------------------------------
    %  New-line events from image/zoom windows
    % ------------------------------------------------------------------
    function onShapeEvent(phase, pts)
        switch phase
            case 'shape'
                sel = model.ProfileSelection;
                if btnReplace.Value && numel(sel) == 1
                    model.ReplaceProfileGeometry(sel, pts);
                else
                    model.AddProfile(pts);
                end
            case 'exit'
                deactivateTool();
        end
    end

    % ------------------------------------------------------------------
    %  Shift via mouse drag
    % ------------------------------------------------------------------
    function onDragEvent(phase, pt)
        switch phase
            case 'start'
                snapSel = model.ProfileSelection;
                snapSel = snapSel(snapSel >= 1 & snapSel <= numel(model.ProfileList));
                if isempty(snapSel), return; end
                snapPts = cell(1, numel(snapSel));
                for k = 1:numel(snapSel)
                    snapPts{k} = struct( ...
                        'points',   model.ProfileList(snapSel(k)).points, ...
                        'smoothed', model.ProfileList(snapSel(k)).smoothedPoints);
                end
                snapP0 = pt;

            case 'move'
                if isempty(snapSel), return; end
                applyShift(pt);
                model.TouchProfiles();

            case 'end'
                if isempty(snapSel), return; end
                applyShift(pt);
                model.RecomputeProfile(snapSel);
                snapSel = [];

            case 'exit'
                snapSel = [];
                deactivateTool();
        end
    end

    function applyShift(pt)
        d = round(pt - snapP0);
        for k = 1:numel(snapSel)
            model.ProfileList(snapSel(k)).points = ...
                snapPts{k}.points   + d(:);
            model.ProfileList(snapSel(k)).smoothedPoints = ...
                snapPts{k}.smoothed + d(:);
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
        sel = model.ProfileSelection;
        sel = sel(sel >= 1 & sel <= numel(model.ProfileList));
        if isempty(sel), return; end
        for k = sel
            model.ProfileList(k).points         = model.ProfileList(k).points         + mult * d(:);
            model.ProfileList(k).smoothedPoints = model.ProfileList(k).smoothedPoints + mult * d(:);
        end
        model.RecomputeProfile(sel);
    end

    % ------------------------------------------------------------------
    %  Profile list operations
    % ------------------------------------------------------------------
    function onDelete()
        model.DeleteProfiles(model.ProfileSelection);
    end

    function onCopy()
        model.CopyProfiles(model.ProfileSelection);
    end

    function onRename()
        sel = model.ProfileSelection;
        if numel(sel) ~= 1, return; end
        answer = inputdlg('Profile name:', 'Rename Profile', 1, ...
            {model.ProfileList(sel).name});
        if isempty(answer) || isempty(strtrim(answer{1})), return; end
        model.RenameProfile(sel, strtrim(answer{1}));
    end

    % ------------------------------------------------------------------
    %  Settings
    % ------------------------------------------------------------------
    function onShowNames(src)
        model.ProfileShowNames = logical(src.Value);
        model.TouchProfiles();
    end

    function onShowDir(src)
        model.ProfileShowDir = logical(src.Value);
        model.TouchProfiles();
    end

    function onJumpChanged(src)
        jumpToPos = logical(src.Value);
    end

    function onWidth(src)
        model.SetProfileWidth(src.Value);
        src.Value = model.ProfileWidth;
    end

    function onProjection(src)
        model.SetProfileProjection(src.Value);
    end

    % ------------------------------------------------------------------
    %  Profile export / import (.mat, original matVis format)
    % ------------------------------------------------------------------
    function onExportProfiles()
        if isempty(model.ProfileList), return; end
        [fName, fPath] = uiputfile('*.mat', 'Export Profiles', 'matVisProfiles.mat');
        figure(fig);
        if isequal(fName, 0), return; end
        matVisProfileExport = model.ProfileList; %#ok<NASGU> saved below
        try
            save(fullfile(fPath, fName), 'matVisProfileExport');
            assignin('base', 'matVisProfileExport', model.ProfileList);
            fprintf(['[matVis2] Exported %d profile(s) to %s (and workspace ' ...
                'variable "matVisProfileExport")\n'], numel(model.ProfileList), ...
                fullfile(fPath, fName));
        catch me
            uialert(fig, sprintf('Export failed: %s', me.message), 'Profile Export');
        end
    end

    function onImportProfiles()
        [fName, fPath] = uigetfile('*.mat', 'Import Profiles');
        figure(fig);
        if isequal(fName, 0), return; end
        try
            S = load(fullfile(fPath, fName));
        catch me
            uialert(fig, sprintf('Could not read file: %s', me.message), 'Profile Import');
            return;
        end

        profs = [];
        if isfield(S, 'matVisProfileExport')
            profs = S.matVisProfileExport;
        else
            fn = fieldnames(S);
            for k = 1:numel(fn)
                v = S.(fn{k});
                if isstruct(v) && isfield(v, 'points')
                    profs = v;
                    break;
                end
            end
        end
        if isempty(profs)
            uialert(fig, 'No matVis profile data found in this file.', 'Profile Import');
            return;
        end

        append = true;
        if ~isempty(model.ProfileList)
            choice = uiconfirm(fig, ...
                'Append imported profiles to the existing list, or replace it?', ...
                'Profile Import', 'Options', {'Append', 'Replace', 'Cancel'}, ...
                'DefaultOption', 1, 'CancelOption', 3);
            if strcmp(choice, 'Cancel'), return; end
            append = strcmp(choice, 'Append');
        end

        nImp = model.ImportProfiles(profs, append);
        if nImp == 0
            uialert(fig, 'No profiles could be imported.', 'Profile Import');
        else
            fprintf('[matVis2] Imported %d profile(s) from %s\n', nImp, ...
                fullfile(fPath, fName));
        end
    end

    % ------------------------------------------------------------------
    %  Data export to workspace
    % ------------------------------------------------------------------
    function onExportData()
        dimIdx = dropExportDim.Value;
        if isempty(dimIdx) || dimIdx == 0, return; end
        if dimIdx == model.XDim || dimIdx == model.YDim
            uialert(fig, 'Cannot export along a display (XY) dimension.', ...
                'Profile Data Export');
            return;
        end

        sel = model.ProfileSelection;
        sel = sel(ismember(sel, model.VisibleProfileIndices()));
        if isempty(sel)
            sel = model.VisibleProfileIndices();
        end
        if isempty(sel)
            uialert(fig, 'No profiles in the current XY display plane.', ...
                'Profile Data Export');
            return;
        end

        suffix = matlab.lang.makeValidName(model.DimNames{dimIdx});
        for k = 1:numel(sel)
            traceMat = MatVisRender.profileTraceAlongDim(model, model.Data, ...
                dimIdx, model.ProfileList(sel(k)));
            if isempty(traceMat), continue; end
            nameSuffix = matlab.lang.makeValidName(model.ProfileList(sel(k)).name);
            varData = sprintf('profileData_%s_%s', suffix, nameSuffix);
            assignin('base', varData, traceMat);
            fprintf(['[matVis2] Exported profile data: "%s" (%d x %d, ' ...
                'length x steps) to the base workspace\n'], varData, ...
                size(traceMat, 1), size(traceMat, 2));
        end
    end

end % MatVisProfileWin
