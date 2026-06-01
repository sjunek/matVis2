function cw = MatVisContrastWin(parent, model, renderFcn)
% Constructor for contrast/colormap control panel.
% Returns handles struct cw with UI components and an Update function.

COLORMAP_NAMES = { ...
    'Gray', 'Gray (Range)', '4xGray', 'Turbo', 'Parula', 'Jet', 'HSV', 'Hot', 'Cool', ...
    'Red1', 'Green1', 'Blue1', 'Cyan1', 'Magenta1', 'Yellow1', ...
    'Red2', 'Green2', 'Blue2', 'Cyan2', 'Magenta2', 'Yellow2', ...
    'Rainbow1', 'Rainbow2', 'Rainbow3', 'Rainbow4', 'Rainbow5', 'Rainbow6', ...
    'Blue-Gray-Yellow', 'Blue-Gray-Red', 'Green-Gray-Red', 'Magenta-Gray-Green'};

dataMin = 0;
dataMax = 1;

grid = uigridlayout(parent, [5 1]);
grid.RowHeight   = {'fit', 'fit', 'fit', 'fit', '1x'};
grid.ColumnWidth = {'1x'};
grid.Padding     = [4 4 4 4];
grid.RowSpacing  = 4;

% --- Colormap row ---
rowCmap = uigridlayout(grid, [1 2]);
rowCmap.Layout.Row    = 1;
rowCmap.ColumnWidth   = {'fit', '1x'};
rowCmap.Padding       = [0 0 0 0];
rowCmap.RowSpacing    = 0;

uilabel(rowCmap, 'Text', 'Colormap');

cw.dropColormap = uidropdown(rowCmap, ...
    'Items', COLORMAP_NAMES, ...
    'Value', COLORMAP_NAMES{model.ColormapIdx}, ...
    'ValueChangedFcn', @onColormapChanged);

% --- Gamma row ---
rowGamma = uigridlayout(grid, [1 3]);
rowGamma.Layout.Row   = 2;
rowGamma.ColumnWidth  = {'fit', '1x', 50};
rowGamma.Padding      = [0 0 0 0];
rowGamma.RowSpacing   = 0;

uilabel(rowGamma, 'Text', 'Gamma');

cw.sliderGamma = uislider(rowGamma);
cw.sliderGamma.Limits = [0.1 5.0];
cw.sliderGamma.Value  = model.Gamma;
cw.sliderGamma.ValueChangedFcn = @onGammaSliderChanged;

cw.editGamma = uieditfield(rowGamma, 'numeric', ...
    'Limits', [0.1 5.0], ...
    'LowerLimitInclusive', 'on', ...
    'UpperLimitInclusive', 'on', ...
    'Value', model.Gamma, ...
    'ValueChangedFcn', @onGammaEditChanged);

% --- Contrast Min row ---
rowCMin = uigridlayout(grid, [1 3]);
rowCMin.Layout.Row   = 3;
rowCMin.ColumnWidth  = {'fit', '1x', 50};
rowCMin.Padding      = [0 0 0 0];
rowCMin.RowSpacing   = 0;

uilabel(rowCMin, 'Text', 'C Min');

cw.sliderCMin = uislider(rowCMin);
cw.sliderCMin.Limits = [dataMin dataMax];
cw.sliderCMin.Value  = max(dataMin, min(dataMax, model.ContrastMin));
cw.sliderCMin.ValueChangedFcn = @onCMinSliderChanged;

cw.editCMin = uieditfield(rowCMin, 'numeric', ...
    'Value', model.ContrastMin, ...
    'ValueChangedFcn', @onCMinEditChanged);

% --- Contrast Max row ---
rowCMax = uigridlayout(grid, [1 3]);
rowCMax.Layout.Row   = 4;
rowCMax.ColumnWidth  = {'fit', '1x', 50};
rowCMax.Padding      = [0 0 0 0];
rowCMax.RowSpacing   = 0;

uilabel(rowCMax, 'Text', 'C Max');

cw.sliderCMax = uislider(rowCMax);
cw.sliderCMax.Limits = [dataMin dataMax];
cw.sliderCMax.Value  = max(dataMin, min(dataMax, model.ContrastMax));
cw.sliderCMax.ValueChangedFcn = @onCMaxSliderChanged;

cw.editCMax = uieditfield(rowCMax, 'numeric', ...
    'Value', model.ContrastMax, ...
    'ValueChangedFcn', @onCMaxEditChanged);

% --- Histogram axes ---
cw.axesHistogram = uiaxes(grid);
cw.axesHistogram.Layout.Row = 5;
cw.axesHistogram.XTick = [];
cw.axesHistogram.YTick = [];
cw.axesHistogram.Box   = 'off';
cw.axesHistogram.Title.String = '';
disableDefaultInteractivity(cw.axesHistogram);

% --- Update function ---
cw.Update = @updatePanel;

% -------------------------------------------------------------------------
    function onColormapChanged(~, evt)
        model.ColormapIdx = find(strcmp(COLORMAP_NAMES, evt.Value), 1);
        renderFcn();
    end

    function onGammaSliderChanged(~, evt)
        model.Gamma = evt.Value;
        cw.editGamma.Value = evt.Value;
        renderFcn();
    end

    function onGammaEditChanged(~, evt)
        model.Gamma = evt.Value;
        cw.sliderGamma.Value = evt.Value;
        renderFcn();
    end

    function onCMinSliderChanged(~, evt)
        v = evt.Value;
        if v >= cw.sliderCMax.Value
            v = cw.sliderCMax.Value - diff(cw.sliderCMax.Limits) * 1e-6;
            cw.sliderCMin.Value = v;
        end
        model.ContrastMin  = v;
        cw.editCMin.Value  = v;
        renderFcn();
    end

    function onCMinEditChanged(~, evt)
        v = evt.Value;
        if v >= model.ContrastMax
            v = model.ContrastMax - diff(cw.sliderCMax.Limits) * 1e-6;
            cw.editCMin.Value = v;
        end
        model.ContrastMin   = v;
        cw.sliderCMin.Value = v;
        renderFcn();
    end

    function onCMaxSliderChanged(~, evt)
        v = evt.Value;
        if v <= cw.sliderCMin.Value
            v = cw.sliderCMin.Value + diff(cw.sliderCMin.Limits) * 1e-6;
            cw.sliderCMax.Value = v;
        end
        model.ContrastMax  = v;
        cw.editCMax.Value  = v;
        renderFcn();
    end

    function onCMaxEditChanged(~, evt)
        v = evt.Value;
        if v <= model.ContrastMin
            v = model.ContrastMin + diff(cw.sliderCMin.Limits) * 1e-6;
            cw.editCMax.Value = v;
        end
        model.ContrastMax   = v;
        cw.sliderCMax.Value = v;
        renderFcn();
    end

    function updatePanel(slice2D)
        if isempty(slice2D)
            return;
        end
        dMin = double(min(slice2D(:)));
        dMax = double(max(slice2D(:)));
        if dMin == dMax
            dMax = dMin + 1;
        end
        dataMin = dMin; %#ok<NASGU>
        dataMax = dMax; %#ok<NASGU>

        % Update slider ranges — must set Limits before Value to avoid out-of-range errors
        cw.sliderCMin.Limits = [dMin dMax];
        cw.sliderCMax.Limits = [dMin dMax];

        % Clamp current contrast values inside new range
        newCMin = max(model.ContrastMin, dMin);
        newCMax = min(model.ContrastMax, dMax);
        if newCMin >= newCMax
            newCMin = dMin;
            newCMax = dMax;
        end
        model.ContrastMin   = newCMin;
        model.ContrastMax   = newCMax;
        cw.sliderCMin.Value = newCMin;
        cw.sliderCMax.Value = newCMax;
        cw.editCMin.Value   = newCMin;
        cw.editCMax.Value   = newCMax;

        % Recompute and draw histogram
        flat  = double(slice2D(:));
        nBins = min(256, numel(flat));
        [counts, edges] = histcounts(flat, nBins);
        bar(cw.axesHistogram, edges(1:end-1), counts, 1, ...
            'FaceColor', [0.4 0.4 0.4], 'EdgeColor', 'none');
        cw.axesHistogram.XLim  = [dMin dMax];
        cw.axesHistogram.XTick = [];
        cw.axesHistogram.YTick = [];
    end

end
