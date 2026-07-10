function [data, meta] = loadScanImageTiff(filepath)
% loadScanImageTiff  Read a ScanImage-acquired Tiff via the
%   ScanImageTiffReader MATLAB package (requires
%   ensureScanImageTiffReader() to be true), surfacing framesPerSlice as
%   its own dimension alongside channel/Z/T.
%
%   [data, meta] = loadScanImageTiff(filepath)
%
%   data is a [Y X C F Z T] array (channel, frames-per-slice, Z-slice,
%   volume/T; singleton axes beyond Y/X dropped). meta carries
%   dimNames/dimScale/dimUnits/channelNames/instrument, matching the
%   contract finalizeOmePlanes produces for the OME-TIFF/Bio-Formats
%   readers (see finalizeOmePlanes.m) so MatVisMetadataWin displays either
%   engine's output the same way.
%
%   See also: ensureScanImageTiffReader, parseScanImageMetadata, isScanImageTiff.

r = ScanImageTiffReader.ScanImageTiffReader(filepath);
cleanupObj = onCleanup(@() closeReaderQuietly(r)); %#ok<NASGU>

raw = r.data();
mdStr = r.metadata();

if ndims(raw) < 2
    error('loadFiles:scanimageBadData', ...
        'ScanImageTiffReader returned unexpected data shape for "%s".', filepath);
end
% ScanImageTiffReader.data() returns [X Y nPages] (see the package's own
% docs: "the image might be transposed from what you expect"); permute to
% matVis's [Y X ...] convention, matching every other reader in this codebase.
rawYX = permute(raw, [2, 1, 3:max(3, ndims(raw))]);
nPages = size(rawYX, 3);

md = parseScanImageMetadata(mdStr);
nCh            = max(1, numel(md.savedChannels));
framesPerSlice = valueOr(md.framesPerSlice, 1);
zSize          = valueOr(md.zSize, 1);
tSize          = valueOr(md.tSize, 1);

nExpected = nCh * framesPerSlice * zSize * tSize;
if nPages ~= nExpected
    warning('loadFiles:scanimagePlaneCountMismatch', ...
        ['File "%s" declares %d planes (channels=%d, framesPerSlice=%g, Z=%d, T=%d) but contains ' ...
         '%d IFDs; adjusting the volume/T count to fit.'], ...
        filepath, nExpected, nCh, framesPerSlice, zSize, tSize, nPages);
    otherCount = nCh * framesPerSlice * zSize;
    tSize = max(1, floor(nPages / otherCount));
    nExpected = nCh * framesPerSlice * zSize * tSize;
end
rawYX = rawYX(:, :, 1:nExpected);

data6 = reshape(rawYX, [size(rawYX, 1), size(rawYX, 2), nCh, framesPerSlice, zSize, tSize]);

keep = [true, true, nCh > 1, framesPerSlice > 1, zSize > 1, tSize > 1];
dimNames = {'Y', 'X', 'C', 'F', 'Z', 'T'};

[scaleY, unitY] = scaleUnitOr(md.dy_um, 'um');
[scaleX, unitX] = scaleUnitOr(md.dx_um, 'um');
[scaleZ, unitZ] = scaleUnitOr(md.dz_um, 'um');
[scaleF, unitF] = scaleUnitOr(periodFromRate(md.frameRate_Hz), 's');
[scaleT, unitT] = scaleUnitOr(periodFromRate(md.volumeRate_Hz), 's');
dimScaleAll = {scaleY, scaleX, 1, scaleF, scaleZ, scaleT};
dimUnitsAll = {unitY, unitX, '', unitF, unitZ, unitT};

data = dropSingletonDims6(data6, keep);

channelIds = md.savedChannels;
if isempty(channelIds)
    channelIds = 1:nCh;
end
channelNames = arrayfun(@(c) sprintf('Ch%d', c), channelIds, 'UniformOutput', false);

instrument = struct( ...
    'MicroscopeManufacturer', '', 'MicroscopeModel', '', 'MicroscopeType', '', ...
    'ObjectiveManufacturer', '', 'ObjectiveModel', '', ...
    'ObjectiveNA', NaN, 'ObjectiveImmersion', '', 'ObjectiveMagnification', NaN, ...
    'ObjectiveRefractiveIndex', NaN, ...
    'AcquisitionDate', '', ...
    'ChannelNames', {channelNames}, ...
    'ChannelExWavelength', nan(1, nCh), 'ChannelEmWavelength', nan(1, nCh), ...
    'ChannelExWavelengthUnit', {repmat({''}, 1, nCh)}, ...
    'ChannelEmWavelengthUnit', {repmat({''}, 1, nCh)}, ...
    'ChannelAcquisitionMode', {repmat({''}, 1, nCh)}, ...
    'Zoom', md.zoom, 'FrameRate_Hz', md.frameRate_Hz, 'VolumeRate_Hz', md.volumeRate_Hz, ...
    'FrameAverage', md.frameAverage);

meta = struct( ...
    'dimNames',     {dimNames(keep)}, ...
    'dimScale',     {dimScaleAll(keep)}, ...
    'dimUnits',     {dimUnitsAll(keep)}, ...
    'channelNames', {channelNames}, ...
    'instrument',   instrument);
end

% =============================================================================
function v = valueOr(v, default)
if isempty(v) || isnan(v) || v <= 0
    v = default;
end
end

% =============================================================================
function period = periodFromRate(rateHz)
if isempty(rateHz) || isnan(rateHz) || rateHz <= 0
    period = NaN;
else
    period = 1 / rateHz;
end
end

% =============================================================================
function [scale, unit] = scaleUnitOr(value, unitIfKnown)
% Fall back to a plain index scale (1) and no unit when the source value is
% unknown, rather than showing a fabricated 'um'/'s' next to a fake "1" step.
if isempty(value) || isnan(value) || value <= 0
    scale = 1;
    unit = '';
else
    scale = value;
    unit = unitIfKnown;
end
end

% =============================================================================
function out = dropSingletonDims6(data6, keep)
% Six-axis analogue of finalizeOmePlanes's dropSingletonDims. Every dropped
% dimension is guaranteed size 1 by the caller, so this only relabels dims
% and never reorders data.
sz6 = [size(data6,1), size(data6,2), size(data6,3), size(data6,4), size(data6,5), size(data6,6)];
out = reshape(data6, sz6(keep));
end

% =============================================================================
function closeReaderQuietly(r)
try
    r.close();
catch
end
end
