classdef MatVisRender
    properties (Constant)
        % Fraction of the RGB-stretch slider track reserved at each end for
        % solid blue / red (the rainbow fills the middle 1 - 2*PAD).
        RGB_STRETCH_PAD = 0.15;
    end

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
            doStretch    = doRGB && ~strcmp(model.RGBStretchMode, 'none');
            if doProj
                idx{pd} = model.ZoomRange(pd, 1) : model.ZoomRange(pd, 2);
            end
            if doStretch
                idx{rd} = MatVisRender.stretchRangeIdx_(model, rd);
            elseif doRGB
                idx{rd} = MatVisRender.rgbTriadIdx_(model, rd);
            end
            raw = double(data(idx{:}));
            raw = MatVisRender.finalizeSlice_(raw, model, doProj, pd, doRGB, rd, doStretch);
        end

        function raw = getRawFullSliceFromData(model, data)
            idx = num2cell(model.CurrPos);
            idx{model.XDim} = 1 : model.Size(model.XDim);
            idx{model.YDim} = 1 : model.Size(model.YDim);
            [doProj, pd] = MatVisRender.projState_(model);
            [doRGB, rd]  = MatVisRender.rgbState_(model, doProj, pd);
            doStretch    = doRGB && ~strcmp(model.RGBStretchMode, 'none');
            if doProj
                if model.ProjZoomLock
                    idx{pd} = model.ZoomRange(pd, 1) : model.ZoomRange(pd, 2);
                else
                    idx{pd} = 1 : model.Size(pd);
                end
            end
            if doStretch
                idx{rd} = MatVisRender.stretchRangeIdx_(model, rd);
            elseif doRGB
                idx{rd} = MatVisRender.rgbTriadIdx_(model, rd);
            end
            raw = double(data(idx{:}));
            raw = MatVisRender.finalizeSlice_(raw, model, doProj, pd, doRGB, rd, doStretch);
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

        % ==================================================================
        %  Profile (line-trace) sampling
        % ==================================================================
        function img = sampleProfileImage(model, data, profile)
            % sampleProfileImage  Straightened profile image for the current
            % slice: an [width × length] array sampled perpendicular to the
            % profile path.  Out-of-bounds samples are NaN.
            sp = profile.smoothedPoints;
            if isempty(sp) || size(sp, 2) < 2, img = []; return; end
            M  = MatVisModel.ProfileSampleMatrix(sp, model.ProfileWidth);
            S  = MatVisRender.currentScalarSlice_(model, data);
            img = interp2(S, M(:, :, 1), M(:, :, 2));   % S(row=y, col=x)
        end

        function p = profileProject(img, method)
            % profileProject  Reduce a [width × length] profile image across
            % its width (dim 1) using the named projection.  Returns a
            % column vector of length = profile length.
            if isempty(img), p = []; return; end
            switch method
                case 'Sum', p = sum(img, 1, 'omitnan');
                case 'Max', p = max(img, [], 1);
                case 'Min', p = min(img, [], 1);
                otherwise,  p = mean(img, 1, 'omitnan');
            end
            p = p(:);
        end

        function traceMat = profileTraceAlongDim(model, data, dimIdx, profile)
            % profileTraceAlongDim  Projected profile sampled at every index
            % along dimIdx.  Returns a [length × nSteps] matrix.  dimIdx must
            % not be one of the display (XY) dimensions.
            sp = profile.smoothedPoints;
            if isempty(sp) || size(sp, 2) < 2, traceMat = []; return; end
            M   = MatVisModel.ProfileSampleMatrix(sp, model.ProfileWidth);
            xq  = M(:, :, 1);  yq = M(:, :, 2);
            nT  = model.Size(dimIdx);
            L   = size(M, 2);
            traceMat = NaN(L, nT);
            idx = num2cell(model.CurrPos);
            idx{model.XDim} = 1 : model.Size(model.XDim);
            idx{model.YDim} = 1 : model.Size(model.YDim);
            for t = 1:nT
                idx{dimIdx} = t;
                raw = squeeze(double(data(idx{:})));
                if model.XDim < model.YDim, raw = raw.'; end
                img = interp2(raw, xq, yq);
                traceMat(:, t) = MatVisRender.profileProject(img, model.ProfileProjection);
            end
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

        function out = filterImage(raw, filterType, filterPar)
            % Apply a spatial filter to a raw 2-D slice (or H×W×3 RGB stack —
            % each channel is filtered independently in x/y).  Mirrors the
            % original matVis Image Processing Toolbox filters; operates on
            % raw (un-normalized) values so contrast bounds stay unaffected.
            %   filterType : 'none' | 'gauss' | 'median' | 'mean' | 'unsharp'
            %   filterPar  : scalar (isotropic) or [x y] (anisotropic).
            %                gauss   -> Gaussian sigma
            %                median  -> median neighbourhood size
            %                mean    -> averaging disk radius
            %                unsharp -> radius (2nd element, if given = amount)
            %                0 or [] disables filtering.
            out = raw;
            if nargin < 2 || isempty(filterType) || strcmp(filterType, 'none')
                return;
            end
            if nargin < 3 || isempty(filterPar)
                return;
            end
            fs = double(filterPar(:)');
            if all(fs == 0) || ~MatVisRender.filterAvailable()
                return;
            end
            % Map the parameter to a [rows cols] = [y x] size.  A 2-element
            % vector is entered as [x y]; swap to match the row/col layout of
            % the finalized slice (rows = Y, cols = X), as the original does.
            if isscalar(fs)
                sz = [fs fs];
            else
                sz = fs([2 1]);
            end
            if ndims(out) == 3 && size(out, 3) == 3
                for c = 1:3
                    out(:, :, c) = MatVisRender.filter2D_(out(:, :, c), filterType, sz, fs);
                end
            else
                out = MatVisRender.filter2D_(out, filterType, sz, fs);
            end
        end

        function tf = filterAvailable()
            % True when the Image Processing Toolbox filtering functions are
            % on the path.  Cached after the first probe.
            persistent avail
            if isempty(avail)
                avail = ~isempty(which('imfilter')) && ~isempty(which('fspecial'));
            end
            tf = avail;
        end

        function tf = filterActive(model)
            % True when an image filter is selected that would alter the data.
            tf = ~isempty(model.FilterType) && ~strcmp(model.FilterType, 'none') ...
                 && any(model.FilterPar(:) ~= 0) && MatVisRender.filterAvailable();
        end

        function [pRaw, pFilt] = renderFilteredSpatialProfile(model, data, dimIdx, useZoom)
            % Profile along a display (X or Y) dimension together with its
            % spatially-filtered counterpart, for overlaying both traces in
            % the plot window.  dimIdx must be model.XDim or model.YDim.
            %
            % The 2-D (XDim,YDim) slice at CurrPos is filtered as a whole,
            % then the line through CurrPos is extracted, so the filtered
            % trace reflects the same neighbourhood smoothing shown in the
            % image.  Both profiles are returned in data index order (matching
            % renderProfileFromData), so toggling the filter never flips the
            % unfiltered trace relative to the unfiltered-only display.
            xd = model.XDim;  yd = model.YDim;
            idx = num2cell(model.CurrPos);
            idx{xd} = 1 : model.Size(xd);
            idx{yd} = 1 : model.Size(yd);
            slab = squeeze(double(data(idx{:})));   % only XDim/YDim are non-singleton
            if xd < yd
                slab = slab.';                       % orient to [Y x X]
            end
            filt = MatVisRender.filterImage(slab, model.FilterType, model.FilterPar);
            if dimIdx == xd          % vary X (columns) at the current Y (row)
                r = model.CurrPos(yd);
                pRaw  = slab(r, :).';
                pFilt = filt(r, :).';
            else                     % vary Y (rows) at the current X (column)
                c = model.CurrPos(xd);
                pRaw  = slab(:, c);
                pFilt = filt(:, c);
            end
            if useZoom
                zr = model.ZoomRange(dimIdx, :);
                pRaw  = pRaw(zr(1):zr(2));
                pFilt = pFilt(zr(1):zr(2));
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

        function tf = rgbActive(model)
            % True when the RGB dimension is eligible for colour display
            % (selected, not an X/Y axis, not colliding with a projection).
            [doProj, pd] = MatVisRender.projState_(model);
            tf = MatVisRender.rgbState_(model, doProj, pd);
        end

        function tf = stretchActive(model)
            % True when a whole-dimension RGB stretch (mean/max) is in effect.
            tf = MatVisRender.rgbActive(model) && ...
                 ~strcmp(model.RGBStretchMode, 'none');
        end

        function idx3 = rgbTriadIndices(model)
            % Public accessor: the [prev, curr, next] source-frame indices
            % along model.RGBDim behind the RGB triad (R,G,B) overlay — for
            % UI indicators (e.g. the position-slider RGB markers).
            idx3 = MatVisRender.rgbTriadIdx_(model, model.RGBDim);
        end

        function idx = rgbStretchSpanIndices(model)
            % Public accessor: the frame indices along model.RGBDim included
            % in the current RGB stretch (full extent, or the zoom interval
            % when RGBStretchZoomLock is on) — for UI indicators.
            idx = MatVisRender.stretchRangeIdx_(model, model.RGBDim);
        end

        function colors = stretchSliceColors(model, N)
            % Per-slice rainbow colours for N frames evenly spanning
            % model.RGBStretchRange (mirrors the colour assignment used in
            % renderStretchImage; shared so UI indicators stay in sync).
            pad = MatVisRender.RGB_STRETCH_PAD;
            rng = model.RGBStretchRange;
            colors = zeros(N, 3);
            for k = 1:N
                sp = rng(1) + (rng(2) - rng(1)) * (k - 1) / max(N - 1, 1);
                t  = (sp - pad) / max(1 - 2*pad, eps);   % slider space -> rainbow pos
                t  = max(0, min(1, t));                  % outer margins -> solid blue/red
                colors(k, :) = MatVisRender.rainbowRGB(t, 3, 1);
            end
        end

        function img = renderStretchImage(model, stack, cMin, cMax, gamma)
            % Colour-code a whole RGB dimension into a display image, à la
            % matVis "MeanStretch"/"MaxStretch".
            %   stack : H×W×N raw intensities (already oriented + flipped)
            %   cMin/cMax : contrast bounds (data units)
            %   gamma : brightness gamma
            % Returns a uint8 H×W×3 image.
            if nargin < 5 || isempty(gamma), gamma = 1; end
            [H, W, N] = size(stack);
            P = H * W;

            % Rainbow colour for each slice. RGBStretchRange holds the two
            % slider positions in [0,1]; the rainbow occupies the middle 70%
            % (0.15..0.85) and slider positions in the outer 15% map to solid
            % blue / red. Indices interpolate linearly between the two thumbs.
            colors = MatVisRender.stretchSliceColors(model, N);

            minV = min(stack(:));
            maxV = max(stack(:));
            S = reshape(double(stack), P, N);

            if strcmp(model.RGBStretchMode, 'mean')
                % Intensity-weighted sum of slice colours (normalized so the
                % brightest achievable colour-sum maps to full scale).
                s = sum(colors, 1);
                denom = max(s);
                if denom > 0, colors = colors / denom; end
                out = S * colors;                      % P×3
            else  % 'max'
                [mx, ind] = max(S, [], 2);             % brightest slice / pixel
                out = repmat(mx, 1, 3) .* colors(ind, :);
            end

            img3 = reshape(out, H, W, 3);

            % Spatial filter (applied to the coloured image, as in matVis).
            if ~strcmp(model.FilterType, 'none')
                img3 = MatVisRender.filterImage(img3, model.FilterType, model.FilterPar);
            end

            % Contrast + gamma on brightness, preserving hue.
            if maxV > minV
                relMin = (cMin - minV) / (maxV - minV);
                relMax = (cMax - minV) / (maxV - minV);
            else
                relMin = 0;  relMax = 1;
            end
            img3 = MatVisRender.rgbContrastAdjust(img3, relMin, relMax, gamma);
            img  = uint8(max(0, min(1, img3)) * 255);
        end

        function out = rgbContrastAdjust(in, relMin, relMax, gamma)
            % Scale brightness of an H×W×3 image by a relative [min,max]
            % window and gamma while preserving hue (the RGB direction).
            % Ported from the original matVis rgbContrastAdjust.
            if nargin < 4 || isempty(gamma), gamma = 1; end
            sz = size(in);
            if numel(sz) < 3, sz(3) = 1; end
            in = reshape(double(in) - min(in(:)), [], sz(3));   % shift >= 0

            brightness = sqrt(sum(in.^2, 2, 'omitnan'));        % vector norm
            mx = max(in, [], 2);
            maxBright = in ./ mx;
            maxBright(mx == 0, :) = 0;
            maxBright = sqrt(sum(maxBright.^2, 2, 'omitnan'));

            hue = in ./ brightness;
            hue(brightness == 0, :) = 0;

            brightness = brightness ./ maxBright;
            brightness(isnan(brightness)) = 0;

            bmax = max(brightness(:));
            if bmax > 0, brightness = brightness / bmax; end    % -> [0,1]
            if relMax > relMin
                brightness = (brightness - relMin) / (relMax - relMin);
            end
            brightness = max(0, min(1, brightness));
            if gamma ~= 1, brightness = brightness .^ gamma; end
            brightness = brightness .* maxBright;               % restore scale

            out = hue .* brightness;
            out(out > 1) = 1;
            out = reshape(out, sz);
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

        % ------------------------------------------------------------------
        %  Real-world axis scaling (ticks + labels for image/zoom axes)
        %
        %  Image/zoom axes hold the data in PIXEL coordinates (1..W / 1..H);
        %  the data index along a dimension is  pixel + offset  (offset = 0
        %  for the full image, ZoomRange(dim,1)-1 for the zoom crop).  These
        %  helpers relabel the rulers with real-world coordinates derived
        %  from model.DimScale, leaving the pixel coordinate system (and all
        %  mouse interaction) untouched.  When no scale is supplied the
        %  labels reduce to the plain pixel indices.
        % ------------------------------------------------------------------
        function applyAxisScale(ax, model, xDim, xOffset, yDim, yOffset)
            if isempty(ax) || ~isvalid(ax), return; end
            [xt, xl] = MatVisRender.axisTicks_(model, xDim, xOffset, ax.XLim);
            [yt, yl] = MatVisRender.axisTicks_(model, yDim, yOffset, ax.YLim);
            if ~isempty(xt)
                ax.XTick = xt;  ax.XTickLabel = xl;
            end
            if ~isempty(yt)
                ax.YTick = yt;  ax.YTickLabel = yl;
            end
            ax.XLabel.String = MatVisRender.axisLabel_(model, xDim);
            ax.YLabel.String = MatVisRender.axisLabel_(model, yDim);
        end

        function ticks = niceTicks(lo, hi, maxN)
            % Choose ~maxN "nice" round tick values spanning [lo, hi].
            if nargin < 3, maxN = 5; end
            if ~isfinite(lo) || ~isfinite(hi) || hi == lo
                ticks = lo;  return;
            end
            if hi < lo, tmp = lo;  lo = hi;  hi = tmp; end
            raw  = (hi - lo) / max(maxN, 1);
            mag  = 10 ^ floor(log10(raw));
            n    = raw / mag;
            if     n < 1.5, step = 1;
            elseif n < 3,   step = 2;
            elseif n < 7,   step = 5;
            else            step = 10;
            end
            step  = step * mag;
            t0    = ceil(lo / step) * step;
            ticks = t0 : step : hi + step * 1e-9;
            ticks = ticks + 0;   % normalize IEEE negative zero (-0 -> 0)
        end

        function cmap = rgbStretchColormap(n)
            % Public n×3 rainbow (blue-cyan-green-yellow-red) used for RGB
            % stretch colour coding and the stretch-bar colourbar.
            if nargin < 1, n = 256; end
            cmap = MatVisRender.buildRainbow(n, 3, 1);
        end
    end

    methods (Static, Access = private)
        function [pixTicks, labels] = axisTicks_(model, dim, offset, lim)
            % Nice real-world ticks for the pixel axis with limits LIM.
            real0 = model.indexToReal(dim, lim(1) + offset);
            real1 = model.indexToReal(dim, lim(2) + offset);
            rt    = MatVisRender.niceTicks(real0, real1, 5);

            sc1 = model.indexToReal(dim, 1);
            f   = model.pixelSize(dim);
            if f == 0, f = 1; end
            idx      = 1 + (rt - sc1) / f;   % real -> data index (linear)
            pixTicks = idx - offset;         % data index -> pixel coordinate

            keep     = pixTicks >= lim(1) - 1e-6 & pixTicks <= lim(2) + 1e-6;
            pixTicks = pixTicks(keep);
            rt       = rt(keep);
            % XTick/YTick must be strictly increasing (scale may be reversed)
            [pixTicks, order] = sort(pixTicks);
            rt = rt(order);
            if isempty(pixTicks)
                pixTicks = [lim(1), lim(2)];
                rt       = [real0, real1];
            end
            labels = arrayfun(@(v) sprintf('%.4g', v), rt, 'UniformOutput', false);
        end

        function s = axisLabel_(model, dim)
            if dim >= 1 && dim <= numel(model.DimNames)
                s = model.DimNames{dim};
            else
                s = sprintf('Dim%d', dim);
            end
            u = model.dimUnit(dim);
            if ~isempty(u)
                s = sprintf('%s [%s]', s, u);
            end
        end
    end

    methods (Static, Access = private)

        function out = filter2D_(in, filterType, sz, fs)
            % Filter a single 2-D plane.  sz = [rows cols] derived size;
            % fs = the raw parameter vector (for unsharp amount).  NaNs are
            % preserved by routing around them where the filter would spread
            % them across the whole image.
            switch filterType
                case 'gauss'
                    sigma = max(sz(1), 0.5);
                    hsize = max(3, round(sz * 5));   % ~5*sigma window, per axis
                    h     = fspecial('gaussian', hsize, sigma);
                    out   = imfilter(in, h, 'replicate');
                case 'median'
                    out = medfilt2(in, max(1, round(sz)));
                case 'mean'
                    h   = fspecial('disk', max(1, sz(1)));
                    out = imfilter(in, h, 'replicate');
                case 'unsharp'
                    if ~isempty(which('imsharpen'))
                        if numel(fs) >= 2
                            out = imsharpen(in, 'Radius', max(0.1, fs(1)), 'Amount', fs(2));
                        else
                            out = imsharpen(in, 'Radius', max(0.1, fs(1)));
                        end
                    else
                        h   = fspecial('unsharp', min(1, sz(1) / 10));
                        out = imfilter(in, h, 'replicate');
                    end
                otherwise
                    out = in;
            end
        end

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

        function raw = finalizeSlice_(data, model, doProj, pd, doRGB, rd, doStretch)
            % Reduce extracted data to a 2-D slice or, in RGB mode, an
            % H×W×nCh array, then apply axis flips.
            %   triad RGB  : nCh = 3 ([prev,curr,next] -> R/G/B)
            %   stretch RGB: nCh = number of slices along rd (coloured later)
            if nargin < 7, doStretch = false; end
            if ~doRGB
                raw = MatVisRender.finalize2D(data, doProj, model.ProjFun, ...
                    pd, model.XDim, model.YDim);
            else
                nd  = ndims(data);
                if doStretch
                    nCh = size(data, rd);
                else
                    nCh = 3;
                end
                chans = cell(1, nCh);
                for c = 1:nCh
                    idxc = repmat({':'}, 1, nd);
                    idxc{rd} = c;
                    chans{c} = MatVisRender.finalize2D(data(idxc{:}), doProj, ...
                        model.ProjFun, pd, model.XDim, model.YDim);
                end
                raw = zeros(size(chans{1}, 1), size(chans{1}, 2), nCh);
                for c = 1:nCh
                    raw(:, :, c) = chans{c};
                end
            end
            if model.FlipX, raw = fliplr(raw); end
            if model.FlipY, raw = flipud(raw); end
        end

        function idx = stretchRangeIdx_(model, rd)
            % Indices along the RGB dimension used for stretch projection:
            % the full extent, or the zoom interval when the stretch lock is on.
            if model.RGBStretchZoomLock
                idx = model.ZoomRange(rd, 1) : model.ZoomRange(rd, 2);
            else
                idx = 1 : model.Size(rd);
            end
            if isempty(idx), idx = 1; end
        end

        function idx3 = rgbTriadIdx_(model, rd)
            % Three consecutive positions along rd around CurrPos(rd), with
            % wraparound: [prev, curr, next] -> [red, green, blue].
            n = model.Size(rd);
            c = model.CurrPos(rd);
            idx3 = mod([c-2, c-1, c], n) + 1;
        end

        function S = currentScalarSlice_(model, data)
            % 2-D scalar slice of the current position oriented as S(y, x):
            % row = YDim index, column = XDim index (same orientation in
            % which ROI/profile overlays are drawn, ignoring axis flips).
            idx = num2cell(model.CurrPos);
            idx{model.XDim} = 1 : model.Size(model.XDim);
            idx{model.YDim} = 1 : model.Size(model.YDim);
            S = squeeze(double(data(idx{:})));
            if model.XDim < model.YDim
                S = S.';
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
