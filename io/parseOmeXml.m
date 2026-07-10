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
%   AcquisitionDate     char ('' if absent) — <Image><AcquisitionDate> text
%   MicroscopeManufacturer/Model  char ('' if absent) — first <Instrument>'s
%                       <Microscope> (anywhere in the document, not scoped to
%                       the first <Image>: <Instrument> is a document-level
%                       sibling of <Image> in the OME schema)
%   MicroscopeType            char ('' if absent)
%   ObjectiveManufacturer/Model  char ('' if absent)
%   ObjectiveNA               double (NaN if absent) — LensNA
%   ObjectiveImmersion        char ('' if absent)
%   ObjectiveMagnification    double (NaN if absent) — NominalMagnification
%   ObjectiveRefractiveIndex  double (NaN if absent) — this Image's
%                       <ObjectiveSettings RefractiveIndex="...">, the
%                       actual-use-case RI (e.g. immersion medium), distinct
%                       from the Objective element itself
%   ChannelExWavelength/ChannelEmWavelength  1×SizeC double (NaN where absent)
%   ChannelExWavelengthUnit/ChannelEmWavelengthUnit  1×SizeC cell of char
%   ChannelAcquisitionMode    1×SizeC cell of char ('' where absent)

meta = struct( ...
    'isOme', false, ...
    'SizeX', 1, 'SizeY', 1, 'SizeZ', 1, 'SizeC', 1, 'SizeT', 1, ...
    'DimensionOrder', 'XYCZT', 'PixelType', '', ...
    'PhysicalSizeX', NaN, 'PhysicalSizeXUnit', '', ...
    'PhysicalSizeY', NaN, 'PhysicalSizeYUnit', '', ...
    'PhysicalSizeZ', NaN, 'PhysicalSizeZUnit', '', ...
    'TimeIncrement', NaN, 'TimeIncrementUnit', '', ...
    'ChannelNames', {{}}, 'Planes', [], 'hasMultipleSeries', false, ...
    'AcquisitionDate', '', ...
    'MicroscopeManufacturer', '', 'MicroscopeModel', '', 'MicroscopeType', '', ...
    'ObjectiveManufacturer', '', 'ObjectiveModel', '', ...
    'ObjectiveNA', NaN, 'ObjectiveImmersion', '', 'ObjectiveMagnification', NaN, ...
    'ObjectiveRefractiveIndex', NaN, ...
    'ChannelExWavelength', [], 'ChannelEmWavelength', [], ...
    'ChannelExWavelengthUnit', {{}}, 'ChannelEmWavelengthUnit', {{}}, ...
    'ChannelAcquisitionMode', {{}});

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

% <AcquisitionDate> is a child element's text content, not an attribute.
meta.AcquisitionDate = getTextOr(imgXml, 'AcquisitionDate', '');

% <Instrument>/<Microscope>/<Objective> are document-level siblings of
% <Image> (an Image references its instrument/objective via InstrumentRef/
% ObjectiveSettings @ID), so search the whole document rather than imgXml.
% A file can define more than one Instrument/Objective (e.g. a shared scope
% config listing every objective turret position) -- resolve the ones this
% Image actually references rather than always taking the first, falling
% back to the first when there's no reference or a multi-instrument/
% multi-objective file that predates matching refs.
instrBlocks = regexp(xmlStr, '<Instrument\>.*?</Instrument>', 'match', 'dotall');
if ~isempty(instrBlocks)
    instrBlock = instrBlocks{1};
    instRefTag = regexp(imgXml, '<InstrumentRef\>[^>]*/?>', 'match', 'once');
    instRefId  = getAttrOr(instRefTag, 'ID', '');
    if ~isempty(instRefId)
        for i = 1:numel(instrBlocks)
            hdrTag = regexp(instrBlocks{i}, '<Instrument\>[^>]*>', 'match', 'once');
            if strcmp(getAttrOr(hdrTag, 'ID', ''), instRefId)
                instrBlock = instrBlocks{i};
                break;
            end
        end
    end

    microscopeTag = regexp(instrBlock, '<Microscope\>[^>]*/?>', 'match', 'once');
    if ~isempty(microscopeTag)
        meta.MicroscopeManufacturer = getAttrOr(microscopeTag, 'Manufacturer', '');
        meta.MicroscopeModel        = getAttrOr(microscopeTag, 'Model', '');
        meta.MicroscopeType         = getAttrOr(microscopeTag, 'Type', '');
    end

    objTags = regexp(instrBlock, '<Objective\>[^>]*/?>', 'match');
    if ~isempty(objTags)
        objectiveTag  = objTags{1};
        objSettingsTag = regexp(imgXml, '<ObjectiveSettings\>[^>]*/?>', 'match', 'once');
        objSettingsId  = getAttrOr(objSettingsTag, 'ID', '');
        if ~isempty(objSettingsId)
            for i = 1:numel(objTags)
                if strcmp(getAttrOr(objTags{i}, 'ID', ''), objSettingsId)
                    objectiveTag = objTags{i};
                    break;
                end
            end
        end
        meta.ObjectiveManufacturer   = getAttrOr(objectiveTag, 'Manufacturer', '');
        meta.ObjectiveModel          = getAttrOr(objectiveTag, 'Model', '');
        meta.ObjectiveNA             = getNumAttrOr(objectiveTag, 'LensNA', NaN);
        meta.ObjectiveImmersion      = getAttrOr(objectiveTag, 'Immersion', '');
        meta.ObjectiveMagnification  = getNumAttrOr(objectiveTag, 'NominalMagnification', NaN);
        % RefractiveIndex lives on <ObjectiveSettings> (per-Image), not on
        % <Objective> itself -- it's the medium actually used, not a lens spec.
        meta.ObjectiveRefractiveIndex = getNumAttrOr(objSettingsTag, 'RefractiveIndex', NaN);
    end
end

% Channels
chBlocks = regexp(imgXml, '<Channel\>[^>]*/?>', 'match');
chNames    = repmat({''}, 1, meta.SizeC);
chExWave   = nan(1, meta.SizeC);
chEmWave   = nan(1, meta.SizeC);
chExUnit   = repmat({''}, 1, meta.SizeC);
chEmUnit   = repmat({''}, 1, meta.SizeC);
chAcqMode  = repmat({''}, 1, meta.SizeC);
for i = 1:min(numel(chBlocks), meta.SizeC)
    chNames{i}   = getAttrOr(chBlocks{i}, 'Name', '');
    chExWave(i)  = getNumAttrOr(chBlocks{i}, 'ExcitationWavelength', NaN);
    chEmWave(i)  = getNumAttrOr(chBlocks{i}, 'EmissionWavelength', NaN);
    chExUnit{i}  = normalizeOmeUnit(getAttrOr(chBlocks{i}, 'ExcitationWavelengthUnit', ''));
    chEmUnit{i}  = normalizeOmeUnit(getAttrOr(chBlocks{i}, 'EmissionWavelengthUnit', ''));
    chAcqMode{i} = getAttrOr(chBlocks{i}, 'AcquisitionMode', '');
end
meta.ChannelNames             = chNames;
meta.ChannelExWavelength      = chExWave;
meta.ChannelEmWavelength      = chEmWave;
meta.ChannelExWavelengthUnit  = chExUnit;
meta.ChannelEmWavelengthUnit  = chEmUnit;
meta.ChannelAcquisitionMode   = chAcqMode;

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
function v = getTextOr(xmlStr, tagName, default)
% Extract the text content of the first <tagName>...</tagName> element
% (no nested elements expected -- true for the simple leaf elements this is
% used for, e.g. <AcquisitionDate>).
pat = sprintf('<%s\\>[^>]*>([^<]*)</%s\\>', tagName, tagName);
tok = regexp(xmlStr, pat, 'tokens', 'once');
if isempty(tok)
    v = default;
else
    v = tok{1};
end
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
