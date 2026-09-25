function writeTestZstdTiff(path, stack, varargin)
% writeTestZstdTiff  Write a small Zstandard-compressed TIFF for tests.
%   writeTestZstdTiff(path, stack, Name, Value, ...)
%
%   stack is [Y X SamplesPerPixel Pages] (trailing singletons may be
%   omitted). Only what loadZstdTiff has to read back is supported: chunky
%   planar configuration, one shared geometry for every page, and either
%   strips or tiles.
%
%   Name-Value pairs
%     BigTiff        false      write the version-43 / 64-bit-offset variant
%     RowsPerStrip   Inf        rows per strip (ignored when tiled)
%     TileSize       []         [tileWidth tileHeight]; tiles instead of strips
%     Predictor      1          1 = none, 2 = horizontal differencing
%     Resolution     []         [xRes yRes] for tags 282/283
%     ResolutionUnit 1          tag 296 (1 none, 2 inch, 3 centimetre)
%     Software       ''         tag 305, written only when non-empty
%     Compression    50000      scheme per page: 1/32771 (uncompressed),
%                               5 (LZW), 8/32946 (Deflate), 32773
%                               (PackBits) or 50000 (Zstandard). A scalar
%                               applies to every page; a vector gives one
%                               code per page, which is how a mixed-scheme
%                               file gets written.
%
%   Compression uses the same Java codecs tiffDecompressSegment reads with,
%   so Bio-Formats must be set up.
%
%   See also loadZstdTiff, tiffDecompressSegment.

opt = struct('BigTiff', false, 'RowsPerStrip', Inf, 'TileSize', [], ...
    'Predictor', 1, 'Resolution', [], 'ResolutionUnit', 1, 'Software', '', ...
    'Compression', 50000);
for k = 1:2:numel(varargin)
    opt.(varargin{k}) = varargin{k+1};
end

sz = [size(stack, 1), size(stack, 2), size(stack, 3), size(stack, 4)];
h = sz(1); w = sz(2); spp = sz(3); nPages = sz(4);

[bits, sampleFormat] = classToTiff(class(stack));

if isempty(opt.TileSize)
    tiled = false;
    rowsPerStrip = min(h, opt.RowsPerStrip);
    tileW = w; tileH = rowsPerStrip;
else
    tiled = true;
    tileW = opt.TileSize(1); tileH = opt.TileSize(2);
end

if ~ensureBioFormats()
    error('writeTestZstdTiff:noEngine', ...
        'Bio-Formats must be set up to compress test data.');
end

% One compression code per page, so a mixed-scheme file can be written.
pageComp = opt.Compression(:)';
if isscalar(pageComp)
    pageComp = repmat(pageComp, 1, nPages);
elseif numel(pageComp) ~= nPages
    error('writeTestZstdTiff:badCompression', ...
        'Compression has %d entries but the stack has %d pages.', numel(pageComp), nPages);
end

if opt.BigTiff
    dirCountBytes = 8; entryBytes = 20; valueBytes = 8; offsetBytes = 8;
    offsetPrec = 'uint64'; offsetType = 16;
else
    dirCountBytes = 2; entryBytes = 12; valueBytes = 4; offsetBytes = 4;
    offsetPrec = 'uint32'; offsetType = 4;
end

fid = fopen(path, 'w', 'ieee-le');
if fid < 0
    error('writeTestZstdTiff:cannotOpen', 'Cannot create "%s".', path);
end
closer = onCleanup(@() fclose(fid)); %#ok<NASGU>

fwrite(fid, 'II', 'char');
if opt.BigTiff
    fwrite(fid, 43, 'uint16');
    fwrite(fid, 8, 'uint16');
    fwrite(fid, 0, 'uint16');
    firstIfdField = ftell(fid);
    fwrite(fid, 0, 'uint64');
else
    fwrite(fid, 42, 'uint16');
    firstIfdField = ftell(fid);
    fwrite(fid, 0, 'uint32');
end

% ---- Pixel data ---------------------------------------------------------
segOffsets = cell(1, nPages);
segCounts  = cell(1, nPages);
for p = 1:nPages
    if tiled
        rowStarts = 1:tileH:h;
        colStarts = 1:tileW:w;
    else
        rowStarts = 1:tileH:h;
        colStarts = 1;
    end
    offs = []; cnts = [];
    for r = rowStarts
        for c = colStarts
            if tiled
                block = zeros(tileH, tileW, spp, class(stack));
                rows = r:min(h, r + tileH - 1);
                cols = c:min(w, c + tileW - 1);
                block(1:numel(rows), 1:numel(cols), :) = stack(rows, cols, :, p);
            else
                rows = r:min(h, r + tileH - 1);
                block = stack(rows, :, :, p);
            end
            raw = encodeSegment(block, opt.Predictor, bits, class(stack));
            comp = encodeBytes(raw, pageComp(p));
            padToEven(fid);
            offs(end+1) = ftell(fid); %#ok<AGROW>
            fwrite(fid, comp, 'uint8');
            cnts(end+1) = numel(comp); %#ok<AGROW>
        end
    end
    segOffsets{p} = offs;
    segCounts{p}  = cnts;
end

% ---- Directories --------------------------------------------------------
padToEven(fid);
ifdStart = ftell(fid);

entriesPerPage = cell(1, nPages);
ifdTotal = zeros(1, nPages);
for p = 1:nPages
    entriesPerPage{p} = buildEntries(w, h, bits, spp, sampleFormat, opt, pageComp(p), ...
        tiled, tileW, tileH, segOffsets{p}, segCounts{p}, offsetType);
    e = entriesPerPage{p};
    extra = 0;
    for i = 1:numel(e)
        nb = numel(e(i).data) * typeSize(e(i).type);
        if nb > valueBytes
            extra = extra + nb + mod(nb, 2);
        end
    end
    ifdTotal(p) = dirCountBytes + numel(e) * entryBytes + offsetBytes + extra;
end

ifdOffsets = ifdStart + [0, cumsum(ifdTotal(1:end-1))];
for p = 1:nPages
    e = entriesPerPage{p};
    base = ifdOffsets(p);
    dataPos = base + dirCountBytes + numel(e) * entryBytes + offsetBytes;
    if p < nPages
        nextIfd = ifdOffsets(p+1);
    else
        nextIfd = 0;
    end

    fseek(fid, base, 'bof');
    if opt.BigTiff
        fwrite(fid, numel(e), 'uint64');
    else
        fwrite(fid, numel(e), 'uint16');
    end

    outOfLine = struct('pos', {}, 'entry', {});
    for i = 1:numel(e)
        fwrite(fid, e(i).tag, 'uint16');
        fwrite(fid, e(i).type, 'uint16');
        if opt.BigTiff
            fwrite(fid, numel(e(i).data) / rationalStride(e(i).type), 'uint64');
        else
            fwrite(fid, numel(e(i).data) / rationalStride(e(i).type), 'uint32');
        end
        nb = numel(e(i).data) * typeSize(e(i).type);
        if nb <= valueBytes
            writeValues(fid, e(i));
            fwrite(fid, zeros(1, valueBytes - nb), 'uint8');
        else
            fwrite(fid, dataPos, offsetPrec);
            outOfLine(end+1) = struct('pos', dataPos, 'entry', e(i)); %#ok<AGROW>
            dataPos = dataPos + nb + mod(nb, 2);
        end
    end
    fwrite(fid, nextIfd, offsetPrec);
    for i = 1:numel(outOfLine)
        fseek(fid, outOfLine(i).pos, 'bof');
        writeValues(fid, outOfLine(i).entry);
        padToEven(fid);
    end
end

fseek(fid, firstIfdField, 'bof');
fwrite(fid, ifdStart, offsetPrec);
end

% =============================================================================
function e = buildEntries(w, h, bits, spp, sampleFormat, opt, compression, tiled, tileW, tileH, ...
    offs, cnts, offsetType)
% Tags in ascending order, as the TIFF spec requires.
e = entry(256, 4, w);
e(end+1) = entry(257, 4, h);
e(end+1) = entry(258, 3, repmat(bits, 1, spp));
e(end+1) = entry(259, 3, compression);
if spp >= 3
    e(end+1) = entry(262, 3, 2);
else
    e(end+1) = entry(262, 3, 1);
end
if ~tiled
    e(end+1) = entry(273, offsetType, offs);
end
e(end+1) = entry(277, 3, spp);
if ~tiled
    e(end+1) = entry(278, 4, tileH);
    e(end+1) = entry(279, offsetType, cnts);
end
if ~isempty(opt.Resolution)
    e(end+1) = entry(282, 5, [round(opt.Resolution(1) * 10000), 10000]);
    e(end+1) = entry(283, 5, [round(opt.Resolution(2) * 10000), 10000]);
end
e(end+1) = entry(284, 3, 1);
e(end+1) = entry(296, 3, opt.ResolutionUnit);
if ~isempty(opt.Software)
    e(end+1) = entry(305, 2, double([opt.Software, 0]));
end
if tiled
    e(end+1) = entry(322, 4, tileW);
    e(end+1) = entry(323, 4, tileH);
    e(end+1) = entry(324, offsetType, offs);
    e(end+1) = entry(325, offsetType, cnts);
end
if opt.Predictor ~= 1
    e(end+1) = entry(317, 3, opt.Predictor);
end
e(end+1) = entry(339, 3, repmat(sampleFormat, 1, spp));

[~, order] = sort([e.tag]);
e = e(order);
end

% =============================================================================
function s = entry(tag, type, data)
s = struct('tag', tag, 'type', type, 'data', data);
end

% =============================================================================
function writeValues(fid, e)
switch e.type
    case 2,        fwrite(fid, e.data, 'uint8');
    case 3,        fwrite(fid, e.data, 'uint16');
    case {4, 5},   fwrite(fid, e.data, 'uint32');
    case 16,       fwrite(fid, e.data, 'uint64');
    otherwise
        error('writeTestZstdTiff:badType', 'Unsupported field type %d.', e.type);
end
end

% =============================================================================
function n = typeSize(type)
sizes = [1 1 2 4 8 1 1 2 4 8 4 8 4 0 0 8 8 8];
n = sizes(type);
if type == 5
    n = 4;   % data is stored as individual uint32s (numerator, denominator)
end
end

% =============================================================================
function n = rationalStride(type)
% RATIONAL entries carry two uint32s per element, so the TIFF count is half
% the number of stored words.
if type == 5
    n = 2;
else
    n = 1;
end
end

% =============================================================================
function raw = encodeSegment(block, predictor, bits, cls)
% [rows cols spp] -> the on-disk chunky byte order [spp x y].
v = permute(block, [3, 2, 1]);
if predictor == 2
    d = double(v);
    d(:, 2:end, :) = diff(d, 1, 2);
    v = cast(mod(d, 2^bits), cls);
end
raw = typecast(v(:), 'uint8');
end

% =============================================================================
function comp = encodeBytes(raw, compression)
% Encode one segment with the scheme its page advertises.
switch compression
    case {1, 32771}
        comp = raw(:);
    case 50000
        compressor = io.airlift.compress.zstd.ZstdCompressor();
        inBuf  = java.nio.ByteBuffer.wrap(typecast(raw(:), 'int8'));
        outBuf = java.nio.ByteBuffer.allocate(compressor.maxCompressedLength(numel(raw)));
        compressor.compress(inBuf, outBuf);
        n = outBuf.position();
        comp = typecast(outBuf.array(), 'uint8');
        comp = comp(1:n);
    case {8, 32946}
        codec = loci.formats.codec.ZlibCodec();
        comp = typecast(codec.compress(typecast(raw(:), 'int8'), []), 'uint8');
    case 32773
        comp = packbitsEncode(raw);
    case 5
        codec = loci.formats.codec.LZWCodec();
        comp = typecast(codec.compress(typecast(raw(:), 'int8'), []), 'uint8');
    otherwise
        % A scheme the writer does not implement: store the bytes as they
        % are and let the tag lie. That is exactly the file a reader
        % "rejects what it cannot decode" test needs.
        comp = raw(:);
end
comp = comp(:);
end

% =============================================================================
function comp = packbitsEncode(raw)
% Literal-only PackBits: every run is a "copy the next n+1 bytes" header.
% Valid (if not compact) output, which is all a reader test needs.
raw = raw(:);
comp = zeros(numel(raw) + ceil(numel(raw) / 128), 1, 'uint8');
in = 1; out = 1;
while in <= numel(raw)
    n = min(128, numel(raw) - in + 1);
    comp(out) = uint8(n - 1);
    comp(out+1:out+n) = raw(in:in+n-1);
    in = in + n;
    out = out + n + 1;
end
comp = comp(1:out-1);
end

% =============================================================================
function padToEven(fid)
if mod(ftell(fid), 2) ~= 0
    fwrite(fid, 0, 'uint8');
end
end

% =============================================================================
function [bits, sampleFormat] = classToTiff(cls)
switch cls
    case 'uint8',  bits = 8;  sampleFormat = 1;
    case 'uint16', bits = 16; sampleFormat = 1;
    case 'uint32', bits = 32; sampleFormat = 1;
    case 'int16',  bits = 16; sampleFormat = 2;
    case 'single', bits = 32; sampleFormat = 3;
    case 'double', bits = 64; sampleFormat = 3;
    otherwise
        error('writeTestZstdTiff:badClass', 'Unsupported sample class "%s".', cls);
end
end
