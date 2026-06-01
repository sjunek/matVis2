function data = loadFiles(filepath)
% loadFiles  Load .mat or .tif file and return raw numeric array.
%   data = loadFiles(filepath)  loads the file at filepath.
%   data = loadFiles('')        opens a file-selection dialog.
%   data = loadFiles()          opens a file-selection dialog.

if nargin < 1 || isempty(filepath)
    [fname, fpath] = uigetfile({'*.mat;*.tif;*.tiff', 'Supported files (*.mat, *.tif, *.tiff)'}, ...
        'Select a file');
    if isequal(fname, 0)
        error('loadFiles:cancelled', 'File selection cancelled.');
    end
    filepath = fullfile(fpath, fname);
end

[~, ~, ext] = fileparts(filepath);
ext = lower(ext);

switch ext
    case '.mat'
        data = loadMat(filepath);
    case {'.tif', '.tiff'}
        data = loadTif(filepath);
    otherwise
        error('loadFiles:unsupportedFormat', ...
            'Unsupported file type: %s. Supported types are .mat, .tif, .tiff.', ext);
end
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

function data = loadTif(filepath)
info = imfinfo(filepath);
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
