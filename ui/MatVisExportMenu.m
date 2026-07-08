function MatVisExportMenu(fig, ax, exportSpec, defaultVarName, defaultFileName)
% MatVisExportMenu  Double-click action menu for image / zoom / plot content.
%
%   MatVisExportMenu(fig, ax, exportSpec, defaultVarName, defaultFileName)
%
%   Presents the user with a choice of:
%     Copy                – copy the current content of `ax` to the system
%                           clipboard as an image (copygraphics).
%     Export to workspace – assign one or more variables to the base
%                           workspace (see exportSpec below).
%     Save as image...    – write the content of `ax` to an image file
%                           (exportgraphics: png/jpg/tif/pdf).
%
%   fig             - parent uifigure (anchors the dialogs)
%   ax             - axes whose visible content is copied / saved
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

sel = uiconfirm(fig, ...
    'Choose an action for the current content:', 'matVis', ...
    'Options', {'Copy', 'Export to workspace', 'Save as image...', 'Cancel'}, ...
    'DefaultOption', 1, 'CancelOption', 4);

switch sel
    case 'Copy'
        copyToClipboard(fig, ax);
    case 'Export to workspace'
        exportToWorkspace(fig, exportSpec, defaultVarName);
    case 'Save as image...'
        saveAsImage(fig, ax, defaultFileName);
end

end % MatVisExportMenu

% -------------------------------------------------------------------------
function copyToClipboard(fig, ax)
    try
        copygraphics(ax, 'BackgroundColor', 'current');
    catch me
        uialert(fig, sprintf('Copy failed: %s', me.message), 'matVis');
    end
end

% -------------------------------------------------------------------------
function exportToWorkspace(fig, spec, defaultName)
    answer = inputdlg('Workspace variable name:', 'Export to workspace', ...
                      1, {defaultName});
    if isempty(answer), return; end
    baseName = strtrim(answer{1});

    % Every <base><suffix> combination must be a legal variable name.
    for i = 1:size(spec, 1)
        if ~isvarname([baseName, spec{i, 1}])
            uialert(fig, 'Invalid variable name.', 'Export to workspace');
            return;
        end
    end

    try
        made = cell(1, size(spec, 1));
        for i = 1:size(spec, 1)
            vn = [baseName, spec{i, 1}];
            assignin('base', vn, spec{i, 2}());
            made{i} = vn;
        end
        fprintf('[matVis2] Exported to workspace: %s\n', strjoin(made, ', '));
    catch me
        uialert(fig, sprintf('Export failed: %s', me.message), 'Export to workspace');
    end
end

% -------------------------------------------------------------------------
function saveAsImage(fig, ax, defaultFile)
    filters = { ...
        '*.png', 'PNG image (*.png)'; ...
        '*.jpg', 'JPEG image (*.jpg)'; ...
        '*.tif', 'TIFF image (*.tif)'; ...
        '*.pdf', 'PDF (*.pdf)'};
    [fn, fp] = uiputfile(filters, 'Save as image', defaultFile);
    if isequal(fn, 0), return; end
    try
        exportgraphics(ax, fullfile(fp, fn));
        fprintf('[matVis2] Saved current content to "%s"\n', fullfile(fp, fn));
    catch me
        uialert(fig, sprintf('Save failed: %s', me.message), 'Save as image');
    end
end
