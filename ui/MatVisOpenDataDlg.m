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
%   Both lists show what is on offer: name, shape, class and size.
%
%   Workspace variables and MAT-files are measured while the list is built,
%   because `whos` reads a variable index rather than any data (3 ms even for
%   a 5.9 GB file).  Other formats need a reader opened -- 0.24 to 2.5 s each
%   -- so those are measured for the files actually selected, and cached.
%
%   Once a selection is measured it is judged exactly as a workspace variable
%   is, and the buttons follow.  Two cases cannot be measured and keep the
%   older, conditional wording: a format with no on-demand reader, and a
%   selection too large to open one reader at a time.  There the caller falls
%   back to a new window if the dimensions turn out not to match.
%
%   See also matVisOpenDatasets, MatVisMainWindow.

res = struct('action', 'cancel', 'source', 'workspace', 'items', {{}});

vars = eligibleWorkspaceVars();

W = 720;  H = 460;
dlg = uifigure('Name', 'Open data', 'Position', [100 100 W H], ...
    'WindowStyle', 'modal');
centerOn(dlg);
cleanup = onCleanup(@() closeIfValid(dlg));

outer = uigridlayout(dlg, [3, 2]);
outer.RowHeight   = {24, '1x', 92};
outer.ColumnWidth = {'1x', '1x'};
outer.Padding     = [12 10 12 10];

lblW = uilabel(outer, 'Text', 'Workspace variables', 'FontWeight', 'bold');
lblW.Layout.Row = 1;  lblW.Layout.Column = 1;
% The folder path takes the place of a "Files" caption: it says what is
% listed better than the word would, and keeping it in the header row leaves
% the two lists exactly the same rectangle.
headRight = uigridlayout(outer, [1, 2]);
headRight.Layout.Row = 1;  headRight.Layout.Column = 2;
headRight.ColumnWidth   = {'1x', 78};
headRight.Padding       = [0 0 0 0];
headRight.ColumnSpacing = 4;

edtDir = uieditfield(headRight, 'text', 'Value', pwd, ...
    'ValueChangedFcn', @(~,~) refreshFiles());
edtDir.Layout.Row = 1;  edtDir.Layout.Column = 1;

btnBrowse = uibutton(headRight, 'Text', 'Browse...', 'FontSize', 11, ...
    'ButtonPushedFcn', @(~,~) onBrowse());
btnBrowse.Layout.Row = 1;  btnBrowse.Layout.Column = 2;

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
% Navigating up is the [..] entry at the top of the list, so the file list
% needs no controls of its own and sits directly in the layout -- the same
% cell shape as the workspace list beside it.
lstFiles = uilistbox(outer, 'Multiselect', 'on', 'FontSize', 11, 'Tag', 'mvFiles', ...
    'FontName', 'monospaced', ...
    'ValueChangedFcn', @(~,~) onSelectionChanged('files'), ...
    'DoubleClickedFcn', @(~,~) onFileDoubleClick());
lstFiles.Layout.Row = 2;  lstFiles.Layout.Column = 2;

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
            describeFileSelection(names, nSets);
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

    function describeFileSelection(names, nSets)
        % Files are judged like workspace variables once their shape is
        % known.  A MAT-file answers from its variable index in a few ms; an
        % image file needs a reader opened, which is why it happens for the
        % selection rather than for the whole listing.
        paths = cellfun(@(f) fullfile(edtDir.Value, f), names, ...
            'UniformOutput', false);
        totalBytes = 0;
        for k = 1:numel(paths)
            dk = dir(paths{k});
            if ~isempty(dk), totalBytes = totalBytes + dk(1).bytes; end
        end

        nDeep = sum(~endsWithExt(paths, '.mat'));
        if nDeep > maxFilesToProbe()
            % Opening this many readers would turn one click into a minute
            % of waiting, so the count alone decides and the wording says
            % the dimensions were not checked.
            lblVerdict.Text = sprintf(['%d files, %s.  Too many to measure without ' ...
                'opening them, so replacing works only if they turn out to hold ' ...
                '%d dataset(s) with %d dimensions; otherwise a new window opens.'], ...
                nSets, bytesText(totalBytes), curNumDatasets, curNumDims);
            btnReplace.Enable = onOff(nSets == curNumDatasets);
            return;
        end

        infos = probeWithProgress(paths);
        known = cellfun(@(i) i.known, infos);
        if ~all(known)
            j = find(~known, 1);
            lblVerdict.Text = sprintf(['%d file(s), %s.  "%s" cannot be measured ' ...
                'without loading it -- %s.  Replacing works if the dimensions turn ' ...
                'out to match; otherwise a new window opens.'], ...
                nSets, bytesText(totalBytes), names{j}, infos{j}.why);
            btnReplace.Enable = onOff(nSets == curNumDatasets);
            return;
        end

        szs       = cellfun(@(i) i.size, infos, 'UniformOutput', false);
        totalSets = sum(cellfun(@(i) i.nSets, infos));
        nd        = numel(szs{1});
        shape     = sprintf('%s %s', dimsText(szs{1}), infos{1}.class);

        whyNot = '';
        if ~allSameVec(szs)
            whyNot = 'the selected files do not all have the same size.';
        elseif totalSets ~= curNumDatasets
            whyNot = sprintf('this viewer holds %d dataset(s), these give %d.', ...
                curNumDatasets, totalSets);
        elseif nd ~= curNumDims
            whyNot = sprintf('this viewer shows %d dimensions.', curNumDims);
        end

        if isempty(whyNot)
            lblVerdict.Text = sprintf('%s -- %s, %s.  Matches this viewer.', ...
                strjoin(names, ', '), shape, bytesText(totalBytes));
            btnReplace.Enable = 'on';
        else
            lblVerdict.Text = sprintf('%s -- %s, %s.  %s  A new window will be opened.', ...
                strjoin(names, ', '), shape, bytesText(totalBytes), capitalise(whyNot));
            btnReplace.Enable = 'off';
        end
    end

    function infos = probeWithProgress(paths)
        % Opening a reader takes up to a couple of seconds, and MATLAB
        % cannot repaint while it does, so the label says what is happening
        % before each one rather than after all of them.
        infos = cell(1, numel(paths));
        for k = 1:numel(paths)
            if numel(paths) > 1
                lblVerdict.Text = sprintf('Reading file information... (%d/%d)', ...
                    k, numel(paths));
            else
                lblVerdict.Text = 'Reading file information...';
            end
            drawnow;
            infos{k} = fileDatasetInfo(paths{k});
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
        'label', sprintf('%-16s %-17s %-8s %9s', w(k).name, ...
                         dimsText(w(k).size), w(k).class, ...
                         bytesText(w(k).bytes))); %#ok<AGROW>
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
e = struct('name', {}, 'isdir', {}, 'label', {}, 'target', {}, 'bytes', {});
end

% =============================================================================
function e = listEntries(folder)
% Subfolders first (bracketed, so they read as navigation rather than data),
% then the files this viewer can actually open.
e = emptyEntries();
if isempty(folder) || ~isfolder(folder), return; end

parent = fileparts(folder);
if ~isempty(parent) && ~strcmp(parent, folder)
    e(end+1) = struct('name', '..', 'isdir', true, 'label', '[..]', ...
        'target', parent, 'bytes', 0);
end

d = dir(folder);
d = d(~ismember({d.name}, {'.', '..'}));
% Leading-dot folders are plumbing (.git and friends), not data.
d = d(~startsWith({d.name}, '.'));

subs = sortNoCase({d([d.isdir]).name});
subs = subs(~isHiddenOrSystem(folder, subs));
for k = 1:numel(subs)
    e(end+1) = struct('name', subs{k}, 'isdir', true, ...
        'label', ['[' subs{k} ']'], 'target', fullfile(folder, subs{k}), ...
        'bytes', 0); %#ok<AGROW>
end

df    = d(~[d.isdir]);
[~, ord] = sort(lower({df.name}));
df    = df(ord);
for k = 1:numel(df)
    if isSupportedFile(fullfile(folder, df(k).name))
        e(end+1) = struct('name', df(k).name, 'isdir', false, ...
            'label', sprintf('%-40s %9s', fitName(df(k).name, 40), ...
                             bytesText(df(k).bytes)), ...
            'target', '', 'bytes', df(k).bytes); %#ok<AGROW>
    end
end
end

% =============================================================================
function s = fitName(n, w)
% Keep the extension visible when a name is too long for the column: the
% middle is what a reader can most afford to lose.
if numel(n) <= w, s = n; return; end
[~, base, ext] = fileparts(n);
keep = w - numel(ext) - 1;
if keep < 4, s = [n(1:w-1) char(8230)]; return; end
head = ceil(keep / 2);
tail = keep - head;
s = [base(1:head) char(8230) base(end-tail+1:end) ext];
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
%
% Code Analyzer suggests filePermissions instead.  It cannot be used here:
% matlab.io.WindowsPermissions carries only AbsolutePath, Readable, Writable
% and Type -- neither the hidden nor the system attribute this needs.
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
    info = matDatasetInfo(p);
    tf   = info.known;
end
end

% =============================================================================
function info = matDatasetInfo(p)
% What a MAT-file holds, by the same rule as the workspace list: matrices
% only, and if there is more than one they have to share a size.
%
% `whos -file` reads the variable index, not the data, so this costs a few
% ms even for a multi-GB file -- measured at 3 ms for a 5.9 GB v7.3 file and
% 6.6 ms for 126 MB of incompressible v7.  Cheap enough to run while listing
% a folder, which is why .mat dimensions can be shown without being asked
% for.  Cached on size and timestamp so re-listing is free.
persistent cache
if isempty(cache)
    cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
end
info = struct('known', false, 'size', [], 'class', '', 'nSets', 0, 'why', '');
d = dir(p);
if isempty(d), info.why = 'the file is gone'; return; end
key = sprintf('%s|%.10f|%d', p, d(1).datenum, d(1).bytes);
if isKey(cache, key), info = cache(key); return; end

try
    w = whos('-file', p);
    keep = arrayfun(@(x) isMatrixVar(x.class, x.size), w);
    w = w(keep);
    if isempty(w)
        info.why = 'it holds no matrices';
    elseif ~allSameSize(w)
        info.why = 'its matrices differ in size';
    else
        info.known = true;
        info.size  = w(1).size;
        info.class = w(1).class;
        info.nSets = numel(w);
    end
catch
    info.why = 'it could not be read';
end
cache(key) = info;
end

% =============================================================================
function info = fileDatasetInfo(p)
% The shape of one file, whatever its format.
%
% A MAT-file answers from its variable index in milliseconds.  Everything
% else needs a reader opened, which measured 0.24-2.5 s per file (plus a
% one-off ~4 s the first time Bio-Formats loads), so this is called for the
% files the user actually selected, never for a whole listing.  Results are
% cached, so re-selecting is instant.
persistent cache
if isempty(cache)
    cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
end
[~, ~, ext] = fileparts(lower(p));
if strcmp(ext, '.mat')
    info = matDatasetInfo(p);
    return;
end

info = struct('known', false, 'size', [], 'class', '', 'nSets', 1, 'why', '');
d = dir(p);
if isempty(d), info.why = 'the file is gone'; return; end
key = sprintf('%s|%.10f|%d', p, d(1).datenum, d(1).bytes);
if isKey(cache, key), info = cache(key); return; end

src = [];
try
    [src, ~, why] = matVisOpenSource(p);
    if isempty(src)
        % No on-demand reader, so the shape is not knowable without loading
        % the whole file -- which is exactly what the user has not asked for
        % yet.  Say so rather than pay for it here.
        if isempty(why), why = 'it has no on-demand reader'; end
        info.why = why;
    else
        info.known = true;
        info.size  = src.Size;
        info.class = src.ClassName;
    end
catch ME
    info.why = ME.message;
end
if ~isempty(src) && isa(src, 'MatVisLazySource')
    try
        src.closeSource();
    catch
    end
end
cache(key) = info;
end

% =============================================================================
function s = onOff(tf)
if tf, s = 'on'; else, s = 'off'; end
end

% =============================================================================
function n = maxFilesToProbe()
% How many files needing a reader open may be measured before the dialog
% gives up and judges on count alone.  A reader open measured 0.24-2.5 s, so
% six is a couple of seconds in the ordinary case and bounded in the worst.
n = 6;
end

% =============================================================================
function tf = endsWithExt(paths, ext)
tf = false(1, numel(paths));
for k = 1:numel(paths)
    [~, ~, e] = fileparts(lower(paths{k}));
    tf(k) = strcmp(e, ext);
end
end

% =============================================================================
function tf = allSameVec(c)
tf = true;
for k = 2:numel(c)
    if ~isequal(c{k}, c{1}), tf = false; return; end
end
end

% =============================================================================
function s = capitalise(s)
% The reasons read as clauses after a dash in the workspace panel, but as
% sentences after the file size here.
if ~isempty(s), s(1) = upper(s(1)); end
end

% =============================================================================
function s = dimsText(sz)
s = ['[' strjoin(arrayfun(@(d) sprintf('%d', d), sz, ...
     'UniformOutput', false), 'x') ']'];
end

% =============================================================================
function s = bytesText(n)
u = {'B', 'kB', 'MB', 'GB', 'TB'};
k = 1;
while n >= 1024 && k < numel(u)
    n = n / 1024;  k = k + 1;
end
if n >= 100 || k == 1
    s = sprintf('%.0f %s', n, u{k});
else
    s = sprintf('%.1f %s', n, u{k});
end
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
