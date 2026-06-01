function args = parseArgs(data, varargin)
% parseArgs  Validate and collect matVis2.0 launch arguments.
%
%   args = parseArgs(data)
%   args = parseArgs(data, Name, Value, ...)
%
%   Required
%     data          numeric array, non-empty
%
%   Name-Value pairs
%     dimNames      cell of strings, length == ndims(data)
%     dimUnits      cell of strings, length == ndims(data)
%     dimScale      cell of numeric vectors, length == ndims(data)
%     matNames      cell of strings
%     alphaMap      numeric array same size as data, or []
%     colorBarLabel string
%     startPar      cell of property-value pairs, e.g. {'gamma',0.8,'cmap',5}
%     debug         logical scalar

p = inputParser;
p.FunctionName = 'parseArgs';
p.CaseSensitive = false;

p.addRequired('data', @(x) validateattributes(x, {'numeric'}, {'nonempty'}, 'parseArgs', 'data'));

p.addParameter('dimNames',      {}, @(x) iscellstr(x) || isstring(x));
p.addParameter('dimUnits',      {}, @(x) iscellstr(x) || isstring(x));
p.addParameter('dimScale',      {}, @(x) iscell(x) && all(cellfun(@isnumeric, x)));
p.addParameter('matNames',      {}, @(x) iscellstr(x) || isstring(x));
p.addParameter('alphaMap',      [], @(x) isnumeric(x));
p.addParameter('colorBarLabel', '', @(x) ischar(x) || isstring(x));
p.addParameter('startPar',      {}, @(x) iscell(x) && mod(numel(x), 2) == 0);
p.addParameter('debug',       false, @(x) islogical(x) && isscalar(x));

p.parse(data, varargin{:});
r = p.Results;

n = ndims(r.data);

r.dimNames = padCellStr(r.dimNames, n, @(i) sprintf('Dim%d', i));
r.dimUnits = padCellStr(r.dimUnits, n, @(i) '');
r.dimScale = padCellVec(r.dimScale, n, r.data);

r.startPar = cellPairsToStruct(r.startPar);

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
    if i <= numel(c)
        out{i} = char(c{i});
    else
        out{i} = defaultFn(i);
    end
end
end

function out = padCellVec(c, n, data)
% Ensure c is a row cell of numeric vectors with exactly n entries,
% defaulting to a linearly-spaced 1:size(data,dim) vector per dimension.
sz = size(data);
out = cell(1, n);
for i = 1:n
    if i <= numel(c) && ~isempty(c{i})
        out{i} = c{i};
    else
        out{i} = 1:sz(i);
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
