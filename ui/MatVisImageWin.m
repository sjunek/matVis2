function iw = MatVisImageWin(model, zoomFromMouseFcn)
% MatVisImageWin  Full-image display + zoom indicator + position cross-hair.
%
%   iw = MatVisImageWin(model, zoomFromMouseFcn)
%
%   model            - MatVisModel handle
%   zoomFromMouseFcn - @(xDim,xRange,yDim,yRange)  pass [] to disable
%
%   iw.Update(rgbImg, zoomRect, posX, posY)
%       rgbImg   : H×W×3 uint8 full-slice image
%       zoomRect : [xMin yMin width height] in data-pixel coords
%       posX     : CurrPos along XDim  (vertical line at this column)
%       posY     : CurrPos along YDim  (horizontal line at this row)
%
%   iw.SetOverlayVisible(tf)  — show/hide crop rect + position lines

if nargin < 2, zoomFromMouseFcn = []; end

fig = uifigure('Name', 'Image Window', 'NumberTitle', 'off', 'MenuBar', 'none');

ax = uiaxes(fig, 'Units', 'normalized', 'Position', [0 0 1 1]);
disableDefaultInteractivity(ax);
ax.Toolbar.Visible = 'off';
axis(ax, 'image');
ax.XTick = []; ax.YTick = [];

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

dragStart = [];

% --- Mouse callbacks (figure-level for reliability in uifigure) ---
if ~isempty(zoomFromMouseFcn)
    fig.WindowButtonDownFcn   = @onMouseDown;
    fig.WindowButtonMotionFcn = @onMouseMove;
    fig.WindowButtonUpFcn     = @onMouseUp;
    fig.WindowScrollWheelFcn  = @onScrollWheel;
end

% --- Public interface ---
iw.fig               = fig;
iw.ax                = ax;
iw.imgHandle         = imgHandle;
iw.rectHandle        = rectHandle;
iw.Update            = @updateDisplay;
iw.SetOverlayVisible = @setOverlayVisible;

% -------------------------------------------------------------------------
    function updateDisplay(rgbImg, zoomRect, posX, posY)
        if ~isvalid(fig), return; end
        set(imgHandle, 'CData', rgbImg);
        [H, W, ~] = size(rgbImg);
        ax.XLim = [0.5, W + 0.5];
        ax.YLim = [0.5, H + 0.5];

        % Zoom rectangle
        if numel(zoomRect) == 4 && zoomRect(3) > 0 && zoomRect(4) > 0
            set(rectHandle, 'Position', zoomRect, 'Visible', 'on');
        else
            set(rectHandle, 'Visible', 'off');
        end

        % Position cross-hair
        if nargin >= 4
            set(posLineV, 'XData', [posX posX], 'YData', [0.5, H + 0.5]);
            set(posLineH, 'XData', [0.5, W + 0.5], 'YData', [posY posY]);
        end
    end

    function setOverlayVisible(tf)
        vis = onOff_(tf);
        set(rectHandle, 'Visible', vis);
        set(posLineV,   'Visible', vis);
        set(posLineH,   'Visible', vis);
    end

    function onMouseDown(~, ~)
        pt = ax.CurrentPoint;
        x  = pt(1,1);  y = pt(1,2);
        xl = ax.XLim;  yl = ax.YLim;
        if x >= xl(1) && x <= xl(2) && y >= yl(1) && y <= yl(2)
            dragStart        = [x, y];
            selRect.Position = [x, y, 0.01, 0.01];
            selRect.Visible  = 'on';
        end
    end

    function onMouseMove(~, ~)
        if isempty(dragStart), return; end
        pt = ax.CurrentPoint;
        x2 = clamp_(pt(1,1), ax.XLim(1), ax.XLim(2));
        y2 = clamp_(pt(1,2), ax.YLim(1), ax.YLim(2));
        x1 = dragStart(1);  y1 = dragStart(2);
        selRect.Position = [min(x1,x2), min(y1,y2), ...
                            max(abs(x2-x1), 0.01), max(abs(y2-y1), 0.01)];
    end

    function onMouseUp(~, ~)
        if isempty(dragStart), return; end
        pt        = ax.CurrentPoint;
        x2        = pt(1,1);  y2 = pt(1,2);
        x1        = dragStart(1);  y1 = dragStart(2);
        dragStart = [];
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

    function onScrollWheel(~, evt)
        % Scroll up (negative count) = zoom in, scroll down = zoom out
        factor = 1.25 ^ evt.VerticalScrollCount;  % >1 = zoom out
        pt = ax.CurrentPoint;
        cx = clamp_(pt(1,1), ax.XLim(1), ax.XLim(2));
        cy = clamp_(pt(1,2), ax.YLim(1), ax.YLim(2));

        xd  = model.XDim;  yd = model.YDim;
        xr  = model.ZoomRange(xd, :);
        yr  = model.ZoomRange(yd, :);

        xHalf = diff(xr) / 2 * factor;
        yHalf = diff(yr) / 2 * factor;

        xMin = max(1, round(cx - xHalf));
        xMax = min(model.Size(xd), round(cx + xHalf));
        yMin = max(1, round(cy - yHalf));
        yMax = min(model.Size(yd), round(cy + yHalf));
        if xMax > xMin && yMax > yMin
            zoomFromMouseFcn(xd, [xMin, xMax], yd, [yMin, yMax]);
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
