classdef MatVisRender
    methods (Static)

        function raw = getRawSlice(model)
            % Returns raw double 2-D slice cropped to model.ZoomRange.
            % If projection is active, projects along ProjDim; if RGB mode is
            % active, returns an H×W×3 array (one page per color channel).
            raw = MatVisRender.getRawSliceFromData(model, model.Data);
        end

        function raw = getRawFullSlice(model)
            % Returns raw double 2-D (or H×W×3 RGB) slice using full extent
            % (ignores ZoomRange).
            raw = MatVisRender.getRawFullSliceFromData(model, model.Data);
        end

        function out = normalizeData(raw, cMin, cMax)
            % Normalize raw data to [0,1] using the given contrast bounds.
            if cMax == cMin
                out = zeros(size(raw));
            else
                out = max(0, min(1, (raw - cMin) ./ (cMax - cMin)));
            end
        end

        function slice2D = renderSlice(model)
            % Returns normalized [0,1] 2-D slice cropped to model.ZoomRange.
            raw = MatVisRender.getRawSlice(model);
            slice2D = MatVisRender.normalize_(raw, model.ContrastMin, model.ContrastMax);
        end

        function slice2D = renderFullSlice(model)
            % Returns normalized [0,1] 2-D slice using full extent (ignores ZoomRange).
            raw = MatVisRender.getRawFullSlice(model);
            slice2D = MatVisRender.normalize_(raw, model.ContrastMin, model.ContrastMax);
        end

        function profile1D = renderProfile(model, dimIdx)
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = model.ZoomRange(dimIdx, 1) : model.ZoomRange(dimIdx, 2);
            raw = double(model.Data(idx{:}));
            profile1D = raw(:);
        end

        function profile1D = renderFullProfile(model, dimIdx)
            % Like renderProfile but spans the full dimension extent (ignores ZoomRange).
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = 1 : model.Size(dimIdx);
            raw = double(model.Data(idx{:}));
            profile1D = raw(:);
        end

        % ------------------------------------------------------------------
        %  Data-overriding variants — use provided data array instead of
        %  model.Data.  Used by multi-dataset rendering loop.
        % ------------------------------------------------------------------

        function raw = getRawSliceFromData(model, data)
            % Like getRawSlice but uses the provided data array.
            idx = num2cell(model.CurrPos);
            xRange = model.ZoomRange(model.XDim, 1) : model.ZoomRange(model.XDim, 2);
            yRange = model.ZoomRange(model.YDim, 1) : model.ZoomRange(model.YDim, 2);
            idx{model.XDim} = xRange;
            idx{model.YDim} = yRange;
            [doProj, pd] = MatVisRender.projState_(model);
            [doRGB, rd]  = MatVisRender.rgbState_(model, doProj, pd);
            if doProj
                idx{pd} = model.ZoomRange(pd, 1) : model.ZoomRange(pd, 2);
            end
            if doRGB
                idx{rd} = 1 : model.Size(rd);
            end
            raw = double(data(idx{:}));
            raw = MatVisRender.finalizeSlice_(raw, model, doProj, pd, doRGB, rd);
        end

        function raw = getRawFullSliceFromData(model, data)
            idx = num2cell(model.CurrPos);
            idx{model.XDim} = 1 : model.Size(model.XDim);
            idx{model.YDim} = 1 : model.Size(model.YDim);
            [doProj, pd] = MatVisRender.projState_(model);
            [doRGB, rd]  = MatVisRender.rgbState_(model, doProj, pd);
            if doProj
                if model.ProjZoomLock
                    idx{pd} = model.ZoomRange(pd, 1) : model.ZoomRange(pd, 2);
                else
                    idx{pd} = 1 : model.Size(pd);
                end
            end
            if doRGB
                idx{rd} = 1 : model.Size(rd);
            end
            raw = double(data(idx{:}));
            raw = MatVisRender.finalizeSlice_(raw, model, doProj, pd, doRGB, rd);
        end

        function profile1D = renderProfileFromData(model, data, dimIdx)
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = model.ZoomRange(dimIdx, 1) : model.ZoomRange(dimIdx, 2);
            raw = double(data(idx{:}));
            profile1D = MatVisRender.avgOverNonProfileDims_(raw, dimIdx, numel(model.Size));
        end

        function profile1D = renderFullProfileFromData(model, data, dimIdx)
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = 1 : model.Size(dimIdx);
            raw = double(data(idx{:}));
            profile1D = MatVisRender.avgOverNonProfileDims_(raw, dimIdx, numel(model.Size));
        end

        function profile1D = renderProfileNeighborFromData(model, data, dimIdx, avgMode)
            % Like renderProfileFromData but averages over an XY neighborhood.
            %   avgMode: 0=1x1, 1=3x3, 2=5x5, 3=full zoom XY extent
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = model.ZoomRange(dimIdx, 1) : model.ZoomRange(dimIdx, 2);
            idx = MatVisRender.applyNeighborIdx_(model, dimIdx, avgMode, idx);
            raw = double(data(idx{:}));
            profile1D = MatVisRender.avgOverNonProfileDims_(raw, dimIdx, numel(model.Size));
        end

        function profile1D = renderFullProfileNeighborFromData(model, data, dimIdx, avgMode)
            % Like renderFullProfileFromData but averages over an XY neighborhood.
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = 1 : model.Size(dimIdx);
            idx = MatVisRender.applyNeighborIdx_(model, dimIdx, avgMode, idx);
            raw = double(data(idx{:}));
            profile1D = MatVisRender.avgOverNonProfileDims_(raw, dimIdx, numel(model.Size));
        end

        function [profile1D, alphaProf] = renderProfileNeighborAlphaFromData(model, data, alphaMap, dimIdx, avgMode)
            % Alpha-weighted variant of renderProfileNeighborFromData.
            % profile1D is the weighted mean sum(data.*alpha)/sum(alpha) over
            % the XY neighborhood; alphaProf is the plain mean of the alpha
            % map over the same pixels. avgMode 0 = single pixel (the
            % weighted mean then reduces to the data value itself).
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = model.ZoomRange(dimIdx, 1) : model.ZoomRange(dimIdx, 2);
            idx = MatVisRender.applyNeighborIdx_(model, dimIdx, avgMode, idx);
            [profile1D, alphaProf] = MatVisRender.weightedProfiles_( ...
                double(data(idx{:})), double(alphaMap(idx{:})), dimIdx, numel(model.Size));
        end

        function [profile1D, alphaProf] = renderFullProfileNeighborAlphaFromData(model, data, alphaMap, dimIdx, avgMode)
            % Like renderProfileNeighborAlphaFromData but spans the full
            % dimension extent (ignores ZoomRange).
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = 1 : model.Size(dimIdx);
            idx = MatVisRender.applyNeighborIdx_(model, dimIdx, avgMode, idx);
            [profile1D, alphaProf] = MatVisRender.weightedProfiles_( ...
                double(data(idx{:})), double(alphaMap(idx{:})), dimIdx, numel(model.Size));
        end

        function profile1D = renderRoiProfileFromData(model, data, dimIdx, roi, useZoomRange)
            % renderRoiProfileFromData  Mean over the ROI mask along dimIdx.
            %   roi          : one element of model.RoiList
            %   useZoomRange : true → restrict dimIdx to its zoom range
            % Returns [] when dimIdx is one of the display axes (the ROI
            % already constrains those) or the ROI mask is empty.
            [lin, nPix, nT] = MatVisRender.roiLinIndex_(model, dimIdx, roi, useZoomRange);
            if isempty(lin), profile1D = []; return; end
            vals = reshape(double(data(lin)), nPix, nT);
            profile1D = mean(vals, 1, 'omitnan')';
        end

        function [profile1D, alphaProf] = renderRoiProfileAlphaFromData(model, data, alphaMap, dimIdx, roi, useZoomRange)
            % renderRoiProfileAlphaFromData  Alpha-weighted variant of
            % renderRoiProfileFromData: the data trace is the weighted mean
            % sum(data.*alpha)/sum(alpha) over the ROI pixels, and alphaProf
            % is the plain mean of the alpha map over the same pixels.
            [lin, nPix, nT] = MatVisRender.roiLinIndex_(model, dimIdx, roi, useZoomRange);
            if isempty(lin), profile1D = []; alphaProf = []; return; end
            vals  = reshape(double(data(lin)),     nPix, nT);
            aVals = reshape(double(alphaMap(lin)), nPix, nT);
            num = sum(vals .* aVals,           1, 'omitnan');
            den = sum(aVals .* ~isnan(vals),   1, 'omitnan');
            profile1D = (num ./ den)';
            alphaProf = mean(aVals, 1, 'omitnan')';
        end

        function vals = getRoiValuesFromData(model, data, roi)
            % getRoiValuesFromData  Data values of all ROI pixels in the
            % current slice (non-XY dims at CurrPos).
            xs = roi.index.x(:);
            ys = roi.index.y(:);
            vals = [];
            if isempty(xs), return; end
            sz = model.Size;
            nD = numel(sz);
            subs = cell(1, nD);
            for d = 1:nD
                if d == model.XDim
                    subs{d} = xs;
                elseif d == model.YDim
                    subs{d} = ys;
                else
                    subs{d} = repmat(model.CurrPos(d), numel(xs), 1);
                end
            end
            vals = double(data(sub2ind(sz, subs{:})));
        end

        function cols = roiColors(n)
            % roiColors  Distinct colors for selected ROI outlines/traces.
            cols = lines(max(n, 1));
            cols = cols(1:max(n, 1), :);
        end

        function profile1D = renderProfileNeighbor(model, dimIdx, avgMode)
            % renderProfileNeighbor  Extract zoom-range profile averaged over an XY neighborhood.
            %   avgMode: 0=1x1 (single pixel), 1=3x3, 2=5x5, 3=full zoom XY extent
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = model.ZoomRange(dimIdx, 1) : model.ZoomRange(dimIdx, 2);
            idx = MatVisRender.applyNeighborIdx_(model, dimIdx, avgMode, idx);
            raw = double(model.Data(idx{:}));
            profile1D = MatVisRender.avgOverNonProfileDims_(raw, dimIdx, numel(model.Size));
        end

        function profile1D = renderFullProfileNeighbor(model, dimIdx, avgMode)
            % Like renderProfileNeighbor but spans the full dimension extent.
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = 1 : model.Size(dimIdx);
            idx = MatVisRender.applyNeighborIdx_(model, dimIdx, avgMode, idx);
            raw = double(model.Data(idx{:}));
            profile1D = MatVisRender.avgOverNonProfileDims_(raw, dimIdx, numel(model.Size));
        end

        function img = applyGamma(data, gamma)
            if gamma == 1
                img = data;
            else
                img = data .^ gamma;
            end
        end

        function img = composeImage(normData, gamma, cmapIdx)
            % Convert a normalized [0,1] slice to a display image.
            % 2-D data is gamma-corrected and colormapped; H×W×3 data
            % (RGB mode) bypasses the colormap.
            g = MatVisRender.applyGamma(normData, gamma);
            if ndims(g) == 3
                img = uint8(max(0, min(1, g)) * 255);
            else
                img = MatVisRender.applyColormap(g, cmapIdx);
            end
        end

        function img = composeImageWithAlpha(normData, gamma, cmapIdx, alphaNorm, bgWhite)
            % Like composeImage, but blends the result against a black or
            % white background using the normalized [0,1] alpha map.
            % Mirrors the original matVis AlphaData display ('scaled'
            % mapping over the alpha contrast range).
            %   alphaNorm : H×W (or H×W×3 in RGB mode) alpha weights in
            %               [0,1]; contrast/gamma already applied.
            %   bgWhite   : false = black background (original default)
            img = MatVisRender.composeImage(normData, gamma, cmapIdx);
            a   = max(0, min(1, double(alphaNorm)));   % also maps NaN → 0
            bg  = 0;
            if nargin >= 5 && bgWhite, bg = 255; end
            img = uint8(double(img) .* a + bg * (1 - a));
        end

        function alphaNorm = renderAlphaSlice(raw, aMin, aMax, alphaGamma)
            % Normalize a raw alpha slice to [0,1] with the given alpha
            % contrast bounds and apply the alpha gamma.
            alphaNorm = MatVisRender.normalizeData(raw, aMin, aMax);
            if alphaGamma ~= 1
                alphaNorm = MatVisRender.applyGamma(alphaNorm, alphaGamma);
            end
        end

        function img = applyColormap(data, cmapIdx)
            cmap    = MatVisRender.getColormap(cmapIdx, 256);
            indices = max(1, min(256, round(data * 255) + 1));
            H = size(data, 1);
            W = size(data, 2);
            rgb = reshape(cmap(indices(:), :), [H W 3]);
            img = uint8(rgb * 255);
        end

        function [counts, edges] = computeHistogram(data)
            [counts, edges] = histcounts(data(:), 256);
        end

        function cmap = getColormap(cmapIdx, nColors)
            % Memoize the last requested map — rendering asks for the same
            % (idx, n) twice per dataset per frame.
            persistent lastIdx lastN lastMap
            if ~isempty(lastMap) && isequal(lastIdx, cmapIdx) && isequal(lastN, nColors)
                cmap = lastMap;
                return;
            end
            n = nColors;
            switch cmapIdx
                case 1,  cmap = gray(n);
                case 2,  cmap = MatVisRender.buildRainbow(n, 0, 1);   % Gray(Range)
                case 3                                                  % 4x Gray
                    g4   = gray(ceil(n/4));
                    cmap = repmat(g4, 4, 1);
                    cmap = cmap(1:n, :);
                case 4,  cmap = turbo(n);
                case 5,  cmap = parula(n);
                case 6,  cmap = jet(n);
                case 7,  cmap = hsv(n);
                case 8,  cmap = hot(n);
                case 9,  cmap = cool(n);
                % Single-hue ramps — order matches dropdown: all *1 first, then all *2
                case 10  % Red1:     Black → Red
                    v = linspace(0,1,n)';  cmap = [v, zeros(n,2)];
                case 11  % Green1:   Black → Green
                    v = linspace(0,1,n)';  cmap = [zeros(n,1), v, zeros(n,1)];
                case 12  % Blue1:    Black → Blue
                    v = linspace(0,1,n)';  cmap = [zeros(n,2), v];
                case 13  % Cyan1:    Black → Cyan
                    v = linspace(0,1,n)';  cmap = [zeros(n,1), v, v];
                case 14  % Magenta1: Black → Magenta
                    v = linspace(0,1,n)';  cmap = [v, zeros(n,1), v];
                case 15  % Yellow1:  Black → Yellow
                    v = linspace(0,1,n)';  cmap = [v, v, zeros(n,1)];
                case 16  % Red2:     Black → Red → White
                    cmap = MatVisRender.buildHue1to2(n, 1, 0, 0);
                case 17  % Green2:   Black → Green → White
                    cmap = MatVisRender.buildHue1to2(n, 0, 1, 0);
                case 18  % Blue2:    Black → Blue → White
                    cmap = MatVisRender.buildHue1to2(n, 0, 0, 1);
                case 19  % Cyan2:    Black → Cyan → White
                    cmap = MatVisRender.buildHue1to2(n, 0, 1, 1);
                case 20  % Magenta2: Black → Magenta → White
                    cmap = MatVisRender.buildHue1to2(n, 1, 0, 1);
                case 21  % Yellow2:  Black → Yellow → White
                    cmap = MatVisRender.buildHue1to2(n, 1, 1, 0);
                case 22, cmap = MatVisRender.buildRainbow(n, 1, 0.5);
                case 23, cmap = MatVisRender.buildRainbow(n, 2, 0.5);
                case 24, cmap = MatVisRender.buildRainbow(n, 3, 0.5);
                case 25, cmap = MatVisRender.buildRainbow(n, 4, 0.5);
                case 26, cmap = MatVisRender.buildRainbow(n, 5, 0.5);
                case 27, cmap = MatVisRender.buildRainbow(n, 6, 0.5);
                case 28, cmap = MatVisRender.buildDiverging(n, 'BlueGrayYellow');
                case 29, cmap = MatVisRender.buildDiverging(n, 'BlueGrayRed');
                case 30, cmap = MatVisRender.buildDiverging(n, 'GreenGrayRed');
                case 31, cmap = MatVisRender.buildDiverging(n, 'MagentaGrayGreen');
                otherwise, cmap = gray(n);
            end
            cmap = max(0, min(1, cmap));
            lastIdx = cmapIdx;  lastN = nColors;  lastMap = cmap;
        end

    end

    methods (Static, Access = private)

        function [doProj, pd] = projState_(model)
            pd = model.ProjDim;
            doProj = ~strcmp(model.ProjFun, 'none') && pd > 0 && ...
                     pd ~= model.XDim && pd ~= model.YDim;
        end

        function [doRGB, rd] = rgbState_(model, doProj, pd)
            % RGB is active when RGBDim > 0; it is suppressed if it would
            % collide with the display axes or an active projection on the
            % same dimension (projection wins).
            rd = model.RGBDim;
            doRGB = rd > 0 && ...
                    rd ~= model.XDim && rd ~= model.YDim && ...
                    ~(doProj && rd == pd);
        end

        function raw = finalizeSlice_(data, model, doProj, pd, doRGB, rd)
            % Reduce extracted data to a 2-D slice or, in RGB mode, an
            % H×W×3 array, then apply axis flips.
            if ~doRGB
                raw = MatVisRender.finalize2D(data, doProj, model.ProjFun, ...
                    pd, model.XDim, model.YDim);
            else
                groups = MatVisRender.rgbGroups_(size(data, rd));
                chans  = cell(1, 3);
                nd     = ndims(data);
                for c = 1:3
                    if isempty(groups{c}), continue; end
                    idxc = repmat({':'}, 1, nd);
                    idxc{rd} = groups{c};
                    sub = data(idxc{:});
                    if numel(groups{c}) > 1
                        sub = mean(sub, rd);
                    end
                    chans{c} = MatVisRender.finalize2D(sub, doProj, ...
                        model.ProjFun, pd, model.XDim, model.YDim);
                end
                ref = chans{find(~cellfun(@isempty, chans), 1)};
                raw = zeros(size(ref, 1), size(ref, 2), 3);
                for c = 1:3
                    if ~isempty(chans{c}), raw(:, :, c) = chans{c}; end
                end
            end
            if model.FlipX, raw = fliplr(raw); end
            if model.FlipY, raw = flipud(raw); end
        end

        function groups = rgbGroups_(n)
            % Map n slices to the three color channels: direct slice→channel
            % for n<=3, otherwise three equal contiguous groups (mean each).
            groups = cell(1, 3);
            if n <= 3
                for c = 1:min(n, 3), groups{c} = c; end
            else
                edges = round(linspace(0, n, 4));
                for c = 1:3, groups{c} = edges(c)+1 : edges(c+1); end
            end
        end

        function raw = finalize2D(data, doProj, projFun, projDim, xDim, yDim)
            % Collapse projection and orient data to [H x W].
            % Handles both scalar-reduction projections and the tile layout.
            if doProj && strcmp(projFun, 'tile')
                raw = MatVisRender.applyTile(data, projDim, xDim, yDim);
            else
                if doProj
                    data = MatVisRender.applyProjFun(data, projFun, projDim);
                end
                raw = squeeze(data);
                if xDim < yDim
                    raw = raw.';
                end
            end
        end

        function out = applyProjFun(data, fun, dim)
            % Reduce DATA along DIM using the named function.
            switch fun
                case 'max',  out = max(data,  [], dim);
                case 'min',  out = min(data,  [], dim);
                case 'mean', out = mean(data,     dim);
                case 'std',  out = std(data,  0,  dim);
                case 'var',  out = var(data,  0,  dim);
                otherwise,   out = max(data,  [], dim);
            end
        end

        function tiled = applyTile(data, projDim, xDim, yDim)
            % Tile all frames along PROJDIM into a near-square 2-D panorama.
            % Each frame is oriented to [H x W].  Incomplete rows are padded
            % with NaN so the grid is fully rectangular.
            N  = size(data, projDim);
            nC = ceil(sqrt(N));
            nR = ceil(N / nC);

            H = size(data, yDim);
            W = size(data, xDim);

            tiled = NaN(H * nR, W * nC);

            nd  = ndims(data);
            for k = 1:N
                % Extract frame k along projDim; keep X and Y as full ranges.
                idx        = repmat({':'}, 1, nd);
                idx{projDim} = k;
                frame = squeeze(data(idx{:}));
                % Orient to [H x W] using the same rule as the main path.
                if xDim < yDim
                    frame = frame.';
                end
                r = floor((k - 1) / nC);   % 0-based row
                c = mod(k - 1, nC);         % 0-based col
                tiled(r*H+1:(r+1)*H, c*W+1:(c+1)*W) = frame;
            end
        end

        function out = normalize_(raw, cMin, cMax)
            if cMax == cMin
                out = zeros(size(raw));
            else
                out = max(0, min(1, (raw - cMin) ./ (cMax - cMin)));
            end
        end

        function cmap = buildHue1to2(n, r, g, b)
            half  = floor(n/2);
            rest  = n - half;
            ramp1 = linspace(0, 1, half)';
            ramp2 = linspace(0, 1, rest)';
            lo    = [r*ramp1, g*ramp1, b*ramp1];
            hi    = [r+(1-r)*ramp2, g+(1-g)*ramp2, b+(1-b)*ramp2];
            cmap  = [lo; hi];
        end

        function cmap = buildRainbow(n, fun_type, exp_val)
            if nargin < 3, exp_val = 1; end
            cmap = zeros(n, 3);
            for k = 1:n
                t = (k-1) / max(n-1, 1);
                cmap(k,:) = MatVisRender.rainbowRGB(t, fun_type, exp_val);
            end
        end

        function rgb = rainbowRGB(col, fun_type, e)
            switch fun_type
                case 0  % gray with blue/red endpoints
                    if col == 0,      rgb = [0 0 1];
                    elseif col == 1,  rgb = [1 0 0];
                    else,             v = col^e; rgb = [v v v];
                    end
                case 1  % black,blue,cyan,green,yellow,red,white
                    if col < 1/6,         rgb = [0, 0, (col*6)^e];
                    elseif col < 2/6,     rgb = [0, (col*6-1)^e, 1];
                    elseif col < 3/6,     rgb = [0, 1, (3-col*6)^e];
                    elseif col < 4/6,     rgb = [(col*6-3)^e, 1, 0];
                    elseif col < 5/6,     rgb = [1, (5-col*6)^e, 0];
                    else,                 rgb = [1, (col*6-5)^e, (col*6-5)^e];
                    end
                case 2  % black,blue,cyan,green,yellow,red,magenta,white
                    if col < 1/7,         rgb = [0, 0, (col*7)^e];
                    elseif col < 2/7,     rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7,     rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7,     rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7,     rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7,     rgb = [1, 0, (col*7-5)^e];
                    else,                 rgb = [1, (col*7-6)^e, 1];
                    end
                case 3  % blue,cyan,green,yellow,red
                    if col < 1/4,         rgb = [0, (col*4)^e, 1];
                    elseif col < 2/4,     rgb = [0, 1, (2-col*4)^e];
                    elseif col < 3/4,     rgb = [(col*4-2)^e, 1, 0];
                    else,                 rgb = [1, (4-col*4)^e, 0];
                    end
                case 4  % blue,cyan,green,yellow,red,magenta
                    if col < 1/5,         rgb = [0, (col*5)^e, 1];
                    elseif col < 2/5,     rgb = [0, 1, (2-col*5)^e];
                    elseif col < 3/5,     rgb = [(col*5-2)^e, 1, 0];
                    elseif col < 4/5,     rgb = [1, (4-col*5)^e, 0];
                    else,                 rgb = [1, 0, (col*5-4)^e];
                    end
                case 5  % white,blue,cyan,green,yellow,red,magenta,white
                    if col < 1/7,         v = (1-col*7)^e; rgb = [v, v, 1];
                    elseif col < 2/7,     rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7,     rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7,     rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7,     rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7,     rgb = [1, 0, (col*7-5)^e];
                    else,                 rgb = [1, (col*7-6)^e, 1];
                    end
                case 6  % white,blue,cyan,green,yellow,red,magenta,black
                    if col < 1/7,         v = (1-col*7)^e; rgb = [v, v, 1];
                    elseif col < 2/7,     rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7,     rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7,     rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7,     rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7,     rgb = [1, 0, (col*7-5)^e];
                    else,                 v = (7-col*7)^e; rgb = [v, 0, v];
                    end
                otherwise
                    rgb = [col, col, col];
            end
        end

        function cmap = buildDiverging(n, name)
            myGV = 0.9;
            half = floor(n/2);
            rest = n - half;
            cmap = zeros(n, 3);
            % Left (negative) side: blue → gray
            cmap(1:half, 1) = linspace(0,    myGV, half);
            cmap(1:half, 2) = linspace(0,    myGV, half);
            cmap(1:half, 3) = linspace(1,    myGV, half);
            % Right (positive) side: gray → red
            cmap(half+1:end, 1) = linspace(myGV, 1,    rest);
            cmap(half+1:end, 2) = linspace(myGV, 0,    rest);
            cmap(half+1:end, 3) = linspace(myGV, 0,    rest);
            switch name
                case 'BlueGrayRed'
                    % base is already Blue-Gray-Red

                case 'BlueGrayYellow'
                    % Replace green channel with red channel (red side → yellow)
                    cmap(:, 2) = cmap(:, 1);

                case 'GreenGrayRed'
                    % Swap red and blue channels (left becomes green, right stays red)
                    cmap = cmap(:, [3 2 1]);
                    % Now left: [myGV→0, myGV→0, 1→myGV] start=[0,0,1]=blue — wrong
                    % Redo: green-gray-red = left green, right red
                    cmap2 = zeros(n, 3);
                    cmap2(1:half, 1) = linspace(0,    myGV, half);
                    cmap2(1:half, 2) = linspace(1,    myGV, half);
                    cmap2(1:half, 3) = linspace(0,    myGV, half);
                    cmap2(half+1:end, 1) = linspace(myGV, 1,  rest);
                    cmap2(half+1:end, 2) = linspace(myGV, 0,  rest);
                    cmap2(half+1:end, 3) = linspace(myGV, 0,  rest);
                    cmap = cmap2;

                case 'MagentaGrayGreen'
                    cmap2 = zeros(n, 3);
                    cmap2(1:half, 1) = linspace(1,    myGV, half);
                    cmap2(1:half, 2) = linspace(0,    myGV, half);
                    cmap2(1:half, 3) = linspace(1,    myGV, half);
                    cmap2(half+1:end, 1) = linspace(myGV, 0,  rest);
                    cmap2(half+1:end, 2) = linspace(myGV, 1,  rest);
                    cmap2(half+1:end, 3) = linspace(myGV, 0,  rest);
                    cmap = cmap2;
            end
        end

        function idx = applyNeighborIdx_(model, dimIdx, avgMode, idx)
            % Return idx with XDim/YDim entries widened for the requested avgMode.
            % avgMode: 0=no-op (single pixel), 1=3x3 (hw=1), 2=5x5 (hw=2), 3=full zoom
            if avgMode == 0, return; end
            xd = model.XDim;
            yd = model.YDim;
            if avgMode == 3
                if dimIdx ~= xd
                    idx{xd} = model.ZoomRange(xd,1) : model.ZoomRange(xd,2);
                end
                if dimIdx ~= yd
                    idx{yd} = model.ZoomRange(yd,1) : model.ZoomRange(yd,2);
                end
            else
                hw = avgMode;
                if dimIdx ~= xd
                    xc = model.CurrPos(xd);
                    idx{xd} = max(1, xc-hw) : min(model.Size(xd), xc+hw);
                end
                if dimIdx ~= yd
                    yc = model.CurrPos(yd);
                    idx{yd} = max(1, yc-hw) : min(model.Size(yd), yc+hw);
                end
            end
        end

        function profile1D = avgOverNonProfileDims_(raw, dimIdx, nD)
            % Average raw over every dimension except dimIdx, then return as column vector.
            for d = 1:nD
                if d ~= dimIdx && size(raw, d) > 1
                    raw = mean(raw, d);
                end
            end
            profile1D = raw(:);
        end

        function [profile1D, alphaProf] = weightedProfiles_(rawData, rawAlpha, dimIdx, nD)
            % Alpha-weighted mean of rawData and plain mean of rawAlpha over
            % every dimension except dimIdx (the original matVis formula:
            % sum(data.*alpha)/sum(alpha.*~isnan(data))).
            num = rawData .* rawAlpha;
            den = rawAlpha .* ~isnan(rawData);
            for d = 1:nD
                if d ~= dimIdx && size(num, d) > 1
                    num = sum(num, d, 'omitnan');
                    den = sum(den, d, 'omitnan');
                end
            end
            profile1D = num(:) ./ den(:);
            for d = 1:nD
                if d ~= dimIdx && size(rawAlpha, d) > 1
                    rawAlpha = mean(rawAlpha, d, 'omitnan');
                end
            end
            alphaProf = rawAlpha(:);
        end

        function [lin, nPix, nT] = roiLinIndex_(model, dimIdx, roi, useZoomRange)
            % Linear indices of all ROI pixels at every step along dimIdx
            % (non-XY, non-profile dims fixed at CurrPos).  lin is a
            % nPix*nT column vector; empty when dimIdx is a display axis
            % or the ROI mask is empty.
            lin = []; nPix = 0; nT = 0;
            xd = model.XDim;  yd = model.YDim;
            if dimIdx == xd || dimIdx == yd
                return;
            end
            xs = roi.index.x(:);
            ys = roi.index.y(:);
            if isempty(xs), return; end
            if useZoomRange
                tR = model.ZoomRange(dimIdx, 1) : model.ZoomRange(dimIdx, 2);
            else
                tR = 1 : model.Size(dimIdx);
            end
            nPix = numel(xs);
            nT   = numel(tR);
            sz   = model.Size;
            nD   = numel(sz);
            subs = cell(1, nD);
            for d = 1:nD
                if d == xd
                    subs{d} = repmat(xs, nT, 1);
                elseif d == yd
                    subs{d} = repmat(ys, nT, 1);
                elseif d == dimIdx
                    subs{d} = kron(tR(:), ones(nPix, 1));
                else
                    subs{d} = repmat(model.CurrPos(d), nPix * nT, 1);
                end
            end
            lin = sub2ind(sz, subs{:});
        end

    end
end
