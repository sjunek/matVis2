function [data, meta] = loadFiles(filepath)
% loadFiles  Load an image file and return its raw numeric array.
%   data = loadFiles(filepath)   loads the file at filepath.
%   data = loadFiles('')         opens a file-selection dialog.
%   data = loadFiles()           opens a file-selection dialog.
%   [data, meta] = loadFiles(filepath)  also returns dimension metadata.
%
%   ScanImage-acquired TIFFs (detected automatically) are read via the
%   ScanImageTiffReader package (see ensureScanImageTiffReader), surfacing
%   framesPerSlice as its own dimension alongside channel/Z/T. When
%   Bio-Formats is set up (see ensureBioFormats), any of the ~150 formats
%   it supports (OME-TIFF, .czi, .lsm, .nd2, .lif, ...) can be read, with
%   full dimension/physical-scale/channel metadata. Zstandard-compressed
%   TIFFs (compression tag 50000), which neither MATLAB nor Bio-Formats can
%   read, are handled by loadZstdTiff. Without either, .mat,
%   .tif/.tiff (incl. multi-page and OME-TIFF via a built-in regex parser),
%   .jpg, .png, and .bmp still work through a built-in fallback; any other
%   format then errors asking for Bio-Formats to be set up.
%
%   meta is a struct with fields dimNames/dimScale/dimUnits/channelNames/
%   instrument, matching parseArgs's dimNames/dimScale/dimUnits name-value
%   pairs. For plain files with no dimension/calibration metadata these are
%   all empty (cells, or [] for instrument), meaning "use defaults".

nativeExts = {'.tif', '.tiff', '.jpg', '.jpeg', '.png', '.bmp'};

% Bio-Formats' BMP reader corrupts pixel data for widths that aren't a
% multiple of 4 bytes (verified empirically: a 64-wide test image round-trips
% fine, a 17-wide one comes back shifted/garbled) -- likely a row-padding bug
% in loci.formats' BmpReader. BMP carries no scientific metadata Bio-Formats
% would add value for anyway, so it always uses the native imread-based
% reader instead of being routed through Bio-Formats.
bioFormatsExcludedExts = {'.bmp'};

if nargin < 1 || isempty(filepath)
    [fname, fpath] = uigetfile(buildFileFilter(), 'Select a file');
    if isequal(fname, 0)
        error('loadFiles:cancelled', 'File selection cancelled.');
    end
    filepath = fullfile(fpath, fname);
end

[~, ~, ext] = fileparts(filepath);
ext = lower(ext);

if strcmp(ext, '.mat')
    data = loadMat(filepath);
    meta = emptyMeta();
    return;
end

% ScanImage TIFFs get their own authoritative reader (surfaces
% framesPerSlice as its own dimension) ahead of Bio-Formats' generic,
% lossier ScanImage support. isScanImageTiff is a cheap Software/
% ImageDescription signature check, so this never prompts about the reader
% for files that don't need it.
if ismember(ext, {'.tif', '.tiff'}) && isScanImageTiff(filepath)
    if ensureScanImageTiffReader()
        try
            [data, meta] = loadScanImageTiff(filepath);
            return;
        catch e
            warning('loadFiles:scanimageReadFailed', ...
                'ScanImageTiffReader failed to read "%s" (%s); falling back to a generic TIFF reader.', ...
                filepath, e.message);
        end
    end
    % else: ensureScanImageTiffReader() already warned; fall through below.
end

% Zstandard-compressed TIFFs (compression tag 50000) are read by neither
% MATLAB's TIFF library ("The compression scheme 50000 is not currently
% supported when reading TIFF files.") nor Bio-Formats 8.5 -- ome-codecs'
% ZstdCodec sizes its output buffer from the Zstandard frame's optional
% content-size field, which these writers omit, and dies with
% NegativeArraySizeException. So they get their own reader, which takes the
% decompressed size from the strip/tile geometry instead. One Zstandard
% page is enough to route the file here: Compression is a per-directory
% tag, and these writers mix schemes within a file, so loadZstdTiff also
% decodes the PackBits/Deflate/LZW/uncompressed pages alongside.
if ismember(ext, {'.tif', '.tiff'}) && isZstdTiff(filepath)
    [data, meta] = loadZstdTiff(filepath);
    return;
end

bfAvailable = ensureBioFormats();
isNative = ismember(ext, nativeExts);
bfKnowsExt = bfAvailable && ismember(ext(2:end), bioFormatsExtensions());

if ~isNative && ~bfKnowsExt
    if bfAvailable
        error('loadFiles:unsupportedFormat', 'Unsupported file type: %s.', ext);
    else
        error('loadFiles:unsupportedFormat', ...
            ['Unsupported file type: %s. Supported types are .mat, .tif, .tiff, .jpg, .jpeg, ' ...
             '.png, .bmp; other formats require Bio-Formats, which is not set up.'], ext);
    end
end

if bfAvailable && ~ismember(ext, bioFormatsExcludedExts)
    try
        [data, meta] = loadBioFormats(filepath);
        return;
    catch e
        if ~isNative
            rethrow(e);
        end
        warning('loadFiles:bioformatsReadFailed', ...
            'Bio-Formats failed to read "%s" (%s); falling back to the built-in reader.', ...
            filepath, e.message);
    end
end

switch ext
    case {'.tif', '.tiff'}
        [data, meta] = loadTifOrOme(filepath);
    case {'.jpg', '.jpeg', '.png', '.bmp'}
        data = loadStandardImage(filepath);
        meta = emptyMeta();
end
end

function meta = emptyMeta()
meta = struct('dimNames', {{}}, 'dimScale', {{}}, 'dimUnits', {{}}, ...
    'channelNames', {{}}, 'instrument', []);
end

function data = loadMat(filepath)
s = load(filepath);
fields = fieldnames(s);
numericFields = fields(cellfun(@(f) isnumeric(s.(f)), fields));
if isempty(numericFields)
    error('loadFiles:noNumericVar', 'No numeric variable found in .mat file: %s', filepath);
end
data = s.(numericFields{1});
end

function data = loadStandardImage(filepath)
data = imread(filepath);
end

function [data, meta] = loadTifOrOme(filepath)
info = imfinfo(filepath);
desc = '';
if isfield(info, 'ImageDescription') && ~isempty(info(1).ImageDescription)
    desc = info(1).ImageDescription;
end

om = struct('isOme', false);
if ~isempty(desc) && ~isempty(regexp(desc, '<OME\>', 'once'))
    om = parseOmeXml(desc);
end

if om.isOme
    [data, meta] = loadOmeTif(filepath, info, om);
else
    data = loadTif(filepath, info);
    meta = emptyMeta();
end
end

function data = loadTif(filepath, info)
nPages = numel(info);
nChannels = info(1).SamplesPerPixel;

if nPages == 1 && nChannels == 1
    data = imread(filepath, 1, 'Info', info);
elseif nPages == 1 && nChannels > 1
    data = imread(filepath, 1, 'Info', info);
elseif nPages > 1 && nChannels == 1
    im1 = imread(filepath, 1, 'Info', info);
    data = zeros([size(im1), nPages], class(im1));
    data(:,:,1) = im1;
    for k = 2:nPages
        data(:,:,k) = imread(filepath, k, 'Info', info);
    end
elseif nPages > 1 && nChannels > 1
    im1 = imread(filepath, 1, 'Info', info);
    data = zeros([size(im1), nPages], class(im1));
    data(:,:,:,1) = im1;
    for k = 2:nPages
        data(:,:,:,k) = imread(filepath, k, 'Info', info);
    end
end
end

function [data, meta] = loadOmeTif(filepath, info, om)
% loadOmeTif  Assemble the IFDs of an OME-TIFF into an [Y X Z C T] array
%   (singleton Z/C/T axes dropped), and derive dimension metadata from the
%   parsed OME-XML.
nIFDs = numel(info);

if om.hasMultipleSeries
    warning('loadFiles:omeMultiSeries', ...
        'File "%s" contains more than one OME image series; only the first is loaded.', ...
        filepath);
end

sz = struct('Z', om.SizeZ, 'C', om.SizeC, 'T', om.SizeT);

if ~isempty(om.Planes)
    zIdx = [om.Planes.Z]; cIdx = [om.Planes.C]; tIdx = [om.Planes.T];
    ifdIdx = [om.Planes.IFD];
    nUse = numel(ifdIdx);
else
    order = om.DimensionOrder(3:5);
    fast = order(1); mid = order(2); slow = order(3);
    nExpected = sz.Z * sz.C * sz.T;
    if nIFDs ~= nExpected
        warning('loadFiles:omeIfdCountMismatch', ...
            ['File "%s" declares %d planes (Z=%d, C=%d, T=%d) but contains %d IFDs; ' ...
             'using the smaller of the two.'], filepath, nExpected, sz.Z, sz.C, sz.T, nIFDs);
    end
    nUse = min(nIFDs, nExpected);
    otherCount = sz.(fast) * sz.(mid);
    sz.(slow) = max(1, floor(nUse / otherCount));
    nUse = sz.(fast) * sz.(mid) * sz.(slow);

    zIdx = zeros(1, nUse); cIdx = zeros(1, nUse); tIdx = zeros(1, nUse);
    ifdIdx = 0:nUse-1;
    k = 0;
    for is = 1:sz.(slow)
        for im = 1:sz.(mid)
            for ifst = 1:sz.(fast)
                idx = struct('Z', 1, 'C', 1, 'T', 1);
                idx.(fast) = ifst; idx.(mid) = im; idx.(slow) = is;
                k = k + 1;
                zIdx(k) = idx.Z - 1; cIdx(k) = idx.C - 1; tIdx(k) = idx.T - 1;
            end
        end
    end
end

SizeZ = sz.Z; SizeC = sz.C; SizeT = sz.T;

im1 = imread(filepath, ifdIdx(1) + 1, 'Info', info);
if ndims(im1) > 2
    error('loadFiles:omeInterleavedUnsupported', ...
        'Interleaved (RGB) OME-TIFF channels are not supported; got a %dD plane in "%s".', ...
        ndims(im1), filepath);
end
data5 = zeros([size(im1, 1), size(im1, 2), SizeZ, SizeC, SizeT], class(im1));
data5(:, :, zIdx(1)+1, cIdx(1)+1, tIdx(1)+1) = im1;
for k = 2:nUse
    plane = imread(filepath, ifdIdx(k) + 1, 'Info', info);
    data5(:, :, zIdx(k)+1, cIdx(k)+1, tIdx(k)+1) = plane;
end

phys = struct( ...
    'Y', om.PhysicalSizeY, 'X', om.PhysicalSizeX, 'Z', om.PhysicalSizeZ, 'T', om.TimeIncrement, ...
    'Yunit', om.PhysicalSizeYUnit, 'Xunit', om.PhysicalSizeXUnit, ...
    'Zunit', om.PhysicalSizeZUnit, 'Tunit', om.TimeIncrementUnit);
instrument = struct( ...
    'MicroscopeManufacturer', om.MicroscopeManufacturer, 'MicroscopeModel', om.MicroscopeModel, ...
    'MicroscopeType', om.MicroscopeType, ...
    'ObjectiveManufacturer', om.ObjectiveManufacturer, 'ObjectiveModel', om.ObjectiveModel, ...
    'ObjectiveNA', om.ObjectiveNA, 'ObjectiveImmersion', om.ObjectiveImmersion, ...
    'ObjectiveMagnification', om.ObjectiveMagnification, ...
    'ObjectiveRefractiveIndex', om.ObjectiveRefractiveIndex, ...
    'AcquisitionDate', om.AcquisitionDate, ...
    'ChannelNames', {om.ChannelNames}, ...
    'ChannelExWavelength', om.ChannelExWavelength, 'ChannelEmWavelength', om.ChannelEmWavelength, ...
    'ChannelExWavelengthUnit', {om.ChannelExWavelengthUnit}, ...
    'ChannelEmWavelengthUnit', {om.ChannelEmWavelengthUnit}, ...
    'ChannelAcquisitionMode', {om.ChannelAcquisitionMode});
[data, meta] = finalizeOmePlanes(data5, phys, om.ChannelNames, instrument);
end
