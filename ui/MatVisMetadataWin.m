function mw = MatVisMetadataWin(model, cb)
% MatVisMetadataWin  Read-only acquisition-metadata viewer for matVis 2.0.
%
%   mw = MatVisMetadataWin(model, cb)
%
%   model - MatVisModel handle. Reads model.FileMetadata{ActiveDataset} (see
%           loadFiles/importMultiFile/parseOmeXml for the field list --
%           Microscope*/Objective*/AcquisitionDate/Channel*), plus
%           DimNames/DimScale/DimUnits for the physical pixel/voxel scale.
%           Tracks model.ActiveDataset (like the histogram/contrast panel),
%           so with multiple datasets this always shows the active one.
%   cb    - struct of callbacks provided by MatVisMainWindow:
%       .onHide()  notify that the window was closed (untoggles the
%                  main-window Info button)
%
%   mw.fig      - uifigure handle (created hidden)
%   mw.Refresh  - @() refresh the table from the model

if nargin < 2, cb = struct(); end
if ~isfield(cb, 'onHide'), cb.onHide = @() []; end

%% ---- Figure & layout ----------------------------------------------------
fig = uifigure('Name', 'Acquisition Metadata', 'NumberTitle', 'off', ...
    'MenuBar', 'none', 'Resize', 'off', 'Visible', 'off');
fig.Position(3:4) = [620, 420];
fig.CloseRequestFcn = @(~,~) onCloseRequest();

mainGrid = uigridlayout(fig, [2, 1]);
mainGrid.RowHeight   = {24, '1x'};
mainGrid.ColumnWidth = {'1x'};
mainGrid.Padding     = [8 8 8 8];
mainGrid.RowSpacing  = 6;

lblTitle = uilabel(mainGrid, 'Text', '', 'FontWeight', 'bold', 'FontSize', 12);
lblTitle.Layout.Row = 1;

tbl = uitable(mainGrid, 'ColumnName', {'Property', 'Value'}, ...
    'ColumnWidth', {150, '1x'}, 'RowName', {}, 'ColumnEditable', [false false], ...
    'FontSize', 11);
tbl.Layout.Row = 2;

%% ---- Model listener -------------------------------------------------------
metaListener = addlistener(model, 'ActiveDatasetChanged', @(~,~) refreshUI());
fig.DeleteFcn = @(~,~) delete(metaListener);

%% ---- Output ---------------------------------------------------------------
mw.fig     = fig;
mw.Refresh = @refreshUI;

refreshUI();

%% =========================================================================
%  Nested functions
%% =========================================================================

    function refreshUI()
        ds = model.ActiveDataset;
        lblTitle.Text = sprintf('Dataset: %s', model.DatasetNames{ds});
        tbl.Data = buildRows(model, ds);
    end

    function onCloseRequest()
        fig.Visible = 'off';
        try; cb.onHide(); catch; end
    end
end

% =============================================================================
function rows = buildRows(model, ds)
% Property/Value rows: physical pixel/voxel scale (always, from
% DimNames/DimScale/DimUnits) followed by acquisition metadata (only for
% datasets loaded from a file with OME/Bio-Formats metadata attached).
rows = cell(0, 2);

dn = model.DimNames; du = model.DimUnits; dsc = model.DimScale;
for d = 1:numel(dn)
    if numel(dsc{d}) >= 2 && ~isempty(du{d})
        step = dsc{d}(2) - dsc{d}(1);
        if strcmp(dn{d}, 'T')
            % Time step + derived frame rate, rather than the generic
            % "T scale .../px" wording, which doesn't read naturally for time.
            rows(end+1, :) = {'Time step', sprintf('%.4g %s/frame', step, du{d})}; %#ok<AGROW>
            periodSec = toSeconds(step, du{d});
            if ~isempty(periodSec) && periodSec > 0
                rows(end+1, :) = {'Frame rate', sprintf('%.4g Hz', 1 / periodSec)}; %#ok<AGROW>
            end
        else
            rows(end+1, :) = {sprintf('%s scale', dn{d}), sprintf('%.4g %s/px', step, du{d})}; %#ok<AGROW>
        end
    end
end

instr = [];
if ds <= numel(model.FileMetadata)
    instr = model.FileMetadata{ds};
end
if isempty(instr)
    rows(end+1, :) = {'Acquisition metadata', 'Not available (not loaded from an OME/Bio-Formats file)'};
    return;
end

rows(end+1, :) = {'Microscope manufacturer', naIfEmpty(instr.MicroscopeManufacturer)};
rows(end+1, :) = {'Microscope model', naIfEmpty(instr.MicroscopeModel)};
rows(end+1, :) = {'Microscope type', naIfEmpty(instr.MicroscopeType)};

rows(end+1, :) = {'Objective manufacturer', naIfEmpty(instr.ObjectiveManufacturer)};
rows(end+1, :) = {'Objective model', naIfEmpty(instr.ObjectiveModel)};
rows(end+1, :) = {'Objective magnification', naIfNan(instr.ObjectiveMagnification, '%gx')};
rows(end+1, :) = {'Objective NA', naIfNan(instr.ObjectiveNA, '%.2f')};
rows(end+1, :) = {'Objective immersion', naIfEmpty(instr.ObjectiveImmersion)};
rows(end+1, :) = {'Objective refractive index', naIfNan(instr.ObjectiveRefractiveIndex, '%.3f')};

rows(end+1, :) = {'Acquisition date', naIfEmpty(instr.AcquisitionDate)};

nCh = numel(instr.ChannelExWavelength);
for c = 1:nCh
    label = sprintf('Channel %d', c);
    if isfield(instr, 'ChannelNames') && c <= numel(instr.ChannelNames) && ~isempty(instr.ChannelNames{c})
        label = sprintf('%s (%s)', label, instr.ChannelNames{c});
    end
    chParts = {};
    if isfinite(instr.ChannelExWavelength(c))
        chParts{end+1} = sprintf('Ex %g %s', instr.ChannelExWavelength(c), unitOrDefault(instr.ChannelExWavelengthUnit{c}));
    end
    if isfinite(instr.ChannelEmWavelength(c))
        chParts{end+1} = sprintf('Em %g %s', instr.ChannelEmWavelength(c), unitOrDefault(instr.ChannelEmWavelengthUnit{c}));
    end
    if c <= numel(instr.ChannelAcquisitionMode) && ~isempty(instr.ChannelAcquisitionMode{c})
        chParts{end+1} = instr.ChannelAcquisitionMode{c};
    end
    rows(end+1, :) = {label, naIfEmpty(strjoin(chParts, ', '))}; %#ok<AGROW>
end

% Readers for formats with no acquisition metadata of their own can attach
% the raw container tags they did find (see loadZstdTiff) as extra rows.
if isfield(instr, 'TiffTags') && ~isempty(instr.TiffTags)
    rows = [rows; instr.TiffTags];
end
end

% =============================================================================
function s = naIfEmpty(s)
if isempty(s), s = 'n/a'; end
end

% =============================================================================
function s = naIfNan(v, fmt)
if isfinite(v)
    s = sprintf(fmt, v);
else
    s = 'n/a';
end
end

% =============================================================================
function s = toSeconds(value, unit)
% Convert a time-dimension step to seconds for a frame-rate computation.
% Returns [] for an unrecognized unit (e.g. 'px' when no real time
% calibration is known) rather than guessing.
switch lower(unit)
    case {'s', 'sec', 'second', 'seconds'}
        s = value;
    case {'ms', 'millisecond', 'milliseconds'}
        s = value / 1e3;
    case {'ns', 'nanosecond', 'nanoseconds'}
        s = value / 1e9;
    case {'min', 'minute', 'minutes'}
        s = value * 60;
    case {'h', 'hr', 'hour', 'hours'}
        s = value * 3600;
    otherwise
        s = [];
end
end

% =============================================================================
function u = unitOrDefault(u)
% OME-XML defaults ExcitationWavelengthUnit/EmissionWavelengthUnit to
% nanometers when the attribute is omitted.
if isempty(u), u = 'nm'; end
end
