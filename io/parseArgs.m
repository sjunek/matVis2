function args = parseArgs(data, varargin)
% parseArgs  Validate and collect matVis2.0 launch arguments.
%
%   args = parseArgs(data)
%   args = parseArgs(data, Name, Value, ...)
%   args = parseArgs({data1,data2,...}, Name, Value, ...)
%
%   Required
%     data          numeric array, non-empty;
%                   OR cell array of numeric arrays with identical dimensions
%
%   Name-Value pairs
%     dimNames      cell of strings, length == ndims(data)
%     dimUnits      cell of strings, length == ndims(data)
%     dimScale      cell of numeric vectors, length == ndims(data)
%     datasetNames  cell of strings, length == number of datasets
%     fileMetadata  cell of structs (or []), length == number of datasets;
%                   per-dataset acquisition metadata (microscope/objective/
%                   channel wavelengths/date) as produced by loadFiles/
%                   importMultiFile, for display in MatVisMetadataWin
%     matNames      cell of strings
%     alphaMap      numeric array same size as data (applied to every
%                   dataset), or cell array with one map per dataset;
%                   normalized to a 1×K cell array (empty if unused)
%     colorBarLabel string
%     startPar      cell of property-value pairs, e.g. {'gamma',0.8,'cmap',5}
%     debug         logical scalar

p = inputParser;
p.FunctionName = 'parseArgs';
p.CaseSensitive = false;

p.addRequired('data', @(x) isDataArg(x) || ...
    (iscell(x) && ~isempty(x) && all(cellfun(@isDataArg, x(:)))));

p.addParameter('dimNames',      {}, @(x) iscellstr(x) || isstring(x));
p.addParameter('dimUnits',      {}, @(x) iscellstr(x) || isstring(x));
p.addParameter('dimScale',      {}, @(x) iscell(x) && all(cellfun(@isnumeric, x)));
p.addParameter('datasetNames',  {}, @(x) iscellstr(x) || isstring(x));
p.addParameter('fileMetadata',  {}, @(x) iscell(x));
p.addParameter('matNames',      {}, @(x) iscellstr(x) || isstring(x));
p.addParameter('alphaMap',      {}, @(x) isnumeric(x) || ...
    (iscell(x) && all(cellfun(@isnumeric, x(:)))));
p.addParameter('colorBarLabel', '', @(x) ischar(x) || isstring(x));
p.addParameter('startPar',      {}, @(x) iscell(x) && mod(numel(x), 2) == 0);
p.addParameter('debug',       false, @(x) islogical(x) && isscalar(x));

p.parse(data, varargin{:});
r = p.Results;

% Normalize data to cell array
if ~iscell(r.data)
    r.data = {r.data};
end

% Validate all datasets have identical dimensions
refSz = dataSize(r.data{1});
for k = 2:numel(r.data)
    if ~isequal(dataSize(r.data{k}), refSz)
        error('parseArgs:dimMismatch', ...
            'All datasets must have identical dimensions. Dataset %d has size [%s] but dataset 1 has size [%s].', ...
            k, num2str(dataSize(r.data{k})), num2str(refSz));
    end
end

% Squeeze out singleton dimensions: a dimension of size 1 has nothing to
% navigate, and the position panel cannot show a one-step slider.  Only
% in-memory arrays are reshaped (free -- no copy); the file sources already
% drop their singleton axes.  At least two dimensions are kept, so a lone
% 1xN row stays an image.  Per-dimension arguments given for the original
% dimensions are reduced to match.
origSz = refSz;
keep = squeezeKeep(refSz);
if ~all(keep) && all(cellfun(@isnumeric, r.data))
    refSz = origSz(keep);
    for k = 1:numel(r.data)
        r.data{k} = reshape(r.data{k}, refSz);
    end
    r.dimNames = dropDims(r.dimNames, keep);
    r.dimUnits = dropDims(r.dimUnits, keep);
    r.dimScale = dropDims(r.dimScale, keep);
else
    keep = true(1, numel(origSz));
end

n = numel(refSz);
K = numel(r.data);

r.dimNames = padCellStr(r.dimNames, n, @(i) sprintf('Dim%d', i));
r.dimUnits = padCellStr(r.dimUnits, n, @(i) '');
r.dimScale = padCellVec(r.dimScale, n, r.data{1});

% Dataset names — pad/generate as needed
if isstring(r.datasetNames)
    r.datasetNames = cellstr(r.datasetNames);
end
r.datasetNames = padCellStr(r.datasetNames, K, @(i) sprintf('Dataset %d', i));
r.fileMetadata = padCell(r.fileMetadata, K, @(i) []);

r.startPar = cellPairsToStruct(r.startPar);
if ~all(keep)
    r.startPar = remapStartPar(r.startPar, keep);
end

% Normalize alphaMap to a 1×K cell (one map per dataset).  A single
% numeric map is shared across all datasets.  On size mismatch the maps
% are ignored with a warning, matching the original matVis behaviour.
if isempty(r.alphaMap)
    r.alphaMap = {};
else
    if isnumeric(r.alphaMap)
        maps = repmat({r.alphaMap}, 1, K);
    else
        maps = r.alphaMap(:)';
        if numel(maps) == 1
            maps = repmat(maps, 1, K);
        end
    end
    ok = numel(maps) == K;
    for k = 1:numel(maps)
        if ~all(keep) && isnumeric(maps{k}) && isequal(size(maps{k}), origSz)
            maps{k} = reshape(maps{k}, refSz);   % squeezed like the data
        end
        ok = ok && isequal(dataSize(maps{k}), refSz);
    end
    if ok
        r.alphaMap = maps;
    else
        warning('parseArgs:alphaMapMismatch', ...
            ['''alphaMap'' must match the data size [%s] ' ...
             '(one map, or one per dataset). ''alphaMap'' ignored.'], ...
            num2str(refSz));
        r.alphaMap = {};
    end
end

args = r;
end

% ---------------------------------------------------------------------------

function out = padCellStr(c, n, defaultFn)
% Ensure c is a row cell of strings with exactly n entries.
if isstring(c)
    c = cellstr(c);
end
out = cell(1, n);
for i = 1:n
    if i <= numel(c) && ~isempty(c{i})
        out{i} = char(c{i});
    else
        out{i} = defaultFn(i);
    end
end
end

function tf = isDataArg(x)
% A dataset may arrive as a numeric array or as a MatVisDataSource that reads
% it from a file on demand; both describe the same thing downstream.
tf = (isnumeric(x) && ~isempty(x)) || isa(x, 'MatVisDataSource');
end

function keep = squeezeKeep(sz)
% Logical mask of the dimensions to keep when squeezing size SZ: every
% non-singleton one, topped up with the leading singletons to two in all.
keep = sz ~= 1;
if nnz(keep) < 2
    keep(find(~keep, 2 - nnz(keep))) = true;
end
end

function c = dropDims(c, keep)
% Reduce a per-dimension list to the dimensions KEEP retains.  A full list
% (one entry per original dimension) is masked; a list already of the
% squeezed length is taken to describe the squeezed dimensions; a shorter
% list covers the leading dimensions and is masked over those.
if isstring(c)
    c = cellstr(c);
end
m = numel(c);
if m == numel(keep)
    c = c(keep);
elseif m ~= nnz(keep) && m < numel(keep)
    c = c(keep(1:m));
end
end

function sp = remapStartPar(sp, keep)
% Translate the dimension-indexed startPar fields from the original to the
% squeezed dimension numbering.  An xySel naming a dropped dimension is
% discarded, leaving the default image dimensions.
newIdx = cumsum(keep);
n = numel(keep);
if isfield(sp, 'xySel')
    v = sp.xySel;
    if isstruct(v)
        for f = intersect(fieldnames(v)', {'x', 'y'})
            d = v.(f{1});
            if isscalar(d) && d >= 1 && d <= n && keep(d)
                v.(f{1}) = newIdx(d);
            else
                v = rmfield(v, f{1});
            end
        end
        sp.xySel = v;
    elseif all(v(:) >= 1 & v(:) <= n & v(:) == round(v(:))) && all(keep(v(:)))
        sp.xySel = newIdx(v);
    else
        sp = rmfield(sp, 'xySel');
    end
end
if isfield(sp, 'currPos') && numel(sp.currPos) == n
    sp.currPos = sp.currPos(keep);
end
if isfield(sp, 'zoomVal') && size(sp.zoomVal, 1) == n
    sp.zoomVal = sp.zoomVal(keep, :);
end
end

function sz = dataSize(x)
if isa(x, 'MatVisDataSource')
    sz = x.Size;
else
    sz = size(x);
end
end

function out = padCellVec(c, n, data)
% Ensure c is a row cell of per-index coordinate vectors with exactly n
% entries.  Each supplied entry may be either
%   * a full coordinate vector of length size(data,i), used verbatim, or
%   * a scalar per-index scaling factor (e.g. µm/pixel), expanded to the
%     coordinate vector (0:size-1)*factor.
% Missing or mismatched entries default to the plain index vector 1:size.
sz = dataSize(data);
out = cell(1, n);
for i = 1:n
    if i <= numel(c) && ~isempty(c{i})
        v = c{i};
        if isscalar(v)
            out{i} = (0:sz(i)-1) * double(v);
        elseif numel(v) == sz(i)
            out{i} = v;
        else
            warning('parseArgs:dimScaleMismatch', ...
                ['''dimScale'' entry %d has %d elements but dimension %d ' ...
                 'has size %d; using index coordinates instead.'], ...
                i, numel(v), i, sz(i));
            out{i} = 1:sz(i);
        end
    else
        out{i} = 1:sz(i);
    end
end
end

function out = padCell(c, n, defaultFn)
% Ensure c is a row cell with exactly n entries, filling any missing
% trailing entries via defaultFn(index). Unlike padCellStr, values are
% passed through as-is (not coerced to char).
out = cell(1, n);
for i = 1:n
    if i <= numel(c)
        out{i} = c{i};
    else
        out{i} = defaultFn(i);
    end
end
end

function s = cellPairsToStruct(c)
% Convert {'key1',val1,'key2',val2,...} to a struct.
s = struct();
for i = 1:2:numel(c)
    key = c{i};
    if ~ischar(key) && ~isstring(key)
        error('parseArgs:startPar:invalidKey', ...
              'startPar keys must be character vectors or strings.');
    end
    s.(char(key)) = c{i+1};
end
end
