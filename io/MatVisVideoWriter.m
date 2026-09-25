classdef MatVisVideoWriter < handle
    % MatVisVideoWriter  Frame sink for the matVis 2.0 video generator.
    %
    %   w = MatVisVideoWriter(fileName, formatKey)
    %   w = MatVisVideoWriter(fileName, formatKey, 'FrameRate', 25, 'Quality', 95)
    %   w.Open();
    %   w.WriteFrame(rgb);          % H×W×3 uint8, same size every frame
    %   w.Close();
    %
    %   Every output format lives in one table (Formats), so codec, file
    %   extension and the meaning of "quality" are declared once instead of
    %   being rebuilt by a switch at each call site — the original matVis
    %   repeated that mapping in four places and they drifted apart.
    %
    %   Backends
    %     'videowriter' : MATLAB VideoWriter profile
    %     'imageseq'    : numbered image files in a directory (imwrite)
    %     'gif'         : single animated GIF (imwrite append)
    %
    %   ffmpeg-based presets are a later phase; the Formats table is the
    %   seam they plug into.

    properties (SetAccess = private)
        FileName        % full path given by the caller
        FormatKey       % key into the Formats table
        Format          % the resolved format row (struct)
        FrameRate  = 25
        Quality    = 95 % 1..100, or the MJ2 compression ratio
        FrameCount = 0
        FrameSize  = []  % [W H] fixed by the first frame
        IsOpen     = false
    end

    properties (Access = private)
        vw_       = []   % VideoWriter object
        seqDir_   = ''   % image-sequence output directory
        seqStem_  = ''   % image-sequence file stem
    end

    % ------------------------------------------------------------------
    methods (Static)
        function F = Formats()
            % Supported outputs.  key / label / ext / backend / profile /
            % qualityField ('' = none) / needsEvenSize.
            F = struct( ...
                'key',         {'mp4',            'mjavi',            'avi',               'mj2',               'archival',            'png_seq',            'tif_seq',            'gif'}, ...
                'label',       {'MPEG-4 (H.264)', 'Motion JPEG AVI',  'Uncompressed AVI',  'Motion JPEG 2000',  'Archival (lossless)', 'PNG image sequence', 'TIFF image sequence','Animated GIF'}, ...
                'ext',         {'.mp4',           '.avi',             '.avi',              '.mj2',              '.mj2',                '.png',               '.tif',               '.gif'}, ...
                'backend',     {'videowriter',    'videowriter',      'videowriter',       'videowriter',       'videowriter',         'imageseq',           'imageseq',           'gif'}, ...
                'profile',     {'MPEG-4',         'Motion JPEG AVI',  'Uncompressed AVI',  'Motion JPEG 2000',  'Archival',            '',                   '',                   ''}, ...
                'qualityField',{'Quality',        'Quality',          '',                  'CompressionRatio',  '',                    '',                   '',                   ''}, ...
                'needsEvenSize', {true,           false,              false,               false,               false,                 false,                false,                false});
        end

        function f = FormatByKey(key)
            F = MatVisVideoWriter.Formats();
            i = find(strcmpi({F.key}, key), 1);
            if isempty(i)
                error('MatVisVideoWriter:unknownFormat', ...
                    'Unknown output format "%s". Known: %s.', ...
                    key, strjoin({F.key}, ', '));
            end
            f = F(i);
        end

        function keys = AvailableFormats()
            % Formats this MATLAB installation can actually write.  A missing
            % VideoWriter profile (MPEG-4 is absent on some Linux installs)
            % drops out here instead of failing at Open().
            F = MatVisVideoWriter.Formats();
            have = {};
            try
                p = VideoWriter.getProfiles();
                have = {p.Name};
            catch
            end
            keep = true(1, numel(F));
            for i = 1:numel(F)
                if strcmp(F(i).backend, 'videowriter')
                    keep(i) = any(strcmp(have, F(i).profile));
                end
            end
            keys = {F(keep).key};
        end

        function [filters, defaultIdx] = FileFilters(preferKey)
            % uiputfile filter list, preferred format first.
            F = MatVisVideoWriter.Formats();
            keys = MatVisVideoWriter.AvailableFormats();
            F = F(ismember({F.key}, keys));
            filters = cell(numel(F), 2);
            for i = 1:numel(F)
                filters{i, 1} = ['*' F(i).ext];
                filters{i, 2} = sprintf('%s (*%s)', F(i).label, F(i).ext);
            end
            defaultIdx = 1;
            if nargin >= 1 && ~isempty(preferKey)
                j = find(strcmpi({F.key}, preferKey), 1);
                if ~isempty(j), defaultIdx = j; end
            end
        end
    end

    % ------------------------------------------------------------------
    methods
        function obj = MatVisVideoWriter(fileName, formatKey, varargin)
            p = inputParser;
            p.addParameter('FrameRate', 25, @(v) isnumeric(v) && isscalar(v) && v > 0);
            p.addParameter('Quality',   95, @(v) isnumeric(v) && isscalar(v) && v > 0);
            p.parse(varargin{:});

            obj.FileName  = char(fileName);
            obj.FormatKey = char(formatKey);
            obj.Format    = MatVisVideoWriter.FormatByKey(obj.FormatKey);
            obj.FrameRate = p.Results.FrameRate;
            obj.Quality   = p.Results.Quality;

            % Force the extension the format demands, so a name typed with
            % the wrong suffix still produces a readable file.
            [pth, stem, ext] = fileparts(obj.FileName);
            if ~strcmpi(ext, obj.Format.ext)
                obj.FileName = fullfile(pth, [stem obj.Format.ext]);
            end
        end

        function Open(obj)
            if obj.IsOpen, return; end
            outDir = fileparts(obj.FileName);
            if ~isempty(outDir) && ~isfolder(outDir)
                error('MatVisVideoWriter:noSuchFolder', ...
                    'Output folder does not exist: %s', outDir);
            end

            switch obj.Format.backend
                case 'videowriter'
                    obj.vw_ = VideoWriter(obj.FileName, obj.Format.profile);
                    obj.vw_.FrameRate = obj.FrameRate;
                    if ~isempty(obj.Format.qualityField)
                        obj.vw_.(obj.Format.qualityField) = obj.qualityValue();
                    end
                    open(obj.vw_);

                case 'imageseq'
                    % One directory per movie: "<stem>_frames".
                    [pth, stem] = fileparts(obj.FileName);
                    obj.seqDir_  = fullfile(pth, [stem '_frames']);
                    obj.seqStem_ = stem;
                    if ~isfolder(obj.seqDir_), mkdir(obj.seqDir_); end

                case 'gif'
                    % Nothing to open; the first WriteFrame creates the file.
            end

            obj.FrameCount = 0;
            obj.FrameSize  = [];
            obj.IsOpen     = true;
        end

        function WriteFrame(obj, rgb)
            if ~obj.IsOpen
                error('MatVisVideoWriter:notOpen', 'Call Open() before WriteFrame().');
            end
            rgb = MatVisVideoWriter.validateFrame(rgb);
            [h, w, ~] = size(rgb);

            if isempty(obj.FrameSize)
                if obj.Format.needsEvenSize && (mod(w, 2) || mod(h, 2))
                    error('MatVisVideoWriter:oddFrameSize', ...
                        ['%s requires even frame dimensions; got %d×%d. ' ...
                         'Round the frame size to even numbers.'], ...
                        obj.Format.label, w, h);
                end
                obj.FrameSize = [w, h];
            elseif ~isequal(obj.FrameSize, [w, h])
                error('MatVisVideoWriter:frameSizeChanged', ...
                    'Frame %d is %d×%d but the movie is %d×%d.', ...
                    obj.FrameCount + 1, w, h, obj.FrameSize(1), obj.FrameSize(2));
            end

            switch obj.Format.backend
                case 'videowriter'
                    writeVideo(obj.vw_, rgb);

                case 'imageseq'
                    fn = fullfile(obj.seqDir_, ...
                        sprintf('%s_%05d%s', obj.seqStem_, obj.FrameCount + 1, obj.Format.ext));
                    imwrite(rgb, fn);

                case 'gif'
                    % GIF is palettised: quantise once per frame.  A shared
                    % palette would be nicer but needs all frames up front.
                    [ind, cmap] = rgb2ind(rgb, 256, 'nodither');
                    if obj.FrameCount == 0
                        imwrite(ind, cmap, obj.FileName, 'gif', ...
                            'LoopCount', Inf, 'DelayTime', 1 / obj.FrameRate);
                    else
                        imwrite(ind, cmap, obj.FileName, 'gif', ...
                            'WriteMode', 'append', 'DelayTime', 1 / obj.FrameRate);
                    end
            end

            obj.FrameCount = obj.FrameCount + 1;
        end

        function Close(obj)
            if ~obj.IsOpen, return; end
            switch obj.Format.backend
                case 'videowriter'
                    try; close(obj.vw_); catch; end
                    obj.vw_ = [];
            end
            obj.IsOpen = false;
        end

        function p = OutputPath(obj)
            % Where the result actually landed (a directory for sequences).
            if strcmp(obj.Format.backend, 'imageseq') && ~isempty(obj.seqDir_)
                p = obj.seqDir_;
            else
                p = obj.FileName;
            end
        end

        function delete(obj)
            obj.Close();
        end
    end

    % ------------------------------------------------------------------
    methods (Access = private)
        function q = qualityValue(obj)
            switch obj.Format.qualityField
                case 'Quality'
                    q = max(1, min(100, round(obj.Quality)));
                case 'CompressionRatio'
                    % MJ2: ratio >= 1, higher = smaller file.  Map the
                    % percentage the UI shows onto a sane ratio.
                    q = max(1, round(100 / max(1, min(100, obj.Quality)) * 10));
                otherwise
                    q = obj.Quality;
            end
        end
    end

    methods (Static, Access = private)
        function rgb = validateFrame(rgb)
            if ~isnumeric(rgb) || ndims(rgb) ~= 3 || size(rgb, 3) ~= 3
                error('MatVisVideoWriter:badFrame', ...
                    'A frame must be an H×W×3 numeric array.');
            end
            if ~isa(rgb, 'uint8')
                if isfloat(rgb)
                    rgb = uint8(255 * max(0, min(1, rgb)));
                else
                    rgb = uint8(rgb);
                end
            end
        end
    end
end
