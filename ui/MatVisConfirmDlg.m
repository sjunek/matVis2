function tf = MatVisConfirmDlg(titleText, message, okLabel, cancelLabel)
%MatVisConfirmDlg  A yes/no question in a window of its own.
%
%   tf = MatVisConfirmDlg(titleText, message, okLabel, cancelLabel)
%
%   Returns true when okLabel was pressed, false for cancel or for closing
%   the window.
%
%   uiconfirm and uialert draw inside the figure they are given, so a message
%   wider than that figure is clipped and a main window narrower than the
%   question cannot show it.  This is a real window: it sizes itself to the
%   text and centres on the screen.
%
%   See also MatVisLoadPrefDlg, MatVisLoadModeDlg.

if nargin < 3 || isempty(okLabel),     okLabel     = 'OK';     end
if nargin < 4 || isempty(cancelLabel), cancelLabel = 'Cancel'; end

tf = false;

% Roughly one line per 62 characters at this width, plus the blank lines the
% caller put in; enough to keep a long explanation from being cut off.
nl    = 1 + count(message, newline) + floor(numel(message) / 62);
textH = max(70, 17 * nl);

W = 520;  H = textH + 86;
dlg = uifigure('Name', titleText, 'Resize', 'off', ...
    'Position', [100 100 W H], 'WindowStyle', 'modal');
centerOn(dlg);
cleanup = onCleanup(@() closeIfValid(dlg));

g = uigridlayout(dlg, [2, 3]);
g.RowHeight   = {'1x', 30};
g.ColumnWidth = {'1x', 150, 150};
g.Padding     = [16 12 16 12];
g.RowSpacing  = 10;

lbl = uilabel(g, 'Text', message, 'WordWrap', 'on', 'FontSize', 11, ...
    'VerticalAlignment', 'top');
lbl.Layout.Row = 1;  lbl.Layout.Column = [1 3];

btnCancel = uibutton(g, 'Text', cancelLabel, 'FontSize', 11, ...
    'Tag', 'mvConfirmCancel', 'ButtonPushedFcn', @(~,~) finish(false));
btnCancel.Layout.Row = 2;  btnCancel.Layout.Column = 2;

btnOk = uibutton(g, 'Text', okLabel, 'FontSize', 11, ...
    'Tag', 'mvConfirmOk', 'ButtonPushedFcn', @(~,~) finish(true));
btnOk.Layout.Row = 2;  btnOk.Layout.Column = 3;

dlg.CloseRequestFcn = @(~,~) finish(false);
uiwait(dlg);

% =====================================================================
    function finish(accept)
        tf = accept;
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
