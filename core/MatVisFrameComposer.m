classdef MatVisFrameComposer < handle
    % MatVisFrameComposer  Offscreen renderer for matVis 2.0 movie frames.
    %
    %   comp = MatVisFrameComposer(model, layout)
    %   comp = MatVisFrameComposer(model, layout, 'FrameSize', [1280 720], ...)
    %   rgb  = comp.RenderFrame();      % H×W×3 uint8, exactly FrameSize
    %   comp.delete();
    %
    %   The frame is composed from the model, not screen-captured from the
    %   live windows: every panel is an axes in one hidden classic figure and
    %   the whole figure is grabbed in a single call.  Consequences that
    %   motivated the design:
    %     * the user's windows are never resized, recoloured or required to
    %       be visible (the original matVis had to do all three);
    %     * output resolution is independent of window size and of the
    %       display's DPI scaling;
    %     * it runs headless, so a movie can be rendered from a script.
    %
    %   Capture path.  MATLAB renders a figure at the display's device scale,
    %   so a 1920×1080 figure yields a larger image on a scaled display (1.25×
    %   and 1.50× were measured on the same monitor under two releases).  The
    %   scale is therefore measured once (MeasureDeviceScale) and the figure
    %   is created at FrameSize/scale; the grab is then cropped/padded to the
    %   exact FrameSize, which also absorbs the ±1 px rounding.
    %
    %   Layout.  A struct array, one entry per panel:
    %     .type     'image' | 'zoom' | 'plot' | 'volume' | 'histogram' |
    %               'title' | 'timelabel' | 'scalebar'
    %     .pos      [x y w h] normalized in the frame, origin bottom-left
    %     .dataset  dataset index (image/zoom/plot/volume/histogram; default 1)
    %     .overlays struct of logicals: rois, profiles, crosshair, zoomRect
    %     .text     title text ('title')
    %     .fontSize point size ('title'/'timelabel'/'scalebar')
    %     .color    text/line colour ('title'/'timelabel'/'scalebar')
    %     .dim      dimension index ('timelabel'); plot: dims to draw
    %     .format   sprintf format ('timelabel', default '%s = %.4g %s')
    %     .length   scalebar length in real units (0/absent = auto)
    %   'volume' adds .dims3 .extent ('full'|'zoom'|'custom') .ranges .maxVox
    %   .style ('max'|'min') .cmapIdx (0 = follow the model) .box .showLabels
    %   .az .el .zoom (defaults; the View3D property overrides them per frame).
    %   'histogram' adds .histRange ([] = the dataset's own range) and .histLog.
    %   Use MatVisFrameComposer.DefaultLayout(...) for the common arrangements.
    %
    %   Display source.  By default the composer computes the displayed RGB
    %   itself from the model.  When a 'DisplayFcn' is supplied (the main
    %   window passes mw.ComputeDisplay) it is used instead, so the movie goes
    %   through exactly the same contrast/gamma/filter pipeline as the live
    %   windows — including the percentile fields that only the UI owns.

    properties (SetAccess = private)
        Model
        Layout
        FrameSize   = [1280 720]   % [W H] in output pixels
        BackColor   = [1 1 1]
        DeviceScale = 1
        Fig         = []
    end

    properties
        DisplayFcn  = []           % @(ds) -> struct (see mw.ComputeDisplay)
        % @() -> [lo hi] for the histogram panel's x axis.  The main window
        % passes its own Hist Min / Hist Max fields, so the movie's
        % histogram is framed exactly like the one on screen instead of
        % guessing a range of its own.  Read at paint time, so dragging
        % those fields moves an open preview too.
        HistRangeFcn = []
        % Per-frame camera for every 'volume' panel: struct with az / el /
        % zoom, or [] to use each panel's own spec.  It is a plain property
        % rather than a Set* method because it changes no graphics object's
        % existence — a recorder can ramp it frame by frame without the
        % rebuild that a layout change forces.
        View3D      = []
    end

    properties (Access = private)
        panels_ = {}               % per-panel graphics state
        built_  = false
    end

    % ------------------------------------------------------------------
    methods (Static)
        function s = MeasureDeviceScale()
            % Ratio between printed pixels and figure pixels on this display.
            % Cached for the session: creating a probe figure is not free and
            % the value cannot change without MATLAB restarting.
            persistent cached
            if ~isempty(cached), s = cached; return; end
            s = 1;
            f = [];
            try
                f = figure('Visible', 'off', 'Units', 'pixels', ...
                           'Position', [50 50 400 300], 'MenuBar', 'none', ...
                           'ToolBar', 'none', 'NumberTitle', 'off');
                axes('Parent', f, 'Position', [0 0 1 1]);
                drawnow;
                probe = print(f, '-RGBImage', '-r0');
                if ~isempty(probe)
                    s = size(probe, 2) / 400;
                end
            catch
                s = 1;
            end
            if ~isfinite(s) || s <= 0, s = 1; end
            try; if ~isempty(f) && isvalid(f), close(f); end; catch; end
            cached = s;
        end

        function kinds = LayoutKinds()
            % Every arrangement DefaultLayout understands, in menu order.
            kinds = {'image', 'zoom', 'image+zoom', 'zoom+plot', ...
                     'image+zoom+plot', '3d', 'image+3d', 'zoom+3d', ...
                     'image+zoom+3d', 'zoom+3d+plot'};
        end

        function layout = DefaultLayout(kind, model)
            % Ready-made arrangements; see LayoutKinds for the list.
            if nargin < 2, model = []; end
            ov  = struct('rois', true, 'profiles', true, ...
                         'crosshair', true, 'zoomRect', true);
            ovZ = struct('rois', true, 'profiles', true, ...
                         'crosshair', true, 'zoomRect', false);
            switch lower(kind)
                case 'image'
                    layout = MatVisFrameComposer.panel('image', [0 0 1 1], ov);
                case 'zoom'
                    layout = MatVisFrameComposer.panel('zoom', [0 0 1 1], ovZ);
                case 'image+zoom'
                    layout = [MatVisFrameComposer.panel('image', [0    0 0.5 1], ov), ...
                              MatVisFrameComposer.panel('zoom',  [0.5  0 0.5 1], ovZ)];
                case 'zoom+plot'
                    layout = [MatVisFrameComposer.panel('zoom', [0 0.35 1 0.65], ovZ), ...
                              MatVisFrameComposer.panel('plot', [0 0    1 0.35], ovZ)];
                case 'image+zoom+plot'
                    layout = [MatVisFrameComposer.panel('image', [0   0.35 0.5 0.65], ov), ...
                              MatVisFrameComposer.panel('zoom',  [0.5 0.35 0.5 0.65], ovZ), ...
                              MatVisFrameComposer.panel('plot',  [0   0    1   0.35], ovZ)];
                case '3d'
                    layout = MatVisFrameComposer.panel('volume', [0 0 1 1], []);
                case 'image+3d'
                    layout = [MatVisFrameComposer.panel('image',  [0   0 0.5 1], ov), ...
                              MatVisFrameComposer.panel('volume', [0.5 0 0.5 1], [])];
                case 'zoom+3d'
                    layout = [MatVisFrameComposer.panel('zoom',   [0   0 0.5 1], ovZ), ...
                              MatVisFrameComposer.panel('volume', [0.5 0 0.5 1], [])];
                case 'image+zoom+3d'
                    layout = [MatVisFrameComposer.panel('image',  [0     0 1/3 1], ov), ...
                              MatVisFrameComposer.panel('zoom',   [1/3   0 1/3 1], ovZ), ...
                              MatVisFrameComposer.panel('volume', [2/3   0 1/3 1], [])];
                case 'zoom+3d+plot'
                    layout = [MatVisFrameComposer.panel('zoom',   [0   0.35 0.5 0.65], ovZ), ...
                              MatVisFrameComposer.panel('volume', [0.5 0.35 0.5 0.65], []), ...
                              MatVisFrameComposer.panel('plot',   [0   0    1   0.35], ovZ)];
                otherwise
                    error('MatVisFrameComposer:unknownLayout', ...
                        'Unknown layout "%s".', kind);
            end
            if ~isempty(model)
                d = MatVisFrameComposer.firstFreeDim(model);

                % A volume panel needs three concrete dimensions; the same
                % triple the 3-D window opens on (display plane + the first
                % free dimension).
                dims3 = MatVisFrameComposer.defaultDims3(model);
                for k = 1:numel(layout)
                    if strcmp(layout(k).type, 'volume')
                        layout(k).dims3 = dims3;
                    end
                end

                % Plot panels default to the dimension a movie normally
                % sweeps, so the panel has content even when the main
                % window's per-dimension plot toggles are all off.
                for k = 1:numel(layout)
                    if strcmp(layout(k).type, 'plot') && layout(k).dim == 0 && ~isempty(d)
                        layout(k).dim = d;
                    end
                end

                % A time label for that dimension — the single most useful
                % annotation in a microscopy movie.  Carried by the first
                % image/zoom panel so it sits on the picture itself.
                if ~isempty(d)
                    for k = 1:numel(layout)
                        if ismember(layout(k).type, {'image', 'zoom'})
                            layout(k).timeDim = d;
                            break;
                        end
                    end
                end
            end
        end

        function p = panel(type, pos, overlays)
            % One layout entry with every field the composer may read, so
            % struct arrays concatenate without "dissimilar structures".
            if nargin < 3 || isempty(overlays)
                overlays = struct('rois', false, 'profiles', false, ...
                                  'crosshair', false, 'zoomRect', false);
            end
            p = struct('type', type, 'pos', pos, 'dataset', 1, ...
                       'overlays', overlays, 'text', '', 'fontSize', 14, ...
                       'color', [0 0 0], 'dim', 0, 'format', '', 'length', 0, ...
                       'yLim', [], ...
                       ... % Annotations carried INSIDE an image/zoom panel.
                       ... % They are drawn in the panel's data coordinates so
                       ... % they stay over the image, which "axis image"
                       ... % letterboxes inside the panel rectangle.
                       'timeDim', 0, 'scaleBar', false, ...
                       'annotColor', [1 1 1], 'annotFontSize', 12, ...
                       ... % 'zoom' panel: grow the crop to the panel's own
                       ... % proportions so it fills the rectangle instead of
                       ... % being letterboxed (composer-local; the shared
                       ... % zoom box is put back afterwards).
                       'fillZoom', false, ...
                       ... % 'volume' panel.  az/el/zoom are only the
                       ... % fallback: the View3D property overrides them, so
                       ... % ramping a camera does not touch the layout (and
                       ... % therefore does not rebuild the figure).
                       'dims3', [1 2 3], 'extent', 'full', 'ranges', [], ...
                       'maxVox', 4e6, 'style', 'max', 'cmapIdx', 0, ...
                       'box', true, 'showLabels', true, ...
                       'az', -37.5, 'el', 30, 'zoom', 1, 'contrast', [], ...
                       ... % 'histogram' panel
                       'histRange', [], 'histLog', false);
        end

        function layout = ScaleInto(layout, rect)
            % Squeeze a whole layout into RECT = [x y w h] of the frame.
            % Lets a caller reserve a strip for an extra panel without every
            % arrangement needing a second set of hard-coded positions.
            for k = 1:numel(layout)
                p = layout(k).pos;
                layout(k).pos = [rect(1) + p(1) * rect(3), ...
                                 rect(2) + p(2) * rect(4), ...
                                 p(3) * rect(3), p(4) * rect(4)];
            end
        end

        function tf = sameStructure(a, b)
            % Do two layouts need the same graphics objects in the same
            % places?  Panel type and rectangle are the only things build()
            % reads that paintPanels does not re-apply.
            tf = numel(a) == numel(b);
            if ~tf, return; end
            for k = 1:numel(a)
                if ~strcmp(a(k).type, b(k).type) || ~isequal(a(k).pos, b(k).pos)
                    tf = false;  return;
                end
            end
        end

        function [xr, yr] = growZoomToPanel(xr, yr, xN, yN, r, wp, hp)
            % Grow the index ranges XR/YR until their on-screen proportions
            % match a WP x HP panel, so a fixed-aspect zoom fills it instead
            % of being letterboxed.  Only ever grows, and never past
            % [1 xN] / [1 yN], so the requested region stays visible.
            %
            % Same arithmetic as MatVisRender.fitZoomToAxes, but for a panel
            % whose pixel size is known up front rather than an axes that has
            % to be measured — the composer needs the answer before the
            % display pipeline runs, i.e. before anything is drawn.
            if wp <= 0 || hp <= 0 || numel(r) ~= 2, return; end
            wx = xr(2) - xr(1) + 1;
            wy = yr(2) - yr(1) + 1;
            if wx <= 0 || wy <= 0, return; end
            needY = wx * (r(2)/r(1)) * (hp/wp);
            needX = wy * (r(1)/r(2)) * (wp/hp);
            if needY > wy + 0.5
                yr = MatVisFrameComposer.growRange(yr, needY, yN);
            elseif needX > wx + 0.5
                xr = MatVisFrameComposer.growRange(xr, needX, xN);
            end
        end

        function r = growRange(r, wNew, n)
            wNew = min(round(wNew), n);
            w    = r(2) - r(1) + 1;
            if wNew <= w, return; end
            lo = round(r(1) - (wNew - w) / 2);      % grow to both sides
            lo = max(1, min(lo, n - wNew + 1));
            r  = [lo, lo + wNew - 1];
        end

        function d = defaultDims3(model)
            % Display plane plus the first dimension with extent, i.e. what
            % MatVis3DWin opens on.  Falls back to repeating a dim when the
            % dataset has fewer than three.
            xd = model.XDim;
            yd = model.YDim;
            others = setdiff(1:numel(model.Size), [xd yd], 'stable');
            if isempty(others)
                d = [xd yd yd];
            else
                d = [xd yd others(1)];
            end
        end

        function r = AnnotationRect(layout, which)
            % Where a time label / scale bar should sit.  Anchored inside the
            % first image or zoom panel rather than at the frame edge: the
            % frame background may be a plot panel (white), where a white
            % annotation would be invisible, and a top-of-frame label would
            % collide with a title.
            host = [];
            for k = 1:numel(layout)
                if ismember(layout(k).type, {'image', 'zoom'})
                    host = layout(k).pos;  break;
                end
            end
            if isempty(host), host = [0 0 1 1]; end
            x = host(1);  y = host(2);  w = host(3);  h = host(4);

            % Inset from the panel edge, but never less than 2 % of the frame
            % — a narrow panel would otherwise push the text against the edge.
            padX = max(0.02, 0.02 * w);

            switch lower(which)
                case 'timelabel'
                    r = [x + padX, y + 0.015*h, 0.55*w, 0.055];
                case 'scalebar'
                    r = [x + 0.58*w, y + 0.02*h, 0.38*w - padX, 0.07];
                otherwise
                    r = [x + padX, y + 0.02*h,  0.5*w,  0.06];
            end
            r(2) = max(0, min(1 - r(4), r(2)));
        end

        function d = firstFreeDim(model)
            % First dimension that is neither X nor Y and has extent > 1 —
            % the one a movie normally sweeps.
            d = [];
            for k = 1:numel(model.Size)
                if k ~= model.XDim && k ~= model.YDim && model.Size(k) > 1
                    d = k; return
                end
            end
        end
    end

    % ------------------------------------------------------------------
    methods
        function obj = MatVisFrameComposer(model, layout, varargin)
            p = inputParser;
            p.addParameter('FrameSize',  [1280 720]);
            p.addParameter('BackColor',  [1 1 1]);
            p.addParameter('DisplayFcn', []);
            p.parse(varargin{:});

            obj.Model      = model;
            obj.Layout     = layout;
            obj.BackColor  = p.Results.BackColor;
            obj.DisplayFcn = p.Results.DisplayFcn;
            obj.SetFrameSize(p.Results.FrameSize);
        end

        function SetFrameSize(obj, sz)
            sz = round(double(sz(:)'));
            if numel(sz) ~= 2 || any(sz < 16)
                error('MatVisFrameComposer:badFrameSize', ...
                    'FrameSize must be [width height], at least 16 px each.');
            end
            if isequal(obj.FrameSize, sz), return; end
            obj.FrameSize = sz;
            obj.teardown();          % geometry changed — rebuild on next use
        end

        % Layout and BackColor decide which graphics objects exist and how
        % they are configured, so they are changed through methods that drop
        % the built figure — assigning the properties directly would leave
        % the panels stale.
        function SetLayout(obj, layout)
            if isequal(obj.Layout, layout), return; end
            % Only which panels exist and where they sit is decided at build
            % time; every other field is re-applied on each paint.  So a
            % change that leaves that structure alone — an overlay toggle, a
            % 3-D style, a histogram's log axis — needs the new specs and
            % nothing else, and the built figure survives.  That matters
            % beyond speed: a visible preview window IS this figure, so
            % rebuilding would make it vanish under the user.
            if obj.built_ && ~isempty(obj.Fig) && isvalid(obj.Fig) && ...
                    MatVisFrameComposer.sameStructure(obj.Layout, layout)
                obj.Layout = layout;
                for k = 1:numel(obj.panels_)
                    obj.panels_{k}.spec = layout(k);
                end
                return;
            end
            obj.Layout = layout;
            obj.teardown();
        end

        function SetBackColor(obj, c)
            if isequal(obj.BackColor, c), return; end
            obj.BackColor = c;
            obj.teardown();
        end

        function PaintFrame(obj)
            % Everything a frame needs except the grab.  Playing a preview
            % goes through here, so animating costs the paint but not the
            % ~54 ms capture per frame.
            obj.build();
            obj.paintPanels();
            drawnow;
        end

        function rgb = RenderFrame(obj)
            obj.PaintFrame();
            rgb = obj.grab();
        end

        function f = PreviewFigure(obj)
            % The composer figure itself, made visible.  It is a faithful
            % preview because it *is* what gets captured.
            obj.build();
            obj.paintPanels();
            obj.Fig.Visible = 'on';
            drawnow;
            f = obj.Fig;
        end

        function delete(obj)
            obj.teardown();
        end
    end

    % ------------------------------------------------------------------
    methods (Access = private)

        function build(obj)
            if obj.built_ && ~isempty(obj.Fig) && isvalid(obj.Fig), return; end
            obj.teardown();

            obj.DeviceScale = MatVisFrameComposer.MeasureDeviceScale();
            figW = max(16, round(obj.FrameSize(1) / obj.DeviceScale));
            figH = max(16, round(obj.FrameSize(2) / obj.DeviceScale));

            obj.Fig = figure('Visible', 'off', 'Units', 'pixels', ...
                'Position', [60 60 figW figH], 'Color', obj.BackColor, ...
                'MenuBar', 'none', 'ToolBar', 'none', 'NumberTitle', 'off', ...
                'Name', 'matVis movie frame', 'Resize', 'off', ...
                'HandleVisibility', 'off', 'DockControls', 'off');

            n = numel(obj.Layout);
            obj.panels_ = cell(1, n);
            for k = 1:n
                obj.panels_{k} = obj.buildPanel(obj.Layout(k));
            end
            obj.built_ = true;
        end

        function P = buildPanel(obj, spec)
            P = struct('spec', spec, 'ax', [], 'img', [], ...
                       'roiH', [], 'profH', [], 'txt', [], ...
                       'posV', [], 'posH', [], 'rect', [], ...
                       'lines', gobjects(1, 0), 'bar', [], 'barTxt', [], ...
                       'tTxt', [], 'sbLine', [], 'sbTxt', [], ...
                       ... % 'volume': the extracted sub-volume is cached, so
                       ... % orbiting the camera over one volume re-projects
                       ... % without re-reading the data.
                       'boxLine', [], 'labTxt', gobjects(1, 0), ...
                       'volKey', [], 'V', [], 'vox', [1 1 1], ...
                       ... % 'histogram'
                       'fillG', [], 'fillI', [], 'fillZ', [], ...
                       'lineMin', [], 'lineMax', [], 'gammaLine', [], ...
                       'cbImg', [], 'globKey', [], 'globCounts', []);
            pos = spec.pos;

            switch spec.type
                case {'image', 'zoom', 'volume'}
                    P.ax = axes('Parent', obj.Fig, 'Units', 'normalized', ...
                                'Position', pos, 'XTick', [], 'YTick', [], ...
                                'Color', obj.BackColor, 'Box', 'off');
                    axis(P.ax, 'image');
                    axis(P.ax, 'off');
                    hold(P.ax, 'on');
                    P.img = image(P.ax, zeros(1, 1, 3, 'uint8'));
                    % image() only flips the Y axis when it is allowed to
                    % configure the axes; "hold on" above suppresses that, so
                    % row 1 would render at the BOTTOM and the frame would be
                    % a mirror image of the live window.  Set it explicitly.
                    P.ax.YDir = 'reverse';
                    % In-image annotations (data coords, so letterboxing
                    % cannot push them off the picture)
                    P.tTxt = text(P.ax, NaN, NaN, '', 'Color', spec.annotColor, ...
                        'FontSize', spec.annotFontSize, 'Visible', 'off', ...
                        'HorizontalAlignment', 'left', 'VerticalAlignment', 'bottom', ...
                        'Interpreter', 'none', 'Clipping', 'off');
                    P.sbLine = line(P.ax, [NaN NaN], [NaN NaN], ...
                        'Color', spec.annotColor, 'LineWidth', 4, 'Visible', 'off');
                    P.sbTxt = text(P.ax, NaN, NaN, '', 'Color', spec.annotColor, ...
                        'FontSize', spec.annotFontSize, 'Visible', 'off', ...
                        'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                        'Interpreter', 'none', 'Clipping', 'off');

                    if strcmp(spec.type, 'volume')
                        fg = obj.foreColor();
                        P.boxLine = line(P.ax, NaN, NaN, 'Color', fg, ...
                            'LineWidth', 0.75, 'Visible', 'off');
                        P.labTxt = gobjects(1, 3);
                        for kL_ = 1:3
                            P.labTxt(kL_) = text(P.ax, NaN, NaN, '', 'Color', fg, ...
                                'FontSize', max(7, round(spec.annotFontSize * 0.85)), ...
                                'HorizontalAlignment', 'center', ...
                                'VerticalAlignment', 'middle', ...
                                'Interpreter', 'none', 'Visible', 'off');
                        end
                    else
                        P.rect = rectangle(P.ax, 'Position', [1 1 1 1], ...
                            'EdgeColor', 'r', 'LineWidth', 1.5, 'FaceColor', 'none', ...
                            'Visible', 'off');
                        P.posV = line(P.ax, [NaN NaN], [NaN NaN], 'Color', 'w', 'LineWidth', 0.8);
                        P.posH = line(P.ax, [NaN NaN], [NaN NaN], 'Color', 'w', 'LineWidth', 0.8);
                    end

                case 'histogram'
                    fg = obj.foreColor();
                    % No Y ticks and no axis label, so it needs far less
                    % margin than a plot panel.
                    P.ax = axes('Parent', obj.Fig, 'Units', 'normalized', ...
                                'Position', obj.insetPlotPos(pos, [30 36 30 10]), ...
                                'Color', obj.BackColor, 'Box', 'off', ...
                                'XColor', fg, 'YColor', 'none', ...
                                'YTick', [], 'TickDir', 'out');
                    hold(P.ax, 'on');
                    P.ax.FontSize = max(7, round(spec.fontSize * 0.7));
                    fa = {'EdgeColor', 'none'};
                    % Grey / mid / dark, as in the main window's histogram:
                    % whole dataset, current image, current zoom crop.
                    P.fillG = fill(P.ax, NaN, NaN, obj.histShade(0.78), 'FaceAlpha', 0.90, fa{:});
                    P.fillI = fill(P.ax, NaN, NaN, obj.histShade(0.45), 'FaceAlpha', 0.90, fa{:});
                    P.fillZ = fill(P.ax, NaN, NaN, obj.histShade(0.10), 'FaceAlpha', 0.92, fa{:});
                    P.cbImg = image(P.ax, 'XData', [0 1], 'YData', [0 1], ...
                        'CData', zeros(2, 256, 3));
                    P.lineMin = line(P.ax, [NaN NaN], [NaN NaN], ...
                        'Color', [0.85 0.15 0.15], 'LineWidth', 1.8);
                    P.lineMax = line(P.ax, [NaN NaN], [NaN NaN], ...
                        'Color', [0.25 0.45 0.95], 'LineWidth', 1.8);
                    P.gammaLine = line(P.ax, NaN, NaN, 'Color', fg, ...
                        'LineWidth', 1.2, 'LineStyle', '-');

                case 'plot'
                    P.ax = axes('Parent', obj.Fig, 'Units', 'normalized', ...
                                'Position', obj.insetPlotPos(pos), ...
                                'Color', obj.BackColor, 'Box', 'off');
                    hold(P.ax, 'on');

                case {'title', 'timelabel'}
                    P.ax = axes('Parent', obj.Fig, 'Units', 'normalized', ...
                                'Position', pos, 'Color', 'none');
                    axis(P.ax, 'off');
                    P.ax.XLim = [0 1];  P.ax.YLim = [0 1];
                    P.txt = text(P.ax, 0, 0.5, '', 'FontSize', spec.fontSize, ...
                        'Color', spec.color, 'VerticalAlignment', 'middle', ...
                        'HorizontalAlignment', 'left', 'Interpreter', 'none');

                case 'scalebar'
                    P.ax = axes('Parent', obj.Fig, 'Units', 'normalized', ...
                                'Position', pos, 'Color', 'none');
                    axis(P.ax, 'off');
                    P.ax.XLim = [0 1];  P.ax.YLim = [0 1];
                    P.bar = line(P.ax, [NaN NaN], [0.35 0.35], ...
                        'Color', spec.color, 'LineWidth', 4);
                    P.barTxt = text(P.ax, 0.5, 0.75, '', 'FontSize', spec.fontSize, ...
                        'Color', spec.color, 'HorizontalAlignment', 'center', ...
                        'VerticalAlignment', 'bottom', 'Interpreter', 'none');

                otherwise
                    error('MatVisFrameComposer:unknownPanel', ...
                        'Unknown panel type "%s".', spec.type);
            end
        end

        function pos = insetPlotPos(obj, pos, margins)
            % Leave room for the plot's tick labels inside its slot.  The
            % margins are a fixed number of frame pixels converted to
            % normalized units, so they don't shrink with the panel and clip
            % the labels (they are text, not scaled graphics).
            if nargin < 3 || numel(margins) ~= 4
                margins = [62 58 12 8];             % [left bottom right top]
            end
            mL = margins(1); mB = margins(2); mR = margins(3); mT = margins(4);
            fx = mL / obj.FrameSize(1);  fr = mR / obj.FrameSize(1);
            fy = mB / obj.FrameSize(2);  ft = mT / obj.FrameSize(2);
            w  = max(0.05, pos(3) - fx - fr);
            h  = max(0.05, pos(4) - fy - ft);
            pos = [pos(1) + fx, pos(2) + fy, w, h];
        end

        function paintPanels(obj)
            m = obj.Model;

            % A zoom panel asked to fill its rectangle needs a wider crop
            % than the shared zoom box.  Grow it ON THE MODEL for the
            % duration of this paint: the display pipeline, the overlays'
            % origin and the image panel's crop rectangle all read
            % ZoomRange, so going through it is the only way none of them
            % can disagree.  It is put back before anything else sees it,
            % including on error.
            undoZoom  = obj.applyFillZoom();
            zoomGuard = onCleanup(undoZoom);

            cache = containers.Map('KeyType', 'double', 'ValueType', 'any');

            for k = 1:numel(obj.panels_)
                P    = obj.panels_{k};
                spec = P.spec;
                switch spec.type
                    case {'image', 'zoom', 'plot', 'volume', 'histogram'}
                        ds = max(1, min(m.NumDatasets, spec.dataset));
                        if ~cache.isKey(ds)
                            cache(ds) = obj.displayFor(ds);
                        end
                        obj.panels_{k} = obj.paintDataPanel(P, cache(ds));
                    case 'title'
                        P.txt.String   = spec.text;
                        P.txt.FontSize = spec.fontSize;
                        P.txt.Color    = spec.color;
                    case 'timelabel'
                        P.txt.String   = obj.timeLabelText(spec);
                        P.txt.FontSize = spec.fontSize;
                        P.txt.Color    = spec.color;
                    case 'scalebar'
                        obj.paintScalebar(P, spec);
                end
            end
        end

        function undo = applyFillZoom(obj)
            % Widen the model's zoom box to the first fill-requesting zoom
            % panel's proportions; returns the function that puts it back.
            undo = @() [];
            m = obj.Model;
            % With a free aspect ratio the panel is stretched to fit anyway,
            % so there is nothing to correct.
            if ~m.AspectRatioFixed, return; end

            spec = [];
            for k = 1:numel(obj.Layout)
                if strcmp(obj.Layout(k).type, 'zoom') && obj.Layout(k).fillZoom
                    spec = obj.Layout(k);  break;
                end
            end
            if isempty(spec), return; end

            r = m.AspectRatio;
            if numel(r) ~= 2, r = [1 1]; end
            [wp, hp] = obj.panelPixels(spec.pos, Inf);
            xd = m.XDim;
            yd = m.YDim;
            saved = m.ZoomRange;
            [xr, yr] = MatVisFrameComposer.growZoomToPanel( ...
                saved(xd, :), saved(yd, :), m.Size(xd), m.Size(yd), r, wp, hp);
            if isequal(xr, saved(xd, :)) && isequal(yr, saved(yd, :))
                return;
            end
            grown = saved;
            grown(xd, :) = xr;
            grown(yd, :) = yr;
            m.ZoomRange = grown;
            undo = @() MatVisFrameComposer.restoreZoom(m, saved);
        end

        function P = paintDataPanel(obj, P, s)
            m    = obj.Model;
            spec = P.spec;

            switch spec.type
                case 'image'
                    rgb    = s.rgbFull;
                    origin = MatVisRender.panelOrigin(m, false);
                case 'zoom'
                    rgb    = s.rgbZoom;
                    origin = MatVisRender.panelOrigin(m, true);
                case 'plot'
                    P = obj.paintPlotPanel(P, s);
                    return;
                case 'volume'
                    P = obj.paintVolumePanel(P, s);
                    return;
                case 'histogram'
                    P = obj.paintHistogramPanel(P, s);
                    return;
            end

            set(P.img, 'CData', rgb);
            [H, W, ~] = size(rgb);
            P.ax.XLim = [0.5, W + 0.5];
            P.ax.YLim = [0.5, H + 0.5];
            obj.applyPanelAspect(P.ax);

            % Crop rectangle (image panel only, and only while zoomed in)
            if spec.overlays.zoomRect && strcmp(spec.type, 'image')
                xd = m.XDim;  yd = m.YDim;
                full = m.ZoomRange(xd,1) <= 1 && m.ZoomRange(xd,2) >= m.Size(xd) && ...
                       m.ZoomRange(yd,1) <= 1 && m.ZoomRange(yd,2) >= m.Size(yd);
                if full
                    P.rect.Visible = 'off';
                else
                    set(P.rect, 'Position', ...
                        [m.ZoomRange(xd,1), m.ZoomRange(yd,1), ...
                         diff(m.ZoomRange(xd,:)), diff(m.ZoomRange(yd,:))], ...
                        'Visible', 'on');
                end
            else
                P.rect.Visible = 'off';
            end

            % Position cross-hair
            if spec.overlays.crosshair
                px = m.CurrPos(m.XDim) - origin(1);
                py = m.CurrPos(m.YDim) - origin(2);
                set(P.posV, 'XData', [px px], 'YData', [0.5, H + 0.5], 'Visible', 'on');
                set(P.posH, 'XData', [0.5, W + 0.5], 'YData', [py py], 'Visible', 'on');
            else
                set([P.posV, P.posH], 'Visible', 'off');
            end

            % ROI / profile overlays — the same painters the windows use.
            if spec.overlays.rois
                P.roiH = MatVisRender.paintRoiOverlay(P.ax, m, origin, P.roiH);
            end
            if spec.overlays.profiles
                P.profH = MatVisRender.paintProfileOverlay(P.ax, m, origin, P.profH);
            end

            obj.paintInImageAnnotations(P, W, H);
        end

        function paintInImageAnnotations(obj, P, W, H)
            % Time label and scale bar drawn in the panel's data coordinates:
            % "axis image" letterboxes the picture inside the panel, so
            % anything anchored to the panel rectangle can end up beside the
            % image rather than on it.
            m    = obj.Model;
            spec = P.spec;
            padX = max(2, 0.025 * W);
            padY = max(2, 0.030 * H);

            if spec.timeDim >= 1 && spec.timeDim <= numel(m.Size)
                ts = spec;  ts.dim = spec.timeDim;
                set(P.tTxt, 'Position', [0.5 + padX, H + 0.5 - padY], ...
                    'String', obj.timeLabelText(ts), 'Color', spec.annotColor, ...
                    'FontSize', spec.annotFontSize, 'Visible', 'on');
            else
                P.tTxt.Visible = 'off';
            end

            if spec.scaleBar
                [barReal, unit, barPix] = obj.scaleBarLength(spec, W);
                x2 = W + 0.5 - padX;
                x1 = x2 - barPix;
                yb = H + 0.5 - padY;
                set(P.sbLine, 'XData', [x1 x2], 'YData', [yb yb], ...
                    'Color', spec.annotColor, ...
                    'LineWidth', max(2, spec.annotFontSize / 3), 'Visible', 'on');
                set(P.sbTxt, 'Position', [(x1 + x2)/2, yb - 0.35*padY], ...
                    'String', sprintf('%g %s', barReal, unit), ...
                    'Color', spec.annotColor, 'FontSize', spec.annotFontSize, ...
                    'Visible', 'on');
            else
                set([P.sbLine, P.sbTxt], 'Visible', 'off');
            end
        end

        function [barReal, unit, barPix] = scaleBarLength(obj, spec, W)
            % Scale bar sized to ~25 % of the visible width, rounded to
            % 1/2/5 x 10^n, expressed in the panel's own pixels.
            m      = obj.Model;
            pxSize = m.pixelSize(m.XDim);
            unit   = m.dimUnit(m.XDim);
            if isempty(pxSize) || ~isfinite(pxSize) || pxSize <= 0
                pxSize = 1;  unit = 'px';
            end
            if spec.length > 0
                barReal = spec.length;
            else
                target = 0.25 * W * pxSize;
                e      = floor(log10(max(target, eps)));
                mant   = target / 10^e;
                if     mant < 1.5, mant = 1;
                elseif mant < 3.5, mant = 2;
                elseif mant < 7.5, mant = 5;
                else,              mant = 10;
                end
                barReal = mant * 10^e;
            end
            barPix = min(0.9 * W, barReal / pxSize);
        end

        function applyPanelAspect(obj, ax)
            m = obj.Model;
            if m.AspectRatioFixed
                r = m.AspectRatio;
                if numel(r) ~= 2, r = [1 1]; end
                ax.DataAspectRatio        = [r(1) r(2) 1];
                ax.PlotBoxAspectRatioMode = 'auto';
            else
                ax.DataAspectRatioMode    = 'auto';
                ax.PlotBoxAspectRatioMode = 'auto';
            end
        end

        function P = paintPlotPanel(obj, P, s)
            m    = obj.Model;
            spec = P.spec;

            % Which dimension to draw: spec.dim when given, else whichever
            % the user has enabled in the main window.
            if spec.dim > 0
                dims = spec.dim;
            else
                dims = find(m.PlotDims);
            end
            dims = dims(dims >= 1 & dims <= numel(m.Size));

            cla(P.ax);
            P.lines = gobjects(1, 0);
            hold(P.ax, 'on');
            P.ax.Color    = obj.BackColor;
            P.ax.FontSize = max(7, round(spec.fontSize * 0.7));

            if isempty(dims), return; end

            d  = dims(1);                 % one dimension per plot panel

            % The display pipeline only fills profiles for dimensions the
            % main window plots.  A movie's plot panel must not depend on
            % which plot windows happen to be open, so compute it here when
            % it is missing.
            if d <= numel(s.profiles) && ~isempty(s.profiles{d})
                pr = s.profiles{d};
            else
                ds     = max(1, min(m.NumDatasets, spec.dataset));
                dsData = m.Datasets{ds};
                if m.PlotLock(d)
                    pr = MatVisRender.renderProfileFromData(m, dsData, d);
                else
                    pr = MatVisRender.renderFullProfileFromData(m, dsData, d);
                end
            end
            if isstruct(pr), y = pr.data; else, y = pr; end
            y = double(y);
            if isempty(y), return; end
            if isvector(y), y = y(:); end

            if m.PlotLock(d)
                x0 = m.ZoomRange(d, 1);
            else
                x0 = 1;
            end
            xIdx = (x0:(x0 + size(y, 1) - 1))';
            xVal = arrayfun(@(i) m.indexToReal(d, i), xIdx);

            cols = lines(max(size(y, 2), 1));
            for c = 1:size(y, 2)
                P.lines(end+1) = plot(P.ax, xVal, y(:, c), '-', ...
                    'Color', cols(c, :), 'LineWidth', 1.2);
            end

            % Marker at the current position along this dimension
            cx = m.indexToReal(d, m.CurrPos(d));

            % A fixed yLim keeps the axis from jumping between frames.  With
            % the default setup it does not: a profile ALONG the swept
            % dimension is independent of the position within it.  It matters
            % when the plotted dimension is not the swept one.
            if numel(spec.yLim) == 2 && spec.yLim(2) > spec.yLim(1)
                yl = double(spec.yLim);
            else
                yl = [min(y(:)), max(y(:))];
                if ~all(isfinite(yl)) || yl(1) == yl(2), yl = [0 1]; end
            end
            P.lines(end+1) = plot(P.ax, [cx cx], yl, '-', ...
                'Color', [0.85 0.33 0.10], 'LineWidth', 1.0);

            xl = [min(xVal), max(xVal)];
            if ~(xl(2) > xl(1)), xl = xl(1) + [0 1]; end
            xlim(P.ax, xl);
            ylim(P.ax, yl);

            % A movie plot panel is short (a fraction of the frame height),
            % so the default tick count overlaps.  Scale it to the space.
            hPix = max(20, spec.pos(4) * obj.FrameSize(2));
            wPix = max(20, spec.pos(3) * obj.FrameSize(1));
            P.ax.YTick = MatVisRender.niceTicks(yl(1), yl(2), max(2, floor(hPix / 42)));
            P.ax.XTick = MatVisRender.niceTicks(xl(1), xl(2), max(2, floor(wPix / 80)));

            xlabel(P.ax, obj.dimLabel(d), 'FontSize', P.ax.FontSize);
            box(P.ax, 'off');
        end

        % ---------------------------------------------------------- volume
        function P = paintVolumePanel(obj, P, s)
            % A projection computed from the data, not a capture of the 3-D
            % window — see MatVisVolumeProjector for why that is the only
            % workable path.  The extracted sub-volume is cached, so orbiting
            % the camera over one volume costs the projection only.
            m     = obj.Model;
            spec  = P.spec;
            ds    = max(1, min(m.NumDatasets, spec.dataset));
            dims3 = obj.volumeDims(spec);

            if isempty(dims3)
                set(P.img, 'CData', zeros(1, 1, 3, 'uint8'));
                set(P.boxLine, 'Visible', 'off');
                set(P.labTxt,  'Visible', 'off');
                return;
            end

            budget = spec.maxVox;
            if ~isscalar(budget) || ~isfinite(budget) || budget <= 0
                budget = Inf;
            end
            [lo, n, strides] = MatVisVolumeView.planSampling( ...
                obj.volumeRanges(spec, dims3), budget);

            cb = double(spec.contrast);
            if numel(cb) ~= 3
                cb = [s.cmin, s.cmax, s.gamma];
            end
            if cb(2) <= cb(1), cb(2) = cb(1) + eps(cb(1)) + 1; end

            other = setdiff(1:numel(m.Size), dims3);
            key   = {ds, dims3, lo, n, strides, m.CurrPos(other), cb};
            if ~isequal(key, P.volKey)
                [V, vox] = MatVisVolumeView.extractVolume(m, m.Datasets{ds}, ...
                    dims3, lo, n, strides, cb(1), cb(2), cb(3));
                P.V      = V;
                P.vox    = vox;
                P.volKey = key;
            end

            [outW, outH] = obj.panelPixels(spec.pos, 900);
            v  = obj.effectiveView(spec);
            ci = spec.cmapIdx;
            if ~(isnumeric(ci) && isscalar(ci) && ci >= 1)
                ci = m.ColormapIdx;
            end
            cmapV = MatVisRender.getColormap(ci, 256);
            pr = MatVisVolumeProjector.project(P.V, P.vox, ...
                'Az', v.az, 'El', v.el, 'Zoom', v.zoom, ...
                'OutSize', [outW outH], 'Style', spec.style, ...
                'Colormap', cmapV);

            % The box and labels lie on the projection, not on the frame
            % background, so they take their colour from what an empty ray
            % projects to: the colormap's bottom for a maximum projection,
            % its top for a minimum one.
            if strcmpi(spec.style, 'min')
                bgv = cmapV(end, :);
            else
                bgv = cmapV(1, :);
            end
            if mean(bgv) < 0.5
                fg = [0.92 0.92 0.92];
            else
                fg = [0.12 0.12 0.12];
            end

            set(P.img, 'CData', pr.img);
            P.ax.XLim = [0.5, size(pr.img, 2) + 0.5];
            P.ax.YLim = [0.5, size(pr.img, 1) + 0.5];
            P.ax.DataAspectRatio        = [1 1 1];
            P.ax.PlotBoxAspectRatioMode = 'auto';

            if spec.box
                set(P.boxLine, 'XData', pr.boxX, 'YData', pr.boxY, ...
                    'Color', fg, 'Visible', 'on');
            else
                P.boxLine.Visible = 'off';
            end

            for k = 1:3
                lp = pr.labelPos(k);
                if spec.showLabels && lp.visible
                    set(P.labTxt(k), 'Position', [lp.x, lp.y], ...
                        'String', obj.dimLabel(dims3(k)), 'Color', fg, ...
                        'FontSize', max(7, round(spec.annotFontSize * 0.85)), ...
                        'HorizontalAlignment', lp.align, ...
                        'VerticalAlignment', lp.valign, 'Visible', 'on');
                else
                    P.labTxt(k).Visible = 'off';
                end
            end

            % A time label works here (it reports a dimension, not a
            % geometry); a scale bar does not, because an oblique projection
            % has no single pixel size — the caller keeps it off.
            obj.paintInImageAnnotations(P, size(pr.img, 2), size(pr.img, 1));
        end

        function d = volumeDims(obj, spec)
            % Three distinct dimensions of this dataset, or [] when the data
            % has fewer than three.
            n = numel(obj.Model.Size);
            d = round(double(spec.dims3(:)'));
            if numel(d) ~= 3 || any(d < 1) || any(d > n) || numel(unique(d)) < 3
                if n < 3, d = [];  return; end
                d = MatVisFrameComposer.defaultDims3(obj.Model);
            end
            if numel(unique(d)) < 3, d = []; end
        end

        function r = volumeRanges(obj, spec, dims3)
            m = obj.Model;
            switch lower(spec.extent)
                case 'zoom'
                    r = m.ZoomRange(dims3(:), :);
                case 'custom'
                    r = spec.ranges;
                    if ~isequal(size(r), [3 2])
                        r = [ones(3, 1), reshape(m.Size(dims3), [], 1)];
                    end
                otherwise
                    r = [ones(3, 1), reshape(m.Size(dims3), [], 1)];
            end
            r = double(r);
            for k = 1:3
                N = m.Size(dims3(k));
                r(k, 1) = max(1, min(round(r(k, 1)), N));
                r(k, 2) = max(r(k, 1), min(round(r(k, 2)), N));
            end
        end

        function v = effectiveView(obj, spec)
            % The panel's own camera, overridden by View3D where it is set.
            v = struct('az', spec.az, 'el', spec.el, 'zoom', spec.zoom);
            o = obj.View3D;
            if isstruct(o) && isscalar(o)
                for f = {'az', 'el', 'zoom'}
                    if isfield(o, f{1}) && isscalar(o.(f{1})) && isfinite(o.(f{1}))
                        v.(f{1}) = double(o.(f{1}));
                    end
                end
            end
            v.el = max(-89, min(89, v.el));
            if ~(v.zoom > 0), v.zoom = 1; end
        end

        % ------------------------------------------------------- histogram
        function P = paintHistogramPanel(obj, P, s)
            % The same three fills the main window shows (whole dataset,
            % current image, current zoom crop) plus the contrast window,
            % the gamma curve and the resulting colour ramp.
            m    = obj.Model;
            spec = P.spec;
            ds   = max(1, min(m.NumDatasets, spec.dataset));

            [lo, hi] = obj.histLimits(spec, s, ds);
            nBins = 100;
            edges = linspace(lo, hi, nBins + 1);
            bw    = edges(2) - edges(1);
            ctrs  = edges(1:end-1) + bw/2;

            logY  = logical(spec.histLog);
            yBase = 0;
            if logY, yBase = 1e-3; end
            yMax  = 1;
            P.ax.FontSize = max(7, round(spec.fontSize * 0.7));

            % Whole-dataset counts do not change while a dimension is swept,
            % so one pass over the dataset serves the entire movie.
            normG = [];
            if isempty(s.chanRange)
                gk = {ds, lo, hi};
                if ~isequal(gk, P.globKey)
                    P.globCounts = histcounts(m.Datasets{ds}(:), edges);
                    P.globKey    = gk;
                end
                normG = P.globCounts / max([max(P.globCounts), 1]);
            end
            MatVisFrameComposer.setHistFill(P.fillG, ctrs, bw, normG, yBase);

            for spc = {{P.fillI, s.srcFull}, {P.fillZ, s.srcZoom}}
                h = spc{1}{1};  d = spc{1}{2};
                if isempty(d) || ~isnumeric(d)
                    set(h, 'Visible', 'off');
                    continue;
                end
                c = histcounts(d(:), edges);
                MatVisFrameComposer.setHistFill(h, ctrs, bw, ...
                    c / max([max(c), 1]), yBase);
            end

            cmin = double(s.cmin);
            cmax = double(s.cmax);
            gam  = double(s.gamma);
            yBot = max(yBase, eps);
            set(P.lineMin, 'XData', [cmin cmin], 'YData', [yBot yMax]);
            set(P.lineMax, 'XData', [cmax cmax], 'YData', [yBot yMax]);

            xg = linspace(cmin, cmax, 100);
            if cmax > cmin
                yg = ((xg - cmin) / (cmax - cmin)) .^ gam * yMax;
            else
                yg = zeros(1, 100);
            end
            set(P.gammaLine, 'XData', xg, 'YData', max(yg, yBase), ...
                'Color', obj.foreColor());

            % Colour ramp under the axis: the mapping the movie actually uses.
            cbH = 0.15 * yMax;
            nC  = 256;
            if MatVisRender.rgbActive(m)
                ci = 1;                  % RGB display bypasses the colormap
            else
                ci = m.ColormapIdx;
            end
            cmap = MatVisRender.getColormap(ci, nC);
            t    = max(0, min(1, (linspace(lo, hi, nC) - cmin) ./ ...
                                 max(cmax - cmin, eps))) .^ gam;
            idx  = max(1, min(nC, round(t * (nC - 1)) + 1));
            set(P.cbImg, 'XData', [lo hi], ...
                'CData', repmat(reshape(cmap(idx, :), [1 nC 3]), 2, 1, 1));

            if logY
                f     = cbH / (cbH + yMax);
                cbTop = yBase;
                cbBot = 10 ^ ((log10(yBase) - f * log10(yMax * 1.1)) / (1 - f));
                % Positive limits first, then the scale — a log axis rejects
                % the linear range it currently holds.
                P.ax.YLim   = [cbBot, yMax * 1.1];
                P.ax.YScale = 'log';
            else
                cbBot = -cbH;
                cbTop = 0;
                P.ax.YScale = 'linear';
                P.ax.YLim   = [cbBot, yMax];
            end
            set(P.cbImg, 'YData', ...
                [(3*cbBot + cbTop)/4, (3*cbTop + cbBot)/4]);

            P.ax.XLim  = [lo hi];
            wPix       = max(20, spec.pos(3) * obj.FrameSize(1));
            P.ax.XTick = MatVisRender.niceTicks(lo, hi, max(2, floor(wPix / 90)));
            P.ax.XColor = obj.foreColor();
            box(P.ax, 'off');
        end

        function [lo, hi] = histLimits(obj, spec, s, ds)
            m = obj.Model;
            r = spec.histRange;
            if numel(r) == 2 && r(2) > r(1)
                lo = double(r(1));
                hi = double(r(2));
                return;
            end
            % The live panel's own axis, when a caller offers it.  Taken as
            % given — not widened to the contrast window below — because the
            % point is to match the main window frame for frame.
            if ~isempty(obj.HistRangeFcn)
                try
                    r = obj.HistRangeFcn();
                catch
                    r = [];
                end
                if numel(r) == 2 && r(2) > r(1)
                    lo = double(r(1));
                    hi = double(r(2));
                    return;
                end
            end
            if ~isempty(s.chanRange)
                % The equalizing RGB modes hand the pipeline channels already
                % mapped onto [0,1], so the dataset's own range is no longer
                % the axis the contrast window lives on.
                lo = 0;  hi = 1;
            else
                lo = double(m.AllDataMins(ds));
                hi = double(m.AllDataMaxs(ds));
            end
            % Always include the contrast window, or dragging it outside the
            % data range would move the lines off the panel.
            lo = min(lo, double(s.cmin));
            hi = max(hi, double(s.cmax));
            if ~(hi > lo), hi = lo + 1; end
        end

        % ------------------------------------------------------------ misc
        function c = foreColor(obj)
            % Lines and text that sit on the frame background rather than on
            % an image, so they must contrast with whichever the user chose.
            if mean(obj.BackColor) < 0.5
                c = [0.92 0.92 0.92];
            else
                c = [0.12 0.12 0.12];
            end
        end

        function c = histShade(obj, lightness)
            % LIGHTNESS runs 0 (dark) .. 1 (light) for a white background;
            % on a dark one the ramp is inverted so the three fills stay
            % distinguishable and visible either way.
            if mean(obj.BackColor) < 0.5
                v = 0.25 + 0.7 * (1 - lightness);
            else
                v = lightness;
            end
            c = [v v v];
        end

        function [w, h] = panelPixels(obj, pos, cap)
            % The panel's size in output pixels, capped so a full-frame 3-D
            % panel cannot make the projection's cost run away.
            w  = max(16, round(pos(3) * obj.FrameSize(1)));
            h  = max(16, round(pos(4) * obj.FrameSize(2)));
            sc = min(1, cap / max(w, h));
            w  = max(16, round(w * sc));
            h  = max(16, round(h * sc));
        end

        function paintScalebar(obj, P, spec)
            m  = obj.Model;
            xd = m.XDim;

            % Panel width in data pixels: the scalebar sits under an image
            % panel, so use the zoom extent when one exists.
            nPix = diff(m.ZoomRange(xd, :)) + 1;
            if nPix <= 1, nPix = m.Size(xd); end

            pxSize = m.pixelSize(xd);
            unit   = m.dimUnit(xd);
            if isempty(pxSize) || ~isfinite(pxSize) || pxSize <= 0
                pxSize = 1;  unit = 'px';
            end

            if spec.length > 0
                barReal = spec.length;
            else
                % Round ~25 % of the visible width to 1/2/5×10^n.
                target  = 0.25 * nPix * pxSize;
                e       = floor(log10(max(target, eps)));
                mant    = target / 10^e;
                if     mant < 1.5, mant = 1;
                elseif mant < 3.5, mant = 2;
                elseif mant < 7.5, mant = 5;
                else,              mant = 10;
                end
                barReal = mant * 10^e;
            end

            frac = min(0.9, barReal / (nPix * pxSize));   % of the panel width
            x1   = 0.5 - frac/2;
            set(P.bar, 'XData', [x1, x1 + frac], 'Color', spec.color, ...
                'LineWidth', max(2, spec.fontSize / 3));
            set(P.barTxt, 'String', sprintf('%g %s', barReal, unit), ...
                'FontSize', spec.fontSize, 'Color', spec.color);
        end

        function s = timeLabelText(obj, spec)
            m = obj.Model;
            d = spec.dim;
            if d < 1 || d > numel(m.Size), s = ''; return; end
            name = m.DimNames{d};
            val  = m.indexToReal(d, m.CurrPos(d));
            unit = m.dimUnit(d);
            if isempty(spec.format)
                if isempty(unit)
                    s = sprintf('%s = %.4g', name, val);
                else
                    s = sprintf('%s = %.4g %s', name, val, unit);
                end
            else
                s = sprintf(spec.format, name, val, unit);
            end
        end

        function lbl = dimLabel(obj, d)
            m    = obj.Model;
            unit = m.dimUnit(d);
            if isempty(unit)
                lbl = m.DimNames{d};
            else
                lbl = sprintf('%s (%s)', m.DimNames{d}, unit);
            end
        end

        function s = displayFor(obj, ds)
            if ~isempty(obj.DisplayFcn)
                s = obj.DisplayFcn(ds);
                return;
            end
            s = MatVisFrameComposer.standaloneDisplay(obj.Model, ds);
        end

        function rgb = grab(obj)
            % getframe is the fast path (measured ~3× print at 1080p) and is
            % occlusion-safe here; print is the fallback if it ever returns
            % nothing usable.
            rgb = [];
            try
                fr = getframe(obj.Fig);
                rgb = fr.cdata;
            catch
            end
            if isempty(rgb)
                rgb = print(obj.Fig, '-RGBImage', '-r0');
            end
            rgb = MatVisFrameComposer.fitTo(rgb, obj.FrameSize, obj.BackColor);
        end

        function teardown(obj)
            try
                if ~isempty(obj.Fig) && isvalid(obj.Fig), delete(obj.Fig); end
            catch
            end
            obj.Fig     = [];
            obj.panels_ = {};
            obj.built_  = false;
        end
    end

    % ------------------------------------------------------------------
    methods (Static, Access = private)

        function restoreZoom(model, zr)
            try
                model.ZoomRange = zr;
            catch
            end
        end

        function setHistFill(h, centers, bw, counts, baseline)
            % Staircase outline of one histogram, as a filled polygon.
            if isempty(counts) || all(counts == 0) || ~any(isfinite(counts))
                set(h, 'Visible', 'off');
                return;
            end
            nB    = numel(centers);
            xL    = centers - bw/2;
            xR    = centers + bw/2;
            yVals = max(counts(:)', baseline);
            xStep = reshape([xL; xR], 1, 2*nB);
            yStep = reshape([yVals; yVals], 1, 2*nB);
            set(h, 'XData', [xL(1), xStep, xR(end)], ...
                   'YData', [baseline, yStep, baseline], 'Visible', 'on');
        end

        function rgb = fitTo(rgb, sz, bg)
            % Crop / pad the grab to exactly [W H].  Rounding the figure size
            % by the device scale can be off by a pixel; letting that reach
            % VideoWriter would abort the movie on frame 2.
            W = sz(1);  H = sz(2);
            [h, w, ~] = size(rgb);
            if h == H && w == W, return; end

            out = repmat(reshape(uint8(round(255 * bg(:)')), 1, 1, 3), H, W);
            hh  = min(h, H);  ww = min(w, W);
            out(1:hh, 1:ww, :) = rgb(1:hh, 1:ww, :);
            rgb = out;
        end

        function s = standaloneDisplay(model, ds)
            % Headless fallback for the display pipeline: what the windows
            % would show, minus the percentile fields that live in the UI.
            data     = model.Datasets{ds};
            raw_full = MatVisRender.getRawFullSliceFromData(model, data);
            raw_zoom = MatVisRender.getRawSliceFromData(model, data);

            [cmin, cmax] = MatVisFrameComposer.boundsFor(model, ds, raw_full, raw_zoom);
            gamma = model.Gamma;
            if ~model.ContrastLocked && numel(model.DatasetGammas) >= ds
                gamma = model.DatasetGammas(ds);
            end

            if MatVisRender.rgbActive(model)
                chanRange = MatVisRender.channelRangeFromStack(raw_full, 0, 1);
                src_full  = MatVisRender.normalizeChannels(raw_full, chanRange);
                src_zoom  = MatVisRender.normalizeChannels(raw_zoom, chanRange);
            else
                chanRange = [];
                src_full  = raw_full;
                src_zoom  = raw_zoom;
            end

            if MatVisRender.stretchActive(model)
                rgbFull = MatVisRender.renderStretchImage(model, src_full, cmin, cmax, gamma);
                rgbZoom = MatVisRender.renderStretchImage(model, src_zoom, cmin, cmax, gamma);
            else
                dFull = MatVisRender.filterImage(src_full, model.FilterType, model.FilterPar);
                dZoom = MatVisRender.filterImage(src_zoom, model.FilterType, model.FilterPar);
                rgbFull = MatVisRender.composeImage( ...
                    MatVisRender.normalizeData(dFull, cmin, cmax), gamma, model.ColormapIdx);
                rgbZoom = MatVisRender.composeImage( ...
                    MatVisRender.normalizeData(dZoom, cmin, cmax), gamma, model.ColormapIdx);
            end

            nDims    = numel(model.Size);
            profiles = cell(1, nDims);
            for ii = 1:nDims
                if model.PlotDims(ii)
                    if model.PlotLock(ii)
                        profiles{ii} = MatVisRender.renderProfileFromData(model, data, ii);
                    else
                        profiles{ii} = MatVisRender.renderFullProfileFromData(model, data, ii);
                    end
                end
            end

            s = struct('rgbFull', rgbFull, 'rgbZoom', rgbZoom, ...
                       'cmin', cmin, 'cmax', cmax, 'gamma', gamma, ...
                       'chanRange', chanRange, 'srcFull', src_full, ...
                       'srcZoom', src_zoom, 'rawFull', raw_full, ...
                       'profiles', {profiles});
        end

        function [cmin, cmax] = boundsFor(model, ds, raw_full, raw_zoom)
            if MatVisRender.rgbActive(model)
                cmin = model.RGBContrastRange(1);
                cmax = model.RGBContrastRange(2);
                return;
            end
            dmin = model.AllDataMins(ds);
            dmax = model.AllDataMaxs(ds);
            switch model.ContrastMode
                case 'Manual'
                    if model.ContrastLocked && ds == model.ActiveDataset
                        cmin = model.ContrastMin;  cmax = model.ContrastMax;
                    else
                        cmin = model.DatasetContrastMins(ds);
                        cmax = model.DatasetContrastMaxs(ds);
                    end
                case 'Image'
                    cmin = double(min(raw_full(:)));  cmax = double(max(raw_full(:)));
                case 'Zoom'
                    cmin = double(min(raw_zoom(:)));  cmax = double(max(raw_zoom(:)));
                otherwise
                    cmin = dmin;  cmax = dmax;
            end
            if ~isfinite(cmin) || ~isfinite(cmax), cmin = dmin; cmax = dmax; end
            if cmin >= cmax
                cmax = cmin + max(1, abs(cmin) * eps * 1e6);
            end
        end
    end
end
