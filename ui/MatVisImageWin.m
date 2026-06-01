function iw = MatVisImageWin(model)
%MatVisImageWin  Standalone figure showing full 2-D slice + zoom indicator.
%
%   iw = MatVisImageWin(model)
%
%   Creates a uifigure that displays the full 2-D image slice and overlays a
%   red rectangle marking the current zoom-crop region.
%
%   Input
%   -----
%   model : object with at least the following readable properties
%       model.Size      – dimension sizes (1 x nDims numeric)
%       model.XDim      – index of the horizontal dimension
%       model.YDim      – index of the vertical   dimension
%       model.ZoomRange – nDims x 2 matrix of [lo hi] per dimension
%
%   Output
%   ------
%   iw.fig        – uifigure handle
%   iw.ax         – uiaxes handle (fills the figure)
%   iw.imgHandle  – image graphics object
%   iw.rectHandle – rectangle graphics object showing the zoom region
%   iw.Update     – function handle:  iw.Update(rgbImg, zoomRect)
%
%   iw.Update(rgbImg, zoomRect)
%       rgbImg   – H x W x 3 uint8 RGB image (colormap + gamma already applied)
%       zoomRect – [xMin yMin width height] in pixel coordinates of full image

%% ---- Input validation -------------------------------------------------------
narginchk(1, 1);

%% ---- Build figure and axes --------------------------------------------------
fig = uifigure('Name',        'Image Window', ...
               'NumberTitle', 'off', ...
               'MenuBar',     'none');

ax = uiaxes(fig, ...
            'Units',    'normalized', ...
            'Position', [0 0 1 1]);

% Suppress the default interactive toolbar added by uiaxes.
disableDefaultInteractivity(ax);
ax.Toolbar.Visible = 'off';

% Keep pixel aspect ratio correct and fill available space.
axis(ax, 'image');
ax.XTick = [];
ax.YTick = [];

%% ---- Initialise image and rectangle handles ---------------------------------
% Draw a placeholder 1x1 transparent image so imgHandle is always a valid
% graphics object before the first Update call.
imgHandle = image(ax, zeros(1, 1, 3, 'uint8'));

% Derive initial rectangle position from the model's zoom range.
[initPos, initVis] = zoomRectFromModel(model);

rectHandle = rectangle(ax, ...
    'Position',  initPos, ...
    'EdgeColor', 'r', ...
    'LineWidth',  1.5, ...
    'FaceColor', 'none', ...
    'Visible',   initVis);

%% ---- Assemble output struct -------------------------------------------------
iw.fig        = fig;
iw.ax         = ax;
iw.imgHandle  = imgHandle;
iw.rectHandle = rectHandle;
iw.Update     = @(rgbImg, zoomRect) updateDisplay(ax, imgHandle, rectHandle, rgbImg, zoomRect);

end % MatVisImageWin

%% ---- Module-private helpers -------------------------------------------------

function updateDisplay(ax, imgHandle, rectHandle, rgbImg, zoomRect)
%updateDisplay  Refresh image data and the zoom-indicator rectangle.
%
%   ax         – uiaxes on which the image lives
%   imgHandle  – image graphics handle
%   rectHandle – rectangle graphics handle
%   rgbImg     – H x W x 3 uint8
%   zoomRect   – [xMin yMin width height]

% Update image content.
set(imgHandle, 'CData', rgbImg);

% Fit axes limits to the new image dimensions.
[H, W, ~] = size(rgbImg);
ax.XLim = [0.5, W + 0.5];
ax.YLim = [0.5, H + 0.5];

% Update zoom rectangle.
if numel(zoomRect) == 4 && zoomRect(3) > 0 && zoomRect(4) > 0
    set(rectHandle, ...
        'Position', zoomRect, ...
        'Visible',  'on');
else
    set(rectHandle, 'Visible', 'off');
end
end


function [pos, vis] = zoomRectFromModel(model)
%zoomRectFromModel  Derive initial rectangle position from model.ZoomRange.
%
%   Returns pos = [xMin yMin width height] and vis = 'on'|'off'.
%   Falls back to a unit square with visibility 'off' on any error.

try
    xDim = model.XDim;
    yDim = model.YDim;
    zr   = model.ZoomRange;   % nDims x 2

    xMin = zr(xDim, 1);
    xMax = zr(xDim, 2);
    yMin = zr(yDim, 1);
    yMax = zr(yDim, 2);

    w = xMax - xMin;
    h = yMax - yMin;

    if w > 0 && h > 0
        pos = [xMin, yMin, w, h];
        vis = 'on';
    else
        pos = [1, 1, 1, 1];
        vis = 'off';
    end
catch
    pos = [1, 1, 1, 1];
    vis = 'off';
end
end
