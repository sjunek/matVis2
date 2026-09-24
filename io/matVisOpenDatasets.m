function [datasets, fm] = matVisOpenDatasets(filePathsArg, importNVs, loadMode)
%matVisOpenDatasets  Open file(s) for matVis, on demand when that is better.
%
%   [datasets, fm] = matVisOpenDatasets(filePathsArg, importNVs, loadMode)
%
%   filePathsArg : path, cellstr of paths, or {} to show the file dialog
%   importNVs    : name-value pairs forwarded to importMultiFile (e.g. Mode)
%   loadMode     : 'auto' | 'lazy' | 'full'
%
%   datasets : cell of MatVisDataSource / numeric arrays, ready for parseArgs
%   fm       : struct with dimNames/dimUnits/dimScale/datasetNames/fileMetadata
%
%   Split out of matVis2 so that a running viewer can open data the same way
%   the entry point does -- same policy, same dialog, same lazy handling --
%   instead of carrying a second, drifting copy of it.
%
%   See also matVis2, matVisOpenSource, matVisLoadPolicy, importMultiFile.

% Load the selected file(s), on demand when that is the better choice.
%
% Lazy opening is per file and all-or-nothing across the selection: mixing a
% file-backed dataset with a fully loaded one would make the two behave
% differently in the same window. Concatenation is excluded too -- it builds
% one array out of several files, which is precisely the materialization
% being avoided.
% The file dialog is shown here rather than inside importMultiFile, because
% how to open a file can only be decided once it has been named -- and asking
% twice, or asking and then ignoring the answer, is worse than either.  Every
% fallback below therefore passes the concrete paths on, not the original
% (possibly empty) argument.
paths = normalizePaths(filePathsArg);
if isempty(paths)
    paths = matVisPickFiles();
end

if strcmp(loadMode, 'full')
    [datasets, fm] = importMultiFile(paths, importNVs{:});
    return;
end

% Several files still go through importMultiFile unless the caller has
% already said they are separate datasets: 'ask' means a dialog that only it
% knows how to show, and 'concatenate' builds one array out of the lot, which
% is exactly the materialization being avoided.
if numel(paths) > 1 && ~any(strcmpi(importNVs, 'separate'))
    [datasets, fm] = importMultiFile(paths, importNVs{:});
    return;
end

srcs = cell(1, numel(paths));
metas = cell(1, numel(paths));
for k = 1:numel(paths)
    [srcs{k}, metas{k}] = matVisOpenSource(paths{k});
    if isempty(srcs{k})
        % This one has no on-demand reader (a .mat, a Zstandard TIFF, a format
        % Bio-Formats cannot open). The others may still be readable, but a
        % window cannot mix the two: whole-dataset numbers would be exact for
        % one dataset and sampled for another, with one label over both. So
        % the selection falls back together -- and importMultiFile reports
        % whichever file is the real problem.
        cellfun(@(s) closeIfSource(s), srcs);
        [datasets, fm] = importMultiFile(paths, importNVs{:});
        return;
    end
end

% Decide, now that the real sizes are known rather than guessed at.
totalBytes = sum(cellfun(@(s) s.byteCount(), srcs));
estSeconds = sum(cellfun(@(s) s.Capabilities.PlaneReadCost * prod(s.Size(3:end)), srcs));
mustBeLazy = ~all(cellfun(@(s) s.FullLoadFeasible, srcs));
if strcmp(loadMode, 'auto') && ~mustBeLazy
    d = matVisLoadPolicy(struct('bytes', totalBytes, 'estSeconds', estSeconds));
    decision = d.recommend;
    if d.shouldAsk
        % A standing rule wins over asking again; 'ask' is the default and
        % only applies to files big enough to have tripped a threshold, so a
        % small dataset is never held up by a dialog.
        pref = getpref('matVis2', 'LoadPolicy', 'ask');
        if ismember(pref, {'lazy', 'full'})
            decision = pref;
        elseif usejava('desktop')
            [decision, remember] = MatVisLoadModeDlg(struct( ...
                'names',      {cellfun(@nameOf, paths, 'UniformOutput', false)}, ...
                'dimsText',   dimsText(srcs{1}), ...
                'bytes',      totalBytes, ...
                'availBytes', d.availableBytes, ...
                'estSeconds', estSeconds, ...
                'stepMs',     srcs{1}.Capabilities.PlaneReadCost * 1000, ...
                'recommend',  d.recommend, ...
                'canFull',    true));
            if strcmp(decision, 'cancel')
                cellfun(@(s) closeIfSource(s), srcs);
                error('matVis2:cancelled', 'Opening cancelled.');
            end
            if ~strcmp(remember, 'ask')
                setpref('matVis2', 'LoadPolicy', remember);
            end
        end
    end
    if strcmp(decision, 'full')
        cellfun(@(s) closeIfSource(s), srcs);
        [datasets, fm] = importMultiFile(paths, importNVs{:});
        return;
    end
    for r = 1:numel(d.reasons)
        fprintf('[matVis2] %s\n', d.reasons{r});
    end
    fprintf(['[matVis2] Opening in memory-efficient mode: planes are read as you\n' ...
             '          navigate, and the global histogram, 3-D view and traces\n' ...
             '          come from a reduced-resolution overview.\n' ...
             '          Pass ''LoadMode'',''full'' to read it all into memory instead.\n']);
end

datasets = srcs;
names = cell(1, numel(paths));
for k = 1:numel(paths)
    [~, nm, xt] = fileparts(paths{k});
    names{k} = [nm xt];
end
m1 = metas{1};
fm = struct('dimNames', {m1.dimNames}, 'dimUnits', {m1.dimUnits}, ...
    'dimScale', {m1.dimScale}, 'datasetNames', {names}, ...
    'fileMetadata', {cellfun(@(m) m.instrument, metas, 'UniformOutput', false)});
end

% =============================================================================
function paths = normalizePaths(filePathsArg)
if isempty(filePathsArg)
    paths = {};
elseif ischar(filePathsArg) || isstring(filePathsArg)
    paths = cellstr(filePathsArg);
else
    paths = filePathsArg;
end
end

% =============================================================================
function n = nameOf(p)
[~, nm, xt] = fileparts(p);
n = [nm xt];
end

% =============================================================================
function s = dimsText(src)
% "1924 x 1920 x 57 x 15, uint16" -- the shape, for the load dialog.
s = sprintf('%s, %s', strjoin(arrayfun(@(v) sprintf('%d', v), src.Size, ...
    'UniformOutput', false), ' x '), src.ClassName);
end

% =============================================================================
function closeIfSource(s)
if ~isempty(s) && isa(s, 'MatVisLazySource')
    s.closeSource();
end
end

