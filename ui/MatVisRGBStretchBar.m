function sb = MatVisRGBStretchBar(parent, onChange)
% MatVisRGBStretchBar  Blue/red-point selector for RGB stretch modes.
%
%   sb = MatVisRGBStretchBar(parent, onChange)
%
%   A horizontal rainbow colour bar (blue -> cyan -> green -> yellow -> red)
%   with two draggable thumbs that set the "blue point" and "red point" — the
%   rainbow positions assigned to the first and last index of the RGB
%   dimension (analogous to the black/white points of a contrast adjustment).
%   Values are in [0,1] with blue <= red.
%
%   onChange([bluePoint redPoint])  is called (if supplied) on every change.
%
%   sb.root             uipanel hosting the bar (set its Layout.Row to place it)
%   sb.SetVisible(tf)   show / hide
%   sb.SetValue([b r])  set thumb values without firing onChange
%   sb.GetValue()       -> [bluePoint redPoint]

if nargin < 2, onChange = []; end

PAD = MatVisRender.RGB_STRETCH_PAD;   % solid-colour margin at each end (0.15)
val = [PAD, 1 - PAD];   % [bluePoint redPoint] — default at rainbow boundaries

root = uipanel(parent, 'BorderType', 'none');
gl   = uigridlayout(root, [1 1]);
gl.Padding    = [0 1 0 1];   % flush horizontally so the bar aligns precisely
gl.ColumnWidth = {'1x'};
gl.RowHeight   = {'1x'};

ax = uiaxes(gl);
disableDefaultInteractivity(ax);
try, ax.Toolbar = []; catch, end   % remove toolbar + R2026a chevron
ax.XLim = [0 1];   ax.YLim = [0 1];
ax.XTick = [];     ax.YTick = [];
ax.Box   = 'on';
ax.XColor = [0.4 0.4 0.4];  ax.YColor = [0.4 0.4 0.4];
ax.Interactions = [];
ax.PositionConstraint = 'innerposition';

% Colour bar: solid blue in the first PAD, rainbow (blue->red) in the middle,
% solid red in the last PAD — so thumbs dragged past the rainbow stay solid.
nC   = 256;
padN = max(1, round(PAD * nC));
midN = nC - 2*padN;
mid  = MatVisRender.rgbStretchColormap(midN);     % midN x 3 rainbow
cmap = [repmat([0 0 1], padN, 1); mid; repmat([1 0 0], padN, 1)];
strip = reshape(cmap, [1 nC 3]);
imgH = image(ax, 'XData', [0 1], 'YData', [0 1], 'CData', strip);
imgH.HitTest = 'off';  imgH.PickableParts = 'none';

% Thumb markers (vertical lines). Clicking anywhere on the bar grabs the
% nearest thumb, so the lines are only visual feedback.
thumbBlue = line(ax, [val(1) val(1)], [0 1], 'Color', 'k', 'LineWidth', 2.5, ...
    'HitTest', 'off', 'PickableParts', 'none');
thumbRed  = line(ax, [val(2) val(2)], [0 1], 'Color', 'w', 'LineWidth', 2.5, ...
    'HitTest', 'off', 'PickableParts', 'none');

ax.ButtonDownFcn = @onDown;

dragWhich = 0;   % 1 = blue, 2 = red
figH_     = [];  % cached host figure (set by installHover_)

sb.root      = root;
sb.ax        = ax;
sb.SetVisible = @setVisible;
sb.SetValue  = @setValue;
sb.GetValue  = @() val;

installHover_();   % horizontal-arrow cursor when hovering the indicator lines

    function setVisible(tf)
        if tf, v = 'on'; else, v = 'off'; end
        root.Visible = v;
    end

    function setValue(v)
        v = max(0, min(1, double(v(:)')));
        val = [min(v), max(v)];
        redraw();
    end

    function redraw()
        thumbBlue.XData = [val(1) val(1)];
        thumbRed.XData  = [val(2) val(2)];
    end

    function x = clickX()
        p = ax.CurrentPoint;
        x = max(0, min(1, p(1, 1)));
    end

    function onDown(~, ~)
        x = clickX();
        % Pick the nearer thumb (prefer red on a tie at the right edge).
        if abs(x - val(1)) <= abs(x - val(2))
            dragWhich = 1;
        else
            dragWhich = 2;
        end
        fig = ancestor(ax, 'figure');
        if isempty(fig), return; end
        savedMotion = fig.WindowButtonMotionFcn;
        savedUp     = fig.WindowButtonUpFcn;
        fig.WindowButtonMotionFcn = @onMove;
        fig.WindowButtonUpFcn     = @onUp;
        fig.Pointer = 'custom';     % keep the horizontal-arrow cursor while dragging
        onMove();   % apply the initial click position immediately

        function onMove(~, ~)
            x2 = clickX();
            if dragWhich == 1
                val(1) = min(x2, val(2));
            else
                val(2) = max(x2, val(1));
            end
            redraw();
            if ~isempty(onChange), onChange(val); end
        end

        function onUp(~, ~)
            fig.WindowButtonMotionFcn = savedMotion;
            fig.WindowButtonUpFcn     = savedUp;
            dragWhich = 0;
        end
    end

    % ---- Hover cursor (horizontal arrows over the indicator lines) --------
    function installHover_()
        figH_ = ancestor(ax, 'figure');
        if isempty(figH_) || ~isvalid(figH_), return; end
        % Install the custom horizontal double-arrow pointer shape once.
        if ~isequal(getappdata(figH_, 'RGBStretch_PointerSet'), true)
            figH_.PointerShapeCData   = horizArrowCData_();
            figH_.PointerShapeHotSpot = [8 8];
            setappdata(figH_, 'RGBStretch_PointerSet', true);
        end
        % Register with the shared hover dispatcher (also used by RangeSlider).
        list = getappdata(figH_, 'RS_HoverList');
        if isempty(list), list = {}; end
        list{end+1} = @hoverCursor_;
        setappdata(figH_, 'RS_HoverList', list);
        if ~isequal(getappdata(figH_, 'RS_MotionInstalled'), true)
            setappdata(figH_, 'RS_MotionInstalled', true);
            figH_.WindowButtonMotionFcn = @RangeSlider.hoverDispatch_;
        end
    end

    function c = hoverCursor_()
        % Returns 'custom' (horizontal arrows) when the cursor is over either
        % indicator line, else '' so other providers/arrow apply.
        c = '';
        if ~isvalid(ax) || ~strcmp(root.Visible, 'on'), return; end
        if dragWhich ~= 0, c = 'custom'; return; end
        try, axp = getpixelposition(ax, true); catch, return; end
        if axp(3) < 2 || axp(4) < 2, return; end
        fp = figH_.CurrentPoint;
        xRel = fp(1) - axp(1);  yRel = fp(2) - axp(2);
        if xRel < -4 || xRel > axp(3)+4 || yRel < -4 || yRel > axp(4)+4
            return;
        end
        cx  = max(0, min(1, xRel / axp(3)));
        thr = 6 / axp(3);   % ~6 px proximity to a line, in data units
        if abs(cx - val(1)) <= thr || abs(cx - val(2)) <= thr
            c = 'custom';
        end
    end

end % MatVisRGBStretchBar

% ---------------------------------------------------------------------------
function cd = horizArrowCData_()
% 16x16 pointer: a black horizontal double-headed arrow (NaN = transparent).
cd = NaN(16, 16);
cd(7:10, 4:13) = 1;                 % shaft
for k = 0:4                         % two arrowheads
    r1 = 8 - k;  r2 = 9 + k;
    cd(r1:r2, 6 - k)  = 1;          % left head (tip at col 2)
    cd(r1:r2, 11 + k) = 1;          % right head (tip at col 15)
end
end
