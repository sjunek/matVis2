function [data, meta] = finalizeOmePlanes(data5, phys, channelNames, instrument)
% finalizeOmePlanes  Drop singleton Z/C/T axes from an assembled [Y X Z C T]
%   array and build the matVis dimension-metadata struct (dimNames/dimScale/
%   dimUnits/channelNames/instrument) to go with it. Shared by the built-in
%   OME-TIFF reader (loadFiles.m's loadOmeTif) and the Bio-Formats reader
%   (loadBioFormats.m) so the two engines produce identically-shaped output.
%
%   phys is a struct with fields Y/X/Z/T (physical scale; NaN or <=0 -> 1)
%   and Yunit/Xunit/Zunit/Tunit (char, '' if unknown).
%   channelNames is a 1xSizeC cell of char.
%   instrument (optional) is a struct describing the acquisition hardware --
%   see parseOmeXml's field list (Microscope*/Objective*/AcquisitionDate/
%   Channel*) -- for display in MatVisMetadataWin. Defaults to all-empty
%   when omitted (e.g. no <Instrument> in the file).

if nargin < 4 || isempty(instrument)
    SizeC = numel(channelNames);
    instrument = struct( ...
        'MicroscopeManufacturer', '', 'MicroscopeModel', '', ...
        'ObjectiveManufacturer', '', 'ObjectiveModel', '', ...
        'ObjectiveNA', NaN, 'ObjectiveImmersion', '', 'ObjectiveMagnification', NaN, ...
        'AcquisitionDate', '', ...
        'ChannelNames', {channelNames}, ...
        'ChannelExWavelength', nan(1, SizeC), 'ChannelEmWavelength', nan(1, SizeC), ...
        'ChannelExWavelengthUnit', {repmat({''}, 1, SizeC)}, ...
        'ChannelEmWavelengthUnit', {repmat({''}, 1, SizeC)}, ...
        'ChannelAcquisitionMode', {repmat({''}, 1, SizeC)});
end

SizeZ = size(data5, 3); SizeC = size(data5, 4); SizeT = size(data5, 5);
keep = [true, true, SizeZ > 1, SizeC > 1, SizeT > 1];

dimNames    = {'Y', 'X', 'Z', 'C', 'T'};
dimScaleAll = {phys.Y, phys.X, phys.Z, 1, phys.T};
dimUnitsAll = {phys.Yunit, phys.Xunit, phys.Zunit, '', phys.Tunit};
for i = 1:5
    if isnan(dimScaleAll{i}) || dimScaleAll{i} <= 0
        dimScaleAll{i} = 1;
    end
end

data = dropSingletonDims(data5, keep);
meta = struct( ...
    'dimNames',     {dimNames(keep)}, ...
    'dimScale',     {dimScaleAll(keep)}, ...
    'dimUnits',     {dimUnitsAll(keep)}, ...
    'channelNames', {channelNames}, ...
    'instrument',   instrument);
end

% =============================================================================
function out = dropSingletonDims(data5, keep)
% Reshape away the dimensions marked false in keep. Every dropped dimension
% is guaranteed size 1 by the caller, so this only relabels dims and never
% reorders data.
sz5 = [size(data5,1), size(data5,2), size(data5,3), size(data5,4), size(data5,5)];
out = reshape(data5, sz5(keep));
end
