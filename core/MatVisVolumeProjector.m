classdef MatVisVolumeProjector
    % MatVisVolumeProjector  Headless volume projection for movie frames.
    %
    %   p = MatVisVolumeProjector.project(V, voxSize, 'Az', -37.5, 'El', 30)
    %   image(p.img);  line(p.boxX, p.boxY);
    %
    %   Why this exists rather than capturing the 3-D window: a viewer3d
    %   cannot be grabbed usefully.  Measured on this machine,
    %   exportgraphics(viewer3d) fails, getframe(viewer3d) is 750-820 ms when
    %   it works at all, and getframe on a *hidden* one deadlocks MATLAB.  A
    %   movie needs a projection it can compute, so the volume is rotated
    %   into the viewing frame and collapsed along the view axis instead:
    %   imwarp + max is ~30 ms for 256x256x64 and runs headless.
    %
    %   Camera convention is the one MatVisVolumeView uses, so azimuth and
    %   elevation mean the same thing here as in the interactive window:
    %     dir (target -> camera) = [ sin(a)cos(e), -cos(a)cos(e), sin(e)]
    %     up                     = [-sin(a)sin(e),  cos(a)sin(e), cos(e)]
    %   az/el = (0,0) looks along +Y with X right and Z up; (0,90) looks down
    %   -Z with X right and Y up.  Zoom magnifies about the volume centre,
    %   like viewer3d's CameraZoom.
    %
    %   The volume is indexed (i,j,k) -> (panel X, panel Y, panel Z) with
    %   VOXSIZE the real-world size of one voxel along each, matching
    %   MatVisVolumeView.extractVolume.
    %
    %   Without the Image Processing Toolbox there is no imwarp, so the
    %   projection degrades to the axis-aligned one nearest the view
    %   direction (p.mode = 'axis') — the same approximation the interactive
    %   window's toolbox-free backend makes.
    %
    %   See also MatVisVolumeView, MatVisFrameComposer.

    methods (Static)

        function [right, up, dir] = camFrame(az, el)
            % Orthonormal viewing frame: screen right, screen up, and the
            % target -> camera direction.
            a = az * pi/180;
            e = el * pi/180;
            dir   = [ sin(a)*cos(e), -cos(a)*cos(e), sin(e)];
            up    = [-sin(a)*sin(e),  cos(a)*sin(e), cos(e)];
            right = cross(up, dir);
        end

        function tf = canWarp()
            % imwarp plus a 3-D affine object, i.e. the true-projection path.
            persistent ok
            if isempty(ok)
                ok = ~isempty(which('imwarp')) && ~isempty(which('imref3d')) && ...
                     (~isempty(which('affinetform3d')) || ~isempty(which('affine3d')));
            end
            tf = ok;
        end

        function p = project(V, voxSize, varargin)
            % Project V along the view direction.  See the class help.
            ip = inputParser;
            ip.addParameter('Az',       -37.5);
            ip.addParameter('El',        30);
            ip.addParameter('Zoom',      1);
            ip.addParameter('OutSize',  [400 400]);    % [W H] pixels
            ip.addParameter('Colormap', []);           % N x 3 in [0 1]
            ip.addParameter('Style',    'max');        % 'max' | 'min'
            ip.addParameter('MaxDepth',  512);
            ip.addParameter('Interp',   'nearest');
            ip.addParameter('Mode',     'auto');       % 'auto' | 'warp' | 'axis'
            ip.parse(varargin{:});
            o = ip.Results;

            if nargin < 2 || isempty(voxSize), voxSize = [1 1 1]; end
            voxSize = double(voxSize(:)');
            if numel(voxSize) ~= 3, voxSize = [1 1 1]; end
            voxSize(~isfinite(voxSize) | voxSize <= 0) = 1;

            outW = max(16, round(o.OutSize(1)));
            outH = max(16, round(o.OutSize(2)));

            if isempty(V)
                p = MatVisVolumeProjector.emptyResult(outW, outH, o.Colormap);
                return;
            end
            if ~isa(V, 'uint8'), V = uint8(max(0, min(255, double(V)))); end

            % World box of the volume, centred so the projection is centred.
            ext = double(size(V, 1:3)) .* voxSize;
            ctr = ext / 2;
            [right, up, dir] = MatVisVolumeProjector.camFrame(o.Az, o.El);
            M = [right; up; dir];

            [cw, edges] = MatVisVolumeProjector.boxCorners(ext);
            Q = (cw - ctr) * M';                       % 8 x 3 in (u, v, d)

            extU = max(Q(:,1)) - min(Q(:,1));
            extV = max(Q(:,2)) - min(Q(:,2));
            % 4 % slack so the bounding box at Zoom = 1 is not flush with the
            % frame edge, where half its line width would be clipped away.
            fit  = 1.04 * max([extU / outW, extV / outH, eps]);
            zf   = o.Zoom;
            if ~isfinite(zf) || zf <= 0, zf = 1; end
            px   = fit / zf;

            uLim = [-outW/2, outW/2] * px;
            vLim = [-outH/2, outH/2] * px;

            if ~strcmpi(o.Mode, 'axis') && MatVisVolumeProjector.canWarp()
                [g, mode] = MatVisVolumeProjector.warpProject(V, voxSize, ...
                    M, ctr, uLim, vLim, Q, [outW outH], o);
            else
                [g, mode] = MatVisVolumeProjector.axisProject(V, M, ...
                    [outW outH], o);
            end

            p = struct();
            p.gray = g;
            p.img  = MatVisVolumeProjector.colorize(g, o.Colormap);
            p.mode = mode;
            p.px   = px;

            % Bounding-box wireframe and axis-label anchors, in image pixels.
            [cx, cy] = MatVisVolumeProjector.toPixels(Q(:, 1:2), uLim, vLim, px, outH);
            bx = NaN(1, 3 * size(edges, 1));
            by = bx;
            bx(1:3:end) = cx(edges(:, 1));  bx(2:3:end) = cx(edges(:, 2));
            by(1:3:end) = cy(edges(:, 1));  by(2:3:end) = cy(edges(:, 2));
            p.boxX     = bx;
            p.boxY     = by;
            p.corners  = [cx(:), cy(:)];
            p.labelPos = MatVisVolumeProjector.labelAnchors(Q(:, 1:2), cx, cy, outW, outH);
        end
    end

    % ------------------------------------------------------------------
    methods (Static, Access = private)

        function [g, mode] = warpProject(V, voxSize, M, ctr, uLim, vLim, Q, outSz, o)
            % True projection: rotate into (u, v, depth) and collapse depth.
            mode  = 'warp';
            minip = strcmpi(o.Style, 'min');
            if minip
                V = 255 - V;          % min along a ray = 255 - max along 255-V
            end

            % imref3d's world X spans columns and Y spans rows, so the volume
            % is permuted to (panel Y, panel X, panel Z) — the same swap
            % volshow needs.
            Vp  = permute(V, [2 1 3]);
            Rin = imref3d(size(Vp, 1:3), voxSize(1), voxSize(2), voxSize(3));

            % Rin's limits start half a voxel before the origin, not at it;
            % shift the centre by the same amount so the warp and the drawn
            % box agree.
            off = [Rin.XWorldLimits(1), Rin.YWorldLimits(1), Rin.ZWorldLimits(1)];
            A = eye(4);
            A(1:3, 1:3) = M;
            A(1:3, 4)   = -M * (ctr(:) + off(:));

            outW = outSz(1);
            outH = outSz(2);

            dLim = [min(Q(:,3)), max(Q(:,3))];
            pz   = min(voxSize);
            nD   = max(1, ceil(diff(dLim) / pz));
            if nD > o.MaxDepth
                nD = o.MaxDepth;
                pz = diff(dLim) / nD;
            end
            dLim(2) = dLim(1) + nD * pz;

            g = [];
            try
                Rout = imref3d([outH outW nD], uLim, vLim, dLim);
                W = imwarp(Vp, Rin, MatVisVolumeProjector.tform(A), o.Interp, ...
                           'OutputView', Rout, 'FillValues', 0);
                g = flipud(max(W, [], 3));   % row 1 is the lowest v = screen bottom
            catch
            end
            if isempty(g)
                [g, mode] = MatVisVolumeProjector.axisProject(V, M, outSz, o);
                % axisProject saw the already-inverted volume, so undo that
                % here instead of below.
                if minip, g = 255 - g; end
                minip = false;
            end
            if minip, g = 255 - g; end
        end

        function [g, mode] = axisProject(V, M, outSz, o)
            % Toolbox-free fallback: the axis-aligned projection nearest the
            % view direction, oriented into the (u, v) frame.  Approximate by
            % construction — it cannot show an oblique view.
            mode = 'axis';
            [~, ax] = max(abs(M(3, :)));
            rest = setdiff(1:3, ax);

            if strcmpi(o.Style, 'min')
                m = squeeze(min(V, [], ax));
            else
                m = squeeze(max(V, [], ax));
            end
            % m is indexed (rest(1), rest(2)).  Decide which of the two runs
            % along screen u, then fix the signs.
            e1 = zeros(3, 1);  e1(rest(1)) = 1;
            e2 = zeros(3, 1);  e2(rest(2)) = 1;
            u1 = M(1, :) * e1;  v1 = M(2, :) * e1;
            u2 = M(1, :) * e2;  v2 = M(2, :) * e2;
            if abs(u1) >= abs(u2)
                g = m.';                        % columns = rest(1) = u
                uSign = sign(u1);  vSign = sign(v2);
            else
                g = m;                          % columns = rest(2) = u
                uSign = sign(u2);  vSign = sign(v1);
            end
            if uSign < 0, g = fliplr(g); end
            if vSign > 0, g = flipud(g); end    % screen up = decreasing row

            g = MatVisVolumeProjector.centreFit(g, outSz(1), outSz(2));
        end

        function g = centreFit(g, outW, outH)
            % Scale to fit, then centre in the frame, so the caller's box
            % overlay still lines up roughly.
            sc = min(outW / max(size(g, 2), 1), outH / max(size(g, 1), 1));
            if isfinite(sc) && sc > 0 && abs(sc - 1) > 1e-6
                g = matVisNearestResize_(g, size(g, 1:2) * sc);
            end
            out = zeros(outH, outW, 'like', g);
            hh  = min(size(g, 1), outH);
            ww  = min(size(g, 2), outW);
            r0  = 1 + floor((outH - hh) / 2);
            c0  = 1 + floor((outW - ww) / 2);
            out(r0:r0+hh-1, c0:c0+ww-1) = g(1:hh, 1:ww);
            g = out;
        end

        function t = tform(A)
            if ~isempty(which('affinetform3d'))
                t = affinetform3d(A);
            else
                t = affine3d(A');      % older post-multiply convention
            end
        end

        function [cw, edges] = boxCorners(ext)
            % Eight corners of [0 ext] and the twelve edges between them.
            b  = double(dec2bin(0:7, 3) - '0');    % 8 x 3, column 1 = axis 1
            b  = fliplr(b);                        % bit 1 -> axis 1
            cw = b .* ext;
            edges = zeros(12, 2);
            n = 0;
            for k = 1:3
                other = setdiff(1:3, k);
                for c = 0:3
                    bits = zeros(1, 3);
                    bits(other(1)) = bitget(c, 1);
                    bits(other(2)) = bitget(c, 2);
                    lo = bits;  lo(k) = 0;
                    hi = bits;  hi(k) = 1;
                    n = n + 1;
                    edges(n, :) = [find(all(b == lo, 2), 1), find(all(b == hi, 2), 1)];
                end
            end
        end

        function [cx, cy] = toPixels(uv, uLim, vLim, px, outH)
            cx = (uv(:, 1) - uLim(1)) / px + 0.5;
            cy = outH + 1 - ((uv(:, 2) - vLim(1)) / px + 0.5);
        end

        function L = labelAnchors(uv, cx, cy, outW, outH)
            % One anchor per axis: the midpoint of whichever of the four
            % parallel edges sits farthest out in the screen plane, nudged
            % away from the centre so the text clears the box.  The
            % alignment comes back with it, because a straight-on view
            % projects the box onto the whole frame and a centred label at
            % the edge would then hang off it.
            L = struct('x', {0, 0, 0}, 'y', {0, 0, 0}, ...
                       'align', {'center', 'center', 'center'}, ...
                       'valign', {'middle', 'middle', 'middle'}, ...
                       'visible', {true, true, true});
            [~, edges] = MatVisVolumeProjector.boxCorners([1 1 1]);
            % Room a centred label needs on each side.  Close to an edge
            % there isn't any, so the label is anchored there and grown
            % inward instead — clamping the position alone still clips half
            % the text, which is what a straight-on view does to all three.
            hRoom = 50;
            vRoom = 14;

            % A panel narrower than a few labels cannot carry them legibly
            % whatever is done with the anchors, and a clipped word is worse
            % than none: the wireframe alone still shows the orientation.
            if outW < 150 || outH < 110
                for k = 1:3, L(k).visible = false; end
                return;
            end
            seg   = zeros(1, 3);        % projected length of each axis, px
            for k = 1:3
                rows  = (k-1)*4 + (1:4);
                best  = rows(1);
                bestD = -Inf;
                for r = rows
                    d = norm(mean(uv(edges(r, :), :), 1));
                    if d > bestD, bestD = d;  best = r; end
                end
                e  = edges(best, :);
                mx = mean(cx(e));
                my = mean(cy(e));

                % An axis pointing at the camera collapses to a point, so a
                % label for it would just sit on a corner meaning nothing.
                seg(k)       = hypot(cx(e(2)) - cx(e(1)), cy(e(2)) - cy(e(1)));
                L(k).visible = seg(k) >= 8;

                v  = [mx - outW/2, my - outH/2];
                nv = norm(v);
                if nv > eps, v = 10 * v / nv; else, v = [0 0]; end
                x = mx + v(1);
                y = my + v(2);

                if x < hRoom
                    L(k).align = 'left';
                elseif x > outW - hRoom
                    L(k).align = 'right';
                end
                if y < vRoom
                    L(k).valign = 'top';
                elseif y > outH - vRoom
                    L(k).valign = 'bottom';
                end
                L(k).x = min(max(x, 3), outW - 2);
                L(k).y = min(max(y, 3), outH - 2);
            end

            % Two labels can land on top of each other when their edges
            % project close together, which on a small panel reads as one
            % garbled word.  Compare the boxes the text will actually
            % occupy — anchors 40 px apart still collide when each string is
            % 46 px wide — and keep the axis with the longer projected edge,
            % since that is the direction a label most needs to explain.
            wEst = 46;      % a typical "Name (unit)" at the size the composer uses
            hEst = 13;
            x0 = zeros(1, 3);
            x1 = zeros(1, 3);
            for k = 1:3
                switch L(k).align
                    case 'left'
                        x0(k) = L(k).x;             x1(k) = L(k).x + wEst;
                    case 'right'
                        x0(k) = L(k).x - wEst;      x1(k) = L(k).x;
                    otherwise
                        x0(k) = L(k).x - wEst/2;    x1(k) = L(k).x + wEst/2;
                end
            end
            for a = 1:3
                for b = a+1:3
                    if ~L(a).visible || ~L(b).visible, continue; end
                    if x0(a) >= x1(b) || x0(b) >= x1(a), continue; end
                    if abs(L(a).y - L(b).y) >= hEst, continue; end
                    if seg(a) >= seg(b)
                        L(b).visible = false;
                    else
                        L(a).visible = false;
                    end
                end
            end
        end

        function img = colorize(g, cmap)
            lut = MatVisVolumeProjector.lut256(cmap);
            idx = double(g) + 1;
            img = uint8(255 * reshape(lut(idx(:), :), [size(g, 1), size(g, 2), 3]));
        end

        function c = lut256(c)
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

        function p = emptyResult(outW, outH, cmap)
            g = zeros(outH, outW, 'uint8');
            p = struct('gray', g, ...
                       'img',  MatVisVolumeProjector.colorize(g, cmap), ...
                       'mode', 'empty', 'px', 1, ...
                       'boxX', NaN, 'boxY', NaN, 'corners', NaN(8, 2), ...
                       'labelPos', struct('x', {0,0,0}, 'y', {0,0,0}, ...
                           'align', {'center','center','center'}, ...
                           'valign', {'middle','middle','middle'}, ...
                           'visible', {false, false, false}));
        end
    end
end

function out = matVisNearestResize_(in, sz)
% Nearest-neighbour resize without imresize, so the fallback path needs no
% toolbox either.
sz = max(1, round(sz));
r  = min(size(in, 1), max(1, round(linspace(1, size(in, 1), sz(1)))));
c  = min(size(in, 2), max(1, round(linspace(1, size(in, 2), sz(2)))));
out = in(r, c);
end
