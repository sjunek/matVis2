classdef MatVisVolumeView < handle
%MatVisVolumeView  One rotatable 3-D view of a sub-volume.
%
%   vv = MatVisVolumeView(parent)
%
%   Builds the Image Processing Toolbox volume renderer (a viewer3d) inside
%   PARENT when one is available, and a toolbox-free fallback otherwise: the
%   three axis-aligned maximum projections are cached and the one facing the
%   camera is texture-mapped onto the far face of the bounding box, so
%   rotating the box keeps showing a projection from (approximately) the
%   current viewing direction.
%
%   Volume data
%     vv.setVolume(V, voxSize)   V is uint8 in the caller's dimension order
%                                (i, j, k) -> (dim1, dim2, dim3); voxSize is
%                                the real-world size of one voxel along each
%                                of those dims.
%     [V, voxSize] = MatVisVolumeView.extractVolume(...)  builds such a
%                                volume from a matVis model.
%
%   Look       Style, Colormap, Alphamap, IsoValue, GradientOpacityValue,
%              Labels -- change any of them, then call applyLook().
%
%   Camera     cameraAngles / setCameraAngles / cameraZoom / setCameraZoom /
%              resetCamera / setProjection / pan / zoomAtCursor.
%              All of them work on both backends.
%
%   Mouse      A viewer3d handles pointer and wheel events inside its own
%              canvas and none of them reach the figure, so the owner must
%              only drive the fallback backend from figure callbacks -- ask
%              isViewer3D() first.  Set PointerFcn to a function returning
%              the pointer position in figure pixels (fig.CurrentPoint goes
%              stale over a viewer3d); it is needed for zoom-about-cursor.
%
%   See also MatVisXSecWin, MatVis3DWin.

    properties (SetAccess = private)
        Backend = 'none'      % 'viewer3d' | 'axes' | 'none'
        Viewer  = []          % viewer3d, when Backend is 'viewer3d'
        VolObj  = []          % images.ui.graphics.Volume
        Ax3     = []          % uiaxes, when Backend is 'axes'
    end

    properties
        Style      = 'MaximumIntensityProjection'
        Colormap   = []       % N×3 in [0 1]
        Alphamap   = ones(256, 1)
        IsoValue   = 0.15
        GradientOpacityValue = 0.3
        Labels     = {'X', 'Y', 'Z'}
        PointerFcn = []       % @() [x y] in figure pixels
        CameraMovedFcn = []   % @() the camera has moved (after our own fix-up)
    end

    properties (Access = private)
        Cell_      = []
        Holder_    = []
        Surf3_     = []
        Vol_       = []       % last volume, caller's dim order
        VoxSize_   = [1 1 1]
        Mip_       = {}       % cached face projections (fallback only)
        MipExtent_ = [1 1 1]
        MipFace_   = 0
        CamPrev_   = []
        CamBusy_   = false    % guards onCameraMoved against our own writes
    end

    methods
        function obj = MatVisVolumeView(parent)
            obj.Colormap = gray(256);
            % A grid layout of its own, so the backend can be rebuilt into a
            % *fresh* uipanel: re-using one leaves the web renderer with a
            % stale slot and the new component comes up blank.
            obj.Cell_ = uigridlayout(parent, [1 1]);
            obj.Cell_.Padding       = [0 0 0 0];
            obj.Cell_.RowSpacing    = 0;
            obj.Cell_.ColumnSpacing = 0;
            obj.build();
        end

        function delete(obj)
            if ~isempty(obj.Cell_) && isvalid(obj.Cell_)
                delete(obj.Cell_);
            end
        end

        function tf = isViewer3D(obj)
            tf = strcmp(obj.Backend, 'viewer3d') && ...
                 ~isempty(obj.Viewer) && isvalid(obj.Viewer);
        end

        function tf = isReady(obj)
            tf = obj.isViewer3D() || ...
                 (~isempty(obj.Ax3) && isvalid(obj.Ax3));
        end

        % ---------------------------------------------------------- data
        function setVolume(obj, V, voxSize)
            % Push a volume into the backend.  Falls back permanently to the
            % toolbox-free renderer when volshow refuses the volume.
            if nargin < 3 || isempty(voxSize), voxSize = [1 1 1]; end
            obj.Vol_     = V;
            obj.VoxSize_ = voxSize(:).';
            if obj.isViewer3D()
                if obj.pushVolshow(), return; end
                MatVisVolumeView.volshowBroken(true);
                obj.build();
            end
            obj.pushFallback();
        end

        function applyLook(obj)
            % Push style / colormap / alphamap / isovalue to the backend.
            if isempty(obj.Vol_), return; end
            if obj.isViewer3D()
                obj.pushVolshow();
            else
                obj.pushFallback();
            end
        end

        % -------------------------------------------------------- camera
        function [az, el] = cameraAngles(obj)
            az = NaN;  el = NaN;
            if obj.isViewer3D()
                try
                    d = double(obj.Viewer.CameraPosition(:)).' - ...
                        double(obj.Viewer.CameraTarget(:)).';
                catch
                    return;
                end
                n = norm(d);
                if ~isfinite(n) || n <= 0, return; end
                d  = d / n;
                el = asind(max(-1, min(1, d(3))));
                az = atan2d(d(1), -d(2));
            elseif ~isempty(obj.Ax3) && isvalid(obj.Ax3)
                [az, el] = view(obj.Ax3);
            end
        end

        function setCameraAngles(obj, az, el)
            el = max(-89, min(89, el));
            if obj.isViewer3D()
                v = obj.Viewer;
                try
                    T = double(v.CameraTarget(:)).';
                    C = double(v.CameraPosition(:)).';
                catch
                    return;
                end
                dist = norm(T - C);
                if ~isfinite(dist) || dist <= 0, return; end
                a = az * pi/180;  e = el * pi/180;
                dir = [sin(a)*cos(e), -cos(a)*cos(e), sin(e)];
                up  = [-sin(a)*sin(e), cos(a)*sin(e), cos(e)];
                obj.CamBusy_ = true;
                try
                    v.CameraPosition = T + dist * dir;
                    v.CameraUpVector = up;
                catch
                end
                obj.CamBusy_ = false;
                obj.CamPrev_ = MatVisVolumeView.readCam(v);
            elseif ~isempty(obj.Ax3) && isvalid(obj.Ax3)
                view(obj.Ax3, az, el);
                obj.placeMipFace();
            end
        end

        function z = cameraZoom(obj)
            z = 1;
            if obj.isViewer3D()
                try; z = double(obj.Viewer.CameraZoom); catch; end
            end
        end

        function setCameraZoom(obj, z)
            if ~isfinite(z) || z <= 0, return; end
            if obj.isViewer3D()
                obj.CamBusy_ = true;
                try; obj.Viewer.CameraZoom = z; catch; end
                obj.CamBusy_ = false;
                obj.CamPrev_ = MatVisVolumeView.readCam(obj.Viewer);
            end
        end

        function resetCamera(obj)
            if obj.isViewer3D()
                obj.CamBusy_ = true;
                try
                    obj.Viewer.CameraZoomMode     = 'auto';
                    obj.Viewer.CameraTargetMode   = 'auto';
                    obj.Viewer.CameraPositionMode = 'auto';
                    obj.Viewer.CameraUpVectorMode = 'auto';
                catch
                end
                obj.CamBusy_ = false;
                obj.CamPrev_ = [];
            elseif ~isempty(obj.Ax3) && isvalid(obj.Ax3)
                camva(obj.Ax3, 'auto');
                camtarget(obj.Ax3, 'auto');
                campos(obj.Ax3, 'auto');
                view(obj.Ax3, -37.5, 30);
                obj.placeMipFace();
            end
        end

        function setProjection(obj, mode)
            % 'orthographic' | 'perspective'
            if obj.isViewer3D()
                try; obj.Viewer.CameraProjection = mode; catch; end
            elseif ~isempty(obj.Ax3) && isvalid(obj.Ax3)
                try; obj.Ax3.Projection = mode; catch; end
            end
        end

        function setBackground(obj, color)
            if obj.isViewer3D()
                try; obj.Viewer.BackgroundColor = color; catch; end
            elseif ~isempty(obj.Ax3) && isvalid(obj.Ax3)
                obj.Ax3.Color = color;
                fg = [1 1 1] - MatVisVolumeView.rgbOf(color);
                set([obj.Ax3.XAxis, obj.Ax3.YAxis, obj.Ax3.ZAxis], 'Color', fg);
                obj.Ax3.Title.Color = fg;
            end
        end

        function setBoxVisible(obj, tf)
            s = MatVisVolumeView.onOff(tf);
            if obj.isViewer3D()
                try; obj.Viewer.Box = s; catch; end
            elseif ~isempty(obj.Ax3) && isvalid(obj.Ax3)
                box(obj.Ax3, s);
                grid(obj.Ax3, s);
                set([obj.Ax3.XAxis, obj.Ax3.YAxis, obj.Ax3.ZAxis], 'Visible', s);
            end
        end

        function setOrientationAxes(obj, tf)
            if obj.isViewer3D()
                try; obj.Viewer.OrientationAxes = MatVisVolumeView.onOff(tf); catch; end
            end
        end

        function pan(obj, dPix)
            % Drag the volume by dPix = [dx dy] figure pixels.
            if obj.isViewer3D()
                v = obj.Viewer;
                [ok, T, C, ~, right, up_, halfW, halfH] = obj.viewerFrame();
                if ~ok, return; end
                pp = getpixelposition(v, true);
                % Move the camera against the drag, so the volume follows it.
                d = -right * (2 * halfW * dPix(1) / max(pp(3), 1)) ...
                    - up_  * (2 * halfH * dPix(2) / max(pp(4), 1));
                obj.CamBusy_ = true;
                try
                    v.CameraTarget   = T + d;
                    v.CameraPosition = C + d;
                catch
                end
                obj.CamBusy_ = false;
                obj.CamPrev_ = MatVisVolumeView.readCam(v);
            elseif ~isempty(obj.Ax3) && isvalid(obj.Ax3)
                camdolly(obj.Ax3, -dPix(1), -dPix(2), 0, 'movetarget', 'pixels');
            end
        end

        function zoomAtCursor(obj, factor)
            % factor > 1 zooms out (same convention as the wheel handlers).
            if ~isfinite(factor) || factor <= 0, return; end
            if obj.isViewer3D()
                obj.setCameraZoom(obj.cameraZoom() / factor);
                obj.recentreOnCursor(factor);
            elseif ~isempty(obj.Ax3) && isvalid(obj.Ax3)
                % Magnify, then dolly so that whatever was under the cursor
                % stays there.
                m  = 1 / factor;
                pp = getpixelposition(obj.Ax3, true);
                pt = obj.pointer();
                if isempty(pt), pt = [pp(1) + pp(3)/2, pp(2) + pp(4)/2]; end
                ox = pt(1) - (pp(1) + pp(3)/2);
                oy = pt(2) - (pp(2) + pp(4)/2);
                camzoom(obj.Ax3, m);
                camdolly(obj.Ax3, ox * (m - 1), oy * (m - 1), 0, ...
                         'movetarget', 'pixels');
            end
        end
    end

% =========================================================================
%  Construction
% =========================================================================
    methods (Access = private)
        function build(obj)
            if ~isempty(obj.Holder_) && isvalid(obj.Holder_)
                delete(obj.Holder_);
            end
            obj.Viewer = [];  obj.VolObj = [];  obj.Ax3 = [];
            obj.Surf3_ = [];  obj.Mip_ = {};    obj.MipFace_ = 0;
            obj.CamPrev_ = [];
            obj.Backend  = 'none';
            obj.Holder_  = uipanel(obj.Cell_, 'BorderType', 'none');

            if ~MatVisVolumeView.volshowBroken() && ...
                    ~isempty(which('viewer3d')) && ~isempty(which('volshow'))
                try
                    v = viewer3d('Parent', obj.Holder_);
                    try; v.BackgroundColor    = 'black'; catch; end
                    try; v.BackgroundGradient = 'off';   catch; end
                    try; v.Lighting           = 'off';   catch; end
                    % Every mouse event over a viewer3d belongs to the viewer
                    % (see the class help), so leave all of its own gestures on.
                    try; v.Interactions = "all"; catch; end
                    try; v.CameraMovedFcn = @(~, ~) obj.onCameraMoved(); catch; end
                    obj.Viewer  = v;
                    obj.Backend = 'viewer3d';
                    return;
                catch
                    MatVisVolumeView.volshowBroken(true);
                    try; delete(obj.Holder_.Children); catch; end
                end
            end
            obj.buildFallback();
        end

        function buildFallback(obj)
            ax3 = uiaxes('Parent', obj.Holder_, 'Units', 'normalized');
            try
                ax3.PositionConstraint = 'outerposition';
                ax3.OuterPosition      = [0 0 1 1];
            catch
                ax3.Position = [0.13 0.13 0.84 0.82];
            end
            disableDefaultInteractivity(ax3);
            try; ax3.Toolbar = []; catch; end
            ax3.FontSize = 8;
            ax3.Color    = 'k';
            view(ax3, -37.5, 30);
            grid(ax3, 'on');
            box(ax3, 'on');
            ax3.Title.String     = '3D projection (drag to rotate)';
            ax3.Title.FontSize   = 9;
            ax3.Title.FontWeight = 'normal';
            s = surface(ax3, zeros(2), zeros(2), zeros(2), ...
                'FaceColor', 'texturemap', 'EdgeColor', 'none', 'Visible', 'off');
            s.HitTest = 'off';  s.PickableParts = 'none';
            obj.Ax3     = ax3;
            obj.Surf3_  = s;
            obj.Backend = 'axes';
        end

% =========================================================================
%  Rendering
% =========================================================================
        function ok = pushVolshow(obj)
            % Data order for volshow is (row, column, page) = (Y, X, Z), so
            % the dims-order volume is permuted; voxel spacing is applied as
            % a scaling transformation.
            ok    = false;
            Vv    = permute(obj.Vol_, [2 1 3]);
            tform = MatVisVolumeView.scaleTform(obj.VoxSize_);
            cmap  = obj.cmap256();
            amap  = obj.amap256();

            % Update in place when possible -- recreating the Volume object
            % on every frame is what makes a live 3-D view unaffordable.
            if ~isempty(obj.VolObj) && isvalid(obj.VolObj)
                try
                    obj.VolObj.Data = Vv;
                    if ~isempty(tform)
                        obj.VolObj.Transformation = tform;
                    end
                    obj.VolObj.Colormap = cmap;
                    try; obj.VolObj.Alphamap = amap; catch; end
                    obj.applyStyleTo(obj.VolObj);
                    ok = true;
                    return;
                catch
                    % e.g. a size change the object won't take -- start over.
                    try; delete(obj.VolObj); catch; end
                    obj.VolObj = [];
                end
            end

            try
                args = {'Parent', obj.Viewer, ...
                        'RenderingStyle', obj.Style, ...
                        'Colormap', cmap, 'Alphamap', amap};
                if ~isempty(tform)
                    args = [args, {'Transformation', tform}];
                end
                obj.VolObj = volshow(Vv, args{:});
                obj.applyStyleTo(obj.VolObj);
                ok = true;
            catch
                obj.VolObj = [];
            end
        end

        function applyStyleTo(obj, vol)
            try; vol.RenderingStyle = obj.Style; catch; end
            try; vol.IsosurfaceValue = obj.IsoValue; catch; end
            try; vol.GradientOpacityValue = obj.GradientOpacityValue; catch; end
        end

        function pushFallback(obj)
            % Toolbox-free 3-D view: cache the three axis-aligned
            % projections, then texture-map the one facing the camera onto
            % the far face of the bounding box.
            if isempty(obj.Ax3) || ~isvalid(obj.Ax3) || isempty(obj.Vol_), return; end
            vd = double(obj.Vol_);
            if strcmp(obj.Style, 'MinimumIntensityProjection')
                pZ = min(vd, [], 3);
                pY = squeeze(min(vd, [], 2));
                pX = squeeze(min(vd, [], 1));
            else
                pZ = max(vd, [], 3);              % (d1, d2)
                pY = squeeze(max(vd, [], 2));     % (d1, d3)
                pX = squeeze(max(vd, [], 1));     % (d2, d3)
            end
            obj.Mip_ = { obj.colorize(pX.'), ...   % rows d3, cols d2
                         obj.colorize(pY.'), ...   % rows d3, cols d1
                         obj.colorize(pZ.') };     % rows d2, cols d1
            obj.MipExtent_ = size(obj.Vol_, 1:3) .* obj.VoxSize_;

            ax3 = obj.Ax3;
            ext = obj.MipExtent_;
            ax3.XLim = [0, max(ext(1), eps)];
            ax3.YLim = [0, max(ext(2), eps)];
            ax3.ZLim = [0, max(ext(3), eps)];
            ax3.DataAspectRatio = [1 1 1];
            ax3.XLabel.String = obj.Labels{1};
            ax3.YLabel.String = obj.Labels{2};
            ax3.ZLabel.String = obj.Labels{3};
            obj.MipFace_ = 0;
            obj.placeMipFace();
        end

        function placeMipFace(obj)
            % Draw the cached projection that faces the camera onto the far
            % side of the bounding box.
            if isempty(obj.Mip_) || isempty(obj.Ax3) || ~isvalid(obj.Ax3), return; end
            [az, el] = view(obj.Ax3);
            a = az * pi/180;  e = el * pi/180;
            camDir = [sin(a)*cos(e), -cos(a)*cos(e), sin(e)];   % target -> camera
            [~, axIdx] = max(abs(camDir));
            far = camDir(axIdx) > 0;    % camera on the + side -> plane at the min end
            faceCode = axIdx * 2 - double(far);
            if faceCode == obj.MipFace_, return; end
            obj.MipFace_ = faceCode;

            ext = obj.MipExtent_;
            img = obj.Mip_{axIdx};
            if far, c = 0; else, c = ext(axIdx); end
            switch axIdx
                case 1   % plane x = c, image rows = d3, cols = d2
                    X = [c c; c c];
                    Y = [0 ext(2); 0 ext(2)];
                    Z = [0 0; ext(3) ext(3)];
                case 2   % plane y = c, image rows = d3, cols = d1
                    X = [0 ext(1); 0 ext(1)];
                    Y = [c c; c c];
                    Z = [0 0; ext(3) ext(3)];
                otherwise % plane z = c, image rows = d2, cols = d1
                    X = [0 ext(1); 0 ext(1)];
                    Y = [0 0; ext(2) ext(2)];
                    Z = [c c; c c];
            end
            set(obj.Surf3_, 'XData', X, 'YData', Y, 'ZData', Z, ...
                'CData', img, 'FaceColor', 'texturemap', 'Visible', 'on');
        end

        function rgb = colorize(obj, m)
            % Map a uint8-valued projection through the current colormap.
            lut = obj.cmap256();
            idx = double(m) + 1;
            rgb = uint8(255 * reshape(lut(idx(:), :), [size(m), 3]));
        end

        function c = cmap256(obj)
            c = obj.Colormap;
            if isempty(c) || size(c, 2) ~= 3
                c = gray(256);
            elseif size(c, 1) ~= 256
                x = linspace(1, size(c, 1), 256).';
                c = [interp1(1:size(c,1), c(:,1), x), ...
                     interp1(1:size(c,1), c(:,2), x), ...
                     interp1(1:size(c,1), c(:,3), x)];
            end
            c = max(0, min(1, c));
        end

        function a = amap256(obj)
            a = obj.Alphamap(:);
            if isempty(a)
                a = ones(256, 1);
            elseif numel(a) ~= 256
                a = interp1(linspace(0, 1, numel(a)).', a, ...
                            linspace(0, 1, 256).');
            end
            a = max(0, min(1, a));
        end

% =========================================================================
%  Camera plumbing (viewer3d)
% =========================================================================
        function onCameraMoved(obj)
            % viewer3d has finished a camera move.  If it was a pure zoom
            % (the wheel, or the toolbar), redo it about the cursor: shift
            % the target so that whatever the pointer was over before the
            % zoom is under it again.  Rotating and panning pass through.
            if obj.CamBusy_ || ~obj.isViewer3D(), return; end
            cur  = MatVisVolumeView.readCam(obj.Viewer);
            prev = obj.CamPrev_;
            obj.CamPrev_ = cur;
            if ~isempty(cur) && ~isempty(prev) && ...
                    ~isequal(cur.zoom, prev.zoom) && isequal(cur.target, prev.target)
                obj.recentreOnCursor(prev.zoom / cur.zoom);
            end
            if ~isempty(obj.CameraMovedFcn)
                try; obj.CameraMovedFcn(); catch; end
            end
        end

        function recentreOnCursor(obj, s)
            % s = zoom factor applied (< 1 after zooming in).  The projection
            % is orthographic, so the depth of the point under the cursor does
            % not matter, only its offset from the view axis.
            if ~isfinite(s) || s <= 0 || abs(s - 1) < 1e-6, return; end
            [ox, oy, inside] = obj.viewerCursorOffset();
            if ~inside, return; end
            [ok, T, C, ~, right, up_, halfW, halfH] = obj.viewerFrame();
            if ~ok, return; end
            Q  = T + right * (ox * halfW / s) + up_ * (oy * halfH / s);
            dT = (1 - s) * (Q - T);
            obj.CamBusy_ = true;
            try
                obj.Viewer.CameraTarget   = T + dT;
                obj.Viewer.CameraPosition = C + dT;
            catch
            end
            obj.CamBusy_ = false;
            obj.CamPrev_ = MatVisVolumeView.readCam(obj.Viewer);
        end

        function [ok, T, C, fwd, right, up_, halfW, halfH] = viewerFrame(obj)
            % Camera frame of the viewer plus the half extent of the visible
            % area at the target plane, in data units.
            ok = false;  T = [];  C = [];  fwd = [];  right = [];  up_ = [];
            halfW = 0;   halfH = 0;
            v = obj.Viewer;
            try
                T   = double(v.CameraTarget(:)).';
                C   = double(v.CameraPosition(:)).';
                up0 = double(v.CameraUpVector(:)).';
                va  = double(v.CameraViewAngle);
                z   = double(v.CameraZoom);
            catch
                return;
            end
            d    = T - C;
            dist = norm(d);
            if ~isfinite(dist) || dist <= 0 || ~isfinite(z) || z <= 0, return; end
            fwd   = d / dist;
            right = cross(fwd, up0);
            if norm(right) < 1e-9, return; end
            right = right / norm(right);
            up_   = cross(right, fwd);
            pp    = getpixelposition(v, true);
            if pp(3) <= 0 || pp(4) <= 0, return; end
            halfH = dist * tand(max(0.01, min(179, va)) / 2) / z;
            halfW = halfH * pp(3) / pp(4);
            ok    = true;
        end

        function [ox, oy, inside] = viewerCursorOffset(obj)
            % Cursor position relative to the centre of the viewer, in units
            % of half its width/height (so [-1 1] spans the visible area).
            ox = 0;  oy = 0;  inside = false;
            pp = getpixelposition(obj.Viewer, true);
            if pp(3) <= 0 || pp(4) <= 0, return; end
            pt = obj.pointer();
            if isempty(pt), return; end
            ox = 2 * (pt(1) - (pp(1) + pp(3)/2)) / pp(3);
            oy = 2 * (pt(2) - (pp(2) + pp(4)/2)) / pp(4);
            inside = abs(ox) <= 1 && abs(oy) <= 1;
        end

        function pt = pointer(obj)
            pt = [];
            if ~isempty(obj.PointerFcn)
                try; pt = obj.PointerFcn(); catch; pt = []; end
            end
        end
    end

% =========================================================================
%  Static helpers
% =========================================================================
    methods (Static)
        function tf = volshowBroken(setTrue)
            % Latch: once volshow/viewer3d has failed anywhere, every view
            % built afterwards goes straight to the fallback renderer.
            persistent broken
            if isempty(broken), broken = false; end
            if nargin > 0 && setTrue, broken = true; end
            tf = broken;
        end

        function s = styleItems()
            s = {'MaximumIntensityProjection', 'MinimumIntensityProjection', ...
                 'VolumeRendering', 'Isosurface', 'GradientOpacity', 'SlicePlanes'};
        end

        function [lo, n, strides] = planSampling(ranges, maxVox)
            % Index start, count and stride along each of three dims so that
            % the sampled volume stays within MAXVOX voxels.
            lo      = ranges(:, 1).';
            n       = ranges(:, 2).' - lo + 1;
            strides = ones(1, 3);
            if isfinite(maxVox) && maxVox > 0
                while prod(ceil(n ./ strides)) > maxVox
                    [~, j] = max(ceil(n ./ strides));
                    strides(j) = strides(j) + 1;
                end
            end
        end

        function [V, voxSize, idxCells] = extractVolume(model, data, dims3, ...
                                              lo, n, strides, cLo, cHi, gamma)
            % Sub-volume spanned by DIMS3, normalized to uint8 with the given
            % contrast bounds and gamma, plus the real-world size of one
            % displayed voxel along each dim.
            idxCells = cell(1, 3);
            for j = 1:3
                idxCells{j} = lo(j) : strides(j) : (lo(j) + n(j) - 1);
            end
            vol = MatVisRender.getRawVolumeForDims(model, data, dims3, idxCells);
            nrm = MatVisRender.applyGamma( ...
                    MatVisRender.normalizeData(vol, cLo, cHi), gamma);
            V   = uint8(max(0, min(1, nrm)) * 255);

            sp = MatVisRender.spacingForDims(model, dims3);
            if isempty(sp), sp = [1 1 1]; end
            voxSize = sp .* strides;
        end

        function a = alphamapPreset(name, win)
            % 256-entry alpha ramps.  'flat' is what a projection wants (the
            % default ramp attenuates dim voxels, so faint structure
            % disappears instead of projecting at its true value); the ramps
            % are for VolumeRendering and friends.
            x = linspace(0, 1, 256).';
            if nargin < 2 || numel(win) ~= 2, win = [0 1]; end
            switch lower(name)
                case 'linear', a = x;
                case 'window'
                    w = sort(win(:).');
                    if w(2) - w(1) < eps
                        a = double(x >= w(1));
                    else
                        a = max(0, min(1, (x - w(1)) / (w(2) - w(1))));
                    end
                otherwise,     a = ones(256, 1);
            end
        end

        function tf = scaleTform(voxSize)
            % Scaling transformation mapping voxel indices to real-world extent.
            tf = [];
            A = eye(4);
            A(1,1) = voxSize(1);  A(2,2) = voxSize(2);  A(3,3) = voxSize(3);
            if ~isempty(which('affinetform3d'))
                tf = affinetform3d(A);
            elseif ~isempty(which('affine3d'))
                tf = affine3d(A');      % older post-multiply convention
            end
        end

        function c = readCam(v)
            % Camera state of a viewer3d, or [] if it cannot be read.
            c = [];
            try
                c = struct('zoom',   double(v.CameraZoom), ...
                           'target', double(v.CameraTarget(:)).', ...
                           'pos',    double(v.CameraPosition(:)).');
            catch
            end
        end
    end

    methods (Static, Access = private)
        function s = onOff(tf)
            if tf, s = 'on'; else, s = 'off'; end
        end

        function c = rgbOf(color)
            if ischar(color) || isstring(color)
                switch lower(char(color))
                    case {'k', 'black'}, c = [0 0 0];
                    case {'w', 'white'}, c = [1 1 1];
                    otherwise,           c = [0 0 0];
                end
            else
                c = double(color(:)).';
                if numel(c) ~= 3, c = [0 0 0]; end
            end
        end
    end
end
