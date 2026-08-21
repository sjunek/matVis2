function [data, meta] = loadZstdTiff(filepath)
% loadZstdTiff  Read a Zstandard-compressed TIFF/BigTIFF (compression 50000).
%   [data, meta] = loadZstdTiff(filepath)
%
%   Neither MATLAB's TIFF library ("The compression scheme 50000 is not
%   currently supported when reading TIFF files.") nor Bio-Formats 8.5 can
%   read these files, so this is a self-contained reader: parseTiffIfds for
%   the tags, zstdDecompress for the strip/tile payloads.
%
%   data is [Y X] for a single-page grayscale image, [Y X Z] for a
%   multi-page one, and [Y X C] / [Y X C Z] when SamplesPerPixel > 1.
%
%   meta matches the contract the other readers use (see finalizeOmePlanes):
%   dimNames/dimScale/dimUnits/channelNames/instrument. A plain TIFF carries
%   no acquisition metadata, so instrument's Microscope*/Objective*/Channel*
%   fields are empty; every tag the file *does* carry is collected into
%   instrument.TiffTags (an Nx2 cell of Property/Value rows) for display in
%   MatVisMetadataWin. Scale comes from XResolution/YResolution: their
%   reciprocal when ResolutionUnit says inch or centimeter, and the values
%   themselves (micrometres per pixel) when ResolutionUnit is "none", which
%   is what the writers of these Zstandard stacks store there. In that case
%   two differing values mean tag 282 is the lateral pitch for both Y and X
%   and tag 283 is the Z step -- see resolutionScales below.
%
%   Supported: strips and tiles, 8/16/32/64-bit unsigned and signed integer
%   and 32/64-bit float samples, chunky and planar configuration, predictor
%   1 (none) and 2 (horizontal differencing, integer samples).
%
%   See also isZstdTiff, parseTiffIfds, zstdDecompress, loadFiles.

[ifds, hdr] = parseTiffIfds(filepath);
if isempty(ifds)
    error('loadZstdTiff:noIfds', 'File "%s" contains no image directories.', filepath);
end

g = readGeometry(ifds(1), hdr, filepath);
nPages = numel(ifds);

fid = fopen(filepath, 'r', 'ieee-le');
if fid < 0
    error('loadZstdTiff:cannotOpen', 'Cannot open file "%s".', filepath);
end
closer = onCleanup(@() fclose(fid)); %#ok<NASGU>

data = zeros([g.height, g.width, g.spp, nPages], g.cls);
for k = 1:nPages
    checkPageMatches(ifds(k), g, k, filepath);
    data(:, :, :, k) = readPage(fid, ifds(k), g);
end

% Collapse the axes the file does not actually use, mirroring the built-in
% multi-page TIFF reader's [Y X nPages] / [Y X C nPages] shapes.
keep = [true, true, g.spp > 1, nPages > 1];
sz4 = [g.height, g.width, g.spp, nPages];
data = reshape(data, sz4(keep));

meta = buildMeta(ifds, hdr, g, nPages, keep);
end

% =============================================================================
function g = readGeometry(ifd, hdr, filepath)
% Pull the pixel layout of the first directory into one struct, rejecting
% anything this reader cannot honour.
g.width  = scalarTag(ifd, 256, [], 'ImageWidth', filepath);
g.height = scalarTag(ifd, 257, [], 'ImageLength', filepath);
g.spp    = scalarTag(ifd, 277, 1, 'SamplesPerPixel', filepath);

compression = scalarTag(ifd, 259, 1, 'Compression', filepath);
if compression ~= 50000
    error('loadZstdTiff:notZstd', ...
        'File "%s" uses compression %d, not Zstandard (50000).', filepath, compression);
end

bits = tiffTagValue(ifd, 258, 8);
if numel(unique(bits)) > 1
    error('loadZstdTiff:mixedBitDepth', ...
        'File "%s" mixes bit depths per sample ([%s]), which is not supported.', ...
        filepath, num2str(bits));
end
g.bits = bits(1);

sampleFormat = tiffTagValue(ifd, 339, 1);
if numel(unique(sampleFormat)) > 1
    error('loadZstdTiff:mixedSampleFormat', ...
        'File "%s" mixes sample formats per sample, which is not supported.', filepath);
end
g.sampleFormat = sampleFormat(1);
g.cls = sampleClass(g.bits, g.sampleFormat, filepath);
g.bytesPerSample = g.bits / 8;

g.planar = scalarTag(ifd, 284, 1, 'PlanarConfiguration', filepath);
if ~ismember(g.planar, [1, 2])
    error('loadZstdTiff:badPlanarConfig', ...
        'File "%s" declares PlanarConfiguration %d; expected 1 or 2.', filepath, g.planar);
end

g.predictor = scalarTag(ifd, 317, 1, 'Predictor', filepath);
if g.predictor == 2 && g.sampleFormat ~= 1
    error('loadZstdTiff:unsupportedPredictor', ...
        ['File "%s" uses horizontal differencing (predictor 2) on non-unsigned ' ...
         'samples, which is not supported.'], filepath);
elseif ~ismember(g.predictor, [1, 2])
    error('loadZstdTiff:unsupportedPredictor', ...
        'File "%s" uses predictor %d; only 1 (none) and 2 (horizontal differencing) are supported.', ...
        filepath, g.predictor);
end

g.littleEndian = hdr.littleEndian;
end

% =============================================================================
function checkPageMatches(ifd, g, k, filepath)
% All pages have to share one geometry -- they land in a single array.
w = scalarTag(ifd, 256, [], 'ImageWidth', filepath);
h = scalarTag(ifd, 257, [], 'ImageLength', filepath);
s = scalarTag(ifd, 277, 1, 'SamplesPerPixel', filepath);
b = tiffTagValue(ifd, 258, 8);
if w ~= g.width || h ~= g.height || s ~= g.spp || b(1) ~= g.bits
    error('loadZstdTiff:inconsistentPages', ...
        ['Page %d of "%s" is %dx%dx%d at %d bits, but page 1 is %dx%dx%d at %d bits; ' ...
         'mixed-geometry TIFFs are not supported.'], ...
        k, filepath, h, w, s, b(1), g.height, g.width, g.spp, g.bits);
end
end

% =============================================================================
function page = readPage(fid, ifd, g)
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
        block = decodeSegment(fid, offsets(s), byteCounts(s), tileWidth, tileHeight, segSpp, g);
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
    block = decodeSegment(fid, offsets(s), byteCounts(s), g.width, y1 - y0 + 1, segSpp, g);
    if g.planar == 2
        page(y0:y1, :, plane) = block;
    else
        page(y0:y1, :, :) = block;
    end
end
end

% =============================================================================
function block = decodeSegment(fid, offset, byteCount, w, h, spp, g)
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
raw = zstdDecompress(comp, expected);

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
function cls = sampleClass(bits, sampleFormat, filepath)
switch sampleFormat
    case 1                                  % unsigned integer
        map = struct('b8', 'uint8', 'b16', 'uint16', 'b32', 'uint32', 'b64', 'uint64');
    case 2                                  % signed integer
        map = struct('b8', 'int8', 'b16', 'int16', 'b32', 'int32', 'b64', 'int64');
    case 3                                  % IEEE float
        map = struct('b32', 'single', 'b64', 'double');
    otherwise
        error('loadZstdTiff:unsupportedSampleFormat', ...
            'File "%s" declares SampleFormat %d, which is not supported.', ...
            filepath, sampleFormat);
end
key = sprintf('b%d', bits);
if ~isfield(map, key)
    error('loadZstdTiff:unsupportedBitDepth', ...
        'File "%s" has %d-bit samples with SampleFormat %d, which is not supported.', ...
        filepath, bits, sampleFormat);
end
cls = map.(key);
end

% =============================================================================
function v = scalarTag(ifd, tagId, defaultValue, name, filepath)
v = tiffTagValue(ifd, tagId, defaultValue);
if isempty(v)
    error('loadZstdTiff:missingTag', ...
        'Required TIFF tag %s (%d) is missing from "%s".', name, tagId, filepath);
end
v = v(1);
end

% =============================================================================
function meta = buildMeta(ifds, hdr, g, nPages, keep)
% Build the dimNames/dimScale/dimUnits/channelNames/instrument struct, and
% collect the file's tags into instrument.TiffTags for the metadata window.
ifd = ifds(1);

resUnit = tiffTagValue(ifd, 296, 2);   % tag default is 2 (inch)
xRes    = firstOrEmpty(tiffTagValue(ifd, 282, []));
yRes    = firstOrEmpty(tiffTagValue(ifd, 283, []));
s = resolutionScales(xRes, yRes, resUnit);

dimNames    = {'Y', 'X', 'C', 'Z'};
dimScaleAll = {s.scaleY, s.scaleX, 1, s.scaleZ};
dimUnitsAll = {s.unitY, s.unitX, '', s.unitZ};

channelNames = arrayfun(@(c) sprintf('Ch%d', c), 1:g.spp, 'UniformOutput', false);

instrument = struct( ...
    'MicroscopeManufacturer', '', 'MicroscopeModel', '', 'MicroscopeType', '', ...
    'ObjectiveManufacturer', '', 'ObjectiveModel', '', ...
    'ObjectiveNA', NaN, 'ObjectiveImmersion', '', 'ObjectiveMagnification', NaN, ...
    'ObjectiveRefractiveIndex', NaN, ...
    'AcquisitionDate', asciiTag(ifd, 306), ...
    'ChannelNames', {channelNames}, ...
    'ChannelExWavelength', nan(1, g.spp), 'ChannelEmWavelength', nan(1, g.spp), ...
    'ChannelExWavelengthUnit', {repmat({''}, 1, g.spp)}, ...
    'ChannelEmWavelengthUnit', {repmat({''}, 1, g.spp)}, ...
    'ChannelAcquisitionMode', {repmat({''}, 1, g.spp)}, ...
    'TiffTags', {tiffTagRows(ifds, hdr, g, nPages, resUnit, xRes, yRes, s)});

meta = struct( ...
    'dimNames',     {dimNames(keep)}, ...
    'dimScale',     {dimScaleAll(keep)}, ...
    'dimUnits',     {dimUnitsAll(keep)}, ...
    'channelNames', {channelNames}, ...
    'instrument',   instrument);
end

% =============================================================================
function rows = tiffTagRows(ifds, hdr, g, nPages, resUnit, xRes, yRes, scales)
% Every piece of metadata the file actually carries, as Property/Value rows.
if hdr.isBigTiff
    flavour = 'BigTIFF';
else
    flavour = 'TIFF';
end
if hdr.littleEndian
    order = 'little-endian';
else
    order = 'big-endian';
end

rows = {'TIFF flavour', sprintf('%s, %s', flavour, order)};
rows(end+1, :) = {'Compression', 'Zstandard (50000)'};
rows(end+1, :) = {'Image size', sprintf('%d x %d px', g.width, g.height)};
rows(end+1, :) = {'Pages (IFDs)', sprintf('%d', nPages)};
rows(end+1, :) = {'Samples per pixel', sprintf('%d', g.spp)};
rows(end+1, :) = {'Sample format', sprintf('%d-bit %s', g.bits, sampleFormatName(g.sampleFormat))};
rows(end+1, :) = {'Photometric interpretation', photometricName(tiffTagValue(ifds(1), 262, []))};
rows(end+1, :) = {'Planar configuration', planarName(g.planar)};
if g.predictor ~= 1
    rows(end+1, :) = {'Predictor', 'horizontal differencing (2)'};
end
rows(end+1, :) = {'Segment layout', segmentLayout(ifds(1), g)};

rows(end+1, :) = {'Resolution unit', resolutionUnitName(resUnit)};
if scales.lateralAndZ
    % Tag 283 was read as the plane spacing, not a lateral pitch -- label
    % both rows for what they were actually used as.
    rows(end+1, :) = {'X/Y resolution', resolutionText(xRes, resUnit)};
    rows(end+1, :) = {'Z resolution', resolutionText(yRes, resUnit)};
    rows(end+1, :) = {'Resolution reading', ...
        'tag 282 = lateral (Y and X) pixel size, tag 283 = Z step'};
else
    rows(end+1, :) = {'X resolution', resolutionText(xRes, resUnit)};
    rows(end+1, :) = {'Y resolution', resolutionText(yRes, resUnit)};
end

% Free-text tags, only when the file carries them.
textTags = {305, 'Software'; 271, 'Make'; 272, 'Model'; 306, 'Date/time'; ...
    269, 'Document name'; 315, 'Artist'; 33432, 'Copyright'; 270, 'Image description'};
for i = 1:size(textTags, 1)
    s = asciiTag(ifds(1), textTags{i, 1});
    if ~isempty(s)
        rows(end+1, :) = {textTags{i, 2}, truncate(s, 400)}; %#ok<AGROW>
    end
end
end

% =============================================================================
function s = resolutionScales(xRes, yRes, resUnit)
% Turn XResolution/YResolution into per-axis scales.
%
% ResolutionUnit 2/3 is the spec case: each tag is samples per inch/centimetre
% for its own axis, so each axis gets its own reciprocal and Z is unknown.
%
% ResolutionUnit 1 ("no absolute unit") is where the writers of these
% Zstandard stacks store micrometres per pixel directly. When the two tags
% disagree there, tag 283 is not a lateral pitch at all -- a square frame
% cannot have a 12:1 pixel aspect -- but the Z step: tag 282 alone gives the
% lateral pitch for both Y and X, and tag 283 becomes the plane spacing.
% Equal tags are taken per-axis as usual, so a genuinely anisotropic image
% still round-trips.
% s.lateralAndZ records which reading was applied, so the metadata rows can
% label the two tags the way they were actually used.
[s.scaleX, s.unitX] = pixelSize(xRes, resUnit);
[s.scaleY, s.unitY] = pixelSize(yRes, resUnit);
s.scaleZ = 1;
s.unitZ = '';
s.lateralAndZ = false;

if resUnit ~= 1 || isempty(xRes) || isempty(yRes) || ~isfinite(xRes) || ~isfinite(yRes)
    if resUnit == 1 && isempty(yRes)
        [s.scaleY, s.unitY] = pixelSize(xRes, resUnit);   % lateral pitch for both axes
    end
    return;
end
if xRes ~= yRes
    [s.scaleY, s.unitY] = pixelSize(xRes, resUnit);
    [s.scaleZ, s.unitZ] = pixelSize(yRes, resUnit);
    s.lateralAndZ = true;
end
end

% =============================================================================
function [scale, unit] = pixelSize(res, resUnit)
% Convert XResolution/YResolution to a pixel pitch in micrometres.
%
% For ResolutionUnit 2/3 that is the spec reading: the tag holds samples per
% inch / per centimetre, so the pitch is its reciprocal. ResolutionUnit 1
% ("no absolute unit") leaves the tags undefined by the spec, and the writers
% that produce these Zstandard stacks use them to store the pixel pitch in
% micrometres directly -- so take those at face value rather than dropping
% the only calibration the file has.
scale = 1;
unit = '';
if isempty(res) || ~isfinite(res) || res <= 0
    return;
end
switch resUnit
    case 1                                  % no TIFF unit: micrometres per pixel
        scale = res;
        unit = 'um';
    case 2                                  % inch
        scale = 25400 / res;
        unit = 'um';
    case 3                                  % centimetre
        scale = 10000 / res;
        unit = 'um';
end
end

% =============================================================================
function s = resolutionText(res, resUnit)
if isempty(res) || ~isfinite(res)
    s = 'n/a';
    return;
end
switch resUnit
    case 2
        s = sprintf('%.6g px/inch (%.4g um/px)', res, 25400 / res);
    case 3
        s = sprintf('%.6g px/cm (%.4g um/px)', res, 10000 / res);
    case 1
        s = sprintf('%.6g um/px', res);
    otherwise
        s = sprintf('%.6g (unknown unit)', res);
end
end

% =============================================================================
function s = resolutionUnitName(u)
switch u
    case 1, s = 'none (values read as um/px)';
    case 2, s = 'inch';
    case 3, s = 'centimeter';
    otherwise, s = sprintf('unknown (%d)', u);
end
end

% =============================================================================
function s = sampleFormatName(sf)
switch sf
    case 1, s = 'unsigned integer';
    case 2, s = 'signed integer';
    case 3, s = 'floating point';
    otherwise, s = sprintf('sample format %d', sf);
end
end

% =============================================================================
function s = photometricName(p)
if isempty(p)
    s = 'n/a';
    return;
end
switch p(1)
    case 0, s = 'WhiteIsZero (0)';
    case 1, s = 'BlackIsZero (1)';
    case 2, s = 'RGB (2)';
    case 3, s = 'Palette (3)';
    case 4, s = 'Transparency mask (4)';
    otherwise, s = sprintf('%d', p(1));
end
end

% =============================================================================
function s = planarName(p)
if p == 2
    s = 'planar (2)';
else
    s = 'chunky (1)';
end
end

% =============================================================================
function s = segmentLayout(ifd, g)
tileWidth = tiffTagValue(ifd, 322, []);
if ~isempty(tileWidth)
    tileHeight = tiffTagValue(ifd, 323, []);
    s = sprintf('tiled, %d x %d px per tile', tileWidth(1), tileHeight(1));
    return;
end
rowsPerStrip = tiffTagValue(ifd, 278, []);
if isempty(rowsPerStrip) || rowsPerStrip(1) <= 0 || rowsPerStrip(1) > g.height
    rowsPerStrip = g.height;
else
    rowsPerStrip = rowsPerStrip(1);
end
nStrips = ceil(g.height / rowsPerStrip);
if nStrips == 1
    s = sprintf('stripped, %d row(s) per strip (1 strip/page)', rowsPerStrip);
else
    s = sprintf('stripped, %d row(s) per strip (%d strips/page)', rowsPerStrip, nStrips);
end
end

% =============================================================================
function s = asciiTag(ifd, tagId)
s = tiffTagValue(ifd, tagId, '');
if ~ischar(s)
    s = '';
end
s = strtrim(s);
end

% =============================================================================
function v = firstOrEmpty(v)
if ~isempty(v)
    v = v(1);
end
end

% =============================================================================
function s = truncate(s, n)
if numel(s) > n
    s = [s(1:n), '...'];
end
end
