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
        Gamma           % scalar double in [0.1, 5.0]
        ColormapIdx     % scalar positive integer
        PlotDims        % 1×N logical vector
        PlotLock        % 1×N logical vector
        ProjZoomLock    % logical
        ContrastMin     % scalar double — active dataset manual lower bound
        ContrastMax     % scalar double — active dataset manual upper bound
        ContrastMode    % string: 'Global', 'Image', 'Zoom', 'Manual'
        FlipX           % logical
        FlipY           % logical

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

            % Rendering
            obj.Gamma        = 1.0;
            obj.ColormapIdx  = 1;
            obj.PlotDims     = false(1, N);
            obj.PlotLock     = false(1, N);
            obj.ProjZoomLock = false;
            obj.FlipX        = false;
            obj.FlipY        = false;

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
    end
end
