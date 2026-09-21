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
            raw = MatVisRender.rawSliceFromPlan(data, model, ...
                MatVisRender.rawZoomSlicePlan(model));
        end

        function raw = getRawFullSliceFromData(model, data)
            raw = MatVisRender.rawSliceFromPlan(data, model, ...
                MatVisRender.rawFullSlicePlan(model));
        end

        % ------------------------------------------------------------------
        %  Slice plans
        %
        %  A plan is the complete recipe for one raw slice: which elements to
        %  read, and how to reduce and orient them.  It carries a KEY that
        %  identifies the resulting array, so a caller can tell whether a
        %  slice it already holds is still valid before paying for a new one
        %  (see MatVisModel.CachedSlice).
        %
        %  Contrast bounds, gamma, the colormap and the RGB stretch colours
        %  are deliberately absent from a plan: they change the colours a
        %  slice is drawn in, never its pixel values, so adjusting them must
        %  never cost a re-slice — which for a projection over a large stack
        %  means re-reading the whole stack.
        % ------------------------------------------------------------------
        function plan = rawZoomSlicePlan(model)
            % Plan for the zoom crop of the model's own display plane.
            xIdx = model.ZoomRange(model.XDim, 1) : model.ZoomRange(model.XDim, 2);
            yIdx = model.ZoomRange(model.YDim, 1) : model.ZoomRange(model.YDim, 2);
            plan = MatVisRender.rawSlicePlan(model, model.XDim, model.YDim, ...
                xIdx, yIdx, false, true);
        end

        function plan = rawFullSlicePlan(model)
            % Plan for the full extent of the model's own display plane.
            plan = MatVisRender.rawSlicePlan(model, model.XDim, model.YDim, ...
                [], [], true, true);
        end

        function plan = rawSlicePlan(model, xDim, yDim, xIdx, yIdx, projLock, doFlip)
            % rawSlicePlan  Index recipe + cache key for one raw slice.
            %   xIdx / yIdx : index vectors along xDim / yDim; [] = full extent
            %   projLock    : true  -> projection spans ProjZoomLock's range
            %                 false -> projection always spans the zoom interval
            %   doFlip      : apply model.FlipX / FlipY (only for its own plane)
            idx = num2cell(model.CurrPos);
            idx{xDim} = MatVisRender.canonIdx_(xIdx, model.Size(xDim));
            idx{yDim} = MatVisRender.canonIdx_(yIdx, model.Size(yDim));
            [doProj, pd] = MatVisRender.projStateFor_(model, xDim, yDim);
            [doRGB,  rd] = MatVisRender.rgbStateFor_(model, xDim, yDim, doProj, pd);
            doStretch    = doRGB && ~strcmp(model.RGBStretchMode, 'none');
            if doProj
                if projLock && ~model.ProjZoomLock
                    pIdx = [];                  % whole extent
                else
                    pIdx = model.ZoomRange(pd, 1) : model.ZoomRange(pd, 2);
                end
                idx{pd} = MatVisRender.canonIdx_(pIdx, model.Size(pd));
            end
            if doStretch
                idx{rd} = MatVisRender.canonIdx_( ...
                    MatVisRender.stretchRangeIdx_(model, rd), model.Size(rd));
            elseif doRGB
                idx{rd} = MatVisRender.rgbTriadIdx_(model, rd);
            end

            flipX = doFlip && model.FlipX;
            flipY = doFlip && model.FlipY;
            plan  = struct('idx', {idx}, 'xDim', xDim, 'yDim', yDim, ...
                'doProj', doProj, 'pd', pd, 'doRGB', doRGB, 'rd', rd, ...
                'doStretch', doStretch, 'doFlip', doFlip, 'key', {[]});
            % Everything the resulting values depend on.  idx covers CurrPos,
            % the zoom ranges and the RGB / stretch index selection; because
            % full-extent ranges are canonicalized to ':', the plans for the
            % full image and for an un-zoomed crop come out with equal keys
            % and the same slice serves both.
            plan.key = {idx, model.ProjFun, ...
                [xDim, yDim, doProj, pd, doRGB, rd, doStretch, flipX, flipY]};
        end

        function raw = rawSliceFromPlan(data, model, plan)
            % rawSliceFromPlan  Execute a plan against one data array.
            raw = MatVisRender.finalizeSliceDims_( ...
                MatVisRender.subarray_(data, plan.idx), model, ...
                plan.xDim, plan.yDim, plan.doProj, plan.pd, ...
                plan.doRGB, plan.rd, plan.doStretch, plan.doFlip);
        end

        % ------------------------------------------------------------------
        %  Arbitrary-plane / volume extraction (cross-section window)
        %
        %  The methods above are hard-wired to the model's own XDim/YDim
        %  display plane.  The ones below take the display dimensions as
        %  arguments so several planes of the same dataset can be shown side
        %  by side.  Projection and RGB colour coding are applied exactly as
        %  in the main image window whenever their dimension is not one of
        %  the two requested display dims; axis flips are applied only for
        %  the model's own plane, since they describe that display.
        % ------------------------------------------------------------------
        function raw = getRawSliceForDims(model, data, xDim, yDim, xIdx, yIdx)
            % getRawSliceForDims  2-D slice spanned by an arbitrary dim pair.
            %   xIdx / yIdx : index vectors along xDim / yDim (e.g. lo:hi)
            % Returns rows = yDim, cols = xDim (H×W×N in RGB modes).
            raw = MatVisRender.rawSliceFromPlan(data, model, ...
                MatVisRender.rawSlicePlanForDims(model, xDim, yDim, xIdx, yIdx));
        end

        function plan = rawSlicePlanForDims(model, xDim, yDim, xIdx, yIdx)
            % Plan behind getRawSliceForDims — exposed so the cross-section
            % window can skip re-slicing a panel whose content is unchanged.
            doFlip = (xDim == model.XDim && yDim == model.YDim);
            plan   = MatVisRender.rawSlicePlan(model, xDim, yDim, ...
                xIdx, yIdx, true, doFlip);
        end

        function vol = getRawVolumeForDims(model, data, dims3, idxCells)
            % getRawVolumeForDims  3-D sub-volume spanned by three dimensions.
            %   dims3    : 1×3 dimension indices
            %   idxCells : 1×3 cell of index vectors (may be strided for
            %              downsampling); all other dims are taken at CurrPos.
            % The result is permuted into dims3 order, so vol(i,j,k) is the
            % value at index idxCells{1}(i) / idxCells{2}(j) / idxCells{3}(k).
            idx = num2cell(model.CurrPos);
            for k = 1:3
                idx{dims3(k)} = idxCells{k};
            end
            raw   = data(idx{:});
            nd    = numel(model.Size);
            order = [dims3(:)', setdiff(1:nd, dims3)];
            raw   = permute(raw, order);
            vol   = double(reshape(raw, numel(idxCells{1}), ...
                                        numel(idxCells{2}), numel(idxCells{3})));
        end

        function tf = rgbActiveForDims(model, xDim, yDim)
            % True when RGB colour coding applies to the given display plane.
            [doProj, pd] = MatVisRender.projStateFor_(model, xDim, yDim);
            tf = MatVisRender.rgbStateFor_(model, xDim, yDim, doProj, pd);
        end

        function tf = stretchActiveForDims(model, xDim, yDim)
            % True when a whole-dimension RGB stretch applies to that plane.
            tf = MatVisRender.rgbActiveForDims(model, xDim, yDim) && ...
                 ~strcmp(model.RGBStretchMode, 'none');
        end

        function sp = spacingForDims(model, dims)
            % spacingForDims  Real-world size of one index step along each of
            % DIMS, or [] when the dims don't carry comparable scale.
            %
            % "Comparable" means every dim has a non-trivial DimScale AND all
            % share the same unit string: stretching an x/t panel by the
            % numeric frame interval (µm against s) is meaningless, so such a
            % pair falls back to square pixels.
            sp = [];
            n  = numel(dims);
            s  = zeros(1, n);
            u0 = model.dimUnit(dims(1));
            for k = 1:n
                d = dims(k);
                if ~model.hasRealScale(d), return; end
                if ~strcmp(model.dimUnit(d), u0), return; end
                v = abs(model.pixelSize(d));
                if ~isfinite(v) || v <= 0, return; end
                s(k) = v;
            end
            sp = s / min(s);
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

        function bad = badDisplayImage(model, where, img)
            % True when IMG is not something an Image object can take as
            % CData (numeric/logical, at most 3-D, 1 or 3 planes).  A render
            % must never hand one out; when it does the caller drops the
            % frame, because letting the CData write throw out of a play
            % timer kills playback and takes the state that caused it along.
            persistent nReported
            bad = ~((isnumeric(img) || islogical(img)) && ...
                    ndims(img) <= 3 && any(size(img, 3) == [1, 3]));
            if ~bad, return; end
            if isempty(nReported), nReported = 0; end
            nReported = nReported + 1;
            if nReported > 5, return; end
            dsSz = '';
            for k = 1:numel(model.Datasets)
                dsSz = [dsSz ' ' mat2str(size(model.Datasets{k}))];  %#ok<AGROW>
            end
            fprintf(2, ['[matVis2] %s received an invalid image (%s %s) - ' ...
                'frame dropped.\n          X=%d Y=%d proj=%d/%s rgb=%d ' ...
                'stretch=%s lock=%s\n          pos=%s zoom=%s filter=%s ' ...
                'contrast=%s\n          model size=%s, data size(s)=%s\n'], ...
                where, class(img), mat2str(size(img)), ...
                model.XDim, model.YDim, model.ProjDim, model.ProjFun, ...
                model.RGBDim, model.RGBStretchMode, ...
                mat2str(model.RGBStretchZoomLock), mat2str(model.CurrPos), ...
                mat2str(model.ZoomRange), model.FilterType, model.ContrastMode, ...
                mat2str(model.Size), dsSz);
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

        function tf = rgbTriadActive(model)
            % True when RGB colour coding maps three consecutive slices to
            % R/G/B (RGB on, no whole-dimension stretch selected).
            tf = MatVisRender.rgbActive(model) && ...
                 strcmp(model.RGBStretchMode, 'none');
        end

        function idx = rgbChannelIndices(model)
            % Source indices along model.RGBDim behind the pages of the
            % current RGB stack: the [prev,curr,next] triad, or the whole
            % stretch span when a stretch mode is active.  Used by the
            % 'Channel' contrast mode to look up each page's data range.
            if strcmp(model.RGBStretchMode, 'none')
                idx = MatVisRender.rgbTriadIdx_(model, model.RGBDim);
            else
                idx = MatVisRender.stretchRangeIdx_(model, model.RGBDim);
            end
        end

        function out = normalizeChannels(stack, chanRange)
            % Per-page contrast equalization of an H×W×N RGB stack: page k is
            % mapped from chanRange(k,:) onto [0,1] and clamped there.  This
            % is the pre-normalization behind the original matVis "Channel"
            % mode, which equalized the range of the channel images before
            % the contrast window was applied.  An empty chanRange or a row
            % count that doesn't match the stack leaves the data untouched.
            out = double(stack);
            if isempty(chanRange), return; end
            n = size(out, 3);
            if size(chanRange, 1) ~= n, return; end
            lo   = reshape(chanRange(:, 1), 1, 1, n);
            span = reshape(chanRange(:, 2) - chanRange(:, 1), 1, 1, n);
            span(span == 0) = 1;
            out = max(0, min(1, (out - lo) ./ span));
        end

        function cr = channelRangeFromStack(stack, pLow, pHigh)
            % N×2 [lo hi] per page of an H×W×N stack — the range of the
            % images currently on display ('ChannelImage' mode).  With
            % percentile cutoffs given (pLow > 0 or pHigh < 1) the quantiles
            % are used instead of the extrema.
            n  = size(stack, 3);
            cr = zeros(n, 2);
            usePerc = nargin >= 3 && ~isempty(pLow) && (pLow > 0 || pHigh < 1);
            for k = 1:n
                p = double(stack(:, :, k));
                p = p(isfinite(p));
                if isempty(p)
                    cr(k, :) = [0, 1];
                elseif usePerc
                    cr(k, :) = quantile(p, [pLow, pHigh]);
                else
                    cr(k, :) = [min(p), max(p)];
                end
            end
        end

        function cr = channelRangeFromData(data, rd, pLow, pHigh)
            % size(data,rd)×2 [lo hi]: the range of every index along
            % dimension rd over the full extent of all other dimensions
            % ('Channel' mode).  Unlike channelRangeFromStack this does not
            % depend on the current position, so the channel equalization
            % stays fixed while navigating the remaining dimensions.
            % One slab is copied at a time (never the whole array), and
            % integer data is reduced natively to avoid a double copy.
            nd = ndims(data);
            n  = size(data, rd);
            cr = zeros(n, 2);
            usePerc = nargin >= 4 && ~isempty(pLow) && (pLow > 0 || pHigh < 1);
            sub = repmat({':'}, 1, nd);
            for k = 1:n
                sub{rd} = k;
                slab = data(sub{:});
                if isfloat(slab)
                    slab = slab(isfinite(slab));
                end
                if isempty(slab)
                    cr(k, :) = [0, 1];
                elseif usePerc
                    cr(k, :) = quantile(double(slab(:)), [pLow, pHigh]);
                else
                    cr(k, :) = [double(min(slab(:))), double(max(slab(:)))];
                end
            end
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
        % ------------------------------------------------------------------
        %  Zoom geometry
        %
        %  An image axes with a fixed data aspect ratio letterboxes: the plot
        %  box shrinks until the data range fits, leaving empty space on one
        %  pair of sides.  fitZoomToAxes grows the range into that space, so
        %  zooming in fills the axes instead of leaving a strip in an empty
        %  panel.  pixelsPerDataUnit reports the screen scale that results,
        %  which is what turns a mouse drag in pixels into a shift in data
        %  indices.
        % ------------------------------------------------------------------
        function [xr, yr] = zoomStepAtCursor(xr, yr, xN, yN, factor, cx, cy)
            % One wheel step on a zoom range: scale both ranges by FACTOR
            % (> 1 = zoom out) about the data point (CX, CY).
            %
            % The width is scaled first and the range is then shifted to fit
            % inside the dimension.  Clipping the two ends instead — which is
            % what this used to do — swallows most of the step near an end of
            % a dimension, so zooming out stalls, its step depends on where
            % the cursor sits, and with the cursor close enough to an end the
            % clipped range comes out *narrower* than before: a zoom-out that
            % zooms in.
            xr = MatVisRender.zoomStep_(xr, xN, factor, cx);
            yr = MatVisRender.zoomStep_(yr, yN, factor, cy);
        end

        function [pxX, pxY] = pixelsPerDataUnit(ax)
            % Screen pixels per data unit along x and y, for the limits the
            % axes currently holds.  Zero when it cannot be determined.
            pxX = 0;  pxY = 0;
            [wp, hp] = MatVisRender.axesDataAreaPixels(ax);
            if wp <= 0 || hp <= 0, return; end
            sx = abs(diff(ax.XLim));
            sy = abs(diff(ax.YLim));
            if sx <= 0 || sy <= 0, return; end
            if strcmp(ax.DataAspectRatioMode, 'manual')
                % The plot box is the largest one of the required shape that
                % still fits, so one common scale k applies to both axes.
                r = ax.DataAspectRatio;
                k = min(wp / (sx / r(1)), hp / (sy / r(2)));
                pxX = k / r(1);
                pxY = k / r(2);
            else
                pxX = wp / sx;      % axes stretches, no letterbox
                pxY = hp / sy;
            end
        end

        function [xr, yr] = fitZoomToAxes(ax, xr, yr, xN, yN)
            % Grow XR/YR (index ranges, [lo hi]) until their proportions
            % match those of AX, so the zoom fills it.  Only ever grows, and
            % never beyond [1 xN] / [1 yN], so the requested region stays
            % visible; a stretched axes needs no correction at all.
            if isempty(ax) || ~isvalid(ax), return; end
            if ~strcmp(ax.DataAspectRatioMode, 'manual'), return; end
            [wp, hp] = MatVisRender.axesDataAreaPixels(ax);
            if wp <= 0 || hp <= 0, return; end
            r  = ax.DataAspectRatio;
            wx = xr(2) - xr(1) + 1;
            wy = yr(2) - yr(1) + 1;
            if wx <= 0 || wy <= 0, return; end
            % On screen the range spans [wx/r(1), wy/r(2)] times a common
            % scale; it fills the axes when that has the axes' proportions.
            needY = wx * (r(2)/r(1)) * (hp/wp);
            needX = wy * (r(1)/r(2)) * (wp/hp);
            if needY > wy + 0.5
                yr = MatVisRender.growRange_(yr, needY, yN);
            elseif needX > wx + 0.5
                xr = MatVisRender.growRange_(xr, needX, xN);
            end
        end

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

        % ==================================================================
        %  Overlay painting
        %
        %  ROI and profile overlays are drawn identically in every panel that
        %  shows a slice — the image window, the zoom window and the offscreen
        %  panels of the video composer.  The panels differ only in where the
        %  panel's (1,1) pixel sits in data coordinates, so that offset is the
        %  single parameter.  Keeping one implementation is what stops the
        %  movie from quietly falling behind the on-screen look.
        %
        %    origin : [xOff yOff] subtracted from data coords before drawing
        %             full-image panel -> [0 0]
        %             zoom panel       -> model.ZoomRange([XDim YDim], 1)' - 1
        %    h      : handle pool returned by the previous call; pass [] the
        %             first time.  Always assign the return value back.
        % ==================================================================
        function origin = panelOrigin(model, isZoomPanel)
            % Data-coordinate offset of a panel's first pixel (see above).
            if nargin < 2 || ~isZoomPanel
                origin = [0 0];
            else
                origin = model.ZoomRange([model.XDim, model.YDim], 1)' - 1;
            end
        end

        function h = paintRoiOverlay(ax, model, origin, h)
            if nargin < 4 || isempty(h)
                h = struct('lines', gobjects(1, 0), 'texts', gobjects(1, 0));
            end
            visIdx = model.VisibleRoiIndices();
            n      = numel(visIdx);

            % Grow / shrink the handle pools
            for k = numel(h.lines)+1 : n
                h.lines(k) = line(ax, NaN, NaN, 'HitTest', 'off', 'PickableParts', 'none');
                h.texts(k) = text(ax, NaN, NaN, '', 'HitTest', 'off', ...
                    'PickableParts', 'none', 'FontSize', 9, 'Clipping', 'on');
            end
            for k = n+1 : numel(h.lines)
                if isgraphics(h.lines(k)), delete(h.lines(k)); end
                if isgraphics(h.texts(k)), delete(h.texts(k)); end
            end
            h.lines = h.lines(1:n);
            h.texts = h.texts(1:n);
            if n == 0, return; end

            sel    = model.RoiSelection;
            selVis = visIdx(ismember(visIdx, sel));
            cols   = MatVisRender.roiColors(max(numel(selVis), 1));
            lw     = max(model.RoiLineWidth, 0.5);

            for k = 1:n
                idx = visIdx(k);
                c   = model.RoiList(idx).corners;
                cx  = c(1,:) - origin(1);
                cy  = c(2,:) - origin(2);
                selPos = find(selVis == idx, 1);
                if ~isempty(selPos)
                    col = cols(selPos, :);  w = lw;             fw = 'bold';
                else
                    col = [1 1 1];          w = max(lw/2, 0.5);  fw = 'normal';
                end
                set(h.lines(k), 'XData', cx, 'YData', cy, ...
                    'Color', col, 'LineWidth', w, 'LineStyle', model.RoiLineStyle, ...
                    'Visible', 'on');
                set(h.texts(k), 'Position', [max(cx) + 1, mean(cy)], ...
                    'String', model.RoiList(idx).name, 'Color', col, ...
                    'FontWeight', fw, 'Visible', MatVisRender.onOff_(model.RoiShowNames));
            end
        end

        function h = paintProfileOverlay(ax, model, origin, h)
            if nargin < 4 || isempty(h)
                h = struct('lines', gobjects(1, 0), 'bands', gobjects(1, 0), ...
                           'arrows', gobjects(1, 0), 'texts', gobjects(1, 0));
            end
            visIdx = model.VisibleProfileIndices();
            n      = numel(visIdx);

            for k = numel(h.lines)+1 : n
                h.lines(k)  = line(ax, NaN, NaN, 'HitTest', 'off', ...
                    'PickableParts', 'none', 'LineWidth', 1.5);
                h.bands(k)  = line(ax, NaN, NaN, 'HitTest', 'off', ...
                    'PickableParts', 'none', 'LineStyle', ':', 'LineWidth', 1);
                h.arrows(k) = line(ax, NaN, NaN, 'HitTest', 'off', ...
                    'PickableParts', 'none', 'LineWidth', 1.5);
                h.texts(k)  = text(ax, NaN, NaN, '', 'HitTest', 'off', ...
                    'PickableParts', 'none', 'FontSize', 9, 'Clipping', 'on');
            end
            for k = n+1 : numel(h.lines)
                if isgraphics(h.lines(k)),  delete(h.lines(k));  end
                if isgraphics(h.bands(k)),  delete(h.bands(k));  end
                if isgraphics(h.arrows(k)), delete(h.arrows(k)); end
                if isgraphics(h.texts(k)),  delete(h.texts(k));  end
            end
            h.lines  = h.lines(1:n);
            h.bands  = h.bands(1:n);
            h.arrows = h.arrows(1:n);
            h.texts  = h.texts(1:n);
            if n == 0, return; end

            sel    = model.ProfileSelection;
            selVis = visIdx(ismember(visIdx, sel));
            cols   = MatVisRender.roiColors(max(numel(selVis), 1));

            for k = 1:n
                idx  = visIdx(k);
                prof = model.ProfileList(idx);
                sp   = prof.smoothedPoints;
                [bx, by, axx, ayy] = MatVisRender.profileBandArrow_(model, sp);
                spx = sp(1,:) - origin(1);   spy = sp(2,:) - origin(2);
                bx  = bx  - origin(1);       by  = by  - origin(2);
                axx = axx - origin(1);       ayy = ayy - origin(2);
                selPos = find(selVis == idx, 1);
                if ~isempty(selPos)
                    col = cols(selPos, :);  w = 2;  fw = 'bold';
                else
                    col = [1 1 1];          w = 1;  fw = 'normal';
                end
                set(h.lines(k),  'XData', spx, 'YData', spy, ...
                    'Color', col, 'LineWidth', w, 'Visible', 'on');
                set(h.bands(k),  'XData', bx, 'YData', by, 'Color', col, ...
                    'Visible', 'on');
                set(h.arrows(k), 'XData', axx, 'YData', ayy, 'Color', col, ...
                    'Visible', MatVisRender.onOff_(model.ProfileShowDir));
                set(h.texts(k),  'Position', [spx(end) + 1, spy(end)], ...
                    'String', prof.name, 'Color', col, 'FontWeight', fw, ...
                    'Visible', MatVisRender.onOff_(model.ProfileShowNames));
            end
        end
    end

    methods (Static, Access = private)
        function s = onOff_(tf)
            if tf, s = 'on'; else, s = 'off'; end
        end

        function [bx, by, axx, ayy] = profileBandArrow_(model, sp)
            % Width-band outline and direction arrow (data coords) for a path SP.
            M   = MatVisModel.ProfileSampleMatrix(sp, model.ProfileWidth);
            s1x = M(1, :, 1);    s1y = M(1, :, 2);
            s2x = M(end, :, 1);  s2y = M(end, :, 2);
            bx  = [s1x, fliplr(s2x), s1x(1)];
            by  = [s1y, fliplr(s2y), s1y(1)];
            p2  = sp(:, end);
            p1  = sp(:, max(1, end-1));
            d   = p2 - p1;  nd = hypot(d(1), d(2));  if nd == 0, nd = 1; end
            d   = d / nd;   perp = [-d(2); d(1)];
            aLen = max(3, model.ProfileWidth * 0.7);
            b1  = p2 - aLen*d + aLen*0.4*perp;
            b2  = p2 - aLen*d - aLen*0.4*perp;
            axx = [b1(1), p2(1), b2(1)];
            ayy = [b1(2), p2(2), b2(2)];
        end

        function [wp, hp] = axesDataAreaPixels(ax)
            % Pixel size of the area the axes has for data, before the aspect
            % ratio shrinks the plot box inside it.  The units are read, not
            % switched: converting them back and forth on every mouse event
            % would drift the axes position.
            wp = 0;  hp = 0;
            if isempty(ax) || ~isvalid(ax), return; end
            try
                ip = ax.InnerPosition;
                switch ax.Units
                    case 'pixels'
                        wp = ip(3);  hp = ip(4);
                    case 'normalized'
                        pp = getpixelposition(ax.Parent, true);
                        wp = ip(3) * pp(3);  hp = ip(4) * pp(4);
                end
            catch
            end
        end

        function r = zoomStep_(r, n, factor, c)
            % Scale one range about C, keeping C at the same relative place
            % in it, so the point under the cursor does not move.
            lo   = r(1);
            w    = r(2) - lo + 1;
            if w <= 0 || n < 1, return; end
            frac = max(0, min(1, (c - lo) / max(w - 1, 1)));
            wNew = max(min(2, n), min(n, round(w * factor)));
            lo   = round(c - frac * (wNew - 1));
            lo   = max(1, min(lo, n - wNew + 1));
            r    = [lo, lo + wNew - 1];
        end

        function r = growRange_(r, wNew, n)
            wNew = min(round(wNew), n);
            w    = r(2) - r(1) + 1;
            if wNew <= w, return; end
            lo = round(r(1) - (wNew - w) / 2);      % grow to both sides
            lo = max(1, min(lo, n - wNew + 1));
            r  = [lo, lo + wNew - 1];
        end

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
            [doProj, pd] = MatVisRender.projStateFor_(model, model.XDim, model.YDim);
        end

        function [doProj, pd] = projStateFor_(model, xDim, yDim)
            pd = model.ProjDim;
            doProj = ~strcmp(model.ProjFun, 'none') && pd > 0 && ...
                     pd ~= xDim && pd ~= yDim;
        end

        function [doRGB, rd] = rgbState_(model, doProj, pd)
            [doRGB, rd] = MatVisRender.rgbStateFor_(model, model.XDim, model.YDim, doProj, pd);
        end

        function [doRGB, rd] = rgbStateFor_(model, xDim, yDim, doProj, pd)
            % RGB is active when RGBDim > 0; it is suppressed if it would
            % collide with the display axes or an active projection on the
            % same dimension (projection wins).
            rd = model.RGBDim;
            doRGB = rd > 0 && ...
                    rd ~= xDim && rd ~= yDim && ...
                    ~(doProj && rd == pd);
        end

        function raw = finalizeSliceDims_(data, model, xDim, yDim, doProj, pd, doRGB, rd, doStretch, doFlip)
            % Reduce extracted data to a 2-D slice or, in RGB mode, an
            % H×W×nCh array, then apply axis flips.
            %   triad RGB  : nCh = 3 ([prev,curr,next] -> R/G/B)
            %   stretch RGB: nCh = number of slices along rd (coloured later)
            if nargin < 9,  doStretch = false; end
            if nargin < 10, doFlip    = true;  end
            if ~doRGB
                raw = MatVisRender.finalize2D(data, doProj, model.ProjFun, ...
                    pd, xDim, yDim);
            else
                % rd can sit past ndims(data) when the RGB dimension is the
                % trailing one and its selection left a singleton, which
                % MATLAB drops from the size; the index cell has to reach it
                % anyway, or the dims in between end up indexed with [].
                nd  = max(ndims(data), rd);
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
                        model.ProjFun, pd, xDim, yDim);
                end
                raw = zeros(size(chans{1}, 1), size(chans{1}, 2), nCh);
                for c = 1:nCh
                    raw(:, :, c) = chans{c};
                end
            end
            if doFlip
                if model.FlipX, raw = fliplr(raw); end
                if model.FlipY, raw = flipud(raw); end
            end
        end

        function idx = canonIdx_(idx, n)
            % Canonical form of one dimension's index vector: ':' whenever it
            % selects the whole dimension in order.  Keeps slice-plan keys
            % comparable across callers that spell the full extent differently
            % ([] vs 1:n), and lets subarray_ skip the copy altogether.
            if isempty(idx) || (numel(idx) == n && isequal(idx(:)', 1:n))
                idx = ':';
            end
        end

        function sub = subarray_(data, idx)
            % Extract the elements a plan asks for.  An all-':' index would
            % still make MATLAB materialize a full copy, so in that case the
            % array is passed through untouched — for a projection over a
            % large stack that copy is the single most expensive step.
            if all(cellfun(@(c) isequal(c, ':'), idx))
                sub = data;
            else
                sub = data(idx{:});
            end
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
            % DATA arrives in its stored type; the cast to double happens on
            % the 2-D result, so an integer stack is never expanded into a
            % full double copy of itself first.
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
            raw = double(raw);
        end

        function out = applyProjFun(data, fun, dim)
            % Reduce DATA along DIM using the named function.
            % max/min are exact in any numeric type and mean accumulates in
            % double when asked to, so those three run on the stored type.
            % std/var accept only floating point, so they still cast first.
            switch fun
                case 'max',  out = max(data,  [], dim);
                case 'min',  out = min(data,  [], dim);
                case 'mean', out = mean(data,     dim, 'double');
                case 'std',  out = std(double(data),  0,  dim);
                case 'var',  out = var(double(data),  0,  dim);
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

            nd  = max(ndims(data), projDim);   % see finalizeSliceDims_
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
