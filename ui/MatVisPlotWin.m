function pw = MatVisPlotWin(model)
% MatVisPlotWin  Standalone plot window displaying stacked 1D profile plots.
%
%   pw = MatVisPlotWin(model)
%
%   Creates a uifigure with one uiaxes per dimension, stacked vertically.
%   Only axes whose corresponding model.PlotDims entry is true are visible.
%
% Input:
%   model  - Struct or object with fields:
%              .PlotDims   (1×N logical)  which dims to show
%              .DimNames   (1×N cell)     axis labels
%              .Size       (1×N int)      data size per dim
%              .ZoomRange  (N×2 double)   zoom extents per dim
%
% Output:
%   pw          - Struct with fields:
%     .fig          uifigure handle
%     .axes         (1×N) cell array of uiaxes handles
%     .lineHandles  (1×N) cell array of line handles
%     .Update       function handle — pw.Update(profiles) refreshes all plots
%
% Usage:
%   pw.Update(profiles)
%     profiles : (1×N) cell array; profiles{i} is a 1-D numeric vector when
%                model.PlotDims(i) is true, otherwise [].

%% ---- Input validation --------------------------------------------------
validateattributes(model.PlotDims,  {'logical','numeric'}, {'vector'}, ...
    'MatVisPlotWin', 'model.PlotDims');
validateattributes(model.DimNames,  {'cell'}, {'vector'}, ...
    'MatVisPlotWin', 'model.DimNames');
validateattributes(model.Size,      {'numeric'}, {'vector','integer','positive'}, ...
    'MatVisPlotWin', 'model.Size');
validateattributes(model.ZoomRange, {'numeric'}, {'2d'}, ...
    'MatVisPlotWin', 'model.ZoomRange');

nDims = numel(model.PlotDims);

if numel(model.DimNames) ~= nDims
    error('MatVisPlotWin:dimMismatch', ...
        'model.DimNames length (%d) must match model.PlotDims length (%d).', ...
        numel(model.DimNames), nDims);
end
if numel(model.Size) ~= nDims
    error('MatVisPlotWin:dimMismatch', ...
        'model.Size length (%d) must match model.PlotDims length (%d).', ...
        numel(model.Size), nDims);
end
if size(model.ZoomRange, 1) ~= nDims
    error('MatVisPlotWin:dimMismatch', ...
        'model.ZoomRange rows (%d) must match model.PlotDims length (%d).', ...
        size(model.ZoomRange,1), nDims);
end

%% ---- Figure ------------------------------------------------------------
fig = uifigure('Name', 'Plot Window', 'NumberTitle', 'off', ...
    'AutoResizeChildren', 'off');

%% ---- Grid layout -------------------------------------------------------
% One row per dimension.
grid = uigridlayout(fig, [nDims, 1]);
grid.RowHeight   = repmat({'1x'}, 1, nDims);
grid.ColumnWidth = {'1x'};
grid.Padding     = [8 8 8 8];
grid.RowSpacing  = 4;

%% ---- Pre-create axes and line handles ----------------------------------
axHandles   = cell(1, nDims);
lineHandles = cell(1, nDims);

for ii = 1 : nDims
    ax = uiaxes(grid);
    ax.Layout.Row    = ii;
    ax.Layout.Column = 1;

    % Label axes with dimension name
    xlabel(ax, model.DimNames{ii});
    ylabel(ax, 'Value');
    ax.Title.String = model.DimNames{ii};
    ax.XLim = [model.ZoomRange(ii,1), model.ZoomRange(ii,2)];

    % Pre-create an empty line
    ln = line(ax, NaN, NaN, 'LineWidth', 1.2);

    % Show/hide based on PlotDims
    if model.PlotDims(ii)
        ax.Visible = 'on';
    else
        ax.Visible = 'off';
    end

    axHandles{ii}   = ax;
    lineHandles{ii} = ln;
end

%% ---- Assemble output struct --------------------------------------------
pw.fig         = fig;
pw.axes        = axHandles;
pw.lineHandles = lineHandles;
pw.Update      = @(profiles) updateProfiles(profiles, axHandles, lineHandles, nDims);

end % MatVisPlotWin

%% =========================================================================
function updateProfiles(profiles, axHandles, lineHandles, nDims)
% updateProfiles  Refresh line data and axis visibility.
%
%   profiles : (1×N) cell — profiles{i} is a numeric 1-D vector or [].

if numel(profiles) ~= nDims
    error('MatVisPlotWin:profilesMismatch', ...
        'profiles length (%d) must equal number of dimensions (%d).', ...
        numel(profiles), nDims);
end

for ii = 1 : nDims
    prof = profiles{ii};
    ax   = axHandles{ii};
    ln   = lineHandles{ii};

    if ~isempty(prof)
        % Update line data
        ln.YData = prof(:)';
        ln.XData = 1 : numel(prof);
        ax.Visible = 'on';
        ln.Visible = 'on';
    else
        ax.Visible = 'off';
        ln.Visible = 'off';
    end
end
end % updateProfiles
