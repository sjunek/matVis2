classdef MatVisModel < handle
    % MatVisModel  Data and metadata container for matVis 2.0.
    %
    %   model = MatVisModel(data)
    %   model = MatVisModel(datasets, datasetNames)
    %
    %   data must be a numeric N-D array (N >= 2) or a cell array of numeric
    %   arrays all with identical dimensions.
    %
    %   Navigation state (CurrPos, ZoomRange, XDim, YDim, etc.) is shared
    %   across all datasets.  Contrast state (Mode, Gamma, ColormapIdx) is
    %   also shared.  Per-dataset Manual contrast bounds are stored in
    %   DatasetContrastMins/Maxs.

    % ------------------------------------------------------------------
    %  Stored properties
    % ------------------------------------------------------------------
    properties
        Datasets            % 1×K cell array of numeric N-D arrays
        DatasetNames        % 1×K cell array of strings
        ActiveDataset       % scalar index (1-based) — selects histogram display
        ContrastLocked      % logical — true=locked(linear scaling), false=independent
        DatasetContrastMins % 1×K double — Manual mode lower bound per dataset
        DatasetContrastMaxs % 1×K double — Manual mode upper bound per dataset
        DatasetGammas       % 1×K double — gamma per dataset (used when ContrastLocked=false)

        % Shared navigation state
        DimNames        % 1×N cell array of strings
        DimScale        % 1×N cell array of numeric vectors
        DimUnits        % 1×N cell array of strings
        CurrPos         % 1×N integer index vector (1-based, clamped)
        ZoomRange       % N×2 double  [lo, hi] per dim (1-based indices)
        XDim            % scalar integer — dimension shown on X axis
        YDim            % scalar integer — dimension shown on Y axis
        ProjDim         % scalar integer — dimension to project along (0 = off)
        ProjFun         % string: 'max','min','mean','std','var','tile','none'
        RGBDim          % scalar integer — dimension mapped to R/G/B channels (0 = off)
        RGBStretchMode  % string: 'none','mean','max' — color-code the whole RGB
                        %   dimension (matVis "MeanStretch"/"MaxStretch") instead
                        %   of showing three consecutive slices as R/G/B
        RGBStretchRange % 1×2 double [bluePoint redPoint] in [0,1] — rainbow
                        %   positions assigned to the first/last RGB-dim index
        RGBStretchZoomLock % logical — when true, stretch only over the RGB
                        %   dimension's zoom interval (mirrors ProjZoomLock)
        Gamma           % scalar double in [0.1, 5.0]
        ColormapIdx     % scalar positive integer
        FilterType      % string: 'none','gauss','median','mean','unsharp'
        FilterPar       % numeric vector — filter parameter (scalar = isotropic,
                        %   [x y] = anisotropic); meaning depends on FilterType
                        %   (sigma / neighbourhood size / radius)
        PlotDims        % 1×N logical vector
        PlotLock        % 1×N logical vector
        ProjZoomLock    % logical
        ContrastMin     % scalar double — active dataset manual lower bound
        ContrastMax     % scalar double — active dataset manual upper bound
        ContrastMode    % string: 'Global', 'Image', 'Zoom', 'Manual'
        FlipX           % logical
        FlipY           % logical

        % Image/zoom axes display state
        AspectRatioFixed % logical — true=fixed aspect ratio, false=fill window
        AspectRatio      % 1×2 double [x y] — data aspect ratio when fixed
        WinScalePct      % scalar — zoom-window display scale [%] (100 = 1:1 px)

        % Alpha channel state (empty AlphaMaps = no alpha; see SetAlphaMaps)
        AlphaMaps         % 1×K cell of numeric N-D arrays (same size as data), or {}
        AlphaContrastMins % 1×K double — alpha contrast lower bound per dataset
        AlphaContrastMaxs % 1×K double — alpha contrast upper bound per dataset
        AlphaGamma        % scalar double in [0.1, 5.0] — gamma applied to alpha
        AlphaBgWhite      % logical — false = black background, true = white

        % ROI state.  RoiList is a struct array using the same field layout
        % as the original matVis ROI export format, so ROI files are
        % interchangeable between versions:
        %   corners         2×N polygon [x; y] (closed, pixel coords)
        %   cornersPixelDim 2×N polygon in pixel coords (same as corners)
        %   index           struct with .x/.y pixel indices inside the mask
        %   mask            logical Size(XDim)×Size(YDim), mask(x,y)
        %   name            char
        %   number          scalar
        %   rectangle       [left bottom right top] bounding box
        %   settings        struct: .position, .zoomVal, .xySel
        %   centerOfGravity 2×2 [geometric; intensity-weighted], rows [x y]
        RoiList         % 1×R struct array (see above)
        RoiSelection    % vector of selected indices into RoiList
        RoiShowNames    % logical — show ROI name labels in image/zoom windows
        RoiLineWidth    % scalar — outline width of selected ROIs
        RoiLineStyle    % char — outline line style ('-','--',':','-.')

        % Profile (line-trace) state.  ProfileList is a struct array using the
        % same field layout as the original matVis profile export format, so
        % profile files are interchangeable between versions:
        %   points          2×N clicked vertices [x; y] (pixel coords)
        %   smoothedPoints  2×M interpolated path at ~1 px spacing [x; y]
        %   name            char
        %   number          scalar
        %   length          scalar — path length (pixels)
        %   settings        struct: .position, .zoomVal, .xySel
        ProfileList         % 1×P struct array (see above)
        ProfileSelection    % vector of selected indices into ProfileList
        ProfileShowNames    % logical — show profile name labels in image/zoom
        ProfileShowDir      % logical — show profile direction arrow
        ProfileWidth        % scalar — perpendicular sampling width (pixels)
        ProfileProjection   % char — 'Mean' | 'Sum' | 'Max' | 'Min'
    end

    properties (SetAccess = private)
        Size            % 1×N double — size of each dataset (all identical)
        AllDataMins     % 1×K double — min of each dataset
        AllDataMaxs     % 1×K double — max of each dataset
        NumDatasets     % scalar K
        AlphaMins       % 1×K double — min of each alpha map (finite values)
        AlphaMaxs       % 1×K double — max of each alpha map (finite values)
    end

    % Dependent convenience properties for backward compat with MatVisRender
    properties (Dependent)
        Data      % Datasets{ActiveDataset}
        DataMin   % AllDataMins(ActiveDataset)
        DataMax   % AllDataMaxs(ActiveDataset)
        WithAlpha % true when alpha maps are attached
    end

    properties (Access = private, Transient)
        LastImageDatas_  % 1×K cell — cached 2-D image slice per dataset (Image mode)
        LastZoomDatas_   % 1×K cell — cached zoom crop per dataset (Zoom mode)
    end

    events
        ContrastModeChanged
        ActiveDatasetChanged
        RoiChanged          % ROI list, geometry, or selection changed
        ProfileChanged      % profile list, geometry, or selection changed
    end

    % ------------------------------------------------------------------
    %  Constructor
    % ------------------------------------------------------------------
    methods
        function obj = MatVisModel(datasets, datasetNames)
            % MatVisModel  Construct from one or more numeric N-D arrays.
            %   datasets     : numeric array  OR  cell array of numeric arrays
            %   datasetNames : cell array of strings (optional)

            if nargin < 2, datasetNames = {}; end

            if isnumeric(datasets)
                datasets = {datasets};
            end
            validateattributes(datasets, {'cell'}, {'nonempty'}, 'MatVisModel', 'datasets');
            for k = 1:numel(datasets)
                validateattributes(datasets{k}, {'numeric'}, {'nonempty'}, ...
                    'MatVisModel', sprintf('datasets{%d}', k));
            end

            K = numel(datasets);
            refSz = size(datasets{1});
            for k = 2:K
                if ~isequal(size(datasets{k}), refSz)
                    error('MatVisModel:sizeMismatch', ...
                        'All datasets must have identical dimensions.');
                end
            end

            obj.Datasets    = datasets(:)';
            obj.NumDatasets = K;
            obj.Size        = refSz;
            N               = numel(refSz);

            % Per-dataset min/max (keep linear index of dataset 1's maximum
            % so CurrPos can start at the brightest pixel)
            allMins = zeros(1, K);
            allMaxs = zeros(1, K);
            maxIdx1 = 1;
            for k = 1:K
                [mx, mi] = max(datasets{k}(:));
                allMins(k) = double(min(datasets{k}(:)));
                allMaxs(k) = double(mx);
                if k == 1, maxIdx1 = mi; end
            end
            obj.AllDataMins = allMins;
            obj.AllDataMaxs = allMaxs;

            % Dataset names
            if isempty(datasetNames)
                datasetNames = arrayfun(@(i) sprintf('Dataset %d', i), 1:K, ...
                    'UniformOutput', false);
            end
            obj.DatasetNames = datasetNames(:)';

            % Per-dataset Manual contrast initialised to full range
            obj.DatasetContrastMins = allMins;
            obj.DatasetContrastMaxs = allMaxs;

            % Cache arrays
            obj.LastImageDatas_ = cell(1, K);
            obj.LastZoomDatas_  = cell(1, K);
            obj.DatasetGammas   = ones(1, K);

            % Shared navigation defaults
            s = refSz;
            obj.DimNames = arrayfun(@(k_) sprintf('Dim%d', k_), 1:N, ...
                'UniformOutput', false);
            obj.DimScale = arrayfun(@(k_) 1:s(k_), 1:N, ...
                'UniformOutput', false);
            obj.DimUnits = repmat({''}, 1, N);
            % Start at the brightest pixel of the first dataset
            sub = cell(1, N);
            [sub{:}] = ind2sub(s, maxIdx1);
            obj.CurrPos = [sub{:}];
            obj.ZoomRange = [ones(N, 1), s(:)];

            % Display dimensions
            obj.YDim = 1;
            obj.XDim = 2;

            % Projection
            obj.ProjFun = 'none';
            nonXY = setdiff(1:N, [1 2]);
            if ~isempty(nonXY)
                obj.ProjDim = nonXY(1);
            else
                obj.ProjDim = 0;
            end

            % RGB channel mode (0 = off; dim shares the non-XY pool with
            % ProjDim — the UI enforces mutual exclusion when active)
            obj.RGBDim = 0;

            % RGB stretch (whole-dimension colour coding); off by default.
            % Range is in slider space [0,1]: the rainbow occupies the middle
            % 70% (0.15..0.85), with solid blue/red in the outer 15%. The
            % default indicators sit at the rainbow boundaries (0.15, 0.85).
            obj.RGBStretchMode     = 'none';
            obj.RGBStretchRange    = [0.15, 0.85];
            obj.RGBStretchZoomLock = false;

            % Rendering
            obj.Gamma        = 1.0;
            obj.ColormapIdx  = 1;
            obj.FilterType   = 'none';
            obj.FilterPar    = 1;
            obj.PlotDims     = false(1, N);
            obj.PlotLock     = false(1, N);
            obj.ProjZoomLock = false;
            obj.FlipX        = false;
            obj.FlipY        = false;

            % Image/zoom axes display defaults (fixed square pixels, 100%)
            obj.AspectRatioFixed = true;
            obj.AspectRatio      = [1 1];
            obj.WinScalePct      = 100;

            % Alpha channel (off until SetAlphaMaps is called)
            obj.AlphaMaps         = {};
            obj.AlphaContrastMins = [];
            obj.AlphaContrastMaxs = [];
            obj.AlphaGamma        = 1.0;
            obj.AlphaBgWhite      = false;

            % ROIs
            obj.RoiList      = MatVisModel.EmptyRoiList();
            obj.RoiSelection = [];
            obj.RoiShowNames = true;
            obj.RoiLineWidth = 1;
            obj.RoiLineStyle = '-';

            % Profiles
            obj.ProfileList       = MatVisModel.EmptyProfileList();
            obj.ProfileSelection  = [];
            obj.ProfileShowNames  = true;
            obj.ProfileShowDir    = false;
            obj.ProfileWidth      = 5;
            obj.ProfileProjection = 'Mean';

            % Contrast — set directly to avoid setter ordering issues
            obj.ContrastMin  = allMins(1);
            obj.ContrastMax  = allMaxs(1);
            obj.ContrastMode = 'Global';

            % Lock (closed = linear scaling across all datasets)
            obj.ContrastLocked = true;

            % Active dataset last (triggers ContrastMin/Max sync)
            obj.ActiveDataset = 1;
        end
    end

    % ------------------------------------------------------------------
    %  Dependent getters
    % ------------------------------------------------------------------
    methods
        function d = get.Data(obj)
            d = obj.Datasets{obj.ActiveDataset};
        end

        function v = get.DataMin(obj)
            v = obj.AllDataMins(obj.ActiveDataset);
        end

        function v = get.DataMax(obj)
            v = obj.AllDataMaxs(obj.ActiveDataset);
        end

        function tf = get.WithAlpha(obj)
            tf = ~isempty(obj.AlphaMaps);
        end
    end

    % ------------------------------------------------------------------
    %  Setters
    % ------------------------------------------------------------------
    methods
        function set.ActiveDataset(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'integer', 'positive'}, 'MatVisModel.set.ActiveDataset', 'ActiveDataset');
            if ~isempty(obj.NumDatasets) && value > obj.NumDatasets
                error('MatVisModel:invalidIdx', ...
                    'ActiveDataset must be in [1, %d].', obj.NumDatasets);
            end
            prevAds = obj.ActiveDataset;
            if isempty(prevAds), prevAds = value; end
            obj.ActiveDataset = value;
            if ~isempty(obj.DatasetContrastMins) && value <= numel(obj.DatasetContrastMins)
                if obj.ContrastLocked && prevAds ~= value
                    % Linearly scale current contrast from prev dataset's range to new one
                    dmin_p = obj.AllDataMins(prevAds);
                    dmax_p = obj.AllDataMaxs(prevAds);
                    rp     = max(dmax_p - dmin_p, eps);
                    flo    = (obj.ContrastMin - dmin_p) / rp;
                    fhi    = (obj.ContrastMax - dmin_p) / rp;
                    dn = obj.AllDataMins(value);
                    dm = obj.AllDataMaxs(value);
                    obj.ContrastMin = dn + flo * (dm - dn);
                    obj.ContrastMax = dn + fhi * (dm - dn);
                else
                    % Independent mode or initial setup: restore stored bounds + gamma
                    obj.ContrastMin = obj.DatasetContrastMins(value);
                    obj.ContrastMax = obj.DatasetContrastMaxs(value);
                    if ~obj.ContrastLocked && ~isempty(obj.DatasetGammas) && ...
                       value <= numel(obj.DatasetGammas)
                        obj.Gamma = obj.DatasetGammas(value);
                    end
                end
            end
            try; notify(obj, 'ActiveDatasetChanged'); catch; end
        end

        function set.ContrastMin(obj, value)
            validateattributes(value, {'numeric'}, {'scalar', 'real'}, ...
                'MatVisModel.set.ContrastMin', 'ContrastMin');
            obj.ContrastMin = double(value);
            % Sync into per-dataset store for the active dataset
            if ~isempty(obj.DatasetContrastMins) && ~isempty(obj.ActiveDataset) && ...
               obj.ActiveDataset <= numel(obj.DatasetContrastMins)
                obj.DatasetContrastMins(obj.ActiveDataset) = double(value);
            end
        end

        function set.ContrastMax(obj, value)
            validateattributes(value, {'numeric'}, {'scalar', 'real'}, ...
                'MatVisModel.set.ContrastMax', 'ContrastMax');
            obj.ContrastMax = double(value);
            if ~isempty(obj.DatasetContrastMaxs) && ~isempty(obj.ActiveDataset) && ...
               obj.ActiveDataset <= numel(obj.DatasetContrastMaxs)
                obj.DatasetContrastMaxs(obj.ActiveDataset) = double(value);
            end
        end

        function set.XDim(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'integer', 'positive'}, 'MatVisModel.set.XDim', 'XDim');
            N = numel(obj.Size);
            if value < 1 || value > N
                error('MatVisModel:invalidDim', 'XDim must be in [1, %d].', N);
            end
            if ~isempty(obj.YDim) && value == obj.YDim
                error('MatVisModel:dimConflict', 'XDim must not equal YDim (%d).', obj.YDim);
            end
            obj.XDim = value;
        end

        function set.YDim(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'integer', 'positive'}, 'MatVisModel.set.YDim', 'YDim');
            N = numel(obj.Size);
            if value < 1 || value > N
                error('MatVisModel:invalidDim', 'YDim must be in [1, %d].', N);
            end
            if ~isempty(obj.XDim) && value == obj.XDim
                error('MatVisModel:dimConflict', 'YDim must not equal XDim (%d).', obj.XDim);
            end
            obj.YDim = value;
        end

        function set.ProjDim(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'integer', 'nonnegative'}, 'MatVisModel.set.ProjDim', 'ProjDim');
            N = numel(obj.Size);
            if value > N
                error('MatVisModel:invalidDim', 'ProjDim must be in [0, %d].', N);
            end
            obj.ProjDim = value;
        end

        function set.ProjFun(obj, value)
            validateattributes(value, {'char', 'string'}, {'scalartext'}, ...
                'MatVisModel.set.ProjFun', 'ProjFun');
            value = char(value);
            if ~ismember(value, {'none', 'max', 'min', 'mean', 'std', 'var', 'tile'})
                error('MatVisModel:invalidProjFun', ...
                    'ProjFun must be none, max, min, mean, std, var, or tile.');
            end
            obj.ProjFun = value;
        end

        function set.RGBDim(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'integer', 'nonnegative'}, 'MatVisModel.set.RGBDim', 'RGBDim');
            N = numel(obj.Size);
            if value > N
                error('MatVisModel:invalidDim', 'RGBDim must be in [0, %d].', N);
            end
            obj.RGBDim = value;
        end

        function set.RGBStretchMode(obj, value)
            value = validatestring(value, {'none', 'mean', 'max'}, ...
                'MatVisModel.set.RGBStretchMode', 'RGBStretchMode');
            obj.RGBStretchMode = value;
        end

        function set.RGBStretchRange(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'vector', 'numel', 2, 'finite'}, ...
                'MatVisModel.set.RGBStretchRange', 'RGBStretchRange');
            v = double(value(:)');
            v = max(0, min(1, v));            % clamp to [0,1]
            obj.RGBStretchRange = [min(v), max(v)];   % keep blue <= red
        end

        function set.RGBStretchZoomLock(obj, value)
            validateattributes(value, {'logical', 'numeric'}, {'scalar'}, ...
                'MatVisModel.set.RGBStretchZoomLock', 'RGBStretchZoomLock');
            obj.RGBStretchZoomLock = logical(value);
        end

        function set.CurrPos(obj, value)
            validateattributes(value, {'numeric'}, {'vector', 'integer'}, ...
                'MatVisModel.set.CurrPos', 'CurrPos');
            s = obj.Size;
            if numel(value) ~= numel(s)
                error('MatVisModel:sizeMismatch', 'CurrPos must have %d elements.', numel(s));
            end
            value = max(1, min(value, s));
            obj.CurrPos = value(:)';
        end

        function set.ZoomRange(obj, value)
            validateattributes(value, {'numeric'}, {'2d', 'ncols', 2}, ...
                'MatVisModel.set.ZoomRange', 'ZoomRange');
            s = obj.Size;
            N = numel(s);
            if size(value, 1) ~= N
                error('MatVisModel:sizeMismatch', 'ZoomRange must be %dx2.', N);
            end
            lo = max(1, min(value(:, 1), s(:)));
            hi = max(1, min(value(:, 2), s(:)));
            lo = min(lo, hi);
            obj.ZoomRange = [lo, hi];
        end

        function set.Gamma(obj, value)
            validateattributes(value, {'numeric'}, {'scalar', 'real', 'finite'}, ...
                'MatVisModel.set.Gamma', 'Gamma');
            obj.Gamma = max(0.1, min(5.0, value));
        end

        function set.AlphaGamma(obj, value)
            validateattributes(value, {'numeric'}, {'scalar', 'real', 'finite'}, ...
                'MatVisModel.set.AlphaGamma', 'AlphaGamma');
            obj.AlphaGamma = max(0.1, min(5.0, value));
        end

        function set.AlphaBgWhite(obj, value)
            validateattributes(value, {'logical', 'numeric'}, {'scalar'}, ...
                'MatVisModel.set.AlphaBgWhite', 'AlphaBgWhite');
            obj.AlphaBgWhite = logical(value);
        end

        function set.ColormapIdx(obj, value)
            validateattributes(value, {'numeric'}, {'scalar', 'integer', 'positive'}, ...
                'MatVisModel.set.ColormapIdx', 'ColormapIdx');
            obj.ColormapIdx = value;
        end

        function set.DimNames(obj, value)
            validateattributes(value, {'cell'}, {'vector'}, ...
                'MatVisModel.set.DimNames', 'DimNames');
            obj.DimNames = value(:)';
        end

        function set.DimScale(obj, value)
            validateattributes(value, {'cell'}, {'vector'}, ...
                'MatVisModel.set.DimScale', 'DimScale');
            obj.DimScale = value(:)';
        end

        function set.DimUnits(obj, value)
            validateattributes(value, {'cell'}, {'vector'}, ...
                'MatVisModel.set.DimUnits', 'DimUnits');
            obj.DimUnits = value(:)';
        end

        function set.PlotDims(obj, value)
            validateattributes(value, {'logical', 'numeric'}, {'vector'}, ...
                'MatVisModel.set.PlotDims', 'PlotDims');
            obj.PlotDims = logical(value(:)');
        end

        function set.ContrastMode(obj, value)
            validateattributes(value, {'char', 'string'}, {'scalartext'}, ...
                'MatVisModel.set.ContrastMode', 'ContrastMode');
            value = char(value);
            if ~ismember(value, {'Global', 'Image', 'Zoom', 'Manual'})
                error('MatVisModel:invalidContrastMode', ...
                    'ContrastMode must be ''Global'', ''Image'', ''Zoom'', or ''Manual''.');
            end
            obj.ContrastMode = value;
            notify(obj, 'ContrastModeChanged');
        end
    end

    % ------------------------------------------------------------------
    %  Public methods
    % ------------------------------------------------------------------
    methods
        function SetAlphaMaps(obj, maps)
            % SetAlphaMaps  Attach alpha maps (one per dataset).
            %   maps : numeric array same size as the data (shared across
            %          all datasets), 1×K cell array of such arrays, or
            %          []/{} to remove the alpha channel.
            % Alpha contrast bounds are initialised to each map's finite
            % data range.
            if isnumeric(maps)
                if isempty(maps)
                    maps = {};
                else
                    maps = repmat({maps}, 1, obj.NumDatasets);
                end
            end
            validateattributes(maps, {'cell'}, {}, 'MatVisModel.SetAlphaMaps', 'maps');

            if isempty(maps)
                obj.AlphaMaps         = {};
                obj.AlphaMins         = [];
                obj.AlphaMaxs         = [];
                obj.AlphaContrastMins = [];
                obj.AlphaContrastMaxs = [];
                return;
            end

            if numel(maps) ~= obj.NumDatasets
                error('MatVisModel:alphaCountMismatch', ...
                    'Expected %d alpha map(s), got %d.', obj.NumDatasets, numel(maps));
            end

            K = obj.NumDatasets;
            aMins = zeros(1, K);
            aMaxs = zeros(1, K);
            for k = 1:K
                if ~isequal(size(maps{k}), obj.Size)
                    error('MatVisModel:alphaSizeMismatch', ...
                        'Alpha map %d must have the same size as the data.', k);
                end
                finiteVals = maps{k}(isfinite(maps{k}));
                if isempty(finiteVals)
                    aMins(k) = 0;  aMaxs(k) = 1;
                else
                    aMins(k) = double(min(finiteVals(:)));
                    aMaxs(k) = double(max(finiteVals(:)));
                end
                if aMins(k) == aMaxs(k)
                    aMaxs(k) = aMins(k) + 1;
                end
            end

            obj.AlphaMaps         = maps(:)';
            obj.AlphaMins         = aMins;
            obj.AlphaMaxs         = aMaxs;
            obj.AlphaContrastMins = aMins;
            obj.AlphaContrastMaxs = aMaxs;
        end

        function SetImageData(obj, imgData, dsIdx)
            % Cache 2-D image slice for Image-mode contrast.
            if nargin < 3, dsIdx = obj.ActiveDataset; end
            if dsIdx >= 1 && dsIdx <= obj.NumDatasets
                obj.LastImageDatas_{dsIdx} = imgData;
            end
        end

        function SetZoomData(obj, zoomData, dsIdx)
            % Cache zoom crop for Zoom-mode contrast.
            if nargin < 3, dsIdx = obj.ActiveDataset; end
            if dsIdx >= 1 && dsIdx <= obj.NumDatasets
                obj.LastZoomDatas_{dsIdx} = zoomData;
            end
        end

        function [cmin, cmax] = GetContrastBounds(obj)
            % Returns contrast bounds for the active dataset (backward compat).
            [cmin, cmax] = obj.GetContrastBoundsForDataset(obj.ActiveDataset);
        end

        function [cmin, cmax] = GetContrastBoundsForDataset(obj, dsIdx)
            % Returns contrast bounds for dataset dsIdx.
            % Manual+locked: scales active dataset's bounds linearly to dsIdx.
            dmin = obj.AllDataMins(dsIdx);
            dmax = obj.AllDataMaxs(dsIdx);

            switch obj.ContrastMode
                case 'Global'
                    cmin = dmin;
                    cmax = dmax;

                case 'Image'
                    if dsIdx <= numel(obj.LastImageDatas_) && ...
                       ~isempty(obj.LastImageDatas_{dsIdx})
                        cmin = min(obj.LastImageDatas_{dsIdx}(:));
                        cmax = max(obj.LastImageDatas_{dsIdx}(:));
                    else
                        cmin = dmin; cmax = dmax;
                    end

                case 'Zoom'
                    if dsIdx <= numel(obj.LastZoomDatas_) && ...
                       ~isempty(obj.LastZoomDatas_{dsIdx})
                        cmin = min(obj.LastZoomDatas_{dsIdx}(:));
                        cmax = max(obj.LastZoomDatas_{dsIdx}(:));
                    else
                        cmin = dmin; cmax = dmax;
                    end

                case 'Manual'
                    if ~obj.ContrastLocked || dsIdx == obj.ActiveDataset
                        cmin = obj.DatasetContrastMins(dsIdx);
                        cmax = obj.DatasetContrastMaxs(dsIdx);
                    else
                        % Scale active dataset's Manual bounds linearly to dsIdx
                        cmin_ref = obj.DatasetContrastMins(obj.ActiveDataset);
                        cmax_ref = obj.DatasetContrastMaxs(obj.ActiveDataset);
                        dmin_ref = obj.AllDataMins(obj.ActiveDataset);
                        dmax_ref = obj.AllDataMaxs(obj.ActiveDataset);
                        range_ref = max(dmax_ref - dmin_ref, eps);
                        flo = (cmin_ref - dmin_ref) / range_ref;
                        fhi = (cmax_ref - dmin_ref) / range_ref;
                        range_ds = dmax - dmin;
                        cmin = dmin + flo * range_ds;
                        cmax = dmin + fhi * range_ds;
                    end

                otherwise
                    cmin = dmin; cmax = dmax;
            end

            if cmin > cmax, [cmin, cmax] = deal(cmax, cmin); end
            if cmin == cmax, cmax = cmin + 1; end
        end

        function applyStartPar(obj, sp)
            % applyStartPar  Apply a startPar struct of named overrides.
            if isempty(sp) || ~isstruct(sp)
                return;
            end

            if isfield(sp, 'xySel')
                v = sp.xySel;
                if isstruct(v)
                    if isfield(v, 'x'), obj.XDim = v.x; end
                    if isfield(v, 'y'), obj.YDim = v.y; end
                else
                    v = v(:)';
                    if numel(v) >= 2
                        xNew = v(1); yNew = v(2);
                        if xNew ~= obj.YDim
                            obj.XDim = xNew; obj.YDim = yNew;
                        else
                            obj.YDim = yNew; obj.XDim = xNew;
                        end
                    end
                end
            end

            if isfield(sp, 'gamma'),   obj.Gamma       = sp.gamma;   end
            if isfield(sp, 'cmap'),    obj.ColormapIdx = sp.cmap;    end
            if isfield(sp, 'currPos'), obj.CurrPos     = sp.currPos; end
            if isfield(sp, 'zoomVal'), obj.ZoomRange   = sp.zoomVal; end
        end
    end

    % ------------------------------------------------------------------
    %  Dimension scaling helpers
    %
    %  DimScale{d} holds the real-world coordinate of every index along
    %  dimension d (default 1:Size(d), i.e. coordinate == index).  These
    %  helpers map between integer/fractional indices and real-world
    %  coordinates (µm, ms, …) so the image/zoom axes, plots and the zoom
    %  readout can display real units while navigation stays index-based.
    % ------------------------------------------------------------------
    methods
        function r = indexToReal(obj, dim, idx)
            % indexToReal  Real-world coordinate(s) at the given index/indices
            % along DIM.  Integer in-range indices return the stored value
            % exactly; fractional / out-of-range indices are linearly
            % interpolated/extrapolated.
            if dim < 1 || dim > numel(obj.DimScale)
                r = idx; return;
            end
            sc = obj.DimScale{dim};
            n  = numel(sc);
            if n == 0
                r = idx;
            elseif n == 1
                r = repmat(sc(1), size(idx));
            else
                r = interp1(1:n, sc, idx, 'linear', 'extrap');
            end
        end

        function f = pixelSize(obj, dim)
            % pixelSize  Real-world size of one index step along DIM
            % (uniform-spacing estimate from the DimScale endpoints).
            f = 1;
            if dim < 1 || dim > numel(obj.DimScale), return; end
            sc = obj.DimScale{dim};
            n  = numel(sc);
            if n >= 2
                f = (sc(end) - sc(1)) / (n - 1);
            end
        end

        function u = dimUnit(obj, dim)
            % dimUnit  Unit string for DIM ('' when none was supplied).
            if dim >= 1 && dim <= numel(obj.DimUnits)
                u = obj.DimUnits{dim};
            else
                u = '';
            end
        end

        function tf = hasRealScale(obj, dim)
            % hasRealScale  True when DIM carries non-trivial scale info: a
            % unit string, or a DimScale that differs from the plain 1:N
            % index vector.
            tf = false;
            if dim < 1 || dim > numel(obj.Size), return; end
            if ~isempty(obj.dimUnit(dim)), tf = true; return; end
            sc = obj.DimScale{dim};
            if isempty(sc), return; end
            f = obj.pixelSize(dim);
            tf = abs(f - 1) > 1e-9 || abs(sc(1) - 1) > 1e-9;
        end
    end

    % ------------------------------------------------------------------
    %  ROI methods
    % ------------------------------------------------------------------
    methods
        function idx = AddRoi(obj, corners, name)
            % AddRoi  Append a new ROI built from polygon corners (pixel
            % coords, 2×N [x;y]).  Returns the new index, which is also
            % selected.  Empty mask polygons are ignored (idx = []).
            roi = obj.buildRoi_(corners);
            if isempty(roi), idx = []; return; end
            if nargin >= 3 && ~isempty(name), roi.name = name; end
            obj.RoiList(end+1) = roi;
            idx = numel(obj.RoiList);
            obj.RoiSelection = idx;
            notify(obj, 'RoiChanged');
        end

        function ReplaceRoiGeometry(obj, idx, corners)
            % ReplaceRoiGeometry  Replace shape of ROI idx, keeping its
            % name, number and stored settings.
            if idx < 1 || idx > numel(obj.RoiList), return; end
            old = obj.RoiList(idx);
            roi = obj.buildRoi_(corners);
            if isempty(roi), return; end
            roi.name     = old.name;
            roi.number   = old.number;
            roi.settings = old.settings;
            obj.RoiList(idx) = roi;
            notify(obj, 'RoiChanged');
        end

        function RecomputeRoiGeometry(obj, indices)
            % RecomputeRoiGeometry  Rebuild mask/index/rectangle/center for
            % ROIs whose corners were edited in place (shift/rotate/scale).
            sx = obj.Size(obj.XDim);
            sy = obj.Size(obj.YDim);
            for idx = indices(:)'
                if idx < 1 || idx > numel(obj.RoiList), continue; end
                c = obj.RoiList(idx).corners;
                [mask, ix, iy] = MatVisModel.MaskFromCorners(c, sx, sy);
                obj.RoiList(idx).cornersPixelDim = c;
                obj.RoiList(idx).mask      = mask;
                obj.RoiList(idx).index.x   = ix;
                obj.RoiList(idx).index.y   = iy;
                obj.RoiList(idx).rectangle = ...
                    [min(c(1,:)), min(c(2,:)), max(c(1,:)), max(c(2,:))];
                obj.RoiList(idx).centerOfGravity = obj.roiCenters_(ix, iy);
            end
            notify(obj, 'RoiChanged');
        end

        function DeleteRois(obj, indices)
            indices = indices(indices >= 1 & indices <= numel(obj.RoiList));
            if isempty(indices), return; end
            obj.RoiList(indices) = [];
            nLeft = numel(obj.RoiList);
            if nLeft == 0
                obj.RoiSelection = [];
            else
                obj.RoiSelection = min(min(indices), nLeft);
            end
            notify(obj, 'RoiChanged');
        end

        function CopyRois(obj, indices)
            newSel = [];
            for idx = indices(:)'
                if idx < 1 || idx > numel(obj.RoiList), continue; end
                src = obj.RoiList(idx);
                roi = obj.buildRoi_(src.cornersPixelDim);
                if isempty(roi), continue; end
                roi.settings = src.settings;
                obj.RoiList(end+1) = roi;
                newSel(end+1) = numel(obj.RoiList); %#ok<AGROW>
            end
            if ~isempty(newSel)
                obj.RoiSelection = newSel;
                notify(obj, 'RoiChanged');
            end
        end

        function RenameRoi(obj, idx, name)
            if idx < 1 || idx > numel(obj.RoiList), return; end
            obj.RoiList(idx).name = char(name);
            notify(obj, 'RoiChanged');
        end

        function SetRoiSelection(obj, sel)
            sel = unique(sel(sel >= 1 & sel <= numel(obj.RoiList)));
            obj.RoiSelection = sel(:)';
            notify(obj, 'RoiChanged');
        end

        function TouchRois(obj)
            % TouchRois  Notify listeners after in-place corner edits
            % (used for live previews during mouse transforms).
            notify(obj, 'RoiChanged');
        end

        function vis = VisibleRoiIndices(obj)
            % Indices of ROIs defined in the current XY display plane.
            vis = [];
            for k = 1:numel(obj.RoiList)
                xy = obj.RoiList(k).settings.xySel;
                if numel(xy) == 2 && xy(1) == obj.XDim && xy(2) == obj.YDim
                    vis(end+1) = k; %#ok<AGROW>
                end
            end
        end

        function nImported = ImportRois(obj, rois, append)
            % ImportRois  Import a struct array in the matVis ROI export
            % format.  Rebuilds masks from pixel corners (clipping to the
            % current data size).  If an imported ROI's xySel is the
            % reverse of the current display plane, its corners are
            % flipped.  append=false replaces the existing list.
            if nargin < 3, append = true; end
            if ~append
                obj.RoiList      = MatVisModel.EmptyRoiList();
                obj.RoiSelection = [];
            end
            nImported = 0;
            for k = 1:numel(rois)
                r = rois(k);
                if isfield(r, 'cornersPixelDim') && ~isempty(r.cornersPixelDim)
                    c = double(r.cornersPixelDim);
                elseif isfield(r, 'corners') && ~isempty(r.corners)
                    c = double(r.corners);
                else
                    continue;
                end
                % Flip if imported plane is the reverse of the current one
                if isfield(r, 'settings') && isfield(r.settings, 'xySel')
                    xy = r.settings.xySel;
                    if numel(xy) == 2 && xy(1) == obj.YDim && xy(2) == obj.XDim
                        c = c([2 1], :);
                    end
                end
                roi = obj.buildRoi_(c);
                if isempty(roi), continue; end
                if isfield(r, 'name') && ~isempty(r.name)
                    roi.name = char(r.name);
                end
                if isfield(r, 'settings')
                    if isfield(r.settings, 'position'), roi.settings.position = r.settings.position; end
                    if isfield(r.settings, 'zoomVal'),  roi.settings.zoomVal  = r.settings.zoomVal;  end
                end
                obj.RoiList(end+1) = roi;
                nImported = nImported + 1;
            end
            if nImported > 0
                obj.RoiSelection = numel(obj.RoiList);
            end
            notify(obj, 'RoiChanged');
        end

        % ==================================================================
        %  Profiles (line traces) — mirror the ROI API above
        % ==================================================================
        function idx = AddProfile(obj, points, name)
            % AddProfile  Append a new profile built from polyline vertices
            % (pixel coords, 2×N [x;y]).  Returns the new index, which is
            % also selected.  Degenerate (single-point) paths are ignored.
            prof = obj.buildProfile_(points);
            if isempty(prof), idx = []; return; end
            if nargin >= 3 && ~isempty(name), prof.name = name; end
            obj.ProfileList(end+1) = prof;
            idx = numel(obj.ProfileList);
            obj.ProfileSelection = idx;
            notify(obj, 'ProfileChanged');
        end

        function ReplaceProfileGeometry(obj, idx, points)
            % ReplaceProfileGeometry  Replace path of profile idx, keeping
            % its name, number and stored settings.
            if idx < 1 || idx > numel(obj.ProfileList), return; end
            old  = obj.ProfileList(idx);
            prof = obj.buildProfile_(points);
            if isempty(prof), return; end
            prof.name     = old.name;
            prof.number   = old.number;
            prof.settings = old.settings;
            obj.ProfileList(idx) = prof;
            notify(obj, 'ProfileChanged');
        end

        function RecomputeProfile(obj, indices)
            % RecomputeProfile  Rebuild smoothedPoints/length for profiles
            % whose vertices were edited in place (shift).
            for idx = indices(:)'
                if idx < 1 || idx > numel(obj.ProfileList), continue; end
                p  = obj.ProfileList(idx).points;
                sp = MatVisModel.SmoothProfilePoints(p);
                obj.ProfileList(idx).smoothedPoints = sp;
                obj.ProfileList(idx).length         = MatVisModel.ProfilePathLength(sp);
            end
            notify(obj, 'ProfileChanged');
        end

        function DeleteProfiles(obj, indices)
            indices = indices(indices >= 1 & indices <= numel(obj.ProfileList));
            if isempty(indices), return; end
            obj.ProfileList(indices) = [];
            nLeft = numel(obj.ProfileList);
            if nLeft == 0
                obj.ProfileSelection = [];
            else
                obj.ProfileSelection = min(min(indices), nLeft);
            end
            notify(obj, 'ProfileChanged');
        end

        function CopyProfiles(obj, indices)
            newSel = [];
            for idx = indices(:)'
                if idx < 1 || idx > numel(obj.ProfileList), continue; end
                src  = obj.ProfileList(idx);
                prof = obj.buildProfile_(src.points);
                if isempty(prof), continue; end
                prof.settings = src.settings;
                obj.ProfileList(end+1) = prof;
                newSel(end+1) = numel(obj.ProfileList); %#ok<AGROW>
            end
            if ~isempty(newSel)
                obj.ProfileSelection = newSel;
                notify(obj, 'ProfileChanged');
            end
        end

        function RenameProfile(obj, idx, name)
            if idx < 1 || idx > numel(obj.ProfileList), return; end
            obj.ProfileList(idx).name = char(name);
            notify(obj, 'ProfileChanged');
        end

        function SetProfileSelection(obj, sel)
            sel = unique(sel(sel >= 1 & sel <= numel(obj.ProfileList)));
            obj.ProfileSelection = sel(:)';
            notify(obj, 'ProfileChanged');
        end

        function SetProfileWidth(obj, w)
            obj.ProfileWidth = max(1, round(w));
            notify(obj, 'ProfileChanged');
        end

        function SetProfileProjection(obj, method)
            if ismember(method, {'Mean', 'Sum', 'Max', 'Min'})
                obj.ProfileProjection = method;
                notify(obj, 'ProfileChanged');
            end
        end

        function TouchProfiles(obj)
            % TouchProfiles  Notify listeners after in-place vertex edits
            % (used for live previews during mouse shifting).
            notify(obj, 'ProfileChanged');
        end

        function vis = VisibleProfileIndices(obj)
            % Indices of profiles defined in the current XY display plane.
            vis = [];
            for k = 1:numel(obj.ProfileList)
                xy = obj.ProfileList(k).settings.xySel;
                if numel(xy) == 2 && xy(1) == obj.XDim && xy(2) == obj.YDim
                    vis(end+1) = k; %#ok<AGROW>
                end
            end
        end

        function nImported = ImportProfiles(obj, profs, append)
            % ImportProfiles  Import a struct array in the matVis profile
            % export format.  Rebuilds the smoothed path from the stored
            % vertices.  append=false replaces the existing list.
            if nargin < 3, append = true; end
            if ~append
                obj.ProfileList      = MatVisModel.EmptyProfileList();
                obj.ProfileSelection = [];
            end
            nImported = 0;
            for k = 1:numel(profs)
                r = profs(k);
                if isfield(r, 'points') && ~isempty(r.points)
                    p = double(r.points);
                else
                    continue;
                end
                if size(p, 1) ~= 2 && size(p, 2) == 2, p = p.'; end
                % Flip if imported plane is the reverse of the current one
                if isfield(r, 'settings') && isfield(r.settings, 'xySel')
                    xy = r.settings.xySel;
                    if numel(xy) == 2 && xy(1) == obj.YDim && xy(2) == obj.XDim
                        p = p([2 1], :);
                    end
                end
                prof = obj.buildProfile_(p);
                if isempty(prof), continue; end
                if isfield(r, 'name') && ~isempty(r.name)
                    prof.name = char(r.name);
                end
                if isfield(r, 'settings')
                    if isfield(r.settings, 'position'), prof.settings.position = r.settings.position; end
                    if isfield(r.settings, 'zoomVal'),  prof.settings.zoomVal  = r.settings.zoomVal;  end
                end
                obj.ProfileList(end+1) = prof;
                nImported = nImported + 1;
            end
            if nImported > 0
                obj.ProfileSelection = numel(obj.ProfileList);
            end
            notify(obj, 'ProfileChanged');
        end
    end

    methods (Access = private)
        function roi = buildRoi_(obj, corners)
            % Build a complete ROI struct from polygon corners (2×N [x;y],
            % pixel coords).  Returns [] if the polygon covers no pixels.
            roi = [];
            if isempty(corners) || size(corners, 1) ~= 2 || size(corners, 2) < 3
                return;
            end
            corners = double(corners);
            if any(corners(:, 1) ~= corners(:, end))
                corners(:, end+1) = corners(:, 1);   % close polygon
            end
            sx = obj.Size(obj.XDim);
            sy = obj.Size(obj.YDim);
            [mask, ix, iy] = MatVisModel.MaskFromCorners(corners, sx, sy);
            if isempty(ix), return; end

            number = 1;
            if ~isempty(obj.RoiList)
                number = max([obj.RoiList.number]) + 1;
            end

            roi.corners         = corners;
            roi.cornersPixelDim = corners;
            roi.index           = struct('x', ix, 'y', iy);
            roi.mask            = mask;
            roi.name            = sprintf('Roi%d', number);
            roi.number          = number;
            roi.rectangle       = [min(corners(1,:)), min(corners(2,:)), ...
                                   max(corners(1,:)), max(corners(2,:))];
            roi.settings        = struct('position', obj.CurrPos, ...
                                         'zoomVal',  obj.ZoomRange, ...
                                         'xySel',    [obj.XDim, obj.YDim]);
            roi.centerOfGravity = obj.roiCenters_(ix, iy);
        end

        function cog = roiCenters_(obj, ix, iy)
            % [geometric; intensity-weighted] centers, rows are [x y].
            % Weighted center uses the active dataset at the current
            % position (offset so all weights are non-negative).
            geo = [mean(ix), mean(iy)];
            cog = [geo; geo];
            try
                idx = num2cell(obj.CurrPos);
                sz  = obj.Size;
                nD  = numel(sz);
                subs = cell(1, nD);
                for d = 1:nD
                    if d == obj.XDim
                        subs{d} = ix(:);
                    elseif d == obj.YDim
                        subs{d} = iy(:);
                    else
                        subs{d} = repmat(idx{d}, numel(ix), 1);
                    end
                end
                vals = double(obj.Data(sub2ind(sz, subs{:})));
                w = vals - min(vals);
                if sum(w) > 0
                    cog(2, :) = [sum(ix(:) .* w) / sum(w), sum(iy(:) .* w) / sum(w)];
                end
            catch
            end
        end

        function prof = buildProfile_(obj, points)
            % Build a complete profile struct from polyline vertices
            % (2×N [x;y], pixel coords).  Returns [] for degenerate paths.
            prof = [];
            if isempty(points) || size(points, 1) ~= 2 || size(points, 2) < 2
                return;
            end
            points = double(points);
            sp = MatVisModel.SmoothProfilePoints(points);
            if size(sp, 2) < 2, return; end

            number = 1;
            if ~isempty(obj.ProfileList)
                number = max([obj.ProfileList.number]) + 1;
            end

            prof.points         = points;
            prof.smoothedPoints = sp;
            prof.name           = sprintf('Prof%d', number);
            prof.number         = number;
            prof.length         = MatVisModel.ProfilePathLength(sp);
            prof.settings       = struct('position', obj.CurrPos, ...
                                         'zoomVal',  obj.ZoomRange, ...
                                         'xySel',    [obj.XDim, obj.YDim]);
        end
    end

    methods (Static)
        function s = EmptyRoiList()
            % Empty struct array with the canonical ROI field order.
            s = struct('corners', {}, 'cornersPixelDim', {}, 'index', {}, ...
                       'mask', {}, 'name', {}, 'number', {}, ...
                       'rectangle', {}, 'settings', {}, 'centerOfGravity', {});
        end

        function [mask, ix, iy] = MaskFromCorners(corners, sx, sy)
            % MaskFromCorners  Rasterize a closed polygon (2×N [x;y]) into
            % a logical sx×sy mask, mask(x,y).  Only evaluates inpolygon
            % over the polygon's bounding box for speed.
            mask = false(sx, sy);
            ix = []; iy = [];
            cx = corners(1, :);  cy = corners(2, :);
            x0 = max(1,  floor(min(cx)));
            x1 = min(sx, ceil(max(cx)));
            y0 = max(1,  floor(min(cy)));
            y1 = min(sy, ceil(max(cy)));
            if x1 < x0 || y1 < y0, return; end
            [XX, YY] = ndgrid(x0:x1, y0:y1);
            in = inpolygon(XX, YY, cx, cy);
            mask(x0:x1, y0:y1) = in;
            [ix, iy] = find(mask);
        end

        function s = EmptyProfileList()
            % Empty struct array with the canonical profile field order.
            s = struct('points', {}, 'smoothedPoints', {}, 'name', {}, ...
                       'number', {}, 'length', {}, 'settings', {});
        end

        function sp = SmoothProfilePoints(points)
            % SmoothProfilePoints  Interpolate a polyline (2×N [x;y]) into a
            % smooth path sampled at ~1 px spacing.  Mirrors the original
            % matVis imgTraceSmooth (pchip along cumulative arc length).
            x = points(1, :).';  y = points(2, :).';
            if numel(unique(x)) <= 1 && numel(unique(y)) <= 1
                sp = points;  return;
            end
            d = [0; cumsum(hypot(diff(x), diff(y)))];
            [d, ia] = unique(d);
            x = x(ia);  y = y(ia);
            if numel(d) < 2, sp = points; return; end
            if numel(d) >= 3, method = 'pchip'; else, method = 'linear'; end
            dt = (0:ceil(d(end))).';
            xp = interp1(d, x, dt, method);
            yp = interp1(d, y, dt, method);
            % Re-parametrize to unit spacing along the resulting curve
            d2  = [0; cumsum(hypot(diff(xp), diff(yp)))];
            dt2 = (0:ceil(d2(end))).';
            xp  = interp1(d2, xp, dt2, 'linear', 'extrap');
            yp  = interp1(d2, yp, dt2, 'linear', 'extrap');
            sp  = [xp.'; yp.'];
        end

        function L = ProfilePathLength(sp)
            if size(sp, 2) < 2, L = 0; return; end
            L = sum(hypot(diff(sp(1, :)), diff(sp(2, :))));
        end

        function M = ProfileSampleMatrix(sp, width)
            % ProfileSampleMatrix  Build a perpendicular sampling grid along
            % a smoothed path.  Returns an [width × L × 2] array where
            % M(:,:,1)/M(:,:,2) are the X/Y sample coordinates.  Mirrors the
            % original matVis imgTraceMatrix.
            xp = sp(1, :).';  yp = sp(2, :).';
            lw = max(1, round(width));
            w  = (0:lw-1) - (lw-1)/2;
            T  = numel(xp);  t = 1:T;
            t1 = max([t-1; ones(1, T)]);
            t2 = min([t+1; T*ones(1, T)]);
            dp = [xp(t2) yp(t2)] - [xp(t1) yp(t1)];
            nrm = hypot(dp(:, 1), dp(:, 2));  nrm(nrm == 0) = 1;
            dp = dp ./ nrm;
            dp = dp.';
            dp = dp(:) * w;
            dp = reshape(dp.', lw, 2, []);
            dp = reshape(permute(dp, [1 3 2]), [], 2);
            dp = dp * [0 1; -1 0];                 % rotate 90° -> perpendicular
            xi = reshape(dp(:, 1), lw, []) + repmat(xp.', [lw 1]);
            yi = reshape(dp(:, 2), lw, []) + repmat(yp.', [lw 1]);
            M  = cat(3, xi, yi);
        end
    end
end
