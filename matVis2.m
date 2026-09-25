function varargout = matVis2(varargin)
% matVis2 — Multi-dimensional data viewer (v2.0)
% Usage:
%   matVis2(data)                                         % single dataset
%   matVis2(data1, data2, ...)                            % multiple datasets
%   matVis2(data1, data2, ..., 'datasetNames', {'A','B'}) % with names
%   matVis2(data, 'dimNames', {'X','Y','Z'}, ...)         % with dim labels
%   matVis2()                                             % pick file(s) to open
%   matVis2(filepath)                                     % open one file
%   matVis2({file1, file2, ...})                          % open multiple files
%   matVis2(filepath, 'dimNames', {...}, ...)             % override auto-detected metadata
%   handles = matVis2(...)
%
%   File-based calls accept anything io/loadFiles supports (.mat, .tif/.tiff
%   incl. multi-page and OME-TIFF, .jpg, .png, .bmp) via io/importMultiFile.
%   OME-TIFF dimension names/scale/units are read automatically. Selecting
%   multiple files prompts for "separate datasets" vs "concatenate"; pass
%   'Mode', 'separate'|'concatenate' to skip that prompt.

t0_matvis_ = tic;

baseDir = fileparts(mfilename('fullpath'));
coreDir = fullfile(baseDir, 'core');
uiDir   = fullfile(baseDir, 'ui');
ioDir   = fullfile(baseDir, 'io');

% This machine has several sibling matVis checkouts on the path, each with its
% own core/ui/io. Make sure OUR sources win resolution: addpath prepends, so
% re-adding puts them at the front. Only pay the rehash cost (~0.3 s) when a
% source is missing or the wrong copy currently resolves.
needPath = ~strcmpi(which('MatVisModel'),      fullfile(coreDir, 'MatVisModel.m'))      || ...
           ~strcmpi(which('MatVisMainWindow'), fullfile(uiDir,   'MatVisMainWindow.m')) || ...
           ~strcmpi(which('parseArgs'),        fullfile(ioDir,   'parseArgs.m'))        || ...
           ~strcmpi(which('matVisConfig'),     fullfile(ioDir,   'matVisConfig.m'));
if needPath
    addpath(coreDir);
    addpath(uiDir);
    addpath(ioDir);
    % A class already loaded in memory is NOT replaced by addpath — drop the
    % stale definitions so they reload from the paths just prepended. (This is
    % a no-op if an instance is still alive, handled by the check below.)
    for cls = {'MatVisModel', 'MatVisRender', 'MatVisMainWindow'}
        try, clear(cls{1}); catch, end
    end
end
fprintf('[matVis2] addpath:         %.3f s\n', toc(t0_matvis_));

% Verify the MatVisModel MATLAB will actually use is this checkout's version.
% If a stale copy is pinned in memory (e.g. by an open matVis2 window from
% another checkout), the clear above is a no-op and we must say so plainly
% rather than fail cryptically later inside MatVisMainWindow.
mc = meta.class.fromName('MatVisModel');
if isempty(mc) || ~any(strcmp({mc.MethodList.Name}, 'pixelSize'))
    error('matVis2:staleClass', ...
        ['A stale/incompatible MatVisModel is loaded in memory and cannot be ' ...
         'replaced while in use.\n' ...
         'Reset MATLAB and try again:\n' ...
         '    close all force;  clear classes\n' ...
         'then call matVis2(...) once more (expected file: %s).'], ...
        fullfile(coreDir, 'MatVisModel.m'));
end

% A no-arg call, or a char/string/cellstr leading argument, means "load from
% file(s)" rather than "here is already-loaded data".
fileMode = nargin == 0 || ...
    (ischar(varargin{1}) || isstring(varargin{1}) || iscellstr(varargin{1}));

if fileMode
    if nargin == 0
        filePathsArg = {};
        restArgs = {};
    else
        filePathsArg = varargin{1};
        restArgs = varargin(2:end);
    end

    % Pull out a 'Mode' override for importMultiFile; everything else is
    % forwarded to parseArgs untouched.
    importNVs = {};
    modeIdx = find(cellfun(@(x) (ischar(x) || isstring(x)) && strcmpi(x, 'Mode'), restArgs));
    if ~isempty(modeIdx) && modeIdx(1) < numel(restArgs)
        mi = modeIdx(1);
        importNVs = {'Mode', restArgs{mi+1}};
        restArgs([mi, mi+1]) = [];
    end

    % 'LoadMode': 'auto' (default) reads the file in full unless it is large
    % or slow enough that matVisLoadPolicy recommends otherwise; 'lazy' and
    % 'full' force the choice, which is what a script wants.
    loadMode = 'auto';
    lmIdx = find(cellfun(@(x) (ischar(x) || isstring(x)) && strcmpi(x, 'LoadMode'), restArgs));
    if ~isempty(lmIdx) && lmIdx(1) < numel(restArgs)
        li = lmIdx(1);
        loadMode = lower(char(restArgs{li+1}));
        restArgs([li, li+1]) = [];
    end
    if ~ismember(loadMode, {'auto', 'lazy', 'full'})
        error('matVis2:badLoadMode', ...
            'LoadMode must be ''auto'', ''lazy'' or ''full''.');
    end

    t1a_ = tic;
    [datasets, fm] = matVisOpenDatasets(filePathsArg, importNVs, loadMode);
    fprintf('[matVis2] load:            %.3f s\n', toc(t1a_));

    nvPairs = mergeDefaultNV( ...
        {'dimNames', fm.dimNames, 'dimUnits', fm.dimUnits, 'dimScale', fm.dimScale, ...
         'datasetNames', fm.datasetNames, 'fileMetadata', fm.fileMetadata}, restArgs);
else
    % Split leading datasets from name-value pairs.  A dataset is a numeric
    % array or a MatVisDataSource that reads one from a file on demand --
    % nothing downstream tells them apart, and neither may this.  Opening a
    % large file from a running window hands the new window exactly such a
    % source, and accepting only arrays here rejected it.
    nLeading = 0;
    for k = 1:numel(varargin)
        if (isnumeric(varargin{k}) && ~isscalar(varargin{k})) || ...
                isa(varargin{k}, 'MatVisDataSource')
            nLeading = k;
        else
            break;
        end
    end

    if nLeading == 0
        error('matVis2:noData', ...
            'At least one data array or MatVisDataSource must be provided.');
    end

    datasets  = varargin(1:nLeading);
    nvPairs   = varargin(nLeading+1:end);

    % Default dataset names to the caller's workspace variable names (e.g.
    % matVis2(myStack) titles windows "myStack" instead of "Dataset 1").
    % Arguments passed as expressions/ans have no name and fall back to
    % parseArgs' 'Dataset %d' default; an explicit 'datasetNames' NV pair
    % always wins.
    defaultNames = cell(1, nLeading);
    for k = 1:nLeading
        defaultNames{k} = inputname(k);
    end
    if any(~cellfun(@isempty, defaultNames))
        nvPairs = mergeDefaultNV({'datasetNames', defaultNames}, nvPairs);
    end
end

t1_ = tic;
args = parseArgs(datasets, nvPairs{:});
fprintf('[matVis2] parseArgs:       %.3f s\n', toc(t1_));

t2_ = tic;
model = MatVisModel(args.data, args.datasetNames);
if ~isempty(args.dimNames);  model.DimNames  = args.dimNames;  end
if ~isempty(args.dimUnits);  model.DimUnits  = args.dimUnits;  end
if ~isempty(args.dimScale);  model.DimScale  = args.dimScale;  end
if ~isempty(args.fileMetadata); model.FileMetadata = args.fileMetadata; end
if ~isempty(args.alphaMap);  model.SetAlphaMaps(args.alphaMap); end
model.applyStartPar(args.startPar);
fprintf('[matVis2] MatVisModel:     %.3f s\n', toc(t2_));

if ~confirmUniformData(model)
    if nargout > 0, varargout{1} = []; end
    return;
end

t3_ = tic;
mw = MatVisMainWindow(model);
fprintf('[matVis2] MatVisMainWindow:%.3f s  (includes sub-section detail above)\n', toc(t3_));
fprintf('[matVis2] Total:           %.3f s\n\n', toc(t0_matvis_));

if nargout > 0
    varargout{1} = mw;
end
end

% =============================================================================
function tf = confirmUniformData(model)
% A dataset in which every entry is the same value has nothing to display:
% no contrast, an empty histogram, a blank image.  That is usually a sign
% that the wrong file or the wrong channel was picked, so say so and let the
% user decide rather than opening a window onto nothing.
%
% It is worth asking rather than merely warning, because on a large file the
% window costs seconds to build.
tf = true;
uniform = false(1, model.NumDatasets);
for k = 1:model.NumDatasets
    [lo, hi] = model.Datasets{k}.valueRange();
    uniform(k) = ~(hi > lo);
end
if ~any(uniform)
    return;
end

names = model.DatasetNames;
if numel(names) ~= model.NumDatasets
    names = arrayfun(@(i) sprintf('Dataset %d', i), 1:model.NumDatasets, ...
        'UniformOutput', false);
end
[val, ~] = model.Datasets{find(uniform, 1)}.valueRange();

if all(uniform) && model.NumDatasets == 1
    body = sprintf(['Every value in this dataset is %g, so there is nothing ' ...
        'to see: no contrast, and an empty histogram.'], val);
else
    body = sprintf(['Every value is identical in: %s.  Those datasets have ' ...
        'no contrast and an empty histogram.'], strjoin(names(uniform), ', '));
end

if ~usejava('desktop')
    % Non-interactive: say it and carry on, rather than block a script on a
    % dialog nobody can answer.
    warning('matVis2:uniformData', '%s Opening it anyway.', body);
    return;
end

choice = questdlg([body newline newline 'Open it anyway?'], 'Uniform data', ...
    'Open anyway', 'Cancel', 'Open anyway');
tf = strcmp(choice, 'Open anyway');
end

% =============================================================================
function merged = mergeDefaultNV(defaultsCell, userCell)
% Prepend each Name/Value pair in defaultsCell whose Name isn't already
% present (case-insensitively) in userCell — user-supplied values always win.
userKeys = userCell(1:2:end);
merged = userCell;
for i = 1:2:numel(defaultsCell)
    key = defaultsCell{i};
    if ~any(cellfun(@(k) (ischar(k) || isstring(k)) && strcmpi(k, key), userKeys))
        merged = [merged, defaultsCell(i:i+1)]; %#ok<AGROW>
    end
end
end
