function [pos, vis, mon, savedN] = matVisConfigLayout(config, n)
% matVisConfigLayout  The saved window layout that fits n datasets.
%
%   [pos, vis, mon, savedN] = matVisConfigLayout(config, n)
%
%   pos     window positions struct (Main, Image1, Zoom1, ...), [] if none
%   vis     window visibility struct, [] if none
%   mon     monitor layout the positions were saved under, [] if unknown
%   savedN  number of datasets the positions were saved for
%
% A config keeps one layout for a single dataset (windowPositions,
% windowVisibility, monitorPositions) and one for several (the same names
% with "Multi" appended, plus numDatasetsMulti).  Files written before the
% two were separated (no layoutVersion) hold one layout only, for whatever
% number of datasets saved it last (numDatasets): it counts for the case it
% was saved in.  With no layout for several datasets, their windows are
% still shown or hidden as the single-dataset layout has them.

pos = [];  vis = [];  mon = [];  savedN = 0;
separated = isfield(config, 'layoutVersion') && config.layoutVersion >= 2;

if n > 1 && isfield(config, 'windowPositionsMulti')
    pos    = config.windowPositionsMulti;
    savedN = config.numDatasetsMulti;
    vis    = field_(config, 'windowVisibilityMulti');
    mon    = field_(config, 'monitorPositionsMulti');
    return;
end

legacyN = 1;
if ~separated && isfield(config, 'numDatasets'), legacyN = config.numDatasets; end
if isfield(config, 'windowPositions') && (n > 1) == (legacyN > 1)
    pos    = config.windowPositions;
    savedN = legacyN;
    mon    = field_(config, 'monitorPositions');
end
vis = field_(config, 'windowVisibility');
end

function v = field_(s, name)
v = [];
if isfield(s, name), v = s.(name); end
end
