function varargout = matVis(varargin)
% matVis — Multi-dimensional data viewer (v2.0)
% Usage:
%   matVis(data)                                         % single dataset
%   matVis(data1, data2, ...)                            % multiple datasets
%   matVis(data1, data2, ..., 'datasetNames', {'A','B'}) % with names
%   matVis(data, 'dimNames', {'X','Y','Z'}, ...)         % with dim labels
%   handles = matVis(...)

t0_matvis_ = tic;

baseDir = fileparts(mfilename('fullpath'));
% addpath rehashes the toolbox cache (~0.3 s) — only do it when needed
if isempty(which('MatVisModel')) || isempty(which('parseArgs')) || isempty(which('MatVisMainWindow'))
    addpath(fullfile(baseDir, 'core'));
    addpath(fullfile(baseDir, 'ui'));
    addpath(fullfile(baseDir, 'io'));
end
fprintf('[matVis] addpath:         %.3f s\n', toc(t0_matvis_));

% Split leading numeric arrays from name-value pairs
nLeading = 0;
for k = 1:numel(varargin)
    if isnumeric(varargin{k}) && ~isscalar(varargin{k})
        nLeading = k;
    else
        break;
    end
end

if nLeading == 0
    error('matVis:noData', 'At least one numeric data array must be provided.');
end

datasets  = varargin(1:nLeading);
nvPairs   = varargin(nLeading+1:end);

t1_ = tic;
args = parseArgs(datasets, nvPairs{:});
fprintf('[matVis] parseArgs:       %.3f s\n', toc(t1_));

t2_ = tic;
model = MatVisModel(args.data, args.datasetNames);
if ~isempty(args.dimNames);  model.DimNames  = args.dimNames;  end
if ~isempty(args.dimUnits);  model.DimUnits  = args.dimUnits;  end
if ~isempty(args.dimScale);  model.DimScale  = args.dimScale;  end
if ~isempty(args.alphaMap);  model.SetAlphaMaps(args.alphaMap); end
model.applyStartPar(args.startPar);
fprintf('[matVis] MatVisModel:     %.3f s\n', toc(t2_));

t3_ = tic;
mw = MatVisMainWindow(model);
fprintf('[matVis] MatVisMainWindow:%.3f s  (includes sub-section detail above)\n', toc(t3_));
fprintf('[matVis] Total:           %.3f s\n\n', toc(t0_matvis_));

if nargout > 0
    varargout{1} = mw;
end
end
