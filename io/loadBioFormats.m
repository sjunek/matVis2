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
[data, meta] = finalizeOmePlanes(data5, phys, chNames);
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
function closeReaderQuietly(r)
try
    r.close();
catch
end
end
