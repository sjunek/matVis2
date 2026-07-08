function meta = parseOmeXml(xmlStr)
% parseOmeXml  Parse OME-XML (as embedded in an OME-TIFF ImageDescription tag)
%   into a struct describing dataset dimensions, physical scale and units.
%
%   meta = parseOmeXml(xmlStr)
%
% Namespace-agnostic regex extraction (no XML DOM parser dependency), reading
% only the first <Image>/<Pixels> block. Unrecognised/absent fields fall back
% to OME defaults (Size* = 1, DimensionOrder = 'XYCZT') or NaN/'' for physical
% scale/units, so callers can treat them uniformly.
%
% meta fields
%   isOme               logical — false if xmlStr has no <OME>/<Image>/<Pixels>
%   SizeX/Y/Z/C/T       double
%   DimensionOrder      char, e.g. 'XYCZT'
%   PixelType           char ('' if absent)
%   PhysicalSizeX/Y/Z   double (NaN if absent)
%   PhysicalSizeXUnit/YUnit/ZUnit  char ('' if absent)
%   TimeIncrement       double (NaN if absent)
%   TimeIncrementUnit   char ('' if absent)
%   ChannelNames        1×SizeC cell of char ('' where unnamed)
%   Planes              struct array (fields IFD,Z,C,T, all 0-based) built
%                       from explicit per-plane <TiffData FirstZ/FirstC/FirstT>
%                       entries, or [] if the file has none (the common case:
%                       IFDs fill sequentially per DimensionOrder)
%   hasMultipleSeries   logical — true if more than one <Image> is present
%                       (only the first is parsed)

meta = struct( ...
    'isOme', false, ...
    'SizeX', 1, 'SizeY', 1, 'SizeZ', 1, 'SizeC', 1, 'SizeT', 1, ...
    'DimensionOrder', 'XYCZT', 'PixelType', '', ...
    'PhysicalSizeX', NaN, 'PhysicalSizeXUnit', '', ...
    'PhysicalSizeY', NaN, 'PhysicalSizeYUnit', '', ...
    'PhysicalSizeZ', NaN, 'PhysicalSizeZUnit', '', ...
    'TimeIncrement', NaN, 'TimeIncrementUnit', '', ...
    'ChannelNames', {{}}, 'Planes', [], 'hasMultipleSeries', false);

% Note: MATLAB's regexp does not support the generic \b word-boundary escape
% (it is silently treated as a literal 'b'); use \< / \> (start/end-of-word)
% instead, which it does support.
xmlStr = char(xmlStr);
if isempty(xmlStr) || isempty(regexp(xmlStr, '<OME\>', 'once'))
    return;
end

imageBlocks = regexp(xmlStr, '<Image\>.*?</Image>', 'match', 'dotall');
if isempty(imageBlocks)
    return;
end
meta.hasMultipleSeries = numel(imageBlocks) > 1;
imgXml = imageBlocks{1};

pixelsTag = regexp(imgXml, '<Pixels\>[^>]*>', 'match', 'once');
if isempty(pixelsTag)
    return;
end
meta.isOme = true;

meta.DimensionOrder = upper(getAttrOr(pixelsTag, 'DimensionOrder', 'XYCZT'));
meta.PixelType      = getAttrOr(pixelsTag, 'Type', '');
meta.SizeX = getNumAttrOr(pixelsTag, 'SizeX', 1);
meta.SizeY = getNumAttrOr(pixelsTag, 'SizeY', 1);
meta.SizeZ = getNumAttrOr(pixelsTag, 'SizeZ', 1);
meta.SizeC = getNumAttrOr(pixelsTag, 'SizeC', 1);
meta.SizeT = getNumAttrOr(pixelsTag, 'SizeT', 1);

meta.PhysicalSizeX = getNumAttrOr(pixelsTag, 'PhysicalSizeX', NaN);
meta.PhysicalSizeY = getNumAttrOr(pixelsTag, 'PhysicalSizeY', NaN);
meta.PhysicalSizeZ = getNumAttrOr(pixelsTag, 'PhysicalSizeZ', NaN);
meta.TimeIncrement  = getNumAttrOr(pixelsTag, 'TimeIncrement', NaN);

meta.PhysicalSizeXUnit = normalizeOmeUnit(getAttrOr(pixelsTag, 'PhysicalSizeXUnit', ''));
meta.PhysicalSizeYUnit = normalizeOmeUnit(getAttrOr(pixelsTag, 'PhysicalSizeYUnit', ''));
meta.PhysicalSizeZUnit = normalizeOmeUnit(getAttrOr(pixelsTag, 'PhysicalSizeZUnit', ''));
meta.TimeIncrementUnit = normalizeOmeUnit(getAttrOr(pixelsTag, 'TimeIncrementUnit', ''));

% Channels
chBlocks = regexp(imgXml, '<Channel\>[^>]*/?>', 'match');
chNames = repmat({''}, 1, meta.SizeC);
for i = 1:min(numel(chBlocks), meta.SizeC)
    chNames{i} = getAttrOr(chBlocks{i}, 'Name', '');
end
meta.ChannelNames = chNames;

% Explicit per-plane IFD -> (Z,C,T) map, if present.
tdBlocks = regexp(imgXml, '<TiffData\>[^>]*/?>', 'match');
planes = [];
for i = 1:numel(tdBlocks)
    tb = tdBlocks{i};
    hasFirst = ~isempty(regexp(tb, '\<FirstZ\s*=', 'once')) || ...
               ~isempty(regexp(tb, '\<FirstC\s*=', 'once')) || ...
               ~isempty(regexp(tb, '\<FirstT\s*=', 'once'));
    if ~hasFirst, continue; end
    ifd = getNumAttrOr(tb, 'IFD', NaN);
    if isnan(ifd), continue; end
    p = struct( ...
        'IFD', ifd, ...
        'Z', getNumAttrOr(tb, 'FirstZ', 0), ...
        'C', getNumAttrOr(tb, 'FirstC', 0), ...
        'T', getNumAttrOr(tb, 'FirstT', 0));
    if isempty(planes)
        planes = p;
    else
        planes(end+1) = p; %#ok<AGROW>
    end
end
meta.Planes = planes;
end

% =============================================================================
function v = getAttrOr(tagStr, attrName, default)
% Extract attrName="value" from an XML tag string. A negative lookbehind
% guards against matching a longer attribute name that happens to end with
% attrName (e.g. 'SizeX' inside 'PhysicalSizeX').
pat = sprintf('(?<![A-Za-z])%s\\s*=\\s*"([^"]*)"', attrName);
tok = regexp(tagStr, pat, 'tokens', 'once');
if isempty(tok)
    v = default;
else
    v = tok{1};
end
end

% =============================================================================
function v = getNumAttrOr(tagStr, attrName, default)
s = getAttrOr(tagStr, attrName, '');
if isempty(s)
    v = default;
    return;
end
v = str2double(s);
if isnan(v)
    v = default;
end
end
