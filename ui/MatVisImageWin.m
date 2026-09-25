function iw = MatVisImageWin(model, zoomFromMouseFcn, positionFromMouseFcn, dsIdx)
% MatVisImageWin  Full-image display + zoom indicator + position cross-hair.
%
%   iw = MatVisImageWin(model, zoomFromMouseFcn, positionFromMouseFcn)
%
%   model               - MatVisModel handle
%   zoomFromMouseFcn    - @(xDim,xRange,yDim,yRange)  pass [] to disable
%   positionFromMouseFcn- @(xDim,xPos,yDim,yPos)      pass [] to disable
%
%   iw.Update(rgbImg, zoomRect, posX, posY)
%       rgbImg   : H×W×3 uint8 full-slice image
%       zoomRect : [xMin yMin width height] in data-pixel coords
%       posX     : CurrPos along XDim  (vertical line at this column)
%       posY     : CurrPos along YDim  (horizontal line at this row)
%
%   iw.SetOverlayVisible(tf)  — show/hide crop rect + position lines
%
% Mouse interactions:
%   Left-drag on image    : rubber-band zoom selection
%   Left-drag on posLineV : move vertical position line (changes X position)
%   Left-drag on posLineH : move horizontal position line (changes Y position)
%   Left-drag on crossing : move both position lines (2-D position update)
%   Left-drag on zoom rect: pan the zoom rectangle
%   Middle-click          : jump both positions to clicked location
%   Right-click           : reset zoom to full range
%   Double-click          : copy / export to workspace / save current image
%   Scroll wheel          : zoom in/out centred on cursor

if nargin < 2, zoomFromMouseFcn     = []; end
if nargin < 3, positionFromMouseFcn = []; end
if nargin < 4 || isempty(dsIdx), dsIdx = model.ActiveDataset; end
if isempty(dsIdx), dsIdx = 1; end
dsTag = '';                             % disambiguate exports across datasets
if model.NumDatasets > 1, dsTag = ['_ds' num2str(dsIdx)]; end

fig = uifigure('Name', ['Image: ' model.DatasetNames{model.ActiveDataset}], 'NumberTitle', 'off', ...
               'Resize', 'on', 'AutoResizeChildren', 'off', 'Visible', 'off');

% Axes are shown as regular MATLAB axes with rulers on the left/bottom so
% real-world (or, when no scale is supplied, pixel) coordinates are visible.
ax = uiaxes(fig, 'Units', 'normalized', 'Position', [0.12 0.11 0.85 0.85]);
disableDefaultInteractivity(ax);
try; ax.Toolbar = []; catch; end   % remove toolbar + R2026a chevron
ax.FontSize = 9;
axis(ax, 'image');
applyAspectRatio(model.AspectRatioFixed, model.AspectRatio);

% Image (disable hit-testing so clicks reach the figure callbacks)
imgHandle = image(ax, zeros(1, 1, 3, 'uint8'));
imgHandle.HitTest      = 'off';
imgHandle.PickableParts = 'none';

% Red zoom-crop indicator
[initPos, initVis] = zoomRectFromModel(model);
rectHandle = rectangle(ax, 'Position', initPos, ...
    'EdgeColor', 'r', 'LineWidth', 1.5, 'FaceColor', 'none', 'Visible', initVis);
rectHandle.HitTest      = 'off';
rectHandle.PickableParts = 'none';

% White position cross-hair lines
posLineV = line(ax, [NaN NaN], [0.5 1.5], ...
    'Color', 'w', 'LineWidth', 0.8, 'LineStyle', '-');
posLineH = line(ax, [0.5 1.5], [NaN NaN], ...
    'Color', 'w', 'LineWidth', 0.8, 'LineStyle', '-');
posLineV.HitTest      = 'off'; posLineV.PickableParts = 'none';
posLineH.HitTest      = 'off'; posLineH.PickableParts = 'none';

% Yellow dashed selection rect for drag-to-zoom
selRect = rectangle(ax, 'Position', [1 1 1 1], ...
    'EdgeColor', [1 1 0], 'LineStyle', '--', 'LineWidth', 1.2, ...
    'FaceColor', 'none', 'Visible', 'off');
selRect.HitTest      = 'off';
selRect.PickableParts = 'none';

% ROI / profile overlays are painted by MatVisRender (shared with the zoom
% window and the video composer); these are only their handle pools.
roiOverlay  = [];
profOverlay = [];
tempRoiLine = line(ax, NaN, NaN, 'Color', [1 1 0], 'LineWidth', 1.2, ...
    'LineStyle', '--', 'Visible', 'off');
tempRoiLine.HitTest = 'off';  tempRoiLine.PickableParts = 'none';

% State variables
dragStart    = [];   % [x y] in data coords where drag began
dragMode     = [];   % [] = none; string = 'posV','posH','pos2D','zoom','sel'
currPosX     = NaN;  % last known X position (data coord)
currPosY     = NaN;  % last known Y position (data coord)
currZoomRect = [];   % [x1 y1 w h] of visible zoom rect, [] when hidden
rectShown    = strcmp(initVis, 'on');  % rectHandle visibility state
lastHW       = [NaN, NaN];             % last image size (skip redundant limit writes)
lastTickSig  = [];                     % signature for axis-scale ticks (skip redundant writes)

% ROI interaction state
roiMode     = '';    % '', 'rect', 'ellipse', 'poly', 'drag'
roiCb       = [];    % @(phase, pts) — 'shape': pts = 2×N corners (data px);
                     % 'start'/'move'/'end': pts = [x y]; 'exit': pts = []
roiDragP0   = [];    % [x y] where shape/transform drag began
roiPolyPts  = [];    % 2×N accumulated polygon vertices
roiPolyDraw = false; % true while freehand-accumulating points

% --- Mouse callbacks ---
fig.WindowButtonDownFcn   = @onMouseDown;
fig.WindowButtonMotionFcn = @onMouseMove;
fig.WindowButtonUpFcn     = @onMouseUp;
fig.WindowScrollWheelFcn  = @onScrollWheel;

% --- Public interface ---
iw.fig               = fig;
iw.ax                = ax;
iw.imgHandle         = imgHandle;
iw.rectHandle        = rectHandle;
iw.Update            = @updateDisplay;
iw.SetOverlayVisible = @setOverlayVisible;
iw.SetRoiMode        = @setRoiMode;
iw.SetAspectRatio    = @applyAspectRatio;

% -------------------------------------------------------------------------
    function updateDisplay(rgbImg, zoomRect, posX, posY, ext)
        % Only the image CData changes every frame — limits, crosshair and
        % zoom rect are written only when their values actually change.
        if ~isvalid(fig), return; end
        if MatVisRender.badDisplayImage(model, 'image window', rgbImg), return; end
        set(imgHandle, 'CData', rgbImg);
        [H, W, ~] = size(rgbImg);

        % The picture may be a decimated view of the plane rather than one
        % pixel per data point (see MatVisRender.planExtent), so it is placed
        % by the data coordinates it covers and the axes keep spanning the
        % full dimension.  Everything else in this window -- ticks, ROI
        % outlines, the crosshair, the zoom rectangle -- works in those
        % coordinates and so needs no knowledge of the decimation.
        if nargin < 5 || isempty(ext)
            ext = struct('x', [1, W], 'y', [1, H], 'nx', W, 'ny', H);
        end
        set(imgHandle, 'XData', ext.x, 'YData', ext.y);

        szChanged = ~isequal(lastHW, [ext.ny, ext.nx]);
        if szChanged
            lastHW  = [ext.ny, ext.nx];
            ax.XLim = [0.5, ext.nx + 0.5];
            ax.YLim = [0.5, ext.ny + 0.5];
        end

        % Full-image rulers: data index == pixel (offset 0). Re-label only
        % when the display extent or the X/Y dimension assignment changes.
        tickSig = [ext.nx, ext.ny, model.XDim, model.YDim];
        if ~isequal(tickSig, lastTickSig)
            MatVisRender.applyAxisScale(ax, model, model.XDim, 0, model.YDim, 0);
            lastTickSig = tickSig;
        end

        % Store current position for hit-test
        posChanged = false;
        if nargin >= 4
            posChanged = ~isequal([currPosX, currPosY], [posX, posY]);
            currPosX = posX;
            currPosY = posY;
        end

        % Zoom rectangle — hide when fully zoomed out
        if numel(zoomRect) == 4 && zoomRect(3) > 0 && zoomRect(4) > 0
            xd_ = model.XDim;  yd_ = model.YDim;
            fullZoom = model.ZoomRange(xd_,1) <= 1 && ...
                       model.ZoomRange(xd_,2) >= model.Size(xd_) && ...
                       model.ZoomRange(yd_,1) <= 1 && ...
                       model.ZoomRange(yd_,2) >= model.Size(yd_);
            if fullZoom
                if rectShown, set(rectHandle, 'Visible', 'off'); rectShown = false; end
                currZoomRect = [];
            elseif ~isequal(currZoomRect, zoomRect) || ~rectShown
                set(rectHandle, 'Position', zoomRect, 'Visible', 'on');
                rectShown    = true;
                currZoomRect = zoomRect;
            end
        else
            if rectShown, set(rectHandle, 'Visible', 'off'); rectShown = false; end
            currZoomRect = [];
        end

        % Position cross-hair
        if nargin >= 4 && (posChanged || szChanged)
            set(posLineV, 'XData', [posX posX], 'YData', [0.5, ext.ny + 0.5]);
            set(posLineH, 'XData', [0.5, ext.nx + 0.5], 'YData', [posY posY]);
        end

        syncRoiOverlay();
        syncProfileOverlay();
    end

    function setOverlayVisible(tf)
        vis = onOff_(tf);
        set(rectHandle, 'Visible', vis);
        set(posLineV,   'Visible', vis);
        set(posLineH,   'Visible', vis);
        rectShown = logical(tf);
    end

    function applyAspectRatio(fixed, ratio)
        % fixed = true : square/fixed-ratio pixels (letterboxed in window)
        % fixed = false: stretch image to fill the window
        if nargin < 2 || numel(ratio) ~= 2, ratio = [1 1]; end
        if ~isvalid(ax), return; end
        if fixed
            ax.DataAspectRatio        = [ratio(1) ratio(2) 1];   % sets mode->manual
            ax.PlotBoxAspectRatioMode = 'auto';
        else
            ax.DataAspectRatioMode    = 'auto';
            ax.PlotBoxAspectRatioMode = 'auto';
        end
    end

    % ---- ROI / profile overlays (shared painter) ---------------------------
    function syncRoiOverlay()
        roiOverlay = MatVisRender.paintRoiOverlay(ax, model, ...
            MatVisRender.panelOrigin(model, false), roiOverlay);
    end

    function syncProfileOverlay()
        profOverlay = MatVisRender.paintProfileOverlay(ax, model, ...
            MatVisRender.panelOrigin(model, false), profOverlay);
    end

    % ---- ROI interaction mode ----------------------------------------------
    function setRoiMode(mode, cb)
        roiMode     = mode;
        if nargin >= 2, roiCb = cb; else, roiCb = []; end
        roiDragP0   = [];
        roiPolyPts  = [];
        roiPolyDraw = false;
        tempRoiLine.Visible = 'off';
        if isempty(roiMode)
            fig.Pointer = 'arrow';
        else
            fig.Pointer = 'crosshair';
        end
    end

    function emitRoi(phase, pts)
        if ~isempty(roiCb)
            roiCb(phase, pts);
        end
    end

    function updateTempRoi(pts)
        if isempty(pts)
            tempRoiLine.Visible = 'off';
        else
            set(tempRoiLine, 'XData', pts(1,:), 'YData', pts(2,:), 'Visible', 'on');
        end
    end

    function pts = shapeCorners(mode, p0, p1)
        % Build closed polygon corners for rect/ellipse between two points.
        x1 = round(min(p0(1), p1(1))) - 0.5;  x2 = round(max(p0(1), p1(1))) + 0.5;
        y1 = round(min(p0(2), p1(2))) - 0.5;  y2 = round(max(p0(2), p1(2))) + 0.5;
        if strcmp(mode, 'rect')
            pts = [x1 x1 x2 x2 x1; y1 y2 y2 y1 y1];
        else
            cx = (x1 + x2) / 2;  cy = (y1 + y2) / 2;
            w  = x2 - x1;        h  = y2 - y1;
            nP = max(24, ceil(w + h));
            t  = linspace(0, 2*pi, nP);
            pts = [cx + w/2 * sin(t); cy + h/2 * cos(t)];
            pts(:, end) = pts(:, 1);
        end
    end

    function handled = roiMouseDown(src, x, y)
        handled = ~isempty(roiMode);
        if ~handled, return; end

        if strcmp(src.SelectionType, 'alt')
            % Right-click: finish polygon/profile, or exit the mode
            if strcmp(roiMode, 'poly') && size(roiPolyPts, 2) >= 3
                finishPoly();
            elseif strcmp(roiMode, 'profile') && size(roiPolyPts, 2) >= 2
                finishProfile();
            else
                updateTempRoi([]);
                roiPolyPts = [];
                emitRoi('exit', []);
            end
            return;
        end

        if strcmp(src.SelectionType, 'open')
            % Double-click: finish polygon/profile
            if strcmp(roiMode, 'poly') && size(roiPolyPts, 2) >= 3
                finishPoly();
            elseif strcmp(roiMode, 'profile') && size(roiPolyPts, 2) >= 2
                finishProfile();
            end
            return;
        end

        if ~strcmp(src.SelectionType, 'normal'), return; end

        switch roiMode
            case {'rect', 'ellipse'}
                roiDragP0 = [x, y];
            case {'poly', 'profile'}
                roiPolyPts(:, end+1) = [x; y];
                roiPolyDraw = true;
                updateTempRoi(roiPolyPts);
            case 'drag'
                roiDragP0 = [x, y];
                emitRoi('start', [x, y]);
        end
    end

    function handled = roiMouseMove(x, y)
        handled = ~isempty(roiMode);
        if ~handled, return; end
        x = clamp_(x, ax.XLim(1), ax.XLim(2));
        y = clamp_(y, ax.YLim(1), ax.YLim(2));

        switch roiMode
            case {'rect', 'ellipse'}
                if ~isempty(roiDragP0)
                    updateTempRoi(shapeCorners(roiMode, roiDragP0, [x, y]));
                end
            case {'poly', 'profile'}
                if roiPolyDraw
                    % Freehand: accumulate while the button is held
                    if isempty(roiPolyPts) || ...
                       hypot(x - roiPolyPts(1,end), y - roiPolyPts(2,end)) > 0.5
                        roiPolyPts(:, end+1) = [x; y];
                    end
                    updateTempRoi(roiPolyPts);
                elseif ~isempty(roiPolyPts)
                    % Rubber-band from last vertex to cursor
                    updateTempRoi([roiPolyPts, [x; y]]);
                end
            case 'drag'
                if ~isempty(roiDragP0)
                    emitRoi('move', [x, y]);
                end
        end
    end

    function handled = roiMouseUp()
        handled = ~isempty(roiMode);
        if ~handled, return; end
        pt = ax.CurrentPoint;
        x  = clamp_(pt(1,1), ax.XLim(1), ax.XLim(2));
        y  = clamp_(pt(1,2), ax.YLim(1), ax.YLim(2));

        switch roiMode
            case {'rect', 'ellipse'}
                if ~isempty(roiDragP0)
                    pts = shapeCorners(roiMode, roiDragP0, [x, y]);
                    roiDragP0 = [];
                    updateTempRoi([]);
                    emitRoi('shape', pts);
                end
            case {'poly', 'profile'}
                roiPolyDraw = false;
            case 'drag'
                if ~isempty(roiDragP0)
                    roiDragP0 = [];
                    emitRoi('end', [x, y]);
                end
        end
    end

    function finishPoly()
        pts = roiPolyPts;
        roiPolyPts  = [];
        roiPolyDraw = false;
        updateTempRoi([]);
        % Remove consecutive duplicates, close polygon
        keep = [true, any(diff(pts, 1, 2) ~= 0, 1)];
        pts  = pts(:, keep);
        if size(pts, 2) >= 3
            pts(:, end+1) = pts(:, 1);
            emitRoi('shape', pts);
        end
    end

    function finishProfile()
        pts = roiPolyPts;
        roiPolyPts  = [];
        roiPolyDraw = false;
        updateTempRoi([]);
        % Remove consecutive duplicates, keep open (no closing vertex)
        keep = [true, any(diff(pts, 1, 2) ~= 0, 1)];
        pts  = pts(:, keep);
        if size(pts, 2) >= 2
            emitRoi('shape', pts);
        end
    end

    % Return pixel-space thresholds converted to data coords
    function [xt, yt] = getThresh()
        axPos = getpixelposition(ax);
        xt = 6 * diff(ax.XLim) / max(axPos(3), 1);
        yt = 6 * diff(ax.YLim) / max(axPos(4), 1);
    end

    % Hit-test: what is under the cursor?
    % Returns 'posV','posH','pos2D','zoom','sel'
    % Priority: pos2D > zoom-rect interior > posV/posH > sel
    % (zoom rect takes priority over individual lines so dragging the rect
    %  works even when position lines cross through it)
    function mode = hitTest(x, y)
        mode = 'sel';
        [xt, yt] = getThresh();
        nearV = ~isnan(currPosX) && abs(x - currPosX) <= xt;
        nearH = ~isnan(currPosY) && abs(y - currPosY) <= yt;

        if nearV && nearH
            mode = 'pos2D';  % crossing point: highest priority
            return;
        end

        if ~isempty(currZoomRect)
            zr = currZoomRect;
            if x >= zr(1) && x <= zr(1)+zr(3) && y >= zr(2) && y <= zr(2)+zr(4)
                mode = 'zoom';  % inside zoom rect: second priority
                return;
            end
        end

        % Position lines outside the zoom rect
        if nearV
            mode = 'posV';
        elseif nearH
            mode = 'posH';
        end
    end

    function updateCursor(mode)
        switch mode
            case 'posV',  fig.Pointer = 'left';   % E-W drag
            case 'posH',  fig.Pointer = 'top';    % N-S drag
            case 'pos2D', fig.Pointer = 'fleur';  % four-way
            case 'zoom',  fig.Pointer = 'hand';
            otherwise,    fig.Pointer = 'arrow';
        end
    end

    function onMouseDown(src, ~)
        pt = ax.CurrentPoint;
        x  = pt(1,1);  y = pt(1,2);
        xl = ax.XLim;  yl = ax.YLim;
        if x < xl(1) || x > xl(2) || y < yl(1) || y > yl(2), return; end

        % ROI mode takes over all mouse interaction
        if roiMouseDown(src, x, y), return; end

        % Double-click: offer copy / export / save of the current image
        if strcmp(src.SelectionType, 'open')
            selRect.Visible = 'off';
            dragMode = [];  dragStart = [];  fig.Pointer = 'arrow';
            MatVisExportMenu(fig, ax, ...
                {'_raw',     @() MatVisRender.getRawFullSliceFromData(model, model.Datasets{dsIdx}); ...
                 '_display', @() imgHandle.CData}, ...
                ['matVisImage' dsTag], ['matVisImage' dsTag '.png']);
            return;
        end

        % Middle click: jump to position and start dragging
        if strcmp(src.SelectionType, 'extend')
            if ~isempty(positionFromMouseFcn)
                xd = model.XDim;  yd = model.YDim;
                positionFromMouseFcn(xd, clamp_(round(x), 1, model.Size(xd)), ...
                                     yd, clamp_(round(y), 1, model.Size(yd)));
            end
            dragMode  = 'pos2D';
            dragStart = [x, y];
            updateCursor('pos2D');
            return;
        end

        % Right-click: reset zoom to full range
        if strcmp(src.SelectionType, 'alt')
            if ~isempty(zoomFromMouseFcn)
                xd = model.XDim;  yd = model.YDim;
                zoomFromMouseFcn(xd, [1, model.Size(xd)], yd, [1, model.Size(yd)]);
            end
            return;
        end

        % Left-click: determine drag mode from hit-test
        mode     = hitTest(x, y);
        dragMode  = mode;
        dragStart = [x, y];

        if strcmp(mode, 'sel')
            selRect.Position = [x, y, 0.01, 0.01];
            selRect.Visible  = 'on';
        end
        updateCursor(mode);
    end

    function [val, alphaVal] = getPixelVal(px, py)
        xd = model.XDim;  yd = model.YDim;
        px = clamp_(round(px), 1, model.Size(xd));
        py = clamp_(round(py), 1, model.Size(yd));
        idx      = num2cell(model.CurrPos);
        idx{xd}  = px;
        idx{yd}  = py;
        val = model.Data.readSub(idx);
        alphaVal = [];
        if model.WithAlpha
            alphaVal = model.AlphaMaps{model.ActiveDataset}.readSub(idx);
        end
    end

    function updateTitle(px, py)
        baseName = ['Image: ' model.DatasetNames{model.ActiveDataset}];
        if nargin == 0
            fig.Name = baseName;
        else
            [val, alphaVal] = getPixelVal(px, py);
            posStr = posReadout(round(px), round(py));
            if isempty(alphaVal)
                fig.Name = sprintf('%s - Values: %g / Position: %s', ...
                    baseName, val, posStr);
            else
                fig.Name = sprintf('%s - Value: %g, alphaValue: %g / Position: %s', ...
                    baseName, val, alphaVal, posStr);
            end
        end
    end

    function s = posReadout(px, py)
        % Pixel position, plus the real-world coordinate when either display
        % dimension carries a scale (e.g. '(60,40) px / (120,80) µm').
        s = sprintf('(%d,%d) px', px, py);
        xd = model.XDim;  yd = model.YDim;
        if model.hasRealScale(xd) || model.hasRealScale(yd)
            rx = model.indexToReal(xd, px);
            ry = model.indexToReal(yd, py);
            ux = model.dimUnit(xd);   uy = model.dimUnit(yd);
            if strcmp(ux, uy)
                s = sprintf('%s / (%.4g,%.4g) %s', s, rx, ry, ux);
            else
                s = sprintf('%s / (%.4g %s, %.4g %s)', s, rx, ux, ry, uy);
            end
        end
    end

    function onMouseMove(~, ~)
        pt = ax.CurrentPoint;
        x  = pt(1,1);  y = pt(1,2);

        if roiMouseMove(x, y), return; end

        if isempty(dragMode)
            % Hover only: update cursor based on what's under the mouse
            xl = ax.XLim;  yl = ax.YLim;
            if x >= xl(1) && x <= xl(2) && y >= yl(1) && y <= yl(2)
                updateCursor(hitTest(x, y));
                updateTitle(x, y);
            else
                fig.Pointer = 'arrow';
                updateTitle();
            end
            return;
        end

        % Active drag
        x2 = clamp_(x, ax.XLim(1), ax.XLim(2));
        y2 = clamp_(y, ax.YLim(1), ax.YLim(2));
        updateTitle(x2, y2);

        switch dragMode
            case 'posV'
                if ~isempty(positionFromMouseFcn)
                    xd = model.XDim;  yd = model.YDim;
                    newX = clamp_(round(x2), 1, model.Size(xd));
                    positionFromMouseFcn(xd, newX, yd, round(currPosY));
                end

            case 'posH'
                if ~isempty(positionFromMouseFcn)
                    xd = model.XDim;  yd = model.YDim;
                    newY = clamp_(round(y2), 1, model.Size(yd));
                    positionFromMouseFcn(xd, round(currPosX), yd, newY);
                end

            case 'pos2D'
                if ~isempty(positionFromMouseFcn)
                    xd = model.XDim;  yd = model.YDim;
                    newX = clamp_(round(x2), 1, model.Size(xd));
                    newY = clamp_(round(y2), 1, model.Size(yd));
                    positionFromMouseFcn(xd, newX, yd, newY);
                end

            case 'zoom'
                % Pan the zoom rectangle
                if ~isempty(zoomFromMouseFcn)
                    dx = x2 - dragStart(1);
                    dy = y2 - dragStart(2);
                    dragStart = [x2, y2];  % incremental
                    xd = model.XDim;  yd = model.YDim;
                    zr = model.ZoomRange(xd, :);
                    yr = model.ZoomRange(yd, :);
                    zw = diff(zr);  zh = diff(yr);
                    xSz = model.Size(xd);  ySz = model.Size(yd);
                    newX1 = round(clamp_(zr(1) + dx, 1, max(1, xSz - zw)));
                    newY1 = round(clamp_(yr(1) + dy, 1, max(1, ySz - zh)));
                    newX2 = min(xSz, newX1 + zw);
                    newY2 = min(ySz, newY1 + zh);
                    if newX2 > newX1 && newY2 > newY1
                        % keepSize: moving the rectangle must not resize it
                        zoomFromMouseFcn(xd, [newX1, newX2], yd, [newY1, newY2], true);
                    end
                end

            case 'sel'
                x1 = dragStart(1);  y1 = dragStart(2);
                selRect.Position = [min(x1,x2), min(y1,y2), ...
                                    max(abs(x2-x1), 0.01), max(abs(y2-y1), 0.01)];
        end
    end

    function onMouseUp(~, ~)
        if roiMouseUp(), return; end
        if isempty(dragMode), return; end

        if strcmp(dragMode, 'sel') && ~isempty(zoomFromMouseFcn)
            pt = ax.CurrentPoint;
            x2 = pt(1,1);  y2 = pt(1,2);
            x1 = dragStart(1);  y1 = dragStart(2);
            selRect.Visible = 'off';
            xd   = model.XDim;  yd = model.YDim;
            xMin = max(1, round(min(x1,x2)));
            xMax = min(model.Size(xd), round(max(x1,x2)));
            yMin = max(1, round(min(y1,y2)));
            yMax = min(model.Size(yd), round(max(y1,y2)));
            if xMax > xMin && yMax > yMin
                zoomFromMouseFcn(xd, [xMin, xMax], yd, [yMin, yMax]);
            end
        end

        dragMode  = [];
        dragStart = [];
        fig.Pointer = 'arrow';
    end

    function onScrollWheel(~, evt)
        factor = 1.25 ^ evt.VerticalScrollCount;  % >1 = zoom out
        pt = ax.CurrentPoint;
        cx = clamp_(pt(1,1), ax.XLim(1), ax.XLim(2));
        cy = clamp_(pt(1,2), ax.YLim(1), ax.YLim(2));

        xd  = model.XDim;  yd = model.YDim;
        xr  = model.ZoomRange(xd, :);
        yr  = model.ZoomRange(yd, :);

        % The image axes shows the whole plane, so the cursor is already in
        % data coordinates.
        [xrNew, yrNew] = MatVisRender.zoomStepAtCursor(xr, yr, ...
            model.Size(xd), model.Size(yd), factor, cx, cy);
        if ~isempty(zoomFromMouseFcn) && ...
                (~isequal(xrNew, xr) || ~isequal(yrNew, yr))
            zoomFromMouseFcn(xd, xrNew, yd, yrNew);
        end
    end

end % MatVisImageWin

% ---- Module helpers -------------------------------------------------------
function [pos, vis] = zoomRectFromModel(model)
    try
        xr = model.ZoomRange(model.XDim, :);
        yr = model.ZoomRange(model.YDim, :);
        w  = diff(xr);  h = diff(yr);
        if w > 0 && h > 0
            pos = [xr(1), yr(1), w, h];  vis = 'on';
        else
            pos = [1 1 1 1];  vis = 'off';
        end
    catch
        pos = [1 1 1 1];  vis = 'off';
    end
end

function v = clamp_(x, lo, hi)
    v = max(lo, min(hi, x));
end

function s = onOff_(tf)
    if tf, s = 'on'; else, s = 'off'; end
end
