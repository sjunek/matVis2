function [data, meta] = loadBioFormats(filepath, progressFcn)
% loadBioFormats  Read an image file via Bio-Formats (loci.formats), the
%   canonical reader for OME-XML/TIFF and ~150 other microscopy formats
%   (.czi, .lsm, .nd2, .lif, ...). Requires ensureBioFormats() to be true.
%
%   [data, meta] = loadBioFormats(filepath)
%   [data, meta] = loadBioFormats(filepath, progressFcn)
%
%   progressFcn is called as stop = progressFcn(done, total) every few planes
%   while the file is read, and as progressFcn([], []) once the run is over.
%   It must return a logical: true stops the read, which then throws
%   loadBioFormats:cancelled. The file is read plane by plane either way, so
%   reporting costs only the caller's own drawnow -- which is also the one
%   moment MATLAB can notice a Cancel button having been pressed.
%
%   Produces the same output contract as loadFiles.m's built-in OME-TIFF
%   reader (see finalizeOmePlanes): data is an [Y X Z C T] array with
%   singleton Z/C/T axes dropped, and meta carries dimNames/dimScale/
%   dimUnits/channelNames. Only the first series of a multi-series file is
%   read (warns if there is more than one), matching the built-in reader's
%   scope.
%
%   See also: ensureBioFormats, finalizeOmePlanes, bfGetReader, bfGetPlane.

if nargin < 2, progressFcn = []; end

r = bfGetReader(filepath);
cleanupObj = onCleanup(@() closeReaderQuietly(r)); %#ok<NASGU>

nSeries = r.getSeriesCount();
if nSeries > 1
    warning('loadFiles:bioformatsMultiSeries', ...
        'File "%s" contains %d series; only the first is loaded.', filepath, nSeries);
end

SizeZ = r.getSizeZ(); SizeC = r.getSizeC(); SizeT = r.getSizeT();

data5 = [];
nPlanes = SizeZ * SizeC * SizeT;
% Only worth announcing when there is enough to wait for, and only every
% fourth plane: each report costs the caller a drawnow.
report = ~isempty(progressFcn) && nPlanes >= 4;
q = 0;
for t = 1:SizeT
    for c = 1:SizeC
        for z = 1:SizeZ
            q = q + 1;
            if report && mod(q, 4) == 1 && progressFcn(q, nPlanes)
                progressFcn([], []);
                error('loadBioFormats:cancelled', ...
                    'Reading cancelled after %d of %d planes.', q - 1, nPlanes);
            end
            idx = r.getIndex(z - 1, c - 1, t - 1) + 1;
            plane = bfGetPlane(r, idx);
            if isempty(data5)
                data5 = zeros([size(plane, 1), size(plane, 2), SizeZ, SizeC, SizeT], class(plane));
            end
            data5(:, :, z, c, t) = plane;
        end
    end
end
if report
    progressFcn([], []);
end

[phys, chNames, instrument] = bfReadMetadata(r, filepath);
[data, meta] = finalizeOmePlanes(data5, phys, chNames, instrument);
end

% =============================================================================
function closeReaderQuietly(r)
try
    r.close();
catch
end
end
