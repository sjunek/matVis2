function zw = MatVisZoomWin(model, zoomFromMouseFcn, positionFromMouseFcn)
% MatVisZoomWin  Zoomed-crop display + position cross-hair.
%
%   zw = MatVisZoomWin(model, zoomFromMouseFcn, positionFromMouseFcn)
%
%   zw.Update(rgbImg, posXLocal, posYLocal)
%       rgbImg     : H×W×3 uint8 cropped image
%       posXLocal  : CurrPos(XDim) - ZoomRange(XDim,1) + 1  (column)
%       posYLocal  : CurrPos(YDim) - ZoomRange(YDim,1) + 1  (row)
%
%   zw.SetOverlayVisible(tf)
%
% Mouse interactions:
%   Left-drag on posLineV : move vertical position line (changes X position)
%   Left-drag on posLineH : move horizontal position line (changes Y position)
%   Left-drag on crossing : move both position lines (2-D position update)
%   Left-drag elsewhere   : rubber-band zoom selection (sub-zoom)
%   Middle-click          : jump both positions to clicked location
%   Right-click           : reset zoom to full range
%   Scroll wheel          : zoom in/out centred on cursor

if nargin < 2, zoomFromMouseFcn     = []; end
if nargin < 3, positionFromMouseFcn = []; end

fig = uifigure('Name', ['Zoom: ' model.DatasetNames{model.ActiveDataset}], 'NumberTitle', 'off', ...
               'Resize', 'on', 'AutoResizeChildren', 'off', 'Visible', 'off');

ax = uiaxes('Parent', fig, 'Units', 'normalized', 'Position', [0 0 1 1]);
disableDefaultInteractivity(ax);
axis(ax, 'image');
ax.XTick = []; ax.YTick = [];
ax.XColor = 'none'; ax.YColor = 'none';
ax.Color  = [0 0 0];

imgHandle = image(ax, zeros(1, 1, 3, 'uint8'));
imgHandle.Visible       = 'off';
imgHandle.HitTest       = 'off';
imgHandle.PickableParts = 'none';

% White position cross-hair
posLineV = line(ax, [NaN NaN], [0.5 1.5], 'Color', 'w', 'LineWidth', 0.8);
posLineH = line(ax, [0.5 1.5], [NaN NaN], 'Color', 'w', 'LineWidth', 0.8);
posLineV.HitTest      = 'off'; posLineV.PickableParts = 'none';
posLineH.HitTest      = 'off'; posLineH.PickableParts = 'none';

% Yellow dashed selection rect
selRect = rectangle(ax, 'Position', [1 1 1 1], ...
    'EdgeColor', [1 1 0], 'LineStyle', '--', 'LineWidth', 1.2, ...
    'FaceColor', 'none', 'Visible', 'off');
selRect.HitTest      = 'off';
selRect.PickableParts = 'none';

% ROI overlay (outlines + name labels) and temp drawing shape
roiLines    = gobjects(1, 0);
roiTexts    = gobjects(1, 0);
tempRoiLine = line(ax, NaN, NaN, 'Color', [1 1 0], 'LineWidth', 1.2, ...
    'LineStyle', '--', 'Visible', 'off');
tempRoiLine.HitTest = 'off';  tempRoiLine.PickableParts = 'none';

% State variables
dragStart  = [];   % [x y] in local (zoomed) data coords
dragMode   = [];   % [] = none; string = 'posV','posH','pos2D','sel'
currPosXL  = NaN;  % current X position in local coords
currPosYL  = NaN;  % current Y position in local coords
lastHW     = [NaN, NaN];  % last image size (skip redundant limit writes)

% ROI interaction state (all positions kept in LOCAL coords; callbacks
% receive DATA coords)
roiMode     = '';    % '', 'rect', 'ellipse', 'poly', 'drag'
roiCb       = [];
roiDragP0   = [];
roiPolyPts  = [];
roiPolyDraw = false;

fig.WindowButtonDownFcn   = @onMouseDown;
fig.WindowButtonMotionFcn = @onMouseMove;
fig.WindowButtonUpFcn     = @onMouseUp;
fig.WindowScrollWheelFcn  = @onScrollWheel;

zw.fig               = fig;
zw.ax                = ax;
zw.imgHandle         = imgHandle;
zw.Update            = @updateImage;
zw.SetOverlayVisible = @setOverlayVisible;
zw.SetRoiMode        = @setRoiMode;

% -------------------------------------------------------------------------
    function updateImage(rgbImg, posXLocal, posYLocal)
        % Only the image CData changes every frame — limits and crosshair
        % are written only when their values actually change.
        if ~isvalid(fig), return; end
        set(imgHandle, 'CData', rgbImg);
        [H, W, ~] = size(rgbImg);
        szChanged = ~isequal(lastHW, [H, W]);
        if szChanged
            lastHW  = [H, W];
            ax.XLim = [0.5, W + 0.5];
            ax.YLim = [0.5, H + 0.5];
        end
        if strcmp(imgHandle.Visible, 'off')
            imgHandle.Visible = 'on';
        end

        % Store local position for hit-test
        posChanged = false;
        if nargin >= 3
            posChanged = ~isequal([currPosXL, currPosYL], [posXLocal, posYLocal]);
            currPosXL = posXLocal;
            currPosYL = posYLocal;
        end

        % Position cross-hair (NaN if out of bounds)
        if nargin >= 3 && (posChanged || szChanged)
            px = posXLocal;  py = posYLocal;
            if px >= 0.5 && px <= W + 0.5
                set(posLineV, 'XData', [px px], 'YData', [0.5, H + 0.5]);
            else
                set(posLineV, 'XData', [NaN NaN]);
            end
            if py >= 0.5 && py <= H + 0.5
                set(posLineH, 'XData', [0.5, W + 0.5], 'YData', [py py]);
            else
                set(posLineH, 'YData', [NaN NaN]);
            end
        end

        syncRoiOverlay();
    end

    function setOverlayVisible(tf)
        vis = onOff_(tf);
        set(posLineV, 'Visible', vis);
        set(posLineH, 'Visible', vis);
    end

    % ---- ROI overlay (corners converted to local coords) -------------------
    function syncRoiOverlay()
        visIdx = model.VisibleRoiIndices();
        n      = numel(visIdx);

        for k = numel(roiLines)+1 : n
            roiLines(k) = line(ax, NaN, NaN, 'HitTest', 'off', 'PickableParts', 'none');
            roiTexts(k) = text(ax, NaN, NaN, '', 'HitTest', 'off', ...
                'PickableParts', 'none', 'FontSize', 9, 'Clipping', 'on');
        end
        for k = n+1 : numel(roiLines)
            if isgraphics(roiLines(k)), delete(roiLines(k)); end
            if isgraphics(roiTexts(k)), delete(roiTexts(k)); end
        end
        roiLines = roiLines(1:n);
        roiTexts = roiTexts(1:n);
        if n == 0, return; end

        xd  = model.XDim;  yd = model.YDim;
        xrZ = model.ZoomRange(xd, :);
        yrZ = model.ZoomRange(yd, :);

        sel    = model.RoiSelection;
        selVis = visIdx(ismember(visIdx, sel));
        cols   = MatVisRender.roiColors(max(numel(selVis), 1));
        lw     = max(model.RoiLineWidth, 0.5);

        for k = 1:n
            idx = visIdx(k);
            c   = model.RoiList(idx).corners;
            cxL = c(1,:) - xrZ(1) + 1;
            cyL = c(2,:) - yrZ(1) + 1;
            selPos = find(selVis == idx, 1);
            if ~isempty(selPos)
                col = cols(selPos, :);  w = lw;             fw = 'bold';
            else
                col = [1 1 1];          w = max(lw/2, 0.5);  fw = 'normal';
            end
            set(roiLines(k), 'XData', cxL, 'YData', cyL, ...
                'Color', col, 'LineWidth', w, 'LineStyle', model.RoiLineStyle, ...
                'Visible', 'on');
            set(roiTexts(k), 'Position', [max(cxL) + 1, mean(cyL)], ...
                'String', model.RoiList(idx).name, 'Color', col, ...
                'FontWeight', fw, 'Visible', onOff_(model.RoiShowNames));
        end
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

    function ptsD = localPts2data(ptsL)
        % Convert a 2×N local-coordinate point array to data coords.
        xd  = model.XDim;  yd = model.YDim;
        ptsD = [ptsL(1,:) + model.ZoomRange(xd,1) - 1; ...
                ptsL(2,:) + model.ZoomRange(yd,1) - 1];
    end

    function updateTempRoi(pts)
        if isempty(pts)
            tempRoiLine.Visible = 'off';
        else
            set(tempRoiLine, 'XData', pts(1,:), 'YData', pts(2,:), 'Visible', 'on');
        end
    end

    function pts = shapeCorners(mode, p0, p1)
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
            if strcmp(roiMode, 'poly') && size(roiPolyPts, 2) >= 3
                finishPoly();
            else
                updateTempRoi([]);
                roiPolyPts = [];
                emitRoi('exit', []);
            end
            return;
        end

        if strcmp(src.SelectionType, 'open')
            if strcmp(roiMode, 'poly') && size(roiPolyPts, 2) >= 3
                finishPoly();
            end
            return;
        end

        if ~strcmp(src.SelectionType, 'normal'), return; end

        switch roiMode
            case {'rect', 'ellipse'}
                roiDragP0 = [x, y];
            case 'poly'
                roiPolyPts(:, end+1) = [x; y];
                roiPolyDraw = true;
                updateTempRoi(roiPolyPts);
            case 'drag'
                roiDragP0 = [x, y];
                pD = localPts2data([x; y]);
                emitRoi('start', pD');
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
            case 'poly'
                if roiPolyDraw
                    if isempty(roiPolyPts) || ...
                       hypot(x - roiPolyPts(1,end), y - roiPolyPts(2,end)) > 0.5
                        roiPolyPts(:, end+1) = [x; y];
                    end
                    updateTempRoi(roiPolyPts);
                elseif ~isempty(roiPolyPts)
                    updateTempRoi([roiPolyPts, [x; y]]);
                end
            case 'drag'
                if ~isempty(roiDragP0)
                    pD = localPts2data([x; y]);
                    emitRoi('move', pD');
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
                    emitRoi('shape', localPts2data(pts));
                end
            case 'poly'
                roiPolyDraw = false;
            case 'drag'
                if ~isempty(roiDragP0)
                    roiDragP0 = [];
                    pD = localPts2data([x; y]);
                    emitRoi('end', pD');
                end
        end
    end

    function finishPoly()
        pts = roiPolyPts;
        roiPolyPts  = [];
        roiPolyDraw = false;
        updateTempRoi([]);
        keep = [true, any(diff(pts, 1, 2) ~= 0, 1)];
        pts  = pts(:, keep);
        if size(pts, 2) >= 3
            pts(:, end+1) = pts(:, 1);
            emitRoi('shape', localPts2data(pts));
        end
    end

    % Return pixel-space thresholds converted to local data coords
    function [xt, yt] = getThresh()
        axPos = getpixelposition(ax);
        xt = 6 * diff(ax.XLim) / max(axPos(3), 1);
        yt = 6 * diff(ax.YLim) / max(axPos(4), 1);
    end

    % Hit-test in local coords: returns 'posV','posH','pos2D','sel'
    function mode = hitTest(x, y)
        mode = 'sel';
        [xt, yt] = getThresh();
        nearV = ~isnan(currPosXL) && abs(x - currPosXL) <= xt;
        nearH = ~isnan(currPosYL) && abs(y - currPosYL) <= yt;
        if nearV && nearH
            mode = 'pos2D';
        elseif nearV
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
            otherwise,    fig.Pointer = 'arrow';
        end
    end

    % Convert local (zoomed window) coords to data coords
    function [xd_val, yd_val] = local2data(xL, yL)
        xd  = model.XDim;  yd = model.YDim;
        xrZ = model.ZoomRange(xd, :);
        yrZ = model.ZoomRange(yd, :);
        xd_val = xrZ(1) + xL - 1;
        yd_val = yrZ(1) + yL - 1;
    end

    function onMouseDown(src, ~)
        pt = ax.CurrentPoint;
        x  = pt(1,1);  y = pt(1,2);
        xl = ax.XLim;  yl = ax.YLim;
        if x < xl(1) || x > xl(2) || y < yl(1) || y > yl(2), return; end

        % ROI mode takes over all mouse interaction
        if roiMouseDown(src, x, y), return; end

        % Middle click: jump to position and start dragging
        if strcmp(src.SelectionType, 'extend')
            if ~isempty(positionFromMouseFcn)
                xd = model.XDim;  yd_dim = model.YDim;
                [xD, yD] = local2data(x, y);
                positionFromMouseFcn(xd, clamp_(round(xD), 1, model.Size(xd)), ...
                                     yd_dim, clamp_(round(yD), 1, model.Size(yd_dim)));
            end
            dragMode  = 'pos2D';
            dragStart = [x, y];
            updateCursor('pos2D');
            return;
        end

        % Right-click: reset zoom to full range
        if strcmp(src.SelectionType, 'alt')
            if ~isempty(zoomFromMouseFcn)
                xd = model.XDim;  yd_dim = model.YDim;
                zoomFromMouseFcn(xd, [1, model.Size(xd)], yd_dim, [1, model.Size(yd_dim)]);
            end
            return;
        end

        % Left-click: determine drag mode from hit-test
        mode      = hitTest(x, y);
        dragMode  = mode;
        dragStart = [x, y];

        if strcmp(mode, 'sel')
            selRect.Position = [x, y, 0.01, 0.01];
            selRect.Visible  = 'on';
        end
        updateCursor(mode);
    end

    function [val, alphaVal] = getPixelVal(xL, yL)
        [xD, yD] = local2data(xL, yL);
        xd = model.XDim;  yd = model.YDim;
        px = clamp_(round(xD), 1, model.Size(xd));
        py = clamp_(round(yD), 1, model.Size(yd));
        idx      = num2cell(model.CurrPos);
        idx{xd}  = px;
        idx{yd}  = py;
        val = model.Data(idx{:});
        alphaVal = [];
        if model.WithAlpha
            alphaVal = model.AlphaMaps{model.ActiveDataset}(idx{:});
        end
    end

    function updateTitle(xL, yL)
        baseName = ['Zoom: ' model.DatasetNames{model.ActiveDataset}];
        if nargin == 0
            fig.Name = baseName;
        else
            [xD, yD] = local2data(xL, yL);
            xd = model.XDim;  yd = model.YDim;
            px = clamp_(round(xD), 1, model.Size(xd));
            py = clamp_(round(yD), 1, model.Size(yd));
            [val, alphaVal] = getPixelVal(xL, yL);
            if isempty(alphaVal)
                fig.Name = sprintf('%s - Values: %g / Pixel position: (%d,%d)', ...
                    baseName, val, px, py);
            else
                fig.Name = sprintf('%s - Value: %g, alphaValue: %g / Pixel position: (%d,%d)', ...
                    baseName, val, alphaVal, px, py);
            end
        end
    end

    function onMouseMove(~, ~)
        pt = ax.CurrentPoint;
        x  = pt(1,1);  y = pt(1,2);

        if roiMouseMove(x, y), return; end

        if isempty(dragMode)
            % Hover: update cursor
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
                    xd = model.XDim;  yd_dim = model.YDim;
                    [xD, ~] = local2data(x2, y2);
                    [~, yD] = local2data(currPosXL, currPosYL);
                    newX = clamp_(round(xD), 1, model.Size(xd));
                    positionFromMouseFcn(xd, newX, yd_dim, clamp_(round(yD), 1, model.Size(yd_dim)));
                end

            case 'posH'
                if ~isempty(positionFromMouseFcn)
                    xd = model.XDim;  yd_dim = model.YDim;
                    [xD, ~] = local2data(currPosXL, currPosYL);
                    [~, yD] = local2data(x2, y2);
                    newY = clamp_(round(yD), 1, model.Size(yd_dim));
                    positionFromMouseFcn(xd, clamp_(round(xD), 1, model.Size(xd)), yd_dim, newY);
                end

            case 'pos2D'
                if ~isempty(positionFromMouseFcn)
                    xd = model.XDim;  yd_dim = model.YDim;
                    [xD, yD] = local2data(x2, y2);
                    newX = clamp_(round(xD), 1, model.Size(xd));
                    newY = clamp_(round(yD), 1, model.Size(yd_dim));
                    positionFromMouseFcn(xd, newX, yd_dim, newY);
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

            xd  = model.XDim;  yd_dim = model.YDim;
            xrZ = model.ZoomRange(xd, :);
            yrZ = model.ZoomRange(yd_dim, :);

            xMinL = max(1, round(min(x1,x2)));
            xMaxL = min(diff(xrZ)+1, round(max(x1,x2)));
            yMinL = max(1, round(min(y1,y2)));
            yMaxL = min(diff(yrZ)+1, round(max(y1,y2)));

            xMinD = xrZ(1) + xMinL - 1;
            xMaxD = xrZ(1) + xMaxL - 1;
            yMinD = yrZ(1) + yMinL - 1;
            yMaxD = yrZ(1) + yMaxL - 1;

            if xMaxD > xMinD && yMaxD > yMinD
                zoomFromMouseFcn(xd, [xMinD, xMaxD], yd_dim, [yMinD, yMaxD]);
            end
        end

        dragMode  = [];
        dragStart = [];
        fig.Pointer = 'arrow';
    end

    function onScrollWheel(~, evt)
        factor = 1.25 ^ evt.VerticalScrollCount;
        pt     = ax.CurrentPoint;
        cx_L   = clamp_(pt(1,1), ax.XLim(1), ax.XLim(2));
        cy_L   = clamp_(pt(1,2), ax.YLim(1), ax.YLim(2));

        xd  = model.XDim;  yd_dim = model.YDim;
        xrZ = model.ZoomRange(xd, :);
        yrZ = model.ZoomRange(yd_dim, :);

        % Convert local coords to data coords
        cx_D = xrZ(1) + cx_L - 1;
        cy_D = yrZ(1) + cy_L - 1;

        xHalf = diff(xrZ) / 2 * factor;
        yHalf = diff(yrZ) / 2 * factor;

        xMin = max(1, round(cx_D - xHalf));
        xMax = min(model.Size(xd), round(cx_D + xHalf));
        yMin = max(1, round(cy_D - yHalf));
        yMax = min(model.Size(yd_dim), round(cy_D + yHalf));
        if xMax > xMin && yMax > yMin && ~isempty(zoomFromMouseFcn)
            zoomFromMouseFcn(xd, [xMin, xMax], yd_dim, [yMin, yMax]);
        end
    end

end % MatVisZoomWin

function v = clamp_(x, lo, hi)
    v = max(lo, min(hi, x));
end

function s = onOff_(tf)
    if tf, s = 'on'; else, s = 'off'; end
end
