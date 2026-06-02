classdef MatVisModel < handle
    % MatVisModel  Data and metadata container for matVis 2.0.
    %
    %   model = MatVisModel(data)
    %
    %   data must be a numeric N-D array (N >= 2).  All properties are
    %   initialised to sensible defaults; use applyStartPar to override.

    properties
        Data            % numeric N-D array
        DimNames        % 1xN cell array of strings
        DimScale        % 1xN cell array of numeric vectors
        DimUnits        % 1xN cell array of strings
        CurrPos         % 1xN integer index vector (1-based, clamped)
        ZoomRange       % Nx2 double  [lo, hi] per dim (1-based indices)
        XDim            % scalar integer -- dimension shown on X axis
        YDim            % scalar integer -- dimension shown on Y axis
        Gamma           % scalar double in [0.1, 5.0], default 1.0
        ColormapIdx     % scalar positive integer, default 1
        PlotDims        % 1xN logical vector
        ContrastMin     % scalar double
        ContrastMax     % scalar double
    end

    properties (SetAccess = private)
        Size            % 1xN double -- size of Data (read-only)
        DataMin  double % min of Data(:) — fixed at load time, not contrast setting
        DataMax  double % max of Data(:) — fixed at load time
    end

    % ------------------------------------------------------------------
    %  Constructor
    % ------------------------------------------------------------------
    methods
        function obj = MatVisModel(data)
            % MatVisModel  Construct a model from a numeric N-D array.
            validateattributes(data, {'numeric'}, {'nonempty'}, ...
                'MatVisModel', 'data');

            % Bootstrap Size before setters run
            obj.Size = size(data);

            % Assign Data directly (bypass setter so Size is already set)
            obj.Data = data;

            s = obj.Size;
            N = numel(s);

            % DimNames
            obj.DimNames = arrayfun(@(k) sprintf('Dim%d', k), 1:N, ...
                'UniformOutput', false);

            % DimScale -- linear 1..size per dimension
            obj.DimScale = arrayfun(@(k) 1:s(k), 1:N, ...
                'UniformOutput', false);

            % DimUnits
            obj.DimUnits = repmat({''}, 1, N);

            % CurrPos -- centred
            obj.CurrPos = max(1, round(s / 2));

            % ZoomRange -- full extent
            obj.ZoomRange = [ones(N, 1), s(:)];

            % Display dimensions (set YDim first to avoid conflict with
            % default empty XDim)
            obj.YDim = 1;
            obj.XDim = 2;

            % Rendering
            obj.Gamma       = 1.0;
            obj.ColormapIdx = 1;
            obj.PlotDims    = false(1, N);

            % Contrast
            obj.ContrastMin = double(min(data(:)));
            obj.ContrastMax = double(max(data(:)));
        end
    end

    % ------------------------------------------------------------------
    %  Setters
    % ------------------------------------------------------------------
    methods
        function set.Data(obj, value)
            validateattributes(value, {'numeric'}, {'nonempty'}, ...
                'MatVisModel.set.Data', 'Data');
            obj.Data    = value;
            obj.Size    = size(value);
            obj.DataMin = double(min(value(:)));
            obj.DataMax = double(max(value(:)));
            obj.ContrastMin = obj.DataMin;
            obj.ContrastMax = obj.DataMax;
        end

        function set.XDim(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'integer', 'positive'}, ...
                'MatVisModel.set.XDim', 'XDim');
            N = numel(obj.Size);
            if value < 1 || value > N
                error('MatVisModel:invalidDim', ...
                    'XDim must be in [1, %d].', N);
            end
            if ~isempty(obj.YDim) && value == obj.YDim
                error('MatVisModel:dimConflict', ...
                    'XDim must not equal YDim (%d).', obj.YDim);
            end
            obj.XDim = value;
        end

        function set.YDim(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'integer', 'positive'}, ...
                'MatVisModel.set.YDim', 'YDim');
            N = numel(obj.Size);
            if value < 1 || value > N
                error('MatVisModel:invalidDim', ...
                    'YDim must be in [1, %d].', N);
            end
            if ~isempty(obj.XDim) && value == obj.XDim
                error('MatVisModel:dimConflict', ...
                    'YDim must not equal XDim (%d).', obj.XDim);
            end
            obj.YDim = value;
        end

        function set.CurrPos(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'vector', 'integer'}, ...
                'MatVisModel.set.CurrPos', 'CurrPos');
            s = obj.Size;
            if numel(value) ~= numel(s)
                error('MatVisModel:sizeMismatch', ...
                    'CurrPos must have %d elements.', numel(s));
            end
            % clamp to valid range
            value = max(1, min(value, s));
            obj.CurrPos = value(:)';
        end

        function set.ZoomRange(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'2d', 'ncols', 2}, ...
                'MatVisModel.set.ZoomRange', 'ZoomRange');
            s = obj.Size;
            N = numel(s);
            if size(value, 1) ~= N
                error('MatVisModel:sizeMismatch', ...
                    'ZoomRange must be %dx2.', N);
            end
            % clamp lo and hi to [1, Size]
            lo = max(1, min(value(:, 1), s(:)));
            hi = max(1, min(value(:, 2), s(:)));
            % ensure lo <= hi
            lo = min(lo, hi);
            obj.ZoomRange = [lo, hi];
        end

        function set.Gamma(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'real', 'finite'}, ...
                'MatVisModel.set.Gamma', 'Gamma');
            obj.Gamma = max(0.1, min(5.0, value));
        end

        function set.ColormapIdx(obj, value)
            validateattributes(value, {'numeric'}, ...
                {'scalar', 'integer', 'positive'}, ...
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

        function set.ContrastMin(obj, value)
            validateattributes(value, {'numeric'}, {'scalar', 'real'}, ...
                'MatVisModel.set.ContrastMin', 'ContrastMin');
            obj.ContrastMin = double(value);
        end

        function set.ContrastMax(obj, value)
            validateattributes(value, {'numeric'}, {'scalar', 'real'}, ...
                'MatVisModel.set.ContrastMax', 'ContrastMax');
            obj.ContrastMax = double(value);
        end
    end

    % ------------------------------------------------------------------
    %  Public methods
    % ------------------------------------------------------------------
    methods
        function applyStartPar(obj, sp)
            % applyStartPar  Apply a startPar struct of named overrides.
            %
            %   Recognised fields (all optional):
            %     xySel   -- [xDim, yDim] vector  or struct with .x / .y
            %     gamma   -- scalar Gamma value
            %     cmap    -- scalar ColormapIdx
            %     currPos -- 1xN CurrPos vector
            %     zoomVal -- Nx2 ZoomRange matrix

            if isempty(sp) || ~isstruct(sp)
                return;
            end

            % xySel: [xDim, yDim]
            if isfield(sp, 'xySel')
                v = sp.xySel;
                if isstruct(v)
                    if isfield(v, 'x'), obj.XDim = v.x; end
                    if isfield(v, 'y'), obj.YDim = v.y; end
                else
                    v = v(:)';
                    if numel(v) >= 2
                        xNew = v(1);
                        yNew = v(2);
                        % Avoid transient conflict: set the one that won't
                        % collide with current values first.
                        if xNew ~= obj.YDim
                            obj.XDim = xNew;
                            obj.YDim = yNew;
                        else
                            obj.YDim = yNew;
                            obj.XDim = xNew;
                        end
                    end
                end
            end

            if isfield(sp, 'gamma')
                obj.Gamma = sp.gamma;
            end

            if isfield(sp, 'cmap')
                obj.ColormapIdx = sp.cmap;
            end

            if isfield(sp, 'currPos')
                obj.CurrPos = sp.currPos;
            end

            if isfield(sp, 'zoomVal')
                obj.ZoomRange = sp.zoomVal;
            end
        end
    end
end
