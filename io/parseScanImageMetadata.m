function md = parseScanImageMetadata(mdStr)
% parseScanImageMetadata  Extract dimension/scale metadata from the 'SI.*'
%   header string returned by ScanImageTiffReader's metadata() method.
%   Mirrors the field mapping in matlabTools/fileReadingWriting/readSIHolo.m.
%
%   md = parseScanImageMetadata(mdStr)
%
% md fields (NaN / [] if the corresponding SI.* key is absent):
%   xSize, ySize      SI.hRoiManager.pixelsPerLine / linesPerFrame
%   zSize, tSize      SI.hStackManager.actualNumSlices / numVolumes
%   zoom              SI.hRoiManager.scanZoomFactor
%   frameRate_Hz      SI.hRoiManager.scanFrameRate
%   volumeRate_Hz     SI.hRoiManager.scanVolumeRate
%   savedChannels     SI.hChannels.channelSave (numeric vector)
%   dz_um             SI.hStackManager.actualStackZStepSize
%   framesPerSlice    SI.hStackManager.framesPerSlice, already divided by
%                     frameAverage (raw metadata counts averaged sub-frames,
%                     not the frames actually written to the file)
%   frameAverage      SI.hScan2D.logAverageFactor
%   FOV_um            [height width], derived from the 4-corner
%                     SI.hRoiManager.imagingFovUm polygon
%   dx_um, dy_um      FOV_um ./ [xSize ySize]

fields(1)  = struct('mdName', 'xSize',          'siName', 'SI.hRoiManager.pixelsPerLine',          'type', 'numeric');
fields(2)  = struct('mdName', 'ySize',          'siName', 'SI.hRoiManager.linesPerFrame',          'type', 'numeric');
fields(3)  = struct('mdName', 'zSize',          'siName', 'SI.hStackManager.actualNumSlices',      'type', 'numeric');
fields(4)  = struct('mdName', 'tSize',          'siName', 'SI.hStackManager.numVolumes',           'type', 'numeric');
fields(5)  = struct('mdName', 'zoom',           'siName', 'SI.hRoiManager.scanZoomFactor',         'type', 'numeric');
fields(6)  = struct('mdName', 'frameRate_Hz',   'siName', 'SI.hRoiManager.scanFrameRate',          'type', 'numeric');
fields(7)  = struct('mdName', 'volumeRate_Hz',  'siName', 'SI.hRoiManager.scanVolumeRate',         'type', 'numeric');
fields(8)  = struct('mdName', 'savedChannels',  'siName', 'SI.hChannels.channelSave',              'type', 'vector');
fields(9)  = struct('mdName', 'dz_um',          'siName', 'SI.hStackManager.actualStackZStepSize', 'type', 'numeric');
fields(10) = struct('mdName', 'framesPerSlice', 'siName', 'SI.hStackManager.framesPerSlice',       'type', 'numeric');
fields(11) = struct('mdName', 'frameAverage',   'siName', 'SI.hScan2D.logAverageFactor',           'type', 'numeric');
fields(12) = struct('mdName', 'FOV_um',         'siName', 'SI.hRoiManager.imagingFovUm',           'type', 'fov');

md = struct('xSize', NaN, 'ySize', NaN, 'zSize', NaN, 'tSize', NaN, 'zoom', NaN, ...
    'frameRate_Hz', NaN, 'volumeRate_Hz', NaN, 'savedChannels', [], 'dz_um', NaN, ...
    'framesPerSlice', NaN, 'frameAverage', NaN, 'FOV_um', [], 'dx_um', NaN, 'dy_um', NaN);

desiredNames = {fields.siName};
lines = strsplit(char(mdStr), '\n');
for i = 1:numel(lines)
    pair = strsplit(lines{i}, '=');
    if numel(pair) < 2
        continue;
    end
    name = strtrim(pair{1});
    idx = find(strcmp(desiredNames, name), 1);
    if isempty(idx)
        continue;
    end
    value = strtrim(strjoin(pair(2:end), '='));  % rejoin in case the value itself contained '='

    switch fields(idx).type
        case 'numeric'
            md.(fields(idx).mdName) = str2double(value);
        case 'vector'
            md.(fields(idx).mdName) = evalScanImageValue(value);
        case 'fov'
            corners = evalScanImageValue(value);
            if ~isempty(corners) && isequal(size(corners), [4 2])
                md.FOV_um = [corners(3,2) - corners(1,2), corners(2,1) - corners(1,1)];
            end
    end
end

if ~isempty(md.FOV_um) && isfinite(md.xSize) && isfinite(md.ySize) && md.xSize > 0 && md.ySize > 0
    md.dx_um = md.FOV_um(2) / md.xSize;
    md.dy_um = md.FOV_um(1) / md.ySize;
end

if isfinite(md.framesPerSlice) && isfinite(md.frameAverage) && md.frameAverage > 0
    md.framesPerSlice = md.framesPerSlice / md.frameAverage;
end
end

% =============================================================================
function v = evalScanImageValue(str)
% ScanImage encodes vector/matrix metadata values as literal MATLAB
% expression text (e.g. '[1 2 3]', '[-5 -5;5 -5;5 5;-5 5]'). eval is safe
% here: str comes from a trusted local metadata block, not user input, and
% matches the parsing approach in the reference readSIHolo.m.
try
    v = eval(str); %#ok<EVLDOT>
catch
    v = [];
end
end
