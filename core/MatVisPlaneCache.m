classdef MatVisPlaneCache < handle
    % MatVisPlaneCache  Least-recently-used cache of decoded image planes.
    %
    %   One cache is shared by every lazy source in a session, so the budget
    %   is a property of the machine rather than of any one dataset.  That
    %   matters because the render loop touches every dataset on every frame
    %   (see computeDatasetDisplay in MatVisMainWindow): giving each dataset
    %   its own budget would multiply memory use by the number of datasets.
    %
    %   Planes are keyed by an opaque char key built by the caller, which must
    %   identify the source, the resolution level and the plane.
    %
    %   See also MatVisLazySource.

    properties (SetAccess = private)
        BudgetBytes     % byte ceiling for held planes
        UsedBytes = 0   % bytes currently held
        Hits      = 0
        Misses    = 0
    end

    properties (Access = private)
        Map_            % containers.Map: key -> struct('data', A, 'bytes', n)
        Order_          % 1xM cell of keys, most recently used LAST
    end

    methods
        function obj = MatVisPlaneCache(budgetBytes)
            if nargin < 1 || isempty(budgetBytes)
                budgetBytes = MatVisPlaneCache.defaultBudget();
            end
            obj.BudgetBytes = budgetBytes;
            obj.Map_   = containers.Map('KeyType', 'char', 'ValueType', 'any');
            obj.Order_ = {};
        end

        function [A, hit] = fetch(obj, key, producer)
            % fetch  Held plane for KEY, or PRODUCER() stored under it.
            if obj.Map_.isKey(key)
                rec = obj.Map_(key);
                A   = rec.data;
                hit = true;
                obj.Hits = obj.Hits + 1;
                obj.touch_(key);
                return;
            end
            obj.Misses = obj.Misses + 1;
            hit = false;
            A   = producer();
            obj.store(key, A);
        end

        function store(obj, key, A)
            % store  Put A under KEY, evicting the least recently used planes
            % until the budget is met.  A plane larger than the whole budget
            % is simply not cached -- returning it uncached is better than
            % emptying the cache for something that cannot be kept anyway.
            n = numel(A) * MatVisDataSource.bytesPerElement(class(A));
            if n > obj.BudgetBytes
                return;
            end
            if obj.Map_.isKey(key)
                obj.UsedBytes = obj.UsedBytes - obj.Map_(key).bytes;
            end
            obj.Map_(key) = struct('data', A, 'bytes', n);
            obj.UsedBytes = obj.UsedBytes + n;
            obj.touch_(key);
            obj.evictTo_(obj.BudgetBytes);
        end

        function tf = isCached(obj, key)
            tf = obj.Map_.isKey(key);
        end

        function clear(obj)
            obj.Map_   = containers.Map('KeyType', 'char', 'ValueType', 'any');
            obj.Order_ = {};
            obj.UsedBytes = 0;
        end

        function setBudget(obj, budgetBytes)
            obj.BudgetBytes = budgetBytes;
            obj.evictTo_(budgetBytes);
        end

        function s = stats(obj)
            s = struct('held', obj.Map_.Count, 'usedBytes', obj.UsedBytes, ...
                'budgetBytes', obj.BudgetBytes, 'hits', obj.Hits, ...
                'misses', obj.Misses);
        end
    end

    methods (Access = private)
        function touch_(obj, key)
            hit = strcmp(obj.Order_, key);
            if any(hit), obj.Order_(hit) = []; end
            obj.Order_{end+1} = key;
        end

        function evictTo_(obj, limit)
            while obj.UsedBytes > limit && ~isempty(obj.Order_)
                oldest = obj.Order_{1};
                obj.Order_(1) = [];
                if obj.Map_.isKey(oldest)
                    obj.UsedBytes = obj.UsedBytes - obj.Map_(oldest).bytes;
                    obj.Map_.remove(oldest);
                end
            end
        end
    end

    methods (Static)
        function c = shared(budgetBytes)
            % shared  The session-wide cache, created on first use.
            persistent theCache
            if nargin >= 1 && ~isempty(budgetBytes)
                if isempty(theCache) || ~isvalid(theCache)
                    theCache = MatVisPlaneCache(budgetBytes);
                else
                    theCache.setBudget(budgetBytes);
                end
            elseif isempty(theCache) || ~isvalid(theCache)
                theCache = MatVisPlaneCache();
            end
            c = theCache;
        end

        function n = defaultBudget()
            % A fixed fraction of free memory, clamped to a sane range.
            % Windows-only `memory`; elsewhere fall back to a flat 1 GB.
            n = 1024^3;
            try
                if ispc
                    u = memory;
                    n = min(max(0.10 * u.MemAvailableAllArrays, 256*1024^2), 4*1024^3);
                end
            catch
            end
        end
    end
end
