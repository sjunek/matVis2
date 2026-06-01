function zw = MatVisZoomWin(model, zoomFromMouseFcn)
% MatVisZoomWin  Zoomed-crop display window.
%
%   zw = MatVisZoomWin(model, zoomFromMouseFcn)
%
%   model            - MatVisModel handle (XDim, YDim, ZoomRange, Size)
%   zoomFromMouseFcn - @(xDim,xRange,yDim,yRange) for drag-to-sub-zoom.
%                      Pass [] to disable.
%
%   zw.Update(rgbImg)  — rgbImg is the already-cropped H×W×3 uint8 image.

if nargin < 2, zoomFromMouseFcn = []; end

fig = uifigure('Name', 'Zoom Window', 'NumberTitle', 'off', ...
               'Resize', 'on', 'AutoResizeChildren', 'off');

ax = uiaxes('Parent', fig, 'Units', 'normalized', 'Position', [0 0 1 1]);
axis(ax, 'image');
ax.XTick = [];  ax.YTick = [];
ax.XColor = 'none';  ax.YColor = 'none';
ax.Color  = [0 0 0];

imgHandle = image(ax, zeros(1, 1, 3, 'uint8'));
imgHandle.Visible = 'off';

selRect = rectangle(ax, ...
    'Position', [1 1 1 1], ...
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

zw.fig       = fig;
zw.ax        = ax;
zw.imgHandle = imgHandle;
zw.Update    = @updateImage;

% -------------------------------------------------------------------------
    function updateImage(rgbImg)
        if ~isvalid(fig), return; end
        set(imgHandle, 'CData', rgbImg);
        [H, W, ~] = size(rgbImg);
        ax.XLim = [0.5, W + 0.5];
        ax.YLim = [0.5, H + 0.5];
        if strcmp(imgHandle.Visible, 'off')
            imgHandle.Visible = 'on';
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

        xd  = model.XDim;  yd = model.YDim;
        xrZ = model.ZoomRange(xd, :);
        yrZ = model.ZoomRange(yd, :);

        % Pixel coords in ZoomWin are local-zoom indices (1 = first zoom pixel).
        % Data index = ZoomRange_lo + local_idx - 1
        xMinL = max(1, round(min(x1, x2)));
        xMaxL = min(diff(xrZ)+1, round(max(x1, x2)));
        yMinL = max(1, round(min(y1, y2)));
        yMaxL = min(diff(yrZ)+1, round(max(y1, y2)));

        xMinD = xrZ(1) + xMinL - 1;
        xMaxD = xrZ(1) + xMaxL - 1;
        yMinD = yrZ(1) + yMinL - 1;
        yMaxD = yrZ(1) + yMaxL - 1;

        if xMaxD > xMinD && yMaxD > yMinD
            zoomFromMouseFcn(xd, [xMinD, xMaxD], yd, [yMinD, yMaxD]);
        end
    end

end % MatVisZoomWin
