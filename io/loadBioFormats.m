function [data, meta] = loadBioFormats(filepath)
% loadBioFormats  Read an image file via Bio-Formats (loci.formats), the
%   canonical reader for OME-XML/TIFF and ~150 other microscopy formats
%   (.czi, .lsm, .nd2, .lif, ...). Requires ensureBioFormats() to be true.
%
%   [data, meta] = loadBioFormats(filepath)
%
%   Produces the same output contract as loadFiles.m's built-in OME-TIFF
%   reader (see finalizeOmePlanes): data is an [Y X Z C T] array with
%   singleton Z/C/T axes dropped, and meta carries dimNames/dimScale/
%   dimUnits/channelNames. Only the first series of a multi-series file is
%   read (warns if there is more than one), matching the built-in reader's
%   scope.
%
%   See also: ensureBioFormats, finalizeOmePlanes, bfGetReader, bfGetPlane.

r = bfGetReader(filepath);
cleanupObj = onCleanup(@() closeReaderQuietly(r)); %#ok<NASGU>

nSeries = r.getSeriesCount();
if nSeries > 1
    warning('loadFiles:bioformatsMultiSeries', ...
        'File "%s" contains %d series; only the first is loaded.', filepath, nSeries);
end

SizeZ = r.getSizeZ(); SizeC = r.getSizeC(); SizeT = r.getSizeT();

data5 = [];
for t = 1:SizeT
    for c = 1:SizeC
        for z = 1:SizeZ
            idx = r.getIndex(z - 1, c - 1, t - 1) + 1;
            plane = bfGetPlane(r, idx);
            if isempty(data5)
                data5 = zeros([size(plane, 1), size(plane, 2), SizeZ, SizeC, SizeT], class(plane));
            end
            data5(:, :, z, c, t) = plane;
        end
    end
end

omeMeta = r.getMetadataStore();
[physX, unitX] = getOmeQuantity(@() omeMeta.getPixelsPhysicalSizeX(0));
[physY, unitY] = getOmeQuantity(@() omeMeta.getPixelsPhysicalSizeY(0));
[physZ, unitZ] = getOmeQuantity(@() omeMeta.getPixelsPhysicalSizeZ(0));
[physT, unitT] = getOmeQuantity(@() omeMeta.getPixelsTimeIncrement(0));

chNames = repmat({''}, 1, SizeC);
for c = 1:SizeC
    try
        nm = omeMeta.getChannelName(0, c - 1);
        if ~isempty(nm)
            chNames{c} = char(nm);
        end
    catch
    end
end

phys = struct('Y', physY, 'X', physX, 'Z', physZ, 'T', physT, ...
    'Yunit', unitY, 'Xunit', unitX, 'Zunit', unitZ, 'Tunit', unitT);
instrument = getInstrumentInfo(r, omeMeta, SizeC, filepath);
instrument.ChannelNames = chNames;
[data, meta] = finalizeOmePlanes(data5, phys, chNames, instrument);
end

% =============================================================================
function [val, unit] = getOmeQuantity(fn)
% Extract .value()/.unit().getSymbol() from an ome.units.quantity.* object
% (Length or Time share this API). Returns NaN/'' on a null/missing/errored
% quantity, matching parseOmeXml's convention for absent metadata.
val = NaN;
unit = '';
try
    obj = fn();
    if isempty(obj)
        return;
    end
    val = obj.value().doubleValue();
    unit = normalizeOmeUnit(char(obj.unit().getSymbol()));
catch
end
end

% =============================================================================
function s = getOmeStringOr(fn)
% Call a metadata-store getter that returns a Java String (or an enum with a
% toString()), returning '' on a null/missing/errored result.
s = '';
try
    v = fn();
    if ~isempty(v)
        s = char(v.toString());
    end
catch
end
end

% =============================================================================
function v = getOmeNumberOr(fn)
% Call a metadata-store getter that returns a boxed Java number (e.g.
% Double), returning NaN on a null/missing/errored result.
v = NaN;
try
    obj = fn();
    if ~isempty(obj)
        v = obj.doubleValue();
    end
catch
end
end

% =============================================================================
function s = getGlobalMetadataOr(r, key, default)
% Look up a key in the reader's raw/original per-format metadata table (the
% vendor's own field names, pre-OME-translation), returning default if the
% key is absent or the lookup errors.
s = default;
try
    v = r.getGlobalMetadata().get(key);
    if ~isempty(v)
        s = char(string(v));
    end
catch
end
end

% =============================================================================
function idx = resolveRefIndex(refId, count, idFn)
% Find which of `count` items (0-based) has an ID matching refId, via
% idFn(i) -> that item's ID string. Falls back to 0 (the first item) when
% refId is empty/unmatched -- e.g. no reference in the file, a lookup
% error, or a single-instrument/objective file with mismatched IDs.
idx = 0;
if isempty(refId), return; end
for i = 0:count-1
    if strcmp(idFn(i), refId)
        idx = i;
        return;
    end
end
end

% =============================================================================
function instrument = getInstrumentInfo(r, omeMeta, SizeC, filepath)
% Read Instrument/Microscope/Objective, AcquisitionDate, and per-channel
% excitation/emission/acquisition-mode from the Bio-Formats metadata store.
% Every getter is optional in OME-XML, so each is independently guarded --
% a file missing (e.g.) Objective info still yields Microscope/date/channel
% fields where present.
%
% Some format readers (e.g. Zeiss CZI) don't translate every field of their
% vendor metadata into the OME MetadataStore -- the microscope's model name
% is one such gap (verified against a real .czi: getMicroscopeModel() comes
% back empty even though the CZI's own metadata has it under
% "Information|Instrument|Microscope|System"). r.getGlobalMetadata() exposes
% that raw per-format key/value table as a fallback for such gaps.
%
% Manufacturer strings are often absent from the file entirely rather than
% just untranslated (verified against the same .czi: neither the Microscope
% nor Objective element carries a manufacturer string anywhere in its raw
% metadata) -- guessManufacturerFromExtension() then infers it from the file
% format itself for known single-vendor formats (.czi -> Zeiss, etc.).
instrument = struct( ...
    'MicroscopeManufacturer', '', 'MicroscopeModel', '', 'MicroscopeType', '', ...
    'ObjectiveManufacturer', '', 'ObjectiveModel', '', ...
    'ObjectiveNA', NaN, 'ObjectiveImmersion', '', 'ObjectiveMagnification', NaN, ...
    'ObjectiveRefractiveIndex', NaN, ...
    'AcquisitionDate', '', ...
    'ChannelExWavelength', nan(1, SizeC), 'ChannelEmWavelength', nan(1, SizeC), ...
    'ChannelExWavelengthUnit', {repmat({''}, 1, SizeC)}, ...
    'ChannelEmWavelengthUnit', {repmat({''}, 1, SizeC)}, ...
    'ChannelAcquisitionMode', {repmat({''}, 1, SizeC)});

try
    if omeMeta.getInstrumentCount() > 0
        % A file can define more than one Instrument (e.g. a shared scope
        % config listing every objective turret position) -- resolve the one
        % this image (index 0, the only one matVis reads) actually
        % references, falling back to instrument 0 when there's no
        % reference or no match.
        instIdx = resolveRefIndex(getOmeStringOr(@() omeMeta.getImageInstrumentRef(0)), ...
            omeMeta.getInstrumentCount(), @(i) getOmeStringOr(@() omeMeta.getInstrumentID(i)));

        instrument.MicroscopeManufacturer = getOmeStringOr(@() omeMeta.getMicroscopeManufacturer(instIdx));
        instrument.MicroscopeModel        = getOmeStringOr(@() omeMeta.getMicroscopeModel(instIdx));
        instrument.MicroscopeType         = getOmeStringOr(@() omeMeta.getMicroscopeType(instIdx));
        if omeMeta.getObjectiveCount(instIdx) > 0
            objIdx = resolveRefIndex(getOmeStringOr(@() omeMeta.getObjectiveSettingsID(0)), ...
                omeMeta.getObjectiveCount(instIdx), @(i) getOmeStringOr(@() omeMeta.getObjectiveID(instIdx, i)));

            instrument.ObjectiveManufacturer  = getOmeStringOr(@() omeMeta.getObjectiveManufacturer(instIdx, objIdx));
            instrument.ObjectiveModel         = getOmeStringOr(@() omeMeta.getObjectiveModel(instIdx, objIdx));
            instrument.ObjectiveNA            = getOmeNumberOr(@() omeMeta.getObjectiveLensNA(instIdx, objIdx));
            instrument.ObjectiveImmersion     = getOmeStringOr(@() omeMeta.getObjectiveImmersion(instIdx, objIdx));
            instrument.ObjectiveMagnification = getOmeNumberOr(@() omeMeta.getObjectiveNominalMagnification(instIdx, objIdx));
        end
    end
catch
end
if isempty(instrument.MicroscopeModel)
    instrument.MicroscopeModel = getGlobalMetadataOr(r, 'Information|Instrument|Microscope|System', '');
end
vendorGuess = guessManufacturerFromExtension(filepath);
if isempty(instrument.MicroscopeManufacturer)
    instrument.MicroscopeManufacturer = vendorGuess;
end
if isempty(instrument.ObjectiveManufacturer)
    instrument.ObjectiveManufacturer = vendorGuess;
end
% RefractiveIndex lives on this Image's <ObjectiveSettings>, not on the
% <Objective> itself -- it's the medium actually used, not a lens spec.
instrument.ObjectiveRefractiveIndex = getOmeNumberOr(@() omeMeta.getObjectiveSettingsRefractiveIndex(0));

instrument.AcquisitionDate = getOmeStringOr(@() omeMeta.getImageAcquisitionDate(0));

for c = 1:SizeC
    [instrument.ChannelExWavelength(c), instrument.ChannelExWavelengthUnit{c}] = ...
        getOmeQuantity(@() omeMeta.getChannelExcitationWavelength(0, c - 1));
    [instrument.ChannelEmWavelength(c), instrument.ChannelEmWavelengthUnit{c}] = ...
        getOmeQuantity(@() omeMeta.getChannelEmissionWavelength(0, c - 1));
    instrument.ChannelAcquisitionMode{c} = getOmeStringOr(@() omeMeta.getChannelAcquisitionMode(0, c - 1));
end
end

% =============================================================================
function closeReaderQuietly(r)
try
    r.close();
catch
end
end
