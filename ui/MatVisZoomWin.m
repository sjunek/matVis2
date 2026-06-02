function zw = MatVisZoomWin(model, zoomFromMouseFcn)
% MatVisZoomWin  Zoomed-crop display + position cross-hair.
%
%   zw = MatVisZoomWin(model, zoomFromMouseFcn)
%
%   zw.Update(rgbImg, posXLocal, posYLocal)
%       rgbImg     : H×W×3 uint8 cropped image
%       posXLocal  : CurrPos(XDim) - ZoomRange(XDim,1) + 1  (column)
%       posYLocal  : CurrPos(YDim) - ZoomRange(YDim,1) + 1  (row)
%
%   zw.SetOverlayVisible(tf)

if nargin < 2, zoomFromMouseFcn = []; end

fig = uifigure('Name', 'Zoom Window', 'NumberTitle', 'off', ...
               'Resize', 'on', 'AutoResizeChildren', 'off');

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
posLineV = line(ax, [NaN NaN], [0.5 1.5], ...
    'Color', 'w', 'LineWidth', 0.8);
posLineH = line(ax, [0.5 1.5], [NaN NaN], ...
    'Color', 'w', 'LineWidth', 0.8);
posLineV.HitTest      = 'off'; posLineV.PickableParts = 'none';
posLineH.HitTest      = 'off'; posLineH.PickableParts = 'none';

% Yellow dashed selection rect
selRect = rectangle(ax, 'Position', [1 1 1 1], ...
    'EdgeColor', [1 1 0], 'LineStyle', '--', 'LineWidth', 1.2, ...
    'FaceColor', 'none', 'Visible', 'off');
selRect.HitTest      = 'off';
selRect.PickableParts = 'none';

dragStart = [];

if ~isempty(zoomFromMouseFcn)
    fig.WindowButtonDownFcn   = @onMouseDown;
    fig.WindowButtonMotionFcn = @onMouseMove;
    fig.WindowButtonUpFcn     = @onMouseUp;
    fig.WindowScrollWheelFcn  = @onScrollWheel;
end

zw.fig               = fig;
zw.ax                = ax;
zw.imgHandle         = imgHandle;
zw.Update            = @updateImage;
zw.SetOverlayVisible = @setOverlayVisible;

% -------------------------------------------------------------------------
    function updateImage(rgbImg, posXLocal, posYLocal)
        if ~isvalid(fig), return; end
        set(imgHandle, 'CData', rgbImg);
        [H, W, ~] = size(rgbImg);
        ax.XLim = [0.5, W + 0.5];
        ax.YLim = [0.5, H + 0.5];
        if strcmp(imgHandle.Visible, 'off')
            imgHandle.Visible = 'on';
        end

        % Position cross-hair (NaN if out of bounds)
        if nargin >= 3
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
    end

    function setOverlayVisible(tf)
        vis = onOff_(tf);
        set(posLineV, 'Visible', vis);
        set(posLineH, 'Visible', vis);
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

        xd  = model.XDim;  yd = model.YDim;
        xrZ = model.ZoomRange(xd, :);
        yrZ = model.ZoomRange(yd, :);

        xMinL = max(1, round(min(x1,x2)));
        xMaxL = min(diff(xrZ)+1, round(max(x1,x2)));
        yMinL = max(1, round(min(y1,y2)));
        yMaxL = min(diff(yrZ)+1, round(max(y1,y2)));

        xMinD = xrZ(1) + xMinL - 1;
        xMaxD = xrZ(1) + xMaxL - 1;
        yMinD = yrZ(1) + yMinL - 1;
        yMaxD = yrZ(1) + yMaxL - 1;

        if xMaxD > xMinD && yMaxD > yMinD
            zoomFromMouseFcn(xd, [xMinD, xMaxD], yd, [yMinD, yMaxD]);
        end
    end

    function onScrollWheel(~, evt)
        factor = 1.25 ^ evt.VerticalScrollCount;
        pt     = ax.CurrentPoint;
        cx_L   = clamp_(pt(1,1), ax.XLim(1), ax.XLim(2));
        cy_L   = clamp_(pt(1,2), ax.YLim(1), ax.YLim(2));

        xd  = model.XDim;  yd = model.YDim;
        xrZ = model.ZoomRange(xd, :);
        yrZ = model.ZoomRange(yd, :);

        % Convert local coords to data coords
        cx_D = xrZ(1) + cx_L - 1;
        cy_D = yrZ(1) + cy_L - 1;

        xHalf = diff(xrZ) / 2 * factor;
        yHalf = diff(yrZ) / 2 * factor;

        xMin = max(1, round(cx_D - xHalf));
        xMax = min(model.Size(xd), round(cx_D + xHalf));
        yMin = max(1, round(cy_D - yHalf));
        yMax = min(model.Size(yd), round(cy_D + yHalf));
        if xMax > xMin && yMax > yMin
            zoomFromMouseFcn(xd, [xMin, xMax], yd, [yMin, yMax]);
        end
    end

end % MatVisZoomWin

function v = clamp_(x, lo, hi)
    v = max(lo, min(hi, x));
end

function s = onOff_(tf)
    if tf, s = 'on'; else, s = 'off'; end
end
