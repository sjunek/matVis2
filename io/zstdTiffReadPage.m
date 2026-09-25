function page = zstdTiffReadPage(fid, ifd, g, compression, filepath, pageNo)
% zstdTiffReadPage  Decode ONE directory of a Zstandard/PackBits TIFF.
%
%   page = zstdTiffReadPage(fid, ifd, g, compression)
%   page = zstdTiffReadPage(fid, ifd, g, compression, filepath, pageNo)
%       also checks that the page matches the geometry g taken from page 1,
%       and names the file and page number if it does not.
%
%   fid  is an open read handle; the caller owns it.  g and compression come
%   from zstdTiffOpen.  Returns [height width spp] of class g.cls.
%
%   Split out of loadZstdTiff so a page can be decoded without reading the
%   rest of the file: MatVisZstdTiffSource reads one plane at a time as the
%   display asks for it, and the whole-file loader is the same decode in a
%   loop.  Measured on a 735-page 2048x2048 BigTIFF: ~100 ms a page against
%   75 s for the file.
%
%   See also zstdTiffOpen, loadZstdTiff, MatVisZstdTiffSource.

if nargin >= 6 && ~isempty(filepath)
    checkPageMatches(ifd, g, pageNo, filepath);
end
page = readPage(fid, ifd, g, compression);
end

% =============================================================================
function checkPageMatches(ifd, g, k, filepath)
% All pages have to share one geometry -- they land in a single array.
w = tiffScalarTag(ifd, 256, [], 'ImageWidth', filepath);
h = tiffScalarTag(ifd, 257, [], 'ImageLength', filepath);
s = tiffScalarTag(ifd, 277, 1, 'SamplesPerPixel', filepath);
b = tiffTagValue(ifd, 258, 8);
if w ~= g.width || h ~= g.height || s ~= g.spp || b(1) ~= g.bits
    error('loadZstdTiff:inconsistentPages', ...
        ['Page %d of "%s" is %dx%dx%d at %d bits, but page 1 is %dx%dx%d at %d bits; ' ...
         'mixed-geometry TIFFs are not supported.'], ...
        k, filepath, h, w, s, b(1), g.height, g.width, g.spp, g.bits);
end
end

% =============================================================================
% =============================================================================
function page = readPage(fid, ifd, g, compression)
% Decode one directory into a [height width spp] array.
page = zeros(g.height, g.width, g.spp, g.cls);

if g.planar == 2
    segSpp = 1;
else
    segSpp = g.spp;
end

tileWidth = tiffTagValue(ifd, 322, []);
if ~isempty(tileWidth)
    tileHeight  = tiffTagValue(ifd, 323, []);
    offsets     = tiffTagValue(ifd, 324, []);
    byteCounts  = tiffTagValue(ifd, 325, []);
    if isempty(tileHeight) || isempty(offsets) || numel(byteCounts) ~= numel(offsets)
        error('loadZstdTiff:badTileTags', ...
            'TileLength/TileOffsets/TileByteCounts are missing or inconsistent.');
    end
    tileWidth   = tileWidth(1);
    tileHeight  = tileHeight(1);
    tilesAcross = ceil(g.width / tileWidth);
    tilesDown   = ceil(g.height / tileHeight);
    perPlane    = tilesAcross * tilesDown;
    for s = 1:numel(offsets)
        plane = floor((s - 1) / perPlane) + 1;
        idx   = mod(s - 1, perPlane);
        y0    = floor(idx / tilesAcross) * tileHeight + 1;
        x0    = mod(idx, tilesAcross) * tileWidth + 1;
        y1    = min(g.height, y0 + tileHeight - 1);
        x1    = min(g.width,  x0 + tileWidth - 1);
        % Tiles are always full-size on disk; the edge ones are padded.
        block = decodeSegment(fid, offsets(s), byteCounts(s), tileWidth, tileHeight, segSpp, g, compression);
        block = block(1:(y1 - y0 + 1), 1:(x1 - x0 + 1), :);
        if g.planar == 2
            page(y0:y1, x0:x1, plane) = block;
        else
            page(y0:y1, x0:x1, :) = block;
        end
    end
    return;
end

rowsPerStrip = tiffTagValue(ifd, 278, []);
if isempty(rowsPerStrip) || rowsPerStrip(1) <= 0 || rowsPerStrip(1) > g.height
    rowsPerStrip = g.height;   % tag default is 2^32-1, i.e. "one strip"
else
    rowsPerStrip = rowsPerStrip(1);
end
offsets    = tiffTagValue(ifd, 273, []);
byteCounts = tiffTagValue(ifd, 279, []);
if isempty(offsets) || numel(byteCounts) ~= numel(offsets)
    error('loadZstdTiff:badStripTags', ...
        'StripOffsets/StripByteCounts are missing or inconsistent (%d vs %d entries).', ...
        numel(offsets), numel(byteCounts));
end
perPlane = ceil(g.height / rowsPerStrip);
for s = 1:numel(offsets)
    plane = floor((s - 1) / perPlane) + 1;
    idx   = mod(s - 1, perPlane);
    y0    = idx * rowsPerStrip + 1;
    y1    = min(g.height, y0 + rowsPerStrip - 1);
    block = decodeSegment(fid, offsets(s), byteCounts(s), g.width, y1 - y0 + 1, segSpp, g, compression);
    if g.planar == 2
        page(y0:y1, :, plane) = block;
    else
        page(y0:y1, :, :) = block;
    end
end
end

% =============================================================================
function block = decodeSegment(fid, offset, byteCount, w, h, spp, g, compression)
% Read one Zstandard-compressed strip/tile and reshape it to [h w spp].
if fseek(fid, offset, 'bof') ~= 0
    error('loadZstdTiff:badSegmentOffset', ...
        'Strip/tile offset %d is past the end of the file.', offset);
end
comp = fread(fid, byteCount, '*uint8');
if numel(comp) ~= byteCount
    error('loadZstdTiff:truncatedSegment', ...
        'Strip/tile at offset %d is truncated (%d of %d bytes).', ...
        offset, numel(comp), byteCount);
end

expected = w * h * spp * g.bytesPerSample;
raw = tiffDecompressSegment(comp, expected, compression);

vals = typecast(raw, g.cls);
if g.bytesPerSample > 1 && ~g.littleEndian
    vals = swapbytes(vals);
end

% On disk a chunky segment runs sample-by-sample within a pixel, pixel by
% pixel along a row, row by row -- i.e. [spp x y] in MATLAB column order.
block = reshape(vals, spp, w, h);
if g.predictor == 2
    block = undoHorizontalDifferencing(block, g);
end
block = permute(block, [3, 2, 1]);
end

% =============================================================================
function block = undoHorizontalDifferencing(block, g)
% Predictor 2: each sample stores its difference from the sample one pixel to
% the left. Accumulate along x, wrapping like the unsigned type the writer
% used (MATLAB integer arithmetic saturates, so accumulate in double).
acc = cumsum(double(block), 2);
block = cast(mod(acc, 2^g.bits), g.cls);
end

% =============================================================================
