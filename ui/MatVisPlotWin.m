function pw = MatVisPlotWin(model, posChangeFcn, zoomChangeFcn, dsIdx)
% MatVisPlotWin  Standalone plot window with interactive position/zoom controls.
%
%   pw = MatVisPlotWin(model)
%   pw = MatVisPlotWin(model, posChangeFcn, zoomChangeFcn)
%
%   posChangeFcn(dimIdx, newPos)   called while position indicator dragged
%   zoomChangeFcn(dimIdx, lo, hi)  called on mouse release after zoom-drag
%
% Mouse interactions:
%   Left-drag near indicator : move the position indicator
%   Left-drag elsewhere      : rubber-band zoom selection
%   Right-click              : reset zoom to full range
%   Double-click             : copy / export to workspace / save the plot
%
% pw.Update(profiles)         refresh profile data, x-limits, and position indicators
%                             profiles{d} is a column vector, or — for
%                             multi-trace (ROI) display — a struct with
%                             fields:
%                               .data   [nSteps × nTraces] matrix
%                               .names  1×nTraces cellstr (legend labels, optional)
%                               .colors nTraces×3 RGB (optional)
%                               .alpha  [nSteps × nTraces] mean-alpha traces
%                                       (optional) — drawn dotted on a right
%                                       y-axis, colors matching .colors
% pw.UpdatePos()              refresh x-limits and position indicators only
% pw.SetShowMarker(tf)        show/hide '.' markers on all profile lines
% pw.SetFixX(tf, limits)      lock/unlock X-axis scale; limits=[xmin xmax] (optional)
% pw.SetFixY(tf, limits)      lock/unlock Y-axis scale; limits=[ymin ymax] (optional)

if nargin < 2 || isempty(posChangeFcn),  posChangeFcn  = @(~,~)   []; end
if nargin < 3 || isempty(zoomChangeFcn), zoomChangeFcn = @(~,~,~) []; end
if nargin < 4 || isempty(dsIdx), dsIdx = model.ActiveDataset; end
if isempty(dsIdx), dsIdx = 1; end
dsTag = '';                             % disambiguate exports across datasets
if model.NumDatasets > 1, dsTag = ['_ds' num2str(dsIdx)]; end

%% ---- Input validation --------------------------------------------------
validateattributes(model.PlotDims,  {'logical','numeric'}, {'vector'},                     'MatVisPlotWin', 'model.PlotDims');
validateattributes(model.DimNames,  {'cell'},              {'vector'},                     'MatVisPlotWin', 'model.DimNames');
validateattributes(model.Size,      {'numeric'},           {'vector','integer','positive'}, 'MatVisPlotWin', 'model.Size');
validateattributes(model.ZoomRange, {'numeric'},           {'2d'},                         'MatVisPlotWin', 'model.ZoomRange');

nDims = numel(model.PlotDims);

%% ---- Tool state (driven externally via Set* methods) -------------------
showMarker = false;
fixXScale  = false;
fixXLimits = [1, max(model.Size)];
fixYScale  = false;
fixYLimits = [0, 1];   % overwritten by SetFixY before first use

%% ---- Drag interaction state --------------------------------------------
dragActive  = false;
dragMode    = '';
dragDimIdx  = 0;
dragStartX  = NaN;
dragCurrX   = NaN;
lastDragPos = NaN;

%% ---- Figure ------------------------------------------------------------
try
    figName = ['Plot: ' model.DatasetNames{model.ActiveDataset}];
catch
    figName = 'Plot Window';
end
fig = uifigure('Name', figName, 'NumberTitle', 'off', 'Resize', 'on', 'AutoResizeChildren', 'off', 'Visible', 'off');

%% ---- Grid layout -------------------------------------------------------
gridH = uigridlayout(fig, [nDims, 1]);
gridH.RowHeight   = repmat({'1x'}, 1, nDims);
gridH.ColumnWidth = {'1x'};
gridH.Padding     = [8 8 8 8];
gridH.RowSpacing  = 4;

%% ---- Axes, profile lines, position indicators, selection patches -------
axHandles   = cell(1, nDims);
lineHandles = cell(1, nDims);
extraLines  = cell(1, nDims);   % additional trace lines (multi-trace mode)
alphaLines  = cell(1, nDims);   % dotted mean-alpha traces (right y-axis)
posLines    = cell(1, nDims);
selPatches  = cell(1, nDims);
alphaColor  = [0.45 0.45 0.45]; % single-trace alpha line / right ruler color
legendOn    = false(1, nDims);  % whether a legend is currently shown per axis

for ii = 1:nDims
    ax = uiaxes(gridH);
    ax.Layout.Row    = ii;
    ax.Layout.Column = 1;

    xlabel(ax, xLabelText(ii));
    ylabel(ax, 'Value');
    ax.Title.String = model.DimNames{ii};

    if model.PlotLock(ii)
        ax.XLim = safeXLim(model.ZoomRange(ii, :));
    else
        ax.XLim = safeXLim([1, model.Size(ii)]);
    end

    ln = line(ax, NaN, NaN, 'LineWidth', 1.2, 'HitTest', 'off');

    posLn = xline(ax, model.CurrPos(ii), ...
        'Color', [0.85 0.1 0.1], 'LineWidth', 1.8, ...
        'Label', '', 'HitTest', 'off');

    yl = ax.YLim;
    sp = patch(ax, ...
        'XData', [NaN NaN NaN NaN], ...
        'YData', [yl(1) yl(1) yl(2) yl(2)], ...
        'FaceColor', [0.25 0.50 1.00], ...
        'FaceAlpha', 0.15, ...
        'EdgeColor', [0.15 0.35 0.90], 'LineWidth', 1.5, ...
        'HitTest', 'off', 'Visible', 'off');

    if model.PlotDims(ii)
        ax.Visible    = 'on';
        posLn.Visible = 'on';
    else
        ax.Visible    = 'off';
        posLn.Visible = 'off';
    end

    axHandles{ii}   = ax;
    lineHandles{ii} = ln;
    extraLines{ii}  = gobjects(1, 0);
    alphaLines{ii}  = gobjects(1, 0);
    posLines{ii}    = posLn;
    selPatches{ii}  = sp;
end

%% ---- Mouse callbacks ---------------------------------------------------
fig.WindowButtonDownFcn   = @onMouseDown;
fig.WindowButtonMotionFcn = @onMouseMove;
fig.WindowButtonUpFcn     = @onMouseUp;

%% ---- Output struct -----------------------------------------------------
pw.fig            = fig;
pw.grid           = gridH;
pw.axes           = axHandles;
pw.lineHandles    = lineHandles;
pw.Update         = @updateProfiles;
pw.UpdatePos      = @updatePositions;
pw.SetShowMarker  = @setShowMarker;
pw.SetFixX        = @setFixX;
pw.SetFixY        = @setFixY;

% =========================================================================
%   NESTED FUNCTIONS
% =========================================================================

    % -----------------------------------------------------------------
    function updateProfiles(profiles)
        if numel(profiles) ~= nDims
            error('MatVisPlotWin:profilesMismatch', ...
                'profiles length (%d) must equal nDims (%d).', numel(profiles), nDims);
        end

        visCount = 0;
        newRH    = cell(1, nDims);
        for jj = 1:nDims
            if ~isempty(profiles{jj})
                newRH{jj} = '1x';
                visCount  = visCount + 1;
            else
                newRH{jj} = 0;
            end
        end
        if visCount == 0
            newRH = repmat({'1x'}, 1, nDims);
        end
        if visCount <= 1
            newRS = 0;
        elseif visCount == 2
            newRS = 3;
        else
            newRS = 2;
        end
        % Layout writes trigger a relayout pass — only write on change
        if ~isequal(gridH.RowHeight, newRH),  gridH.RowHeight  = newRH; end
        if ~isequal(gridH.RowSpacing, newRS), gridH.RowSpacing = newRS; end

        for jj = 1:nDims
            prof = profiles{jj};
            ax   = axHandles{jj};
            ln   = lineHandles{jj};

            traceNames  = {};
            traceColors = [];
            traceAlpha  = [];
            if isstruct(prof)
                if isfield(prof, 'names'),  traceNames  = prof.names;  end
                if isfield(prof, 'colors'), traceColors = prof.colors; end
                if isfield(prof, 'alpha'),  traceAlpha  = prof.alpha;  end
                prof = prof.data;
            end

            if ~isempty(prof)
                if isvector(prof), prof = prof(:); end
                nTraces = size(prof, 2);

                if model.PlotLock(jj)
                    xData = model.ZoomRange(jj,1) : model.ZoomRange(jj,2);
                else
                    xData = 1 : model.Size(jj);
                end

                % Sync the extra-line pool to nTraces-1
                for k = numel(extraLines{jj})+1 : nTraces-1
                    extraLines{jj}(k) = line(ax, NaN, NaN, ...
                        'LineWidth', 1.2, 'HitTest', 'off');
                end
                for k = nTraces : numel(extraLines{jj})
                    if isgraphics(extraLines{jj}(k)), delete(extraLines{jj}(k)); end
                end
                extraLines{jj} = extraLines{jj}(1:max(nTraces-1, 0));

                allLines = [ln, extraLines{jj}];
                for k = 1:nTraces
                    lk = allLines(k);
                    lk.XData = xData;
                    lk.YData = prof(:, k)';
                    if showMarker
                        if ~strcmp(lk.Marker, '.')
                            lk.Marker     = '.';
                            lk.MarkerSize = 8;
                        end
                    elseif ~strcmp(lk.Marker, 'none')
                        lk.Marker = 'none';
                    end
                    if ~isempty(traceColors) && k <= size(traceColors, 1) && ...
                       ~isequal(lk.Color, traceColors(k, :))
                        lk.Color = traceColors(k, :);
                    end
                    if numel(traceNames) >= k
                        dn = traceNames{k};
                    else
                        dn = '';
                    end
                    if ~isequal(lk.DisplayName, dn), lk.DisplayName = dn; end
                    if ~strcmp(lk.Visible, 'on'),    lk.Visible = 'on';    end
                end

                % Legend only in named multi-trace (ROI) mode.  legend()
                % calls are expensive — only touch it on state changes.
                if ~isempty(traceNames)
                    lg = legend(ax, allLines(1:min(nTraces, numel(traceNames))));
                    lg.Location = 'northeast';
                    lg.Box      = 'off';
                    legendOn(jj) = true;
                else
                    if legendOn(jj)
                        legend(ax, 'off');
                        legendOn(jj) = false;
                    end
                    if ~isequal(ln.Color, [0 0 0])
                        ln.Color = [0 0 0];   % restore primitive-line default
                    end
                end

                if ~strcmp(ax.Visible, 'on'),            ax.Visible = 'on';           end
                if ~strcmp(posLines{jj}.Visible, 'on'),  posLines{jj}.Visible = 'on'; end

                % Dotted mean-alpha traces on the right y-axis
                updateAlphaTraces(jj, xData, traceAlpha, traceColors);

                % Y limits over all traces
                if ~fixYScale
                    ylo = min(prof(:));  yhi = max(prof(:));
                    if isempty(ylo) || ~isfinite(ylo),  ylo = 0;  yhi = 1;  end
                    if ylo == yhi,  ylo = ylo - 1;  yhi = yhi + 1;  end
                    pad = 0.05 * (yhi - ylo);
                    ax.YLim     = [ylo - pad, yhi + pad];
                    ax.YLimMode = 'manual';
                else
                    ax.YLim     = fixYLimits;
                    ax.YLimMode = 'manual';
                end

                syncSelPatchY(jj);
            else
                if ~strcmp(ax.Visible, 'off')
                    ax.Visible = 'off';
                    ln.Visible = 'off';
                    for k = 1:numel(extraLines{jj})
                        if isgraphics(extraLines{jj}(k)), extraLines{jj}(k).Visible = 'off'; end
                    end
                    for k = 1:numel(alphaLines{jj})
                        if isgraphics(alphaLines{jj}(k)), alphaLines{jj}(k).Visible = 'off'; end
                    end
                    posLines{jj}.Visible   = 'off';
                    selPatches{jj}.Visible = 'off';
                end
                if legendOn(jj)
                    legend(ax, 'off');
                    legendOn(jj) = false;
                end
            end
        end

        updatePositions();
    end

    % -----------------------------------------------------------------
    function updatePositions()
        for jj = 1:nDims
            if ~isvalid(axHandles{jj}), continue; end

            if ~fixXScale
                if model.PlotLock(jj)
                    xl = safeXLim(model.ZoomRange(jj, :));
                else
                    xl = safeXLim([1, model.Size(jj)]);
                end
                if ~isequal(axHandles{jj}.XLim, xl)
                    axHandles{jj}.XLim = xl;
                end
            end

            if isvalid(posLines{jj}) && posLines{jj}.Value ~= model.CurrPos(jj)
                posLines{jj}.Value = model.CurrPos(jj);
            end

            relabelXAxis(jj);
        end
    end

    % -----------------------------------------------------------------
    function relabelXAxis(jj)
        % Keep the plot's X data in index coordinates (so mouse drag/zoom
        % stay index-based) but relabel the tick marks with the real-world
        % coordinate of each index when the dimension carries a scale.
        ax = axHandles{jj};
        if ~isvalid(ax) || ~model.hasRealScale(jj), return; end
        t = ax.XTick;
        if isempty(t), return; end
        rv = model.indexToReal(jj, t);
        ax.XTickLabel = arrayfun(@(v) sprintf('%.4g', v), rv, 'UniformOutput', false);
    end

    % -----------------------------------------------------------------
    function s = xLabelText(jj)
        s = model.DimNames{jj};
        u = model.dimUnit(jj);
        if ~isempty(u)
            s = sprintf('%s [%s]', s, u);
        end
    end

    % -----------------------------------------------------------------
    function xl = safeXLim(xl)
        % XLim requires a strictly increasing 2-vector; a singleton
        % dimension (Size==1, or a ZoomRange collapsed to one sample)
        % yields lo==hi, so widen it around that value.
        if xl(2) <= xl(1)
            xl = [xl(1) - 0.5, xl(1) + 0.5];
        end
    end

    % -----------------------------------------------------------------
    function updateAlphaTraces(jj, xData, A, traceColors)
        % Draw mean-alpha traces dotted on a right y-axis (mirrors the
        % original matVis withAlpha plot style). Colors follow the data
        % traces in multi-trace (ROI) mode, neutral gray otherwise.
        ax = axHandles{jj};
        if isempty(A)
            for k = 1:numel(alphaLines{jj})
                if isgraphics(alphaLines{jj}(k)), alphaLines{jj}(k).Visible = 'off'; end
            end
            return;
        end
        if isvector(A), A = A(:); end
        nA = size(A, 2);

        yyaxis(ax, 'right');

        % Sync the alpha-line pool to nA
        for k = numel(alphaLines{jj})+1 : nA
            alphaLines{jj}(k) = line(ax, NaN, NaN, ...
                'LineStyle', ':', 'LineWidth', 1.0, 'Marker', 'none', ...
                'Color', alphaColor, 'HitTest', 'off');
        end
        for k = nA+1 : numel(alphaLines{jj})
            if isgraphics(alphaLines{jj}(k)), delete(alphaLines{jj}(k)); end
        end
        alphaLines{jj} = alphaLines{jj}(1:nA);

        for k = 1:nA
            lk = alphaLines{jj}(k);
            lk.XData = xData;
            lk.YData = A(:, k)';
            if ~isempty(traceColors) && k <= size(traceColors, 1)
                lk.Color = traceColors(k, :);
            else
                lk.Color = alphaColor;
            end
            lk.Visible = 'on';
        end

        % Right ruler styling and limits
        ax.YAxis(2).Color = alphaColor;
        ylabel(ax, 'Alpha');
        alo = min(A(:));  ahi = max(A(:));
        if isempty(alo) || ~isfinite(alo),  alo = 0;  ahi = 1;  end
        if alo == ahi,  alo = alo - 1;  ahi = ahi + 1;  end
        pad = 0.05 * (ahi - alo);
        ax.YLim = [alo - pad, ahi + pad];

        yyaxis(ax, 'left');
    end

    % -----------------------------------------------------------------
    function setShowMarker(tf)
        showMarker = logical(tf);
        for jj = 1:nDims
            lns = [lineHandles{jj}, extraLines{jj}];
            for k = 1:numel(lns)
                ln = lns(k);
                if isgraphics(ln)
                    if showMarker
                        ln.Marker     = '.';
                        ln.MarkerSize = 8;
                    else
                        ln.Marker = 'none';
                    end
                end
            end
        end
    end

    % -----------------------------------------------------------------
    function setFixX(tf, limits)
        fixXScale = logical(tf);
        if nargin >= 2 && ~isempty(limits) && numel(limits) == 2
            fixXLimits = double(limits(:)');
        end
        if fixXScale
            for jj = 1:nDims
                if isvalid(axHandles{jj})
                    axHandles{jj}.XLim = fixXLimits;
                end
            end
        else
            updatePositions();
        end
    end

    % -----------------------------------------------------------------
    function setFixY(tf, limits)
        fixYScale = logical(tf);
        if nargin >= 2 && ~isempty(limits) && numel(limits) == 2
            fixYLimits = double(limits(:)');
        end
        if fixYScale
            for jj = 1:nDims
                if isvalid(axHandles{jj})
                    axHandles{jj}.YLim     = fixYLimits;
                    axHandles{jj}.YLimMode = 'manual';
                end
            end
        else
            for jj = 1:nDims
                if isvalid(axHandles{jj})
                    axHandles{jj}.YLimMode = 'auto';
                end
            end
        end
    end

    % -----------------------------------------------------------------
    function syncSelPatchY(jj)
        sp = selPatches{jj};
        if ~isvalid(sp), return; end
        yl = axHandles{jj}.YLim;
        sp.YData = [yl(1), yl(1), yl(2), yl(2)];
    end

    % -----------------------------------------------------------------
    function updateSelPatchX(jj, x1, x2)
        sp = selPatches{jj};
        if ~isvalid(sp), return; end
        syncSelPatchY(jj);
        sp.XData   = [x1, x2, x2, x1];
        sp.Visible = 'on';
    end

    % -----------------------------------------------------------------
    function dimIdx = axUnderMouse()
        dimIdx = 0;
        try
            fcp = fig.CurrentPoint;
            for jj = 1:nDims
                ax = axHandles{jj};
                if ~isvalid(ax) || strcmp(ax.Visible, 'off'), continue; end
                pp = getpixelposition(ax, true);
                if fcp(1) >= pp(1) && fcp(1) <= pp(1)+pp(3) && ...
                   fcp(2) >= pp(2) && fcp(2) <= pp(2)+pp(4)
                    dimIdx = jj;
                    return;
                end
            end
        catch
        end
    end

    % -----------------------------------------------------------------
    function x = mouseDataX(dimIdx)
        try
            cp = axHandles{dimIdx}.CurrentPoint;
            x  = cp(1,1);
        catch
            x = NaN;
        end
    end

    % -----------------------------------------------------------------
    function near = nearPosIndicator(dimIdx, dataX)
        xl     = axHandles{dimIdx}.XLim;
        thresh = max(0.5, 0.025 * diff(xl));
        near   = abs(dataX - model.CurrPos(dimIdx)) < thresh;
    end

    % -----------------------------------------------------------------
    function s = collectPlotData(dimIdx)
        % Gather the visible traces of one plot axis into an export struct.
        lns   = [lineHandles{dimIdx}, extraLines{dimIdx}];
        x     = [];
        Y     = [];
        names = {};
        for k = 1:numel(lns)
            ln = lns(k);
            if isgraphics(ln) && strcmp(ln.Visible, 'on')
                x = ln.XData(:);
                Y = [Y, ln.YData(:)]; %#ok<AGROW>
                names{end+1} = ln.DisplayName; %#ok<AGROW>
            end
        end
        s = struct('x', x, 'y', Y, 'names', {names}, ...
                   'dimension', model.DimNames{dimIdx});
    end

    % -----------------------------------------------------------------
    function onMouseDown(~, ~)
        dimIdx = axUnderMouse();
        if dimIdx == 0, return; end

        % Double-click: offer copy / export / save of the current plot
        if strcmp(fig.SelectionType, 'open')
            dragActive  = false;  dragMode = '';  dragDimIdx = 0;
            dragStartX  = NaN;  dragCurrX = NaN;  lastDragPos = NaN;
            fig.Pointer = 'arrow';
            MatVisExportMenu(fig, axHandles{dimIdx}, ...
                {'', @() collectPlotData(dimIdx)}, ...
                ['matVisPlot' dsTag], ['matVisPlot' dsTag '.png']);
            return;
        end

        if strcmp(fig.SelectionType, 'alt')
            zoomChangeFcn(dimIdx, 1, model.Size(dimIdx));
            return;
        end

        dataX = mouseDataX(dimIdx);
        if isnan(dataX), return; end

        xl    = axHandles{dimIdx}.XLim;
        dataX = max(xl(1), min(xl(2), dataX));

        % Middle click: jump to clicked position and start dragging it
        if strcmp(fig.SelectionType, 'extend')
            newPos = max(1, min(model.Size(dimIdx), round(dataX)));
            dragActive  = true;
            dragDimIdx  = dimIdx;
            dragStartX  = dataX;
            dragCurrX   = dataX;
            lastDragPos = newPos;
            dragMode    = 'position';
            posChangeFcn(dimIdx, newPos);
            fig.Pointer = 'left';
            return;
        end

        dragActive  = true;
        dragDimIdx  = dimIdx;
        dragStartX  = dataX;
        dragCurrX   = dataX;
        lastDragPos = NaN;

        if nearPosIndicator(dimIdx, dataX)
            dragMode = 'position';
        else
            dragMode = 'zoom';
        end
    end

    % -----------------------------------------------------------------
    function onMouseMove(~, ~)
        if dragActive
            dataX = mouseDataX(dragDimIdx);
            if isnan(dataX), return; end
            xl    = axHandles{dragDimIdx}.XLim;
            dataX = max(xl(1), min(xl(2), dataX));
            dragCurrX = dataX;

            if strcmp(dragMode, 'position')
                newPos = max(1, min(model.Size(dragDimIdx), round(dataX)));
                if newPos ~= lastDragPos
                    lastDragPos = newPos;
                    posChangeFcn(dragDimIdx, newPos);
                end
                fig.Pointer = 'left';
            else
                x1 = min(dragStartX, dataX);
                x2 = max(dragStartX, dataX);
                updateSelPatchX(dragDimIdx, x1, x2);
                fig.Pointer = 'crosshair';
            end

        else
            dimIdx = axUnderMouse();
            if dimIdx == 0
                fig.Pointer = 'arrow';
                return;
            end
            dataX = mouseDataX(dimIdx);
            if isnan(dataX)
                fig.Pointer = 'arrow';
                return;
            end
            if nearPosIndicator(dimIdx, dataX)
                fig.Pointer = 'left';
            else
                fig.Pointer = 'arrow';
            end
        end
    end

    % -----------------------------------------------------------------
    function onMouseUp(~, ~)
        if ~dragActive, return; end

        dataX = mouseDataX(dragDimIdx);
        if isnan(dataX), dataX = dragCurrX; end

        if strcmp(dragMode, 'position')
            newPos = max(1, min(model.Size(dragDimIdx), round(dataX)));
            if newPos ~= lastDragPos
                posChangeFcn(dragDimIdx, newPos);
            end
        else
            x1 = min(dragStartX, dataX);
            x2 = max(dragStartX, dataX);
            if x2 - x1 >= 1
                zoomChangeFcn(dragDimIdx, x1, x2);
            end
            if isvalid(selPatches{dragDimIdx})
                selPatches{dragDimIdx}.Visible = 'off';
            end
        end

        dragActive  = false;
        dragMode    = '';
        dragDimIdx  = 0;
        dragStartX  = NaN;
        dragCurrX   = NaN;
        lastDragPos = NaN;
        fig.Pointer = 'arrow';
    end

end % MatVisPlotWin
