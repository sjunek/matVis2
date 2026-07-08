function filterSpec = buildFileFilter()
% buildFileFilter  Build the uigetfile filter spec for matVis's file pickers.
%   filterSpec = buildFileFilter()
%
%   Without Bio-Formats, returns the built-in native-format filter
%   (.mat/.tif/.tiff/.jpg/.jpeg/.png/.bmp). With Bio-Formats available,
%   returns a richer multi-row filter covering every Bio-Formats-supported
%   format (via bfGetFileExtensions) plus .mat, with "All supported formats"
%   listed first -- the same layout convention Bio-Formats-based tools use.
%
%   See also: ensureBioFormats, loadFiles, importMultiFile.

nativeSpec = { ...
    '*.mat;*.tif;*.tiff;*.jpg;*.jpeg;*.png;*.bmp', ...
    'Supported files (*.mat, *.tif, *.tiff, *.jpg, *.jpeg, *.png, *.bmp)'};

if ~ensureBioFormats()
    filterSpec = nativeSpec;
    return;
end

bfExt = bfGetFileExtensions();  % Nx2: {pattern, formatName}; row 1 = 'All formats'
allPattern = [bfExt{1, 1} ';*.mat'];
filterSpec = [ ...
    {allPattern, 'All supported formats'}; ...
    {'*.mat', 'MATLAB (*.mat)'}; ...
    bfExt(2:end, :)];
end
