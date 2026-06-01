function iw = MatVisImageWin(model, zoomFromMouseFcn)
% MatVisImageWin  Full-image display window with zoom-indicator overlay.
%
%   iw = MatVisImageWin(model, zoomFromMouseFcn)
%
%   model            - MatVisModel handle (XDim, YDim, ZoomRange, Size)
%   zoomFromMouseFcn - function handle @(xDim,xRange,yDim,yRange) called
%                      after user drag-selects a new zoom region.
%                      Pass [] to disable drag-to-zoom.
%
%   iw.Update(rgbImg, zoomRect)
%       rgbImg   : H×W×3 uint8 full-slice image
%       zoomRect : [xMin yMin width height] in data-pixel coords

if nargin < 2, zoomFromMouseFcn = []; end

fig = uifigure('Name', 'Image Window', 'NumberTitle', 'off', 'MenuBar', 'none');

ax = uiaxes(fig, 'Units', 'normalized', 'Position', [0 0 1 1]);
disableDefaultInteractivity(ax);
ax.Toolbar.Visible = 'off';
axis(ax, 'image');
ax.XTick = []; ax.YTick = [];

imgHandle = image(ax, zeros(1, 1, 3, 'uint8'));

[initPos, initVis] = zoomRectFromModel(model);
rectHandle = rectangle(ax, ...
    'Position',  initPos, ...
    'EdgeColor', 'r', ...
    'LineWidth',  1.5, ...
    'FaceColor', 'none', ...
    'Visible',   initVis);

% Yellow dashed selection rectangle drawn during mouse drag
selRect = rectangle(ax, ...
    'Position',  [1 1 1 1], ...
    'EdgeColor', [1 1 0], ...
    'LineStyle', '--', ...
    'LineWidth',  1.2, ...
    'FaceColor', 'none', ...
    'Visible',   'off');

dragStart = [];

if ~isempty(zoomFromMouseFcn)
    ax.ButtonDownFcn          = @onMouseDown;
    fig.WindowButtonMotionFcn = @onMouseMove;
    fig.WindowButtonUpFcn     = @onMouseUp;
end

iw.fig        = fig;
iw.ax         = ax;
iw.imgHandle  = imgHandle;
iw.rectHandle = rectHandle;
iw.Update     = @(rgbImg, zoomRect) updateDisplay(rgbImg, zoomRect);

% -------------------------------------------------------------------------
    function updateDisplay(rgbImg, zoomRect)
        if ~isvalid(fig), return; end
        set(imgHandle, 'CData', rgbImg);
        [H, W, ~] = size(rgbImg);
        ax.XLim = [0.5, W + 0.5];
        ax.YLim = [0.5, H + 0.5];
        if numel(zoomRect) == 4 && zoomRect(3) > 0 && zoomRect(4) > 0
            set(rectHandle, 'Position', zoomRect, 'Visible', 'on');
        else
            set(rectHandle, 'Visible', 'off');
        end
    end

    function onMouseDown(~, ~)
        pt = ax.CurrentPoint;
        x  = pt(1,1);  y = pt(1,2);
        xl = ax.XLim;  yl = ax.YLim;
        if x >= xl(1) && x <= xl(2) && y >= yl(1) && y <= yl(2)
            dragStart = [x, y];
            selRect.Position = [x, y, 0.01, 0.01];
            selRect.Visible  = 'on';
        end
    end

    function onMouseMove(~, ~)
        if isempty(dragStart), return; end
        pt = ax.CurrentPoint;
        x2 = max(ax.XLim(1), min(ax.XLim(2), pt(1,1)));
        y2 = max(ax.YLim(1), min(ax.YLim(2), pt(1,2)));
        x1 = dragStart(1);  y1 = dragStart(2);
        selRect.Position = [min(x1,x2), min(y1,y2), ...
                            max(abs(x2-x1), 0.01), max(abs(y2-y1), 0.01)];
    end

    function onMouseUp(~, ~)
        if isempty(dragStart), return; end
        pt = ax.CurrentPoint;
        x2 = pt(1,1);  y2 = pt(1,2);
        x1 = dragStart(1);  y1 = dragStart(2);
        dragStart       = [];
        selRect.Visible = 'off';

        xd   = model.XDim;  yd = model.YDim;
        xMin = max(1, round(min(x1, x2)));
        xMax = min(model.Size(xd), round(max(x1, x2)));
        yMin = max(1, round(min(y1, y2)));
        yMax = min(model.Size(yd), round(max(y1, y2)));

        if xMax > xMin && yMax > yMin
            zoomFromMouseFcn(xd, [xMin, xMax], yd, [yMin, yMax]);
        end
    end

end % MatVisImageWin

function [pos, vis] = zoomRectFromModel(model)
    try
        xr = model.ZoomRange(model.XDim, :);
        yr = model.ZoomRange(model.YDim, :);
        w  = diff(xr);  h = diff(yr);
        if w > 0 && h > 0
            pos = [xr(1), yr(1), w, h];  vis = 'on';
        else
            pos = [1, 1, 1, 1];  vis = 'off';
        end
    catch
        pos = [1, 1, 1, 1];  vis = 'off';
    end
end
