classdef MatVisDataSource < handle
    % MatVisDataSource  Read interface between the display code and one dataset.
    %
    %   Everything matVis draws ultimately asks for a hyperrectangle of one
    %   dataset.  MatVisRender already expresses that request explicitly: a
    %   slice plan's .idx cell names, per dimension, which indices the slice
    %   needs (see MatVisRender.rawSlicePlan).  A data source executes such a
    %   request.  The in-memory implementation indexes an array; a lazy one
    %   reads planes from a file.  Nothing above this class knows which of the
    %   two it is holding.
    %
    %   Reductions -- projection, the RGB channel split, axis flips -- stay in
    %   MatVisRender and run on whatever readSub returns.  A source's only job
    %   is to produce the requested elements, in their stored class.
    %
    %   Whole-dataset queries (valueRange, peakIndex, histCounts,
    %   channelRange) are methods rather than loops written at the call site,
    %   because a source that does not hold the whole array has to answer them
    %   some other way -- from a decimated overview, or by streaming once.
    %   Keeping them here is what makes that substitution possible later.
    %
    %   See also MatVisMemorySource, MatVisRender.rawSlicePlan.

    properties (Abstract, SetAccess = protected)
        Size        % 1xN size vector of the dataset
        ClassName   % char: the ELEMENT class ('uint16'), never class(obj)
        IsInteger   % logical: the element class is an integer type
    end

    properties (SetAccess = protected)
        % True when the whole-dataset answers below -- valueRange, peakIndex,
        % histCounts, channelRange -- are computed from a sample of the data
        % rather than from every element.  Anything the user reads that was
        % derived from one of them has to say so: a contrast window or a
        % histogram that is quietly a few percent wrong is worse than one
        % that admits it.
        StatsApproximate = false
    end

    methods (Abstract)
        % readSub  Elements named by a 1xN cell of index vectors (or ':').
        %   Returns them in the stored class, shaped as MATLAB's own
        %   subscripted reference would.
        A = readSub(obj, idx)

        % readLinear  Elements at linear indices into Size.
        %   Needed by the ROI paths, which build sub2ind lists rather than
        %   per-dimension ranges.
        v = readLinear(obj, lin)

        % valueRange  [min max] over the dataset, as double.
        %   finiteOnly (default false) excludes NaN/Inf -- used for alpha maps.
        [mn, mx] = valueRange(obj, finiteOnly)

        % peakIndex  Linear index and value of the maximum.
        %   Seeds CurrPos at the brightest pixel.
        [idx, val] = peakIndex(obj)

        % histCounts  Counts over EDGES for the whole dataset.
        counts = histCounts(obj, edges)

        % channelRange  size(data,rd)x2 [lo hi] per index along dimension rd.
        %   See MatVisRender.channelRangeFromData for the semantics.
        cr = channelRange(obj, rd, pLow, pHigh)
    end

    methods
        function n = numDims(obj)
            n = numel(obj.Size);
        end

        function n = numElements(obj)
            n = prod(obj.Size);
        end

        function b = byteCount(obj)
            % Size of the dataset in memory, in bytes.
            b = prod(obj.Size) * MatVisDataSource.bytesPerElement(obj.ClassName);
        end
    end

    methods (Static)
        function src = wrap(d)
            % wrap  Accept a source or a numeric array; always return a source.
            %   The single entry point used wherever caller-supplied data
            %   arrives, so numeric input keeps working unchanged.
            if isa(d, 'MatVisDataSource')
                src = d;
            else
                src = MatVisMemorySource(d);
            end
        end

        function n = bytesPerElement(cls)
            switch cls
                case {'double', 'int64', 'uint64'},  n = 8;
                case {'single', 'int32', 'uint32'},  n = 4;
                case {'int16', 'uint16'},            n = 2;
                case {'int8', 'uint8', 'logical'},   n = 1;
                otherwise,                           n = 8;
            end
        end
    end
end
