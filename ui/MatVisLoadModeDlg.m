function [choice, remember] = MatVisLoadModeDlg(info)
%MatVisLoadModeDlg  Ask how a large dataset should be opened.
%
%   [choice, remember] = MatVisLoadModeDlg(info)
%
%   info is a struct describing what is about to be opened:
%     names        1xK cellstr, the file name(s)
%     dimsText     char, e.g. '1924 x 1920 x 57 (Z) x 15 (T), uint16'
%     bytes        total size in memory
%     availBytes   free memory (NaN when unknown)
%     estSeconds   estimated time to read it in full (NaN when unknown)
%     stepMs       estimated cost of one navigation step when read on demand
%     recommend    'full' | 'lazy' -- pre-selected
%     canFull      logical; false disables the full-load option entirely
%
%   choice   : 'full' | 'lazy' | 'cancel'
%   remember : 'ask' | 'lazy' | 'full' -- the rule to apply to later files of
%              this size, or 'ask' to keep being asked
%
%   The numbers that drove the recommendation are on the screen so the choice
%   can be checked rather than taken on trust, and the consequences are given
%   in what the user will experience -- a wait, an approximate histogram --
%   rather than in terms of readers and caches.
%
%   See also matVisLoadPolicy, matVisOpenSource.

choice   = 'cancel';
remember = 'ask';

W = 470;  H = 320;
dlg = uifigure('Name', 'Open dataset', 'Resize', 'off', ...
    'Position', [100 100 W H], 'WindowStyle', 'modal');
centerOnScreen(dlg);
cleanup = onCleanup(@() closeIfValid(dlg));

g = uigridlayout(dlg, [7, 2]);
g.RowHeight   = {22, 40, 34, 66, 66, 26, 30};
g.ColumnWidth = {'1x', 120};
g.Padding     = [14 12 14 10];
g.RowSpacing  = 6;

lblName = uilabel(g, 'Text', strjoin(info.names, ', '), ...
    'FontWeight', 'bold', 'FontSize', 12);
lblName.Layout.Row = 1;  lblName.Layout.Column = [1 2];

lblDims = uilabel(g, 'Text', info.dimsText, 'FontSize', 11, ...
    'FontColor', [0.35 0.35 0.35]);
lblDims.Layout.Row = 2;  lblDims.Layout.Column = [1 2];

lblFacts = uilabel(g, 'Text', factsText(info), 'FontSize', 11, ...
    'Interpreter', 'none');
lblFacts.Layout.Row = 3;  lblFacts.Layout.Column = [1 2];

btnFull = uibutton(g, 'Text', fullText(info), 'FontSize', 11, ...
    'HorizontalAlignment', 'left', 'Tag', 'matVisLoadFull', ...
    'ButtonPushedFcn', @(~,~) pick('full'));
btnFull.Layout.Row = 4;  btnFull.Layout.Column = [1 2];
if ~info.canFull
    btnFull.Enable  = 'off';
    btnFull.Tooltip = ['This file cannot be held in one array at all: a single ' ...
                       'plane exceeds the 2 GB limit of the reader.'];
end

btnLazy = uibutton(g, 'Text', lazyText(info), 'FontSize', 11, ...
    'HorizontalAlignment', 'left', 'Tag', 'matVisLoadLazy', ...
    'ButtonPushedFcn', @(~,~) pick('lazy'));
btnLazy.Layout.Row = 5;  btnLazy.Layout.Column = [1 2];

% Highlight the recommendation rather than hiding the other option.
if strcmp(info.recommend, 'lazy') || ~info.canFull
    btnLazy.FontWeight = 'bold';
else
    btnFull.FontWeight = 'bold';
end

lblRem = uilabel(g, 'Text', 'For files like this:', 'FontSize', 11);
lblRem.Layout.Row = 6;  lblRem.Layout.Column = 1;

ddRemember = uidropdown(g, 'FontSize', 11, 'Tag', 'matVisLoadRemember', ...
    'Items', {'Ask every time', 'Use memory-efficient', 'Always load everything'}, ...
    'ItemsData', {'ask', 'lazy', 'full'}, 'Value', 'ask');
ddRemember.Layout.Row = 6;  ddRemember.Layout.Column = 2;

btnCancel = uibutton(g, 'Text', 'Cancel', 'FontSize', 11, 'Tag', 'matVisLoadCancel', ...
    'ButtonPushedFcn', @(~,~) pick('cancel'));
btnCancel.Layout.Row = 7;  btnCancel.Layout.Column = 2;

dlg.CloseRequestFcn = @(~,~) pick('cancel');
uiwait(dlg);

    function pick(c)
        choice = c;
        if isvalid(ddRemember)
            remember = ddRemember.Value;
        end
        if strcmp(c, 'cancel')
            remember = 'ask';
        end
        uiresume(dlg);
        closeIfValid(dlg);
    end
end

% =============================================================================
function s = factsText(info)
if isfinite(info.availBytes)
    memPart = sprintf('Needs %s of memory;  %s free', ...
        bytesText(info.bytes), bytesText(info.availBytes));
else
    memPart = sprintf('Needs %s of memory', bytesText(info.bytes));
end
if isfinite(info.estSeconds)
    s = sprintf('%s\nReading it in full takes about %s.', memPart, secondsText(info.estSeconds));
else
    s = memPart;
end
end

% =============================================================================
function s = fullText(info)
if isfinite(info.estSeconds)
    wait = sprintf('about %s', secondsText(info.estSeconds));
else
    wait = 'some time';
end
s = sprintf(['Load everything\n' ...
             'Everything is exact and instant to navigate. Waits %s now,\n' ...
             'and keeps %s in memory.'], wait, bytesText(info.bytes));
end

% =============================================================================
function s = lazyText(info)
s = sprintf(['Memory-efficient\n' ...
             'Opens now; reads each plane as you navigate (about %d ms a step).\n' ...
             'Global histogram, 3-D view and value range use a reduced overview.'], ...
             round(info.stepMs));
end

% =============================================================================
function s = bytesText(n)
if ~isfinite(n), s = 'an unknown amount'; return; end
u = {'B', 'kB', 'MB', 'GB', 'TB'};
k = min(numel(u), max(1, floor(log(max(n, 1)) / log(1024)) + 1));
s = sprintf('%.1f %s', n / 1024^(k-1), u{k});
end

% =============================================================================
function s = secondsText(t)
if t < 90
    s = sprintf('%.0f seconds', t);
else
    s = sprintf('%.0f minutes', t / 60);
end
end

% =============================================================================
function centerOnScreen(f)
scr = get(0, 'ScreenSize');
f.Position(1:2) = round([(scr(3) - f.Position(3))/2, (scr(4) - f.Position(4))/2]);
end

% =============================================================================
function closeIfValid(f)
if ~isempty(f) && isvalid(f)
    delete(f);
end
end
