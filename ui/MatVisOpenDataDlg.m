function res = MatVisOpenDataDlg(curNumDatasets, curNumDims, curSizeText)
%MatVisOpenDataDlg  Pick new data for a running viewer: workspace or files.
%
%   res = MatVisOpenDataDlg(curNumDatasets, curNumDims, curSizeText)
%
%   curNumDatasets / curNumDims describe what the calling viewer holds; they
%   decide whether the data picked can replace it or needs a window of its
%   own.  curSizeText is shown so the comparison is visible rather than
%   asserted.
%
%   res is a struct:
%     action : 'replace' | 'new' | 'cancel'
%     source : 'workspace' | 'files'
%     items  : cellstr -- variable names, or full file paths
%
%   Workspace variables are checked against the current viewer immediately,
%   because `whos` already knows their size.  Files are not: finding out
%   costs a reader open, so the dialog says that replacing will happen only
%   if the dimensions turn out to match, and the caller falls back to a new
%   window when they do not.
%
%   See also matVisOpenDatasets, MatVisMainWindow.

res = struct('action', 'cancel', 'source', 'workspace', 'items', {{}});

vars = eligibleWorkspaceVars();

W = 720;  H = 460;
dlg = uifigure('Name', 'Open data', 'Position', [100 100 W H], ...
    'WindowStyle', 'modal');
centerOn(dlg);
cleanup = onCleanup(@() closeIfValid(dlg)); %#ok<NASGU>

outer = uigridlayout(dlg, [3, 2]);
outer.RowHeight   = {22, '1x', 92};
outer.ColumnWidth = {'1x', '1x'};
outer.Padding     = [12 10 12 10];

lblW = uilabel(outer, 'Text', 'Workspace variables', 'FontWeight', 'bold');
lblW.Layout.Row = 1;  lblW.Layout.Column = 1;
lblF = uilabel(outer, 'Text', 'Files', 'FontWeight', 'bold');
lblF.Layout.Row = 1;  lblF.Layout.Column = 2;

% ---- left: workspace ----------------------------------------------------
lstVars = uilistbox(outer, 'Multiselect', 'on', 'FontName', 'monospaced', 'Tag', 'mvVars', ...
    'FontSize', 11, 'Items', {vars.label}, 'ItemsData', 1:numel(vars), ...
    'ValueChangedFcn', @(~,~) onSelectionChanged('workspace'));
lstVars.Layout.Row = 2;  lstVars.Layout.Column = 1;
if isempty(vars)
    lstVars.Items = {'(no numeric variables in the base workspace)'};
    lstVars.ItemsData = 0;
    lstVars.Enable = 'off';
end

% ---- right: files -------------------------------------------------------
right = uigridlayout(outer, [3, 2]);
right.Layout.Row = 2;  right.Layout.Column = 2;
right.RowHeight   = {24, '1x', 24};
right.ColumnWidth = {'1x', 78};
right.Padding     = [0 0 0 0];
right.RowSpacing  = 4;

edtDir = uieditfield(right, 'text', 'Value', pwd, ...
    'ValueChangedFcn', @(~,~) refreshFiles());
edtDir.Layout.Row = 1;  edtDir.Layout.Column = 1;

btnBrowse = uibutton(right, 'Text', 'Browse...', 'FontSize', 11, ...
    'ButtonPushedFcn', @(~,~) onBrowse());
btnBrowse.Layout.Row = 1;  btnBrowse.Layout.Column = 2;

lstFiles = uilistbox(right, 'Multiselect', 'on', 'FontSize', 11, 'Tag', 'mvFiles', ...
    'ValueChangedFcn', @(~,~) onSelectionChanged('files'), ...
    'DoubleClickedFcn', @(~,~) onFileDoubleClick());
lstFiles.Layout.Row = 2;  lstFiles.Layout.Column = [1 2];

btnUp = uibutton(right, 'Text', 'Parent folder', 'FontSize', 10, ...
    'ButtonPushedFcn', @(~,~) onUp());
btnUp.Layout.Row = 3;  btnUp.Layout.Column = [1 2];

% ---- bottom: verdict + actions -----------------------------------------
bottom = uigridlayout(outer, [2, 3]);
bottom.Layout.Row = 3;  bottom.Layout.Column = [1 2];
bottom.RowHeight   = {'1x', 30};
bottom.ColumnWidth = {'1x', 150, 150};
bottom.Padding     = [0 0 0 0];

lblVerdict = uilabel(bottom, 'Text', sprintf( ...
    'This viewer holds %d dataset(s), %s.  Select data on either side.', ...
    curNumDatasets, curSizeText), 'WordWrap', 'on', 'FontSize', 11);
lblVerdict.Layout.Row = 1;  lblVerdict.Layout.Column = [1 3];

btnReplace = uibutton(bottom, 'Text', 'Replace in this window', 'FontSize', 11, 'Tag', 'mvReplace', ...
    'Enable', 'off', 'ButtonPushedFcn', @(~,~) finish('replace'));
btnReplace.Layout.Row = 2;  btnReplace.Layout.Column = 2;

btnNew = uibutton(bottom, 'Text', 'Open in a new window', 'FontSize', 11, 'Tag', 'mvNew', ...
    'Enable', 'off', 'ButtonPushedFcn', @(~,~) finish('new'));
btnNew.Layout.Row = 2;  btnNew.Layout.Column = 3;

btnCancel = uibutton(bottom, 'Text', 'Cancel', 'FontSize', 11, 'Tag', 'mvCancel', ...
    'ButtonPushedFcn', @(~,~) finish('cancel'));
btnCancel.Layout.Row = 2;  btnCancel.Layout.Column = 1;
btnCancel.HorizontalAlignment = 'center';

% The list box comes up with its first item already selected, so the dialog
% has to start out agreeing with it.  While activeSide stayed empty the
% buttons were dead until the selection *changed* -- which is impossible
% when there is only one variable to pick.
activeSide = '';
if ~isempty(vars)
    activeSide = 'workspace';
end
entries = emptyEntries();
refreshFiles();
dlg.CloseRequestFcn = @(~,~) finish('cancel');
uiwait(dlg);

% =====================================================================
    function onSelectionChanged(side)
        % Selecting on one side clears the other: one load comes from one
        % place, and a half-workspace half-file dataset list is not a thing
        % the viewer can hold.
        activeSide = side;
        if strcmp(side, 'workspace')
            lstFiles.Value = {};
        else
            lstVars.Value = {};
        end
        updateVerdict();
    end

    function updateVerdict()
        [names, nSets, nd, why, nFolders] = currentSelection();
        if nSets == 0
            if nFolders > 0
                lblVerdict.Text = 'Folder selected -- double-click it to open.';
            else
                lblVerdict.Text = sprintf( ...
                    'This viewer holds %d dataset(s), %s.  Select data on either side.', ...
                    curNumDatasets, curSizeText);
            end
            btnReplace.Enable = 'off';
            btnNew.Enable     = 'off';
            return;
        end
        btnNew.Enable = 'on';

        if strcmp(activeSide, 'files')
            % Dimensions are unknown until the file is opened, and finding
            % out costs a reader open -- so offer both and let the caller
            % fall back if it turns out not to fit.
            lblVerdict.Text = sprintf(['%d file(s) selected.  Replacing works if they turn ' ...
                'out to hold %d dataset(s) with %d dimensions; otherwise a new window opens.'], ...
                nSets, curNumDatasets, curNumDims);
            btnReplace.Enable = onOff(nSets == curNumDatasets);
            return;
        end

        if isempty(why)
            lblVerdict.Text = sprintf('%s -- matches this viewer (%d dataset(s), %d dimensions).', ...
                strjoin(names, ', '), nSets, nd);
            btnReplace.Enable = 'on';
        else
            lblVerdict.Text = sprintf('%s -- %s  A new window will be opened.', ...
                strjoin(names, ', '), why);
            btnReplace.Enable = 'off';
        end
    end

    function [names, nSets, nd, why, nFolders] = currentSelection()
        names = {};  nSets = 0;  nd = 0;  why = '';  nFolders = 0;
        if strcmp(activeSide, 'workspace')
            idx = lstVars.Value;
            if isempty(idx) || isequal(idx, 0), return; end
            if ~iscell(idx), idx = num2cell(idx); end
            sel = [idx{:}];
            names = {vars(sel).name};
            nSets = numel(sel);
            dims  = arrayfun(@(v) numel(v.size), vars(sel));
            nd    = dims(1);
            if any(dims ~= dims(1))
                why = 'the selected variables do not all have the same number of dimensions.';
            elseif ~allSameSize(vars(sel))
                why = 'the selected variables do not all have the same size.';
            elseif nSets ~= curNumDatasets
                why = sprintf('this viewer holds %d dataset(s).', curNumDatasets);
            elseif nd ~= curNumDims
                why = sprintf('this viewer shows %d dimensions.', curNumDims);
            end
        else
            v = lstFiles.Value;
            if isempty(v), return; end
            if iscell(v), v = [v{:}]; end
            sel      = entries(v);
            isdirs   = [sel.isdir];
            nFolders = sum(isdirs);
            names    = {sel(~isdirs).name};
            nSets    = numel(names);
        end
    end

    function finish(action)
        [names, ~, ~, ~] = currentSelection();
        res.action = action;
        res.source = activeSide;
        if strcmp(activeSide, 'files')
            res.items = cellfun(@(f) fullfile(edtDir.Value, f), names, ...
                'UniformOutput', false);
        else
            res.items = names;
        end
        if strcmp(action, 'cancel'), res.items = {}; end
        uiresume(dlg);
        closeIfValid(dlg);
    end

    function onBrowse()
        d = uigetdir(edtDir.Value, 'Choose a folder');
        if ~isequal(d, 0), setFolder(d); end
    end

    function onUp()
        setFolder(fileparts(edtDir.Value));
    end

    function onFileDoubleClick()
        % Folders navigate.  Files deliberately do not: "replace" and "open
        % in a new window" are both plausible, and picking one silently
        % would be a guess at what the user meant.
        v = lstFiles.Value;
        if isempty(v), return; end
        if iscell(v), v = [v{:}]; end
        if numel(v) ~= 1, return; end          % ambiguous multi-selection
        e = entries(v);
        if e.isdir, setFolder(e.target); end
    end

    function setFolder(p)
        if isempty(p) || ~isfolder(p), return; end
        edtDir.Value = p;
        refreshFiles();
    end

    function refreshFiles()
        entries = listEntries(edtDir.Value);
        if isempty(entries)
            lstFiles.Items     = {};
            lstFiles.ItemsData = [];
        else
            lstFiles.Items     = {entries.label};
            lstFiles.ItemsData = 1:numel(entries);
        end
        lstFiles.Value = {};
        updateVerdict();
    end
end

% =============================================================================
function tf = allSameSize(v)
tf = true;
for k = 2:numel(v)
    if ~isequal(v(k).size, v(1).size), tf = false; return; end
end
end

% =============================================================================
function v = eligibleWorkspaceVars()
% Numeric, non-empty, at least 2-D variables of the base workspace, with a
% label that shows what they are so the choice does not need guessing.
v = struct('name', {}, 'size', {}, 'label', {});
try
    w = evalin('base', 'whos');
catch
    return;
end
for k = 1:numel(w)
    if ~isMatrixVar(w(k).class, w(k).size), continue; end
    v(end+1) = struct('name', w(k).name, 'size', w(k).size, ...
        'label', sprintf('%-20s %-18s %s', w(k).name, ...
                         ['[' strjoin(arrayfun(@(d) sprintf('%d', d), w(k).size, ...
                          'UniformOutput', false), 'x') ']'], w(k).class)); %#ok<AGROW>
end
end

% =============================================================================
function tf = isMatrixVar(cls, sz)
% The one rule that decides what counts as displayable data.  Shared by the
% workspace list and the .mat filter so the two cannot drift apart.
tf = ismember(cls, {'double','single','uint8','int8','uint16','int16', ...
                    'uint32','int32','uint64','int64','logical'}) ...
     && numel(sz) >= 2 && prod(sz) > 1;
end

% =============================================================================
function e = emptyEntries()
e = struct('name', {}, 'isdir', {}, 'label', {}, 'target', {});
end

% =============================================================================
function e = listEntries(folder)
% Subfolders first (bracketed, so they read as navigation rather than data),
% then the files this viewer can actually open.
e = emptyEntries();
if isempty(folder) || ~isfolder(folder), return; end

parent = fileparts(folder);
if ~isempty(parent) && ~strcmp(parent, folder)
    e(end+1) = struct('name', '..', 'isdir', true, 'label', '[..]', 'target', parent);
end

d = dir(folder);
d = d(~ismember({d.name}, {'.', '..'}));
% Leading-dot folders are plumbing (.git and friends), not data.
d = d(~startsWith({d.name}, '.'));

subs = sortNoCase({d([d.isdir]).name});
subs = subs(~isHiddenOrSystem(folder, subs));
for k = 1:numel(subs)
    e(end+1) = struct('name', subs{k}, 'isdir', true, ...
        'label', ['[' subs{k} ']'], 'target', fullfile(folder, subs{k})); %#ok<AGROW>
end

files = sortNoCase({d(~[d.isdir]).name});
for k = 1:numel(files)
    if isSupportedFile(fullfile(folder, files{k}))
        e(end+1) = struct('name', files{k}, 'isdir', false, ...
            'label', files{k}, 'target', ''); %#ok<AGROW>
    end
end
end

% =============================================================================
function mask = isHiddenOrSystem(folder, names)
% Windows marks $Recycle.Bin, Config.Msi, System Volume Information and the
% like with the hidden or system attribute rather than a leading dot, so the
% name alone cannot tell them apart from data folders.
%
% fileattrib is asked one path at a time on purpose: given a wildcard it
% recurses into every subfolder, which does not return in any useful time on
% a drive root.  One path at a time costs ~0.2 ms, measured at 56 ms for all
% 22 folders of C:\.  On platforms that do not report these attributes the
% fields come back as -1 and nothing is hidden.
mask = false(1, numel(names));
for k = 1:numel(names)
    try
        [ok, a] = fileattrib(fullfile(folder, names{k}));
        if ok && isstruct(a) && isscalar(a)
            mask(k) = isequal(a.hidden, 1) || isequal(a.system, 1);
        end
    catch
        % unreadable folder -- leave it visible rather than guess
    end
end
end

% =============================================================================
function c = sortNoCase(c)
if isempty(c), c = {}; return; end
[~, ord] = sort(lower(c));
c = c(ord);
end

% =============================================================================
function tf = isSupportedFile(p)
exts = {'.mat','.tif','.tiff','.jpg','.jpeg','.png','.bmp','.czi','.lsm', ...
        '.nd2','.lif','.oib','.oif','.ims','.h5'};
[~, ~, ext] = fileparts(lower(p));
tf = ismember(ext, exts);
if tf && strcmp(ext, '.mat')
    tf = matHoldsDisplayableData(p);
end
end

% =============================================================================
function tf = matHoldsDisplayableData(p)
% Same rule as the workspace list: matrices only, and if there is more than
% one they have to share a size.  `whos -file` reads the variable index, not
% the data, so this costs a few ms even for a multi-GB file -- measured at
% 2.8 ms for a 5.9 GB v7.3 file and 6.6 ms for 126 MB of incompressible v7.
% Cached on size and timestamp so re-listing a folder is free.
persistent cache
if isempty(cache)
    cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
end
d = dir(p);
if isempty(d), tf = false; return; end
key = sprintf('%s|%.10f|%d', p, d(1).datenum, d(1).bytes);
if isKey(cache, key), tf = cache(key); return; end

tf = false;
try
    w = whos('-file', p);
    keep = arrayfun(@(x) isMatrixVar(x.class, x.size), w);
    w = w(keep);
    if ~isempty(w)
        tf = true;
        for k = 2:numel(w)
            if ~isequal(w(k).size, w(1).size), tf = false; break; end
        end
    end
catch
    tf = false;   % unreadable, or not really a MAT-file
end
cache(key) = tf;
end

% =============================================================================
function s = onOff(tf)
if tf, s = 'on'; else, s = 'off'; end
end

% =============================================================================
function centerOn(f)
scr = get(0, 'ScreenSize');
f.Position(1:2) = round([(scr(3)-f.Position(3))/2, (scr(4)-f.Position(4))/2]);
end

% =============================================================================
function closeIfValid(f)
if ~isempty(f) && isvalid(f), delete(f); end
end
