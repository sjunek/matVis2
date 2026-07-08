function [datasets, dsMeta] = importMultiFile(filepaths, varargin)
% importMultiFile  Load one or more image files and combine them for matVis.
%
%   [datasets, dsMeta] = importMultiFile(filepaths)
%   [datasets, dsMeta] = importMultiFile(filepaths, 'Mode', modeStr)
%   [datasets, dsMeta] = importMultiFile()    opens a multi-select file dialog
%   [datasets, dsMeta] = importMultiFile({})  opens a multi-select file dialog
%
%   filepaths   cell array of file paths (any format loadFiles supports), a
%               single char/string path, or empty/omitted to prompt with the
%               OS file picker (uigetfile 'MultiSelect','on').
%
%   Name-Value
%     Mode      'ask' (default) — when more than one file is selected, shows
%               a dialog asking whether to load the files as separate
%               datasets or concatenate them into one along a new trailing
%               dimension. 'separate' / 'concatenate' bypass the dialog
%               (for programmatic/test use). Ignored for a single file.
%
%   Every loaded array must end up the same size. If they don't, each array
%   is cropped to the smallest common size along every dimension and a
%   warning ('importMultiFile:sizeMismatch') lists what was cropped.
%
%   Outputs
%     datasets  cell array of numeric arrays (a single entry when concatenated)
%     dsMeta    struct with fields dimNames/dimScale/dimUnits/datasetNames,
%               ready to splice into parseArgs's name-value pairs.
%
%   See also loadFiles, parseArgs.

p = inputParser;
p.FunctionName = 'importMultiFile';
p.addParameter('Mode', 'ask', @(x) ischar(x) || (isstring(x) && isscalar(x)));
p.parse(varargin{:});
mode = lower(char(p.Results.Mode));
if ~ismember(mode, {'ask', 'separate', 'concatenate'})
    error('importMultiFile:badMode', 'Mode must be ''ask'', ''separate'', or ''concatenate''.');
end

if nargin < 1 || isempty(filepaths)
    [fnames, fpath] = uigetfile(buildFileFilter(), ...
        'Select one or more files', 'MultiSelect', 'on');
    if isequal(fnames, 0)
        error('importMultiFile:cancelled', 'File selection cancelled.');
    end
    if ischar(fnames)
        fnames = {fnames};
    end
    filepaths = cellfun(@(f) fullfile(fpath, f), fnames, 'UniformOutput', false);
elseif ischar(filepaths) || isstring(filepaths)
    filepaths = cellstr(filepaths);
end

nFiles = numel(filepaths);
data  = cell(1, nFiles);
fmeta = cell(1, nFiles);
for k = 1:nFiles
    [data{k}, fmeta{k}] = loadFiles(filepaths{k});
end

% ----------------------------------------------------- reconcile dimensions
maxNd = max(cellfun(@ndims, data));
sizes = ones(nFiles, maxNd);
for k = 1:nFiles
    sz = size(data{k});
    sizes(k, 1:numel(sz)) = sz;
end
commonSz = min(sizes, [], 1);
mismatched = any(sizes ~= commonSz, 2);
if any(mismatched)
    lines = arrayfun(@(k) sprintf('  %s: [%s]', filepaths{k}, num2str(sizes(k, :))), ...
        find(mismatched), 'UniformOutput', false);
    warning('importMultiFile:sizeMismatch', ...
        ['Selected files do not all have the same size; cropping every file to the ' ...
         'smallest common size [%s].\n%s'], num2str(commonSz), strjoin(lines, newline));
    idx = arrayfun(@(n) 1:n, commonSz, 'UniformOutput', false);
    for k = 1:nFiles
        data{k} = data{k}(idx{:});
    end
end

% ------------------------------------------------- separate vs concatenate
if nFiles == 1
    decision = 'separate';
elseif ~strcmp(mode, 'ask')
    decision = mode;
else
    choice = questdlg( ...
        sprintf('%d files selected. Load as separate datasets, or concatenate into one?', nFiles), ...
        'Import files', 'Separate datasets', 'Concatenate', 'Separate datasets');
    if isempty(choice) || strcmp(choice, 'Separate datasets')
        decision = 'separate';
    else
        decision = 'concatenate';
    end
end

baseMeta  = fmeta{1};
baseNames = padDefault(baseMeta.dimNames, maxNd, @(i) sprintf('Dim%d', i));
baseScale = padDefault(baseMeta.dimScale, maxNd, @(i) 1);
baseUnits = padDefault(baseMeta.dimUnits, maxNd, @(i) '');

if strcmp(decision, 'concatenate')
    catDim = maxNd + 1;
    datasets = {cat(catDim, data{:})};
    dsMeta.dimNames = [baseNames, {'Series'}];
    dsMeta.dimScale = [baseScale, {1:nFiles}];
    dsMeta.dimUnits = [baseUnits, {''}];
    dsMeta.datasetNames = {'Concatenated'};
else
    datasets = data;
    dsMeta.dimNames = baseNames;
    dsMeta.dimScale = baseScale;
    dsMeta.dimUnits = baseUnits;
    dsMeta.datasetNames = cellfun(@defaultName, filepaths, 'UniformOutput', false);
end
end

% =============================================================================
function out = padDefault(c, n, defaultFn)
out = cell(1, n);
for i = 1:n
    if i <= numel(c) && ~isempty(c{i})
        out{i} = c{i};
    else
        out{i} = defaultFn(i);
    end
end
end

% =============================================================================
function name = defaultName(filepath)
[~, name] = fileparts(filepath);
end
