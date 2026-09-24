function choice = MatVisLoadPrefDlg(current)
%MatVisLoadPrefDlg  Edit the standing rule for opening large files.
%
%   choice = MatVisLoadPrefDlg(current)
%
%   current : 'ask' | 'lazy' | 'full' -- the rule in force now
%   choice  : the rule chosen, or '' when the dialog was cancelled
%
%   A window of its own rather than uiconfirm: an in-figure dialog is clipped
%   to the main window, which is narrower than this explanation needs.
%
%   See also MatVisLoadModeDlg, matVisLoadPolicy, matVisOpenDatasets.

choice = '';

keys   = {'ask', 'lazy', 'full'};
labels = {'Ask every time', ...
          'Always read on demand (memory-efficient)', ...
          'Always load everything'};
k = find(strcmp(keys, current), 1);
if isempty(k), k = 1; end

W = 470;  H = 250;
dlg = uifigure('Name', 'Loading large files', 'Resize', 'off', ...
    'Position', [100 100 W H], 'WindowStyle', 'modal');
centerOn(dlg);
cleanup = onCleanup(@() closeIfValid(dlg));

g = uigridlayout(dlg, [4, 3]);
g.RowHeight   = {'1x', 22, 26, 30};
g.ColumnWidth = {'1x', 90, 90};
g.Padding     = [14 12 14 12];
g.RowSpacing  = 8;

lbl = uilabel(g, 'WordWrap', 'on', 'FontSize', 11, 'Text', ...
    ['When a file is too large to load comfortably -- either it would not ' ...
     'fit in the free memory, or reading it in full would take a long time ' ...
     '-- matVis can ask what to do, or always decide the same way.' newline newline ...
     'This applies only to files that cross one of those thresholds. ' ...
     'Smaller files are opened straight away and are never held up.']);
lbl.Layout.Row = 1;  lbl.Layout.Column = [1 3];

cap = uilabel(g, 'Text', 'When a file is large:', 'FontSize', 11);
cap.Layout.Row = 2;  cap.Layout.Column = [1 3];

dd = uidropdown(g, 'Items', labels, 'ItemsData', keys, 'Value', keys{k}, ...
    'FontSize', 11, 'Tag', 'mvLoadPref');
dd.Layout.Row = 3;  dd.Layout.Column = [1 3];

btnCancel = uibutton(g, 'Text', 'Cancel', 'FontSize', 11, 'Tag', 'mvPrefCancel', ...
    'ButtonPushedFcn', @(~,~) finish(false));
btnCancel.Layout.Row = 4;  btnCancel.Layout.Column = 2;

btnOk = uibutton(g, 'Text', 'OK', 'FontSize', 11, 'Tag', 'mvPrefOk', ...
    'ButtonPushedFcn', @(~,~) finish(true));
btnOk.Layout.Row = 4;  btnOk.Layout.Column = 3;

dlg.CloseRequestFcn = @(~,~) finish(false);
uiwait(dlg);

% =====================================================================
    function finish(accept)
        if accept
            choice = dd.Value;
        else
            choice = '';
        end
        uiresume(dlg);
        closeIfValid(dlg);
    end
end

% =============================================================================
function centerOn(f)
scr = get(0, 'ScreenSize');
f.Position(1:2) = round([(scr(3) - f.Position(3))/2, (scr(4) - f.Position(4))/2]);
end

% =============================================================================
function closeIfValid(f)
if ~isempty(f) && isvalid(f), delete(f); end
end
