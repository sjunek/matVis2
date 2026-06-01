function varargout = matVis(data, varargin)
% matVis — Multi-dimensional data viewer (v2.0)
% Usage:
%   matVis(data)
%   matVis(data, 'dimNames', {'X','Y','Z'}, 'gamma', 0.8, ...)
%   matVis(data, 'startPar', {'xySel',1,'gamma',0.8}, ...)
%   handles = matVis(data, ...)

baseDir = fileparts(mfilename('fullpath'));
addpath(fullfile(baseDir, 'core'));
addpath(fullfile(baseDir, 'ui'));
addpath(fullfile(baseDir, 'io'));

args = parseArgs(data, varargin{:});

model = MatVisModel(args.data);

if ~isempty(args.dimNames);  model.DimNames  = args.dimNames;  end
if ~isempty(args.dimUnits);  model.DimUnits  = args.dimUnits;  end
if ~isempty(args.dimScale);  model.DimScale  = args.dimScale;  end

model.applyStartPar(args.startPar);

mw = MatVisMainWindow(model);

if nargout > 0
    varargout{1} = mw;
end
end
