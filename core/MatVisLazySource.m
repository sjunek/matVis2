classdef MatVisLazySource < MatVisDataSource
    % MatVisLazySource  Data source that reads image planes from a file on demand.
    %
    %   Shared machinery for every file-backed source.  All the N-dimensional
    %   bookkeeping lives here; a format backend only has to answer three
    %   questions -- how many planes are there, which plane holds a given set
    %   of coordinates, and what are that plane's pixels.
    %
    %   The layout assumption is the one matVis's readers already produce (see
    %   finalizeOmePlanes): dimensions 1 and 2 are the in-plane axes (Y, X),
    %   and dimensions 3..N select a plane.  A request for a hyperrectangle is
    %   therefore a set of plane reads plus an in-plane crop of each.
    %
    %   Whole-dataset answers -- the value range, the global histogram, the
    %   per-channel ranges -- come from a decimated OVERVIEW rather than from
    %   the file in full.  They are approximations, and StatsApproximate says so,
    %   because computing them exactly means reading everything, which is the
    %   cost this class exists to avoid.
    %
    %   See also MatVisDataSource, MatVisPlaneCache, MatVisBioFormatsSource.

    properties (SetAccess = protected)
        Size
        ClassName
        IsInteger
    end

    properties (SetAccess = protected)
        FilePath        % source file
        LevelSizes      % 1xL cell of 1xN sizes; level 1 = full resolution
        Capabilities    % struct: HasFileLevels, SupportsTiles, PlaneReadCost
        Cache           % MatVisPlaneCache (shared)
        CacheTag        % unique prefix for this source's cache keys
        Overview        % decimated N-D array, or [] until built
        OverviewIdx     % 1xN cell of the indices the overview sampled
        FullLoadFeasible = true % false when reading the file into one array
                                % cannot work at all, whatever the machine
    end

    properties
        % Called as ProgressFcn(done, total) while a run of plane reads is in
        % flight, and ProgressFcn([], []) when it finishes.  MATLAB is
        % single-threaded, so this is the only way a long read can say
        % anything: without it a projection over 57 planes is an unexplained
        % three-second pause.
        ProgressFcn = []
    end

    methods
        function obj = MatVisLazySource()
            % Every file-backed source answers whole-dataset questions from a
            % sample; see StatsApproximate on the base class.
            obj.StatsApproximate = true;
        end
    end

    properties (Access = protected)
        Min_    = 0
        Max_    = 1
        Peak_   = 1     % linear index (into Size) of the largest sampled value
        HasRangeEstimate_ = false   % false until the first sample is in
    end

    properties (Constant)
        % Seconds the overview may spend reading planes when it has to
        % decimate the full-resolution stack itself.  A file that carries its
        % own resolution levels ignores this -- reading a coarse level whole
        % is cheaper than any sampling of the fine one.
        OverviewTimeBudget = 5

        % Above this, a plane is read by region rather than whole.  Bio-Formats
        % cannot return a plane larger than 2 GB at all, and caching one that
        % big would evict everything else even when it fits.
        WholePlaneLimit = 128 * 1024^2
    end

    methods (Abstract, Access = protected)
        % readPlaneRaw  Full [Y X] plane PLANEIDX at resolution LEVEL.
        A = readPlaneRaw(obj, planeIdx, level)

        % planeIndexFromSubs  Backend plane number for plane-dimension
        % coordinates SUBS (1x(N-2), all 1-based); [] for a 2-D dataset.
        i = planeIndexFromSubs(obj, subs)
    end

    methods
        function delete(obj)
            obj.closeSource();
        end

        function closeSource(obj)  %#ok<MANU>
            % Release any file/reader handle.  Backends override.
        end

        % ------------------------------------------------------------------
        %  Reads
        % ------------------------------------------------------------------
        function A = readSub(obj, idx)
            % Indices are always in full-resolution coordinates.  A caller
            % that wants fewer pixels than the region contains asks for them
            % with a stride, and that stride is what selects the resolution
            % level: asking for every 9th pixel of a stitched image is served
            % from the level that already is one ninth the size, at a ninth
            % of the cost, instead of reading the finest one and throwing
            % most of it away.  The number of samples returned is the number
            % asked for either way, so nothing above here has to know.
            idx   = MatVisLazySource.canonIdx_(idx, obj.Size);
            level = obj.levelForStride_(obj.inPlaneStride_(idx));
            if level > 1
                idx = obj.fullIdxToLevel_(idx, level);
            end
            A = obj.readSubAtLevel(idx, level);
        end

        function level = levelForStride_(obj, stride)
            % Coarsest level whose own sampling is still at least as fine as
            % the stride asked for, so no detail the caller wanted is lost.
            level = 1;
            for L = 2:numel(obj.LevelSizes)
                if obj.levelScale_(L) <= stride
                    level = L;
                else
                    break;
                end
            end
        end

        function A = readSubAtLevel(obj, idx, level)
            % Like readSub, but indexing the given resolution level: the two
            % in-plane axes are addressed in that level's own coordinates,
            % while the plane dimensions are identical at every level.
            if nargin < 3 || isempty(level), level = 1; end
            sz  = obj.LevelSizes{level};
            N   = numel(sz);
            idx = MatVisLazySource.canonIdx_(idx, sz);
            outSz = cellfun(@numel, idx);
            obj.prepareLevel_(level);

            rows = idx{1};
            cols = idx{2};
            if N <= 2
                A = obj.planeCrop_(obj.planeIndexFromSubs([]), rows, cols, level);
                return;
            end

            sel = idx(3:N);
            cnt = cellfun(@numel, sel);
            nP  = prod(cnt);
            A   = zeros([numel(rows), numel(cols), nP], obj.ClassName);
            % Only worth announcing when there is enough to wait for; a single
            % plane is the ordinary navigation step and must stay silent.
            report = ~isempty(obj.ProgressFcn) && nP >= 4;
            for q = 1:nP
                if report && mod(q, 4) == 1
                    obj.ProgressFcn(q, nP);
                end
                c    = MatVisLazySource.ind2subVec_(cnt, q);
                subs = zeros(1, numel(sel));
                for d = 1:numel(sel)
                    subs(d) = sel{d}(c(d));
                end
                A(:, :, q) = obj.planeCrop_(obj.planeIndexFromSubs(subs), rows, cols, level);
            end
            if report
                obj.ProgressFcn([], []);
            end
            A = reshape(A, outSz);
        end

        function v = readLinear(obj, lin)
            % One plane read per distinct plane touched, not per element:
            % an ROI trace over t asks for the same few pixels in every
            % plane, and reading each plane once is the difference between
            % seconds and minutes.
            N    = numel(obj.Size);
            linv = double(lin(:));
            subs = cell(1, N);
            [subs{:}] = ind2sub(obj.Size, linv);

            v = zeros(numel(linv), 1, obj.ClassName);
            if N <= 2
                P = obj.plane_(obj.planeIndexFromSubs([]));
                v = P(sub2ind(obj.Size(1:2), subs{1}, subs{2}));
                v = reshape(v, size(lin));
                return;
            end

            planeSubs = cell2mat(cellfun(@(c) c(:), subs(3:N), 'UniformOutput', false));
            [uniqueSubs, ~, grp] = unique(planeSubs, 'rows');
            for k = 1:size(uniqueSubs, 1)
                m  = (grp == k);
                pi_ = obj.planeIndexFromSubs(uniqueSubs(k, :));
                % Only the bounding box of the points wanted, not the plane:
                % an ROI is a compact patch, and on a stitched image its plane
                % is one that cannot be read whole at all.
                r0 = min(subs{1}(m));  h = max(subs{1}(m)) - r0 + 1;
                c0 = min(subs{2}(m));  w = max(subs{2}(m)) - c0 + 1;
                R  = obj.planeBox_(pi_, r0, c0, h, w, 1);
                v(m) = R(sub2ind([h, w], subs{1}(m) - r0 + 1, subs{2}(m) - c0 + 1));
            end
            v = reshape(v, size(lin));
        end

        % ------------------------------------------------------------------
        %  Whole-dataset answers, served from the overview
        % ------------------------------------------------------------------
        function [mn, mx] = valueRange(obj, finiteOnly)
            if nargin < 2, finiteOnly = false; end
            if finiteOnly && ~isreal(obj.Min_)
                obj.ensureOverview();
            end
            mn = obj.Min_;
            mx = obj.Max_;
        end

        function [idx, val] = peakIndex(obj)
            idx = obj.Peak_;
            val = obj.Max_;
        end

        function counts = histCounts(obj, edges)
            ov = obj.ensureOverview();
            counts = histcounts(ov(:), edges);
        end

        function cr = channelRange(obj, rd, pLow, pHigh)
            ov = obj.ensureOverview();
            % The overview keeps every index along a small dimension (see
            % overviewIndices_), so a channel/RGB dimension is not decimated
            % and its per-index ranges are exact in that axis.
            cr = MatVisRender.channelRangeFromData(ov, rd, pLow, pHigh);
        end

        % ------------------------------------------------------------------
        %  Overview
        % ------------------------------------------------------------------
        function ov = ensureOverview(obj)
            if isempty(obj.Overview)
                obj.buildOverview();
            end
            ov = obj.Overview;
        end

        function buildOverview(obj, targetVoxels)
            % Read a strided subset of the planes, decimated in-plane, and
            % keep it.  Cost is one read per sampled plane, so the plane
            % stride sets the price: a stride of 8 on an 855-plane stack is
            % ~107 reads instead of 855.
            %
            % When the file carries its own resolution levels, the coarsest
            % one that still meets the pixel budget is read instead of
            % decimating the full-resolution planes.  That is not merely
            % faster -- for an image whose full-resolution plane exceeds
            % Java's 2 GB array limit it is the only way to get an overview
            % at all.
            if nargin < 2 || isempty(targetVoxels), targetVoxels = 4e6; end
            level = obj.pickOverviewLevel_(targetVoxels);
            idx   = obj.overviewIndices_(targetVoxels, level, obj.planeBudget_(level));
            obj.Overview    = obj.readSubAtLevel(idx, level);
            obj.OverviewIdx = obj.levelIdxToFull_(idx, level);
            obj.refreshRangeFromOverview_();
        end

        function s = cacheStats(obj)
            s = obj.Cache.stats();
        end
    end

    methods (Access = protected)
        function prepareLevel_(obj, level)  %#ok<INUSD>
            % Hook: called once before a run of reads at LEVEL.  Backends that
            % have to switch the file into a resolution level override this,
            % so the switch is not repeated per plane.
        end

        function A = plane_(obj, planeIdx, level)
            % One full plane, through the shared cache.
            if nargin < 3 || isempty(level), level = 1; end
            key = sprintf('%s|L%d|%d', obj.CacheTag, level, planeIdx);
            A = obj.Cache.fetch(key, @() obj.readPlaneRaw(planeIdx, level));
        end

        function A = planeCrop_(obj, planeIdx, rows, cols, level)
            if nargin < 5 || isempty(level), level = 1; end
            sz = obj.LevelSizes{level};
            fullBytes = prod(sz(1:2)) * MatVisDataSource.bytesPerElement(obj.ClassName);

            % A stitched image's full-resolution plane can be gigabytes, and
            % Bio-Formats cannot even return one (Java caps an array at 2 GB).
            % Above a threshold, read only the bounding box of what was asked
            % for.  Below it, whole planes stay the unit of caching -- a small
            % plane is cheap, and one cached plane serves any crop of it.
            if fullBytes > MatVisLazySource.WholePlaneLimit && ...
                    obj.canReadRegion() && ~obj.Cache.isCached(obj.planeKey_(planeIdx, level))
                r0 = min(rows);  h = max(rows) - r0 + 1;
                c0 = min(cols);  w = max(cols) - c0 + 1;
                R  = obj.planeBox_(planeIdx, r0, c0, h, w, level);
                A  = R(rows - r0 + 1, cols - c0 + 1);
                return;
            end

            P = obj.plane_(planeIdx, level);
            if isequal(rows(:)', 1:size(P, 1)) && isequal(cols(:)', 1:size(P, 2))
                A = P;
            else
                A = P(rows, cols);
            end
        end

        function A = planeBox_(obj, planeIdx, row0, col0, h, w, level)
            % Contiguous sub-rectangle of a plane, cached under its own key.
            % Falls back to cropping a cached whole plane when the source
            % cannot read regions or the plane is small enough to keep whole.
            sz = obj.LevelSizes{level};
            fullBytes = prod(sz(1:2)) * MatVisDataSource.bytesPerElement(obj.ClassName);
            if fullBytes <= MatVisLazySource.WholePlaneLimit || ~obj.canReadRegion() ...
                    || obj.Cache.isCached(obj.planeKey_(planeIdx, level))
                P = obj.plane_(planeIdx, level);
                A = P(row0:row0+h-1, col0:col0+w-1);
                return;
            end
            key = sprintf('%s|L%d|%d|r%d+%d|c%d+%d', obj.CacheTag, level, planeIdx, ...
                row0, h, col0, w);
            A = obj.Cache.fetch(key, @() obj.readPlaneRegion(planeIdx, level, row0, col0, h, w));
        end

        function k = planeKey_(obj, planeIdx, level)
            k = sprintf('%s|L%d|%d', obj.CacheTag, level, planeIdx);
        end

        function tf = canReadRegion(obj)
            tf = isstruct(obj.Capabilities) && ...
                 isfield(obj.Capabilities, 'SupportsTiles') && ...
                 obj.Capabilities.SupportsTiles;
        end

        function A = readPlaneRegion(obj, planeIdx, level, row0, col0, h, w)
            % Sub-rectangle of a plane.  The default reads the whole plane and
            % crops; backends that can read a region from the file override it.
            P = obj.plane_(planeIdx, level);
            A = P(row0:row0+h-1, col0:col0+w-1);
        end

        function level = pickOverviewLevel_(obj, targetVoxels)
            % Coarsest level whose plane still carries enough pixels to be
            % worth decimating further; falls back to level 1 when the file
            % has no pyramid.
            level = 1;
            minPlanePix = max(targetVoxels / max(prod(obj.Size(3:end)), 1), 128 * 128);
            for L = 1:numel(obj.LevelSizes)
                if prod(obj.LevelSizes{L}(1:2)) >= minPlanePix
                    level = L;
                else
                    break;
                end
            end
        end

        function s = levelScale_(obj, level)
            % How many full-resolution pixels one pixel of LEVEL covers.
            % The two axes are scaled together in every pyramid seen so far;
            % the smaller of the two is the honest answer if they differ.
            s = min(obj.Size(1:2) ./ obj.LevelSizes{level}(1:2));
        end

        function stride = inPlaneStride_(obj, idx)
            % Spacing of the requested in-plane samples.  Uses the span rather
            % than consecutive differences so an irregular selection still
            % gets a sensible answer, and never claims to be coarser than the
            % finest gap present.
            stride = Inf;
            for d = 1:min(2, numel(obj.Size))
                v = idx{d};
                if numel(v) <= 1
                    continue;
                end
                stride = min(stride, (max(v) - min(v) + 1) / numel(v));
            end
            if ~isfinite(stride), stride = 1; end
        end

        function idxLevel = fullIdxToLevel_(obj, idx, level)
            % Full-resolution in-plane indices -> the level's own coordinates,
            % keeping one sample per requested index so the returned array has
            % exactly the shape the caller asked for.
            idxLevel = idx;
            sz = obj.LevelSizes{level};
            for d = 1:min(2, numel(obj.Size))
                scale = obj.Size(d) / sz(d);
                idxLevel{d} = min(sz(d), max(1, ...
                    round((idx{d} - 0.5) / scale + 0.5)));
            end
        end

        function idxFull = levelIdxToFull_(obj, idx, level)
            % Express a level's in-plane indices in full-resolution
            % coordinates, so positions derived from the overview (the seed
            % for CurrPos, above all) stay in the units everything else uses.
            idxFull = idx;
            for d = 1:min(2, numel(obj.Size))
                scale = obj.Size(d) / obj.LevelSizes{level}(d);
                idxFull{d} = min(obj.Size(d), max(1, round((idx{d} - 0.5) * scale + 0.5)));
            end
        end

        function maxPlanes = planeBudget_(obj, level)
            % How many planes the overview may read.  The voxel budget alone
            % is the wrong currency: decimating in-plane makes the result
            % small while the cost stays one read per plane, so an overview
            % that keeps every plane costs as much as loading the file.  A
            % file that already carries the level is cheap to read whole;
            % otherwise the budget is a time budget divided by the measured
            % per-plane cost.
            nPlanes = prod(obj.LevelSizes{level}(3:end));
            if level > 1
                maxPlanes = nPlanes;    % a coarse level is cheap by construction
                return;
            end
            cost = 0.05;
            try
                if isfield(obj.Capabilities, 'PlaneReadCost') && ...
                        obj.Capabilities.PlaneReadCost > 0
                    cost = obj.Capabilities.PlaneReadCost;
                end
            catch
            end
            maxPlanes = min(nPlanes, max(8, round(MatVisLazySource.OverviewTimeBudget / cost)));
        end

        function idx = overviewIndices_(obj, targetVoxels, level, maxPlanes)
            % Per-dimension index vectors for the overview.  In-plane axes are
            % decimated by a common stride (so the picture keeps its aspect);
            % plane dimensions are decimated to fit MAXPLANES reads, except
            % for a short one -- a channel axis, typically -- which is kept
            % whole so that per-channel statistics stay meaningful.
            if nargin < 3 || isempty(level), level = 1; end
            sz = obj.LevelSizes{level};
            N  = numel(sz);
            if nargin < 4 || isempty(maxPlanes), maxPlanes = prod(sz(3:end)); end
            keepWhole = sz <= 8;
            keepWhole(1:min(2, N)) = false;

            planePix   = prod(sz(1:min(2, N)));
            nPlanesAll = prod(sz(3:end));
            budgetPix  = max(targetVoxels / max(min(nPlanesAll, maxPlanes), 1), 64 * 64);

            sxy = max(1, ceil(sqrt(planePix / budgetPix)));
            idx = cell(1, N);
            for d = 1:min(2, N)
                idx{d} = 1 : sxy : sz(d);
            end

            % Plane dimensions: raise the stride of whichever dimension still
            % contributes most until the product fits the read budget, the
            % same balancing MatVisVolumeView.planSampling uses for volumes.
            % Sharing the budget dimension by dimension instead would spend it
            % all on the first one and sample a time series at a single frame.
            if N > 2
                counts  = sz(3:N);
                fixed   = keepWhole(3:N);
                strides = ones(1, N - 2);
                while prod(ceil(counts ./ strides)) > maxPlanes
                    cand = ceil(counts ./ strides);
                    cand(fixed) = 0;
                    [mx, j] = max(cand);
                    if mx <= 1, break; end
                    strides(j) = strides(j) + 1;
                end
                for d = 3:N
                    idx{d} = 1 : strides(d - 2) : sz(d);
                end
            end
        end

        function refreshRangeFromOverview_(obj)
            ov = obj.Overview;
            finite = ov(isfinite(ov));
            if isempty(finite)
                if ~obj.HasRangeEstimate_
                    obj.Min_ = 0;  obj.Max_ = 1;  obj.Peak_ = 1;
                end
                return;
            end
            [mx, mi] = max(ov(:));
            obj.widenRange_(double(min(finite(:))), double(mx), ...
                @() obj.overviewIndexToFull_(mi));
        end

        function widenRange_(obj, mn, mx, peakFcn)
            % Any sample of the data gives bounds that are too narrow, never
            % too wide, so a later sample can only ever extend them.  The
            % overview decimates in-plane more aggressively than the probe
            % does, so replacing the estimate would otherwise make it worse
            % the moment a global feature was first used.
            if ~obj.HasRangeEstimate_
                obj.Min_ = mn;  obj.Max_ = mx;  obj.Peak_ = peakFcn();
                obj.HasRangeEstimate_ = true;
                return;
            end
            obj.Min_ = min(obj.Min_, mn);
            if mx > obj.Max_
                obj.Max_  = mx;
                obj.Peak_ = peakFcn();
            end
        end

        function linFull = overviewIndexToFull_(obj, linOv)
            % Map a linear index in the overview back to one in the dataset,
            % so CurrPos can be seeded at (approximately) the brightest pixel.
            N   = numel(obj.Size);
            ovS = cellfun(@numel, obj.OverviewIdx);
            c   = cell(1, N);
            [c{:}] = ind2sub(ovS, linOv);
            full = zeros(1, N);
            for d = 1:N
                full(d) = obj.OverviewIdx{d}(c{d});
            end
            fullC = num2cell(full);
            linFull = sub2ind(obj.Size, fullC{:});
        end

        function seedRange_(obj)
            % Establish a usable min/max/peak at construction time.
            %
            % With file levels, building the overview straight away is the
            % cheapest option and the only one that works at all when the
            % full-resolution plane is too large to read (Java's 2 GB array
            % limit).  Without them, sample a handful of planes: the overview
            % costs seconds and is deferred until something actually needs it.
            if numel(obj.LevelSizes) > 1
                obj.buildOverview();
            else
                obj.seedRangeFromProbe_();
            end
        end

        function seedRangeFromProbe_(obj, nProbePlanes)
            % A cheap min/max/peak estimate for construction time: a handful
            % of planes spread through the stack, decimated in-plane.  The
            % overview refines this later; until then the contrast window is
            % an estimate, which is why StatsApproximate stays true.
            if nargin < 2, nProbePlanes = 8; end
            N  = numel(obj.Size);
            sz = obj.Size;
            idx = cell(1, N);
            sxy = max(1, ceil(sqrt(prod(sz(1:min(2, N))) / (256 * 256))));
            for d = 1:min(2, N), idx{d} = 1 : sxy : sz(d); end
            nPlanes = prod(sz(3:end));
            pick = unique(round(linspace(1, max(nPlanes, 1), min(nProbePlanes, nPlanes))));
            for d = 3:N, idx{d} = 1; end

            mn = Inf;  mx = -Inf;  peakLin = 1;
            for k = 1:numel(pick)
                if N > 2
                    pc = MatVisLazySource.ind2subVec_(sz(3:N), pick(k));
                    for d = 3:N, idx{d} = pc(d-2); end
                end
                block = obj.readSub(idx);
                b = block(isfinite(block));
                if isempty(b), continue; end
                mn = min(mn, double(min(b(:))));
                [bmx, bmi] = max(block(:));
                if double(bmx) > mx
                    mx = double(bmx);
                    peakLin = obj.probeIndexToFull_(idx, bmi);
                end
            end
            if ~isfinite(mn), mn = 0; end
            if ~isfinite(mx), mx = mn + 1; end
            obj.widenRange_(mn, mx, @() peakLin);
        end

        function linFull = probeIndexToFull_(obj, idx, linBlock)
            N  = numel(obj.Size);
            bs = cellfun(@numel, idx);
            c  = cell(1, N);
            [c{:}] = ind2sub(bs, linBlock);
            full = zeros(1, N);
            for d = 1:N, full(d) = idx{d}(c{d}); end
            fullC = num2cell(full);
            linFull = sub2ind(obj.Size, fullC{:});
        end
    end

    methods (Static, Access = protected)
        function subs = ind2subVec_(cnt, q)
            % Column-major ind2sub returning a plain vector.  MATLAB's own
            % ind2sub rejects a one-element size vector, which is exactly the
            % common case here: a stack with a single plane dimension.
            n    = numel(cnt);
            subs = zeros(1, n);
            r    = q - 1;
            for d = 1:n
                subs(d) = mod(r, cnt(d)) + 1;
                r = floor(r / cnt(d));
            end
        end

        function idx = canonIdx_(idx, sz)
            % ':' and [] mean the whole dimension; everything comes back as a
            % numeric row vector so numel/ind2sub can be used on it.
            for d = 1:numel(sz)
                if d > numel(idx) || isempty(idx{d}) || isequal(idx{d}, ':')
                    idx{d} = 1 : sz(d);
                else
                    idx{d} = double(idx{d}(:))';
                end
            end
            idx = idx(1:numel(sz));
        end
    end
end
