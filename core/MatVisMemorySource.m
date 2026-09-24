classdef MatVisMemorySource < MatVisDataSource
    % MatVisMemorySource  Data source backed by an array already in memory.
    %
    %   The behaviour matVis has always had: every request is answered by
    %   indexing one numeric array.  Datasets passed in from the workspace,
    %   and files loaded in full, end up here.
    %
    %   See also MatVisDataSource.

    properties (SetAccess = protected)
        Size
        ClassName
        IsInteger
    end

    properties (SetAccess = private)
        Array       % the numeric array itself
    end

    methods
        function obj = MatVisMemorySource(a)
            validateattributes(a, {'numeric', 'logical'}, {'nonempty'}, ...
                'MatVisMemorySource', 'data');
            obj.Array     = a;
            obj.Size      = size(a);
            obj.ClassName = class(a);
            obj.IsInteger = isinteger(a);
        end

        function A = readSub(obj, idx)
            % An all-':' index would still make MATLAB materialize a full
            % copy, so in that case the array is passed through untouched --
            % for a projection over a large stack that copy is the single
            % most expensive step.
            if all(cellfun(@(c) isequal(c, ':'), idx))
                A = obj.Array;
            else
                A = obj.Array(idx{:});
            end
        end

        function v = readLinear(obj, lin)
            v = obj.Array(lin);
        end

        function [mn, mx] = valueRange(obj, finiteOnly)
            if nargin < 2, finiteOnly = false; end
            if finiteOnly
                vals = obj.Array(isfinite(obj.Array));
                if isempty(vals)
                    mn = 0;  mx = 1;
                    return;
                end
                mn = double(min(vals(:)));
                mx = double(max(vals(:)));
            else
                mn = double(min(obj.Array(:)));
                mx = double(max(obj.Array(:)));
            end
        end

        function [idx, val] = peakIndex(obj)
            [val, idx] = max(obj.Array(:));
            val = double(val);
        end

        function counts = histCounts(obj, edges)
            % Pass native-type data -- double() would copy the whole array.
            counts = histcounts(obj.Array(:), edges);
        end

        function cr = channelRange(obj, rd, pLow, pHigh)
            cr = MatVisRender.channelRangeFromData(obj.Array, rd, pLow, pHigh);
        end
    end
end
