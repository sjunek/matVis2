function [answer, checked] = MatVisInputDlg(prompt, titleText, defaults, checkLabel, checkDefault, disableWith)
%MatVisInputDlg  Ask for one or more text values in a window of its own.
%
%   answer = MatVisInputDlg(prompt, titleText, defaults)
%   [answer, checked] = MatVisInputDlg(prompt, titleText, defaults, ...
%                                      checkLabel, checkDefault, disableWith)
%
%   prompt and defaults are char or cellstr, one entry per field.  Returns a
%   cellstr of the entered values, or {} for Cancel, Esc or closing the
%   window -- the same contract as inputdlg.  Return accepts.
%
%   checkLabel (char or cellstr) adds one checkbox per entry below the
%   fields, initially checkDefault (logical vector); checked is their state
%   on OK, or checkDefault on Cancel.  While checkbox number disableWith is
%   ticked, the text fields are disabled.
%
%   inputdlg builds a classic figure, and on Windows those are owned by the
%   MATLAB desktop: closing one activates its owner, which pulls the desktop
%   in front of every matVis window.  This is a uifigure, which has no such
%   owner.
%
%   See also MatVisConfirmDlg.

prompt   = cellstr(prompt);
if nargin < 3 || isempty(defaults), defaults = repmat({''}, size(prompt)); end
defaults = cellstr(defaults);
n        = numel(prompt);
if nargin < 4 || isempty(checkLabel), checkLabel = {}; end
checkLabel = cellstr(checkLabel);
nCheck   = numel(checkLabel);
if nargin < 5 || isempty(checkDefault), checkDefault = false(1, nCheck); end
if nargin < 6, disableWith = 0; end
checked  = logical(checkDefault(:)');

answer = {};
values = defaults(:)';     % live text, so Return sees uncommitted typing

rowH = 22;
W = 320 + 60 * (nCheck > 0);  H = 12 + (n + nCheck) * (rowH + 8) + 30 + 12;
dlg = uifigure('Name', titleText, 'Resize', 'off', ...
    'Position', [100 100 W H], 'WindowStyle', 'modal');
centerOn(dlg);
cleanup = onCleanup(@() closeIfValid(dlg));

g = uigridlayout(dlg, [n + nCheck + 1, 3]);
g.RowHeight   = [repmat({rowH}, 1, n + nCheck), {30}];
g.ColumnWidth = {'fit', '1x', 90};
g.Padding     = [12 12 12 12];
g.RowSpacing  = 8;

edits = gobjects(1, n);
for k = 1:n
    lbl = uilabel(g, 'Text', prompt{k}, 'FontSize', 11);
    lbl.Layout.Row = k;  lbl.Layout.Column = 1;
    edits(k) = uieditfield(g, 'text', 'Value', defaults{k}, 'FontSize', 11, ...
        'Tag', sprintf('mvInput%d', k), ...
        'ValueChangingFcn', @(~, e) setValue(k, e.Value), ...
        'ValueChangedFcn',  @(src, ~) setValue(k, src.Value));
    edits(k).Layout.Row = k;  edits(k).Layout.Column = [2 3];
end

cbs = gobjects(1, nCheck);
for k = 1:nCheck
    cbs(k) = uicheckbox(g, 'Text', checkLabel{k}, 'Value', checked(k), 'FontSize', 11, ...
        'Tag', sprintf('mvInputCheck%d', k), 'ValueChangedFcn', @(~,~) syncEnable());
    cbs(k).Layout.Row = n + k;  cbs(k).Layout.Column = [1 3];
end
syncEnable();

btnRow = uigridlayout(g, [1, 3]);
btnRow.Layout.Row = n + nCheck + 1;  btnRow.Layout.Column = [1 3];
btnRow.ColumnWidth   = {'1x', 90, 90};
btnRow.RowHeight     = {'1x'};
btnRow.Padding       = [0 0 0 0];
btnRow.ColumnSpacing = 8;

btnOk = uibutton(btnRow, 'Text', 'OK', 'FontSize', 11, ...
    'Tag', 'mvInputOk', 'ButtonPushedFcn', @(~,~) finish(true));
btnOk.Layout.Column = 2;
btnCancel = uibutton(btnRow, 'Text', 'Cancel', 'FontSize', 11, ...
    'Tag', 'mvInputCancel', 'ButtonPushedFcn', @(~,~) finish(false));
btnCancel.Layout.Column = 3;

dlg.WindowKeyPressFcn = @(~, e) onKey(e.Key);
dlg.CloseRequestFcn   = @(~,~) finish(false);
try focus(edits(1)); catch, end
% Building the window processes events, so it may already have been closed.
if isvalid(dlg), uiwait(dlg); end

% =====================================================================
    function setValue(k, v)
        values{k} = char(v);
    end

    function syncEnable()
        if disableWith < 1 || disableWith > nCheck, return; end
        if cbs(disableWith).Value, st = 'off'; else, st = 'on'; end
        set(edits, 'Enable', st);
    end

    function onKey(key)
        switch key
            case 'return', finish(true);
            case 'escape', finish(false);
        end
    end

    function finish(accept)
        if accept
            answer = values;
            if nCheck > 0, checked = logical([cbs.Value]); end
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
