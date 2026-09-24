classdef MatVisBioFormatsSource < MatVisLazySource
    % MatVisBioFormatsSource  Lazy data source backed by an open Bio-Formats reader.
    %
    %   Holds the reader for the life of the session and reads one plane at a
    %   time through the shared plane cache.  Measured cost on a 5.9 GB .czi:
    %   60-92 ms per plane, against 40 s to read the file in full.
    %
    %   Resolution levels: many formats (Zeiss .czi in particular) already
    %   store a pyramid.  Bio-Formats surfaces those levels as extra series
    %   with the same Z/C/T and strictly smaller X/Y, which is how they are
    %   detected here -- a genuinely multi-scene file has several series of
    %   the SAME size and is not treated as a pyramid.  Levels make the
    %   overview free (40 ms instead of a strided read of the whole stack),
    %   and they are the only way into an image whose full-resolution plane
    %   exceeds Java's 2 GB array limit.
    %
    %   See also MatVisLazySource, bfReadMetadata, loadBioFormats.

    properties (SetAccess = private)
        Reader          % loci.formats reader, held open
        LevelSeries     % 1xL 0-based series indices, finest first
        SizeZCT         % [Z C T] at full resolution
        KeepZCT         % 1x3 logical -- which of Z/C/T survived singleton drop
        Meta            % dimNames/dimScale/dimUnits/channelNames/instrument
        CurrentSeries_ = -1
    end

    methods
        function obj = MatVisBioFormatsSource(filepath, cache)
            if nargin < 2 || isempty(cache)
                cache = MatVisPlaneCache.shared();
            end
            if ~ensureBioFormats()
                error('MatVisBioFormatsSource:noBioFormats', ...
                    'Bio-Formats is not set up; cannot open "%s" lazily.', filepath);
            end

            obj.FilePath = filepath;
            obj.Cache    = cache;
            obj.CacheTag = sprintf('bf:%s:%s', filepath, ...
                char(matlab.lang.internal.uuid));

            r = bfGetReader(filepath);
            obj.Reader = r;

            % Interleaved RGB planes would need un-packing before they could
            % be addressed per channel; matVis has no such path, so say so
            % plainly rather than return scrambled pixels.
            if r.getRGBChannelCount() > 1
                obj.closeSource();
                error('MatVisBioFormatsSource:interleavedRGB', ...
                    ['"%s" stores interleaved RGB planes, which the lazy reader ' ...
                     'does not support; load it in full instead.'], filepath);
            end

            % Every level the file carries is exposed.  The dataset's size is
            % the finest one, whatever that is: a caller that asks for more
            % pixels than fit in one array asks for them with a stride, and
            % readSub serves that from whichever level matches (see
            % MatVisLazySource.readSub).
            obj.LevelSeries = MatVisBioFormatsSource.detectLevels_(r);
            r.setSeries(obj.LevelSeries(1));
            obj.CurrentSeries_ = obj.LevelSeries(1);

            SizeZ = double(r.getSizeZ());
            SizeC = double(r.getSizeC());
            SizeT = double(r.getSizeT());
            obj.SizeZCT = [SizeZ, SizeC, SizeT];
            obj.KeepZCT = [SizeZ > 1, SizeC > 1, SizeT > 1];

            fullSz = [double(r.getSizeY()), double(r.getSizeX())];
            obj.Size = [fullSz, obj.SizeZCT(obj.KeepZCT)];

            obj.LevelSizes = cell(1, numel(obj.LevelSeries));
            for L = 1:numel(obj.LevelSeries)
                r.setSeries(obj.LevelSeries(L));
                obj.LevelSizes{L} = [double(r.getSizeY()), double(r.getSizeX()), ...
                                     obj.SizeZCT(obj.KeepZCT)];
            end
            r.setSeries(obj.LevelSeries(1));
            obj.CurrentSeries_ = obj.LevelSeries(1);

            % One real plane read: establishes the element class and, at the
            % same time, measures what a plane costs -- the number the entry
            % gate and the prefetch depth are both derived from.  It happens
            % at the COARSEST level, because a full-resolution plane of a
            % stitched image can exceed Java's 2 GB array limit and fail --
            % which is exactly the file this class has to be able to open.
            probeLevel = numel(obj.LevelSeries);
            r.setSeries(obj.LevelSeries(probeLevel));
            obj.CurrentSeries_ = obj.LevelSeries(probeLevel);
            t0 = tic;
            probe = bfGetPlane(r, 1);
            readCost = toc(t0);
            obj.ClassName = class(probe);
            obj.IsInteger = isinteger(probe);
            if probeLevel > 1
                % Cost at a coarse level says nothing about the full-res one;
                % scale by the pixel ratio so the estimate is at least the
                % right order of magnitude until a real plane is read.
                readCost = readCost * prod(obj.LevelSizes{1}(1:2)) / ...
                                      prod(obj.LevelSizes{probeLevel}(1:2));
            end
            r.setSeries(obj.LevelSeries(1));
            obj.CurrentSeries_ = obj.LevelSeries(1);

            obj.Capabilities = struct( ...
                'HasFileLevels', numel(obj.LevelSeries) > 1, ...
                'SupportsTiles', true, ...
                'PlaneReadCost', readCost);

            [phys, chNames, instrument] = bfReadMetadata(r, filepath);
            % Dimension names/scale/units come from the same helper the
            % full-load path uses, fed a 1x1xZxCxT stand-in so the singleton
            % rules cannot drift between the two paths.
            [~, obj.Meta] = finalizeOmePlanes( ...
                zeros([1, 1, SizeZ, SizeC, SizeT], 'uint8'), phys, chNames, instrument);

            % A plane too large for one Java array can never be read whole,
            % however much memory the machine has, so a full load of this file
            % is not merely expensive -- it is impossible.
            obj.FullLoadFeasible = prod(obj.Size(1:2)) * ...
                MatVisDataSource.bytesPerElement(obj.ClassName) < 2^31;

            obj.seedRange_();
        end

        function closeSource(obj)
            if ~isempty(obj.Reader)
                try, obj.Reader.close(); catch, end
                obj.Reader = [];
            end
        end

        function n = planeCount(obj)
            n = prod(obj.Size(3:end));
        end
    end

    methods (Access = protected)
        function prepareLevel_(obj, level)
            % Switching series is what selects a resolution level, and it also
            % decides what getIndex means, so it happens once per run of reads
            % rather than per plane.
            obj.setLevel_(level);
        end

        function A = readPlaneRaw(obj, planeIdx, level)
            if nargin < 3 || isempty(level), level = 1; end
            obj.setLevel_(level);
            A = bfGetPlane(obj.Reader, planeIdx);
        end

        function A = readPlaneRegion(obj, planeIdx, level, row0, col0, h, w)
            % bfGetPlane takes the origin as (x, y) = (column, row), 1-based.
            obj.setLevel_(level);
            A = bfGetPlane(obj.Reader, planeIdx, col0, row0, w, h);
        end

        function i = planeIndexFromSubs(obj, subs)
            zct = [1, 1, 1];
            k = 0;
            for d = 1:3
                if obj.KeepZCT(d)
                    k = k + 1;
                    zct(d) = subs(k);
                end
            end
            i = double(obj.Reader.getIndex(zct(1) - 1, zct(2) - 1, zct(3) - 1)) + 1;
        end
    end

    methods (Access = private)
        function setLevel_(obj, level)
            s = obj.LevelSeries(level);
            if s ~= obj.CurrentSeries_
                obj.Reader.setSeries(s);
                obj.CurrentSeries_ = s;
            end
        end
    end

    methods (Static, Access = private)
        function levels = detectLevels_(r)
            % Series that form a resolution pyramid of series 0: same Z/C/T,
            % strictly smaller in both X and Y than the one before.  Anything
            % else (equal sizes, differing Z/C/T) is a separate scene and is
            % left alone -- matVis reads the first one, as it always has.
            n = double(r.getSeriesCount());
            r.setSeries(0);
            z0 = r.getSizeZ();  c0 = r.getSizeC();  t0 = r.getSizeT();
            x0 = double(r.getSizeX());  y0 = double(r.getSizeY());

            levels = 0;
            prevX = x0;  prevY = y0;
            for s = 1:n-1
                r.setSeries(s);
                if r.getSizeZ() ~= z0 || r.getSizeC() ~= c0 || r.getSizeT() ~= t0
                    break;
                end
                x = double(r.getSizeX());  y = double(r.getSizeY());
                if x >= prevX || y >= prevY
                    break;
                end
                levels(end+1) = s; %#ok<AGROW>
                prevX = x;  prevY = y;
            end
            r.setSeries(0);
        end
    end
end
