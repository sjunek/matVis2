function varargout = matVisConfig(varargin)
% matVisConfig  Configuration save/load utilities for matVis 2.0.
%
%   LoadConfig(configPath)
%     Returns a struct with saved state fields.  Returns empty struct if
%     the file doesn't exist.
%
%   SaveConfig(model, mainFig, imageFigs, zoomFigs, plotFigs, configPath)
%     imageFigs/zoomFigs/plotFigs may be a single figure handle or a cell
%     array of figure handles (one per dataset).
%
%   GetConfigPath()
%     Returns the default config file path:
%     [matVis_dir]/matVisConfig_[computerName].mat

    if nargin == 0
        help matVisConfig;
        return;
    end

    action = varargin{1};

    switch action
        case 'LoadConfig'
            if nargin < 2
                error('LoadConfig requires a configPath argument');
            end
            varargout{1} = LoadConfig_(varargin{2});

        case 'SaveConfig'
            if nargin < 7
                error('SaveConfig requires: model, mainFig, imageFigs, zoomFigs, plotFigs, configPath');
            end
            SaveConfig_(varargin{2}, varargin{3}, varargin{4}, varargin{5}, varargin{6}, varargin{7});

        case 'GetConfigPath'
            varargout{1} = GetConfigPath_();

        otherwise
            error('Unknown action: %s', action);
    end
end

% ========================================================================
%  Private helpers
% ========================================================================

function config = LoadConfig_(configPath)
    config = struct();
    if ~isfile(configPath), return; end
    try
        loaded = load(configPath, '-mat');
        fn = fieldnames(loaded);
        for k = 1:numel(fn)
            config.(fn{k}) = loaded.(fn{k});
        end
    catch ME
        warning('matVisConfig:LoadFailed', ...
            'Failed to load config from %s: %s', configPath, ME.message);
    end
end

function SaveConfig_(model, mainFig, imageFigs, zoomFigs, plotFigs, configPath)
    % Normalise single figure handles to cell arrays
    if ~iscell(imageFigs), imageFigs = {imageFigs}; end
    if ~iscell(zoomFigs),  zoomFigs  = {zoomFigs};  end
    if ~iscell(plotFigs),  plotFigs  = {plotFigs};  end

    K = numel(imageFigs);

    try
        % Window visibility
        windowVisibility = struct('Overlay', getappdata(mainFig, 'OverlayVisible'));
        for k = 1:K
            windowVisibility.(sprintf('Image%d', k)) = strcmp(imageFigs{k}.Visible, 'on');
            windowVisibility.(sprintf('Zoom%d',  k)) = strcmp(zoomFigs{k}.Visible,  'on');
            windowVisibility.(sprintf('Plot%d',  k)) = strcmp(plotFigs{k}.Visible,  'on');
        end
        % Legacy single-dataset keys for backward compat
        if K == 1
            windowVisibility.Image = windowVisibility.Image1;
            windowVisibility.Zoom  = windowVisibility.Zoom1;
            windowVisibility.Plot  = windowVisibility.Plot1;
        end

        % Window positions
        windowPositions = struct('Main', mainFig.Position);
        for k = 1:K
            windowPositions.(sprintf('Image%d', k)) = imageFigs{k}.Position;
            windowPositions.(sprintf('Zoom%d',  k)) = zoomFigs{k}.Position;
            windowPositions.(sprintf('Plot%d',  k)) = plotFigs{k}.Position;
        end
        if K == 1
            windowPositions.Image = windowPositions.Image1;
            windowPositions.Zoom  = windowPositions.Zoom1;
            windowPositions.Plot  = windowPositions.Plot1;
        end

        % Model state
        colormapIdx  = model.ColormapIdx;
        contrastMode = model.ContrastMode;
        gamma        = model.Gamma;
        contrastMin  = model.ContrastMin;
        contrastMax  = model.ContrastMax;

        % Multi-dataset state
        numDatasets          = model.NumDatasets;
        activeDataset        = model.ActiveDataset;
        contrastLocked       = model.ContrastLocked;
        datasetContrastMins  = model.DatasetContrastMins;
        datasetContrastMaxs  = model.DatasetContrastMaxs;
        datasetGammas        = model.DatasetGammas;

        % Alpha channel state (empty when no alpha maps attached)
        alphaContrastMins = model.AlphaContrastMins;
        alphaContrastMaxs = model.AlphaContrastMaxs;
        alphaGamma        = model.AlphaGamma;
        alphaBgWhite      = model.AlphaBgWhite;

        save(configPath, ...
            'windowVisibility', 'windowPositions', ...
            'colormapIdx', 'contrastMode', 'gamma', 'contrastMin', 'contrastMax', ...
            'numDatasets', 'activeDataset', 'contrastLocked', ...
            'datasetContrastMins', 'datasetContrastMaxs', 'datasetGammas', ...
            'alphaContrastMins', 'alphaContrastMaxs', 'alphaGamma', 'alphaBgWhite', ...
            '-mat');

        fprintf('Config saved to: %s\n', configPath);

    catch ME
        warning('matVisConfig:SaveFailed', ...
            'Failed to save config to %s: %s', configPath, ME.message);
    end
end

function configPath = GetConfigPath_()
    [~, hostname] = system('hostname');
    hostname = strtrim(hostname);
    if isempty(hostname), hostname = 'Unknown'; end

    matVisFile = which('matVis');
    if isempty(matVisFile)
        matVisDir = pwd;
    else
        matVisDir = fileparts(matVisFile);
    end

    configPath = fullfile(matVisDir, sprintf('matVisConfig_%s.mat', hostname));
end
