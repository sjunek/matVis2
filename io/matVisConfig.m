function varargout = matVisConfig(varargin)
% matVisConfig  Configuration save/load utilities for matVis 2.0.
%
%   LoadConfig(configPath)
%     Returns a struct with saved state fields.  Returns empty struct if
%     the file doesn't exist.
%
%   SaveConfig(model, mainFig, imageFigs, zoomFigs, plotFigs, configPath, ...
%              xsecFigs)
%     imageFigs/zoomFigs/plotFigs may be a single figure handle or a cell
%     array of figure handles (one per dataset).  xsecFigs is optional (the
%     cross-section windows are created lazily, so its entries may be empty
%     or deleted handles — those datasets are simply left out of the file).
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
            if nargin >= 8
                xsecFigs = varargin{8};
            else
                xsecFigs = {};
            end
            SaveConfig_(varargin{2}, varargin{3}, varargin{4}, varargin{5}, ...
                        varargin{6}, varargin{7}, xsecFigs);

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

function SaveConfig_(model, mainFig, imageFigs, zoomFigs, plotFigs, configPath, xsecFigs)
    % Normalise single figure handles to cell arrays
    if nargin < 7 || isempty(xsecFigs), xsecFigs = {}; end
    if ~iscell(imageFigs), imageFigs = {imageFigs}; end
    if ~iscell(zoomFigs),  zoomFigs  = {zoomFigs};  end
    if ~iscell(plotFigs),  plotFigs  = {plotFigs};  end
    if ~iscell(xsecFigs),  xsecFigs  = {xsecFigs};  end

    K = numel(imageFigs);

    try
        % Window visibility
        windowVisibility = struct('Overlay', getappdata(mainFig, 'OverlayVisible'));
        for k = 1:K
            windowVisibility.(sprintf('Image%d', k)) = strcmp(imageFigs{k}.Visible, 'on');
            windowVisibility.(sprintf('Zoom%d',  k)) = strcmp(zoomFigs{k}.Visible,  'on');
            windowVisibility.(sprintf('Plot%d',  k)) = strcmp(plotFigs{k}.Visible,  'on');
            if k <= numel(xsecFigs) && ~isempty(xsecFigs{k}) && isvalid(xsecFigs{k})
                windowVisibility.(sprintf('XSec%d', k)) = strcmp(xsecFigs{k}.Visible, 'on');
            end
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
            if k <= numel(xsecFigs) && ~isempty(xsecFigs{k}) && isvalid(xsecFigs{k})
                windowPositions.(sprintf('XSec%d', k)) = xsecFigs{k}.Position;
            end
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
        rgbContrastRange = model.RGBContrastRange;

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

        % Image/zoom axes display state
        aspectRatioFixed = model.AspectRatioFixed;
        aspectRatio      = model.AspectRatio;
        winScalePct      = model.WinScalePct;

        % Fingerprint of the monitor layout this session's window positions
        % were computed under. get(0,'MonitorPositions') is not portable
        % across MATLAB releases on the same machine -- older releases can
        % under-detect monitors or report a display's resolution differently
        % under Windows per-monitor-DPI-awareness than newer ones do (all on
        % the very same hardware). The config file is shared by hostname, not
        % MATLAB version, so a layout saved under one release can land on
        % completely wrong coordinates when restored under another. Saving
        % this lets onLoadConfig detect that mismatch and fall back to a
        % fresh layout instead of misapplying stale, incompatible coordinates.
        monitorPositions = get(0, 'MonitorPositions');

        save(configPath, ...
            'windowVisibility', 'windowPositions', 'monitorPositions', ...
            'colormapIdx', 'contrastMode', 'gamma', 'contrastMin', 'contrastMax', ...
            'rgbContrastRange', ...
            'numDatasets', 'activeDataset', 'contrastLocked', ...
            'datasetContrastMins', 'datasetContrastMaxs', 'datasetGammas', ...
            'alphaContrastMins', 'alphaContrastMaxs', 'alphaGamma', 'alphaBgWhite', ...
            'aspectRatioFixed', 'aspectRatio', 'winScalePct', ...
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

    % Anchor to THIS checkout's repo root, not wherever which('matVis')
    % happens to resolve -- this machine has multiple sibling matVis/matVis2
    % checkouts on the MATLAB path (see matVis2.m's stale-path guard), and
    % 'matVis' is also the pre-rename name of this project's own entry point,
    % so which('matVis') can easily resolve to a different sibling repo
    % entirely, silently redirecting the saved config to the wrong folder.
    % mfilename('fullpath') is this very file (<repo>/io/matVisConfig.m),
    % so its grandparent directory is unambiguously <repo>.
    matVisDir = fileparts(fileparts(mfilename('fullpath')));

    configPath = fullfile(matVisDir, sprintf('matVisConfig_%s.mat', hostname));
end
