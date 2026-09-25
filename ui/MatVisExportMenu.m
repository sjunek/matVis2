function MatVisExportMenu(fig, ax, exportSpec, defaultVarName, defaultFileName)
% MatVisExportMenu  Double-click export window for image / zoom / plot content.
%
%   MatVisExportMenu(fig, ax, exportSpec, defaultVarName, defaultFileName)
%
%   Opens a small window of its own offering:
%     Copy            – put the current content on the system clipboard.
%     Save as image   – write the current content to an image file.
%     To workspace    – assign one or more variables in the base workspace
%                       (see exportSpec below).
%
%   The window is a separate uifigure rather than a uiconfirm dialog: an
%   in-figure dialog is clipped by, and cannot be dragged out of, the window
%   it belongs to, so on a small image window its buttons were unreachable.
%   Being a window of its own, it has to be closed deliberately: it closes
%   itself once an action has completed, and it is taken down with FIG when
%   that panel (or the whole GUI) is closed.
%
%   For panels that show an image, two content modes are offered:
%     'pixels'  (default) – the displayed image array itself, one file pixel
%                 per data pixel, no overlays and no border.  Copy hands the
%                 array to the clipboard as a bitmap and Save writes it with
%                 imwrite, so both give exactly what "To workspace" gives.
%     'panel'   – the axes as drawn, cross-hair / ROI overlays included, via
%                 copygraphics / exportgraphics at screen resolution.  This
%                 goes through the renderer, so expect a one-pixel border
%                 and ±1 px rounding.
%   A plot axes has no image to export 1:1, so it always uses 'panel'.
%
%   fig             - parent uifigure (only used to place this window)
%   ax             - axes whose content is copied / saved
%   exportSpec     - N×2 cell {suffix, @()value; ...} describing the
%                    workspace export. The user is prompted for a base name;
%                    each row is assigned to  <base><suffix> = value().
%                    Use a single row with an empty suffix to export one
%                    plain variable. Example (image window):
%                       {'_raw',     @() MatVisRender.getRawFullSlice(model); ...
%                        '_display', @() imgHandle.CData}
%   defaultVarName - suggested base-workspace variable name
%   defaultFileName- suggested file name for "Save as image..."

if nargin < 4 || isempty(defaultVarName),  defaultVarName  = 'matVisData'; end
if nargin < 5 || isempty(defaultFileName), defaultFileName = 'matVisImage.png'; end

imgHandle = imageChild(ax);
hasImage  = ~isempty(imgHandle);

W = 470;  H = 118;
if hasImage, H = 152; end
dlg = uifigure('Name', 'matVis — export', 'NumberTitle', 'off', ...
    'Position', dialogPosition(fig, W, H), 'Resize', 'off', 'Visible', 'off');

nRows = 2;  rowH = {22, 30};
if hasImage, nRows = 3;  rowH = {22, 28, 30}; end
grid = uigridlayout(dlg, [nRows, 1]);
grid.RowHeight   = rowH;
grid.ColumnWidth = {'1x'};
grid.Padding     = [10 10 10 8];
grid.RowSpacing  = 8;

uilabel(grid, 'Text', 'Export the current content of this panel:', 'FontSize', 11);

dropMode = [];
if hasImage
    modeRow = uigridlayout(grid, [1, 2]);
    modeRow.ColumnWidth = {60, '1x'};
    modeRow.RowHeight   = {'1x'};
    modeRow.Padding     = [0 0 0 0];
    modeRow.ColumnSpacing = 6;
    uilabel(modeRow, 'Text', 'Content:', 'FontSize', 11, ...
        'HorizontalAlignment', 'right');
    dropMode = uidropdown(modeRow, 'FontSize', 11, ...
        'Items', {'Image pixels (1:1, no overlays)', ...
                  'Panel as displayed (overlays, screen scale)'}, ...
        'ItemsData', {'pixels', 'panel'}, 'Value', 'pixels', ...
        'Tooltip', sprintf(['Image pixels: exactly the displayed array — same size and\n' ...
                            'same values as the workspace export.\n' ...
                            'Panel as displayed: rendered by MATLAB, so overlays are\n' ...
                            'included but the result is not pixel-exact.']));
end

btnRow = uigridlayout(grid, [1, 4]);
btnRow.ColumnWidth   = {'1x', '1x', '1x', '1x'};
btnRow.RowHeight     = {'1x'};
btnRow.Padding       = [0 0 0 0];
btnRow.ColumnSpacing = 8;

uibutton(btnRow, 'push', 'Text', 'Copy', 'FontSize', 11, ...
    'Tooltip', 'Copy to the system clipboard', ...
    'ButtonPushedFcn', @(~,~) onCopy());
uibutton(btnRow, 'push', 'Text', 'Save as image...', 'FontSize', 11, ...
    'ButtonPushedFcn', @(~,~) onSave());
uibutton(btnRow, 'push', 'Text', 'To workspace...', 'FontSize', 11, ...
    'ButtonPushedFcn', @(~,~) onWorkspace());
uibutton(btnRow, 'push', 'Text', 'Cancel', 'FontSize', 11, ...
    'ButtonPushedFcn', @(~,~) delete(dlg));

% This window is not a child of the panel it exports, so nothing would take
% it down with the panel — closing the main GUI (which deletes the image /
% zoom / plot figures) used to leave it orphaned on screen.  The listener is
% parked in the dialog's UserData so it dies with the dialog and cannot fire
% on a stale handle.
dlg.UserData = addlistener(fig, 'ObjectBeingDestroyed', @(~,~) finish());

dlg.Visible = 'on';

% -------------------------------------------------------------------------
    function finish()
        % One export per window: the dialog closes as soon as an action has
        % completed, and on the way out when its panel disappears.
        if isvalid(dlg), delete(dlg); end
    end

    function mode = contentMode()
        mode = 'panel';
        if hasImage && isgraphics(dropMode), mode = dropMode.Value; end
    end

    function onCopy()
        if ~isvalid(ax)
            uialert(dlg, 'The panel is gone.', 'Copy');  return;
        end
        try
            if strcmp(contentMode(), 'pixels')
                [done, why] = copyImageToClipboard(imgHandle.CData);
                if done
                    [h, w, ~] = size(imgHandle.CData);
                    fprintf('[matVis2] Copied %d x %d image to the clipboard\n', w, h);
                    finish();  return;
                end
                % No bitmap clipboard (non-Windows, .NET missing, clipboard
                % held by another process): the rendered path at least gets
                % something across.
                fprintf('[matVis2] Bitmap copy unavailable (%s) — copying the rendered panel\n', why);
            end
            copygraphics(ax, 'ContentType', 'image', 'BackgroundColor', 'current');
            fprintf('[matVis2] Copied the panel to the clipboard\n');
            finish();
        catch me
            uialert(dlg, sprintf('Copy failed: %s', me.message), 'Copy');
        end
    end

    function onSave()
        if ~isvalid(ax)
            uialert(dlg, 'The panel is gone.', 'Save as image');  return;
        end
        filters = { ...
            '*.png', 'PNG image (*.png)'; ...
            '*.tif', 'TIFF image (*.tif)'; ...
            '*.jpg', 'JPEG image (*.jpg)'; ...
            '*.pdf', 'PDF (*.pdf)'};
        [fn, fp] = uiputfile(filters, 'Save as image', defaultFileName);
        if isequal(fn, 0), return; end
        outFile = fullfile(fp, fn);
        [~, ~, ext] = fileparts(fn);
        raster = strcmp(contentMode(), 'pixels') && ...
                 any(strcmpi(ext, {'.png', '.tif', '.tiff', '.jpg', '.jpeg', '.bmp'}));
        try
            if raster
                imwrite(imgHandle.CData, outFile);
                [h, w, ~] = size(imgHandle.CData);
                fprintf('[matVis2] Saved %d x %d image to "%s"\n', w, h, outFile);
            else
                % Rendered output: pin the resolution to the screen's so the
                % file matches the panel instead of the 150 dpi default.
                exportgraphics(ax, outFile, ...
                    'Resolution', get(0, 'ScreenPixelsPerInch'));
                fprintf('[matVis2] Saved the panel to "%s"\n', outFile);
            end
            finish();
        catch me
            uialert(dlg, sprintf('Save failed: %s', me.message), 'Save as image');
        end
    end

    function onWorkspace()
        answer = inputdlg('Workspace variable name:', 'Export to workspace', ...
                          1, {defaultVarName});
        if isempty(answer), return; end
        baseName = strtrim(answer{1});

        % Every <base><suffix> combination must be a legal variable name.
        for i = 1:size(exportSpec, 1)
            if ~isvarname([baseName, exportSpec{i, 1}])
                uialert(dlg, 'Invalid variable name.', 'Export to workspace');
                return;
            end
        end

        try
            made = cell(1, size(exportSpec, 1));
            for i = 1:size(exportSpec, 1)
                vn = [baseName, exportSpec{i, 1}];
                assignin('base', vn, exportSpec{i, 2}());
                made{i} = vn;
            end
            fprintf('[matVis2] Exported to workspace: %s\n', strjoin(made, ', '));
            finish();
        catch me
            uialert(dlg, sprintf('Export failed: %s', me.message), 'Export to workspace');
        end
    end

end % MatVisExportMenu

% -------------------------------------------------------------------------
function h = imageChild(ax)
    % The panel's image, or [] for an axes that shows no image (plot window).
    h = [];
    if ~isgraphics(ax), return; end
    c = findobj(ax, 'Type', 'image');
    for k = 1:numel(c)
        if size(c(k).CData, 1) > 1 && size(c(k).CData, 2) > 1
            h = c(k);  return;
        end
    end
end

% -------------------------------------------------------------------------
function pos = dialogPosition(fig, w, h)
    % Centre on the parent window, then clamp to the screen so the buttons
    % are reachable however small or off-screen the parent is.
    ss = get(0, 'ScreenSize');
    x  = (ss(3) - w) / 2;
    y  = (ss(4) - h) / 2;
    if ~isempty(fig) && isgraphics(fig)
        p = fig.Position;
        x = p(1) + (p(3) - w) / 2;
        y = p(2) + (p(4) - h) / 2;
    end
    x = min(max(x, 10), max(10, ss(3) - w - 10));
    y = min(max(y, 60), max(60, ss(4) - h - 60));
    pos = round([x, y, w, h]);
end
