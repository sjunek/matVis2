function zw = MatVisZoomWin(model) %#ok<INUSD>
% MatVisZoomWin  Create a standalone zoom window for matVis 2.0.
%
%   zw = MatVisZoomWin(model)
%
%   Creates a uifigure displaying only the zoomed (cropped) region of the
%   current image slice.  The caller is responsible for driving updates by
%   invoking zw.Update(rgbImg) whenever the displayed region changes.
%
%   Input
%     model   - MatVisModel instance (reserved for future use; currently
%               unused but kept in the signature for API consistency).
%
%   Output  – struct with fields:
%     zw.fig        uifigure handle
%     zw.ax         uiaxes handle
%     zw.imgHandle  image handle (initially invisible)
%     zw.Update     function handle — call as zw.Update(rgbImg) where
%                   rgbImg is an H×W×3 uint8 RGB image already cropped to
%                   the zoom region.

% ---------------------------------------------------------------------------
% Figure
% ---------------------------------------------------------------------------
fig = uifigure('Name', 'Zoom Window', ...
               'NumberTitle', 'off', ...
               'Resize', 'on', ...
               'AutoResizeChildren', 'off');

% ---------------------------------------------------------------------------
% Axes — fill the figure
% ---------------------------------------------------------------------------
ax = uiaxes('Parent', fig, ...
            'Units', 'normalized', ...
            'Position', [0 0 1 1]);

% Image-style axes settings
axis(ax, 'image');          % equal aspect ratio, tight to data
ax.XTick = [];
ax.YTick = [];
ax.XColor = 'none';
ax.YColor = 'none';
ax.Color  = [0 0 0];        % black background while no image is shown

% ---------------------------------------------------------------------------
% Placeholder image handle (1×1 black pixel, invisible)
% ---------------------------------------------------------------------------
imgHandle = image(ax, zeros(1, 1, 3, 'uint8'));
imgHandle.Visible = 'off';

% ---------------------------------------------------------------------------
% Public interface
% ---------------------------------------------------------------------------
zw.fig       = fig;
zw.ax        = ax;
zw.imgHandle = imgHandle;
zw.Update    = @updateImage;

% ---------------------------------------------------------------------------
% Nested helper
% ---------------------------------------------------------------------------
    function updateImage(rgbImg)
        % updateImage  Push a new cropped RGB frame to the zoom window.
        %
        %   updateImage(rgbImg)
        %
        %   rgbImg : H×W×3 uint8  — cropped zoom region, already rendered
        %            by MatVisRender.renderSlice.

        if ~isvalid(fig)
            return
        end

        set(imgHandle, 'CData', rgbImg);

        if strcmp(imgHandle.Visible, 'off')
            imgHandle.Visible = 'on';
        end
    end

end
