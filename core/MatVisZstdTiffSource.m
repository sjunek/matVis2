classdef MatVisZstdTiffSource < MatVisLazySource
    % MatVisZstdTiffSource  On-demand reader for Zstandard/PackBits TIFFs.
    %
    %   Bio-Formats cannot decode these (it throws
    %   NegativeArraySizeException), and MATLAB's own TIFF library does not
    %   know compression 50000 either, so until now such a file could only be
    %   read whole by io/loadZstdTiff -- which meant waiting for all of it
    %   before seeing any of it.
    %
    %   The file makes this easy: every directory is independently
    %   compressed, so one page decodes without touching the others.  Opening
    %   reads the tag chain only.  Measured on a 735-page 2048x2048 16-bit
    %   BigTIFF (2.4 GB on disk, 5.7 GB in memory):
    %
    %       parse the whole directory chain    0.36 s
    %       decode one page                    0.10 - 0.30 s
    %       read the file in full             ~75 s
    %
    %   There are no resolution levels in such a file, so LevelSizes has one
    %   entry and the viewer reports plane-by-plane reading rather than a
    %   pyramid.
    %
    %   Region reads are deliberately not offered.  The pages this was written
    %   for hold one strip each, spanning every row, so a crop would decode
    %   the whole plane anyway; saying so lets MatVisLazySource cache whole
    %   planes instead, which serves any later crop of the same plane for
    %   free.
    %
    %   See also MatVisLazySource, zstdTiffOpen, zstdTiffReadPage, loadZstdTiff.

    properties (SetAccess = private)
        Fid    = -1     % open read handle, held for the session
        Ifds            % 1xN directory structs
        Geometry        % page geometry from zstdTiffOpen
        Compressions    % 1xN compression tag, one per page
        Meta            % dimNames/dimScale/dimUnits/instrument
    end

    methods
        function obj = MatVisZstdTiffSource(filepath, cache)
            if nargin < 2 || isempty(cache)
                cache = MatVisPlaneCache.shared();
            end
            obj.FilePath = filepath;
            obj.Cache    = cache;
            obj.CacheTag = sprintf('zt:%s:%s', filepath, ...
                char(matlab.lang.internal.uuid));

            S = zstdTiffOpen(filepath);              % tags only, no pixels
            obj.Ifds         = S.ifds;
            obj.Geometry     = S.g;
            obj.Compressions = S.compressions;
            obj.Meta         = S.meta;

            obj.Fid = fopen(filepath, 'r', 'ieee-le');
            if obj.Fid < 0
                error('MatVisZstdTiffSource:cannotOpen', ...
                    'Cannot open "%s" for reading.', filepath);
            end

            % Colour samples within a page are a third axis, exactly as the
            % whole-file reader collapses them; pages are the fourth.
            sz = [S.g.height, S.g.width, S.g.spp, S.nPages];
            obj.Size = sz([true, true, S.g.spp > 1, S.nPages > 1]);

            obj.LevelSizes = {obj.Size};

            % The tags already say what a sample is, so the class costs
            % nothing -- no page has to be decoded to learn it.
            obj.ClassName = S.g.cls;
            obj.IsInteger = ~ismember(S.g.cls, {'single', 'double'});

            % Unlike a stitched pyramid, a page here is an ordinary image, so
            % holding the whole file in one array is a question of memory
            % rather than of the reader's limits.
            obj.FullLoadFeasible = true;

            obj.Capabilities = struct( ...
                'HasFileLevels', false, ...
                'SupportsTiles', false, ...
                'PlaneReadCost', 0);

            obj.seedRange_();

            % Timed only now: the first decode of a session pays for codec
            % warm-up and would treble the estimate, and seedRange_ has just
            % done several.  The middle of the stack is chosen because these
            % files often open on empty frames, which decode in milliseconds
            % and would say nothing about navigating the real data.
            nPl = prod(obj.Size(3:end));
            t0  = tic;
            obj.readPlaneRaw(max(1, round(nPl / 2)), 1);
            obj.Capabilities.PlaneReadCost = toc(t0);
        end

        function closeSource(obj)
            if obj.Fid >= 0
                try
                    fclose(obj.Fid);
                catch
                end
                obj.Fid = -1;
            end
        end
    end

    methods (Access = protected)
        function A = readPlaneRaw(obj, planeIdx, level)  %#ok<INUSD>
            % LEVEL is ignored: the file carries a single resolution.
            if obj.Fid < 0
                error('MatVisZstdTiffSource:closed', ...
                    'The reader for "%s" has been closed.', obj.FilePath);
            end
            [page, sample] = obj.pageAndSample_(planeIdx);
            P = zstdTiffReadPage(obj.Fid, obj.Ifds(page), obj.Geometry, ...
                obj.Compressions(page), obj.FilePath, page);
            A = P(:, :, sample);
        end

        function i = planeIndexFromSubs(obj, subs)
            % Map the plane-dimension subscripts onto a flat plane number.
            % Which axes exist depends on what the file uses, so the same
            % collapsing rule as the constructor decides how to read subs.
            hasC = obj.Geometry.spp > 1;
            hasP = numel(obj.Ifds) > 1;
            c = 1;  p = 1;
            if hasC && hasP
                c = subs(1);  p = subs(2);
            elseif hasC
                c = subs(1);
            elseif hasP
                p = subs(1);
            end
            i = (p - 1) * obj.Geometry.spp + c;
        end
    end

    methods (Access = private)
        function [page, sample] = pageAndSample_(obj, planeIdx)
            spp    = obj.Geometry.spp;
            page   = floor((planeIdx - 1) / spp) + 1;
            sample = mod(planeIdx - 1, spp) + 1;
        end
    end
end
