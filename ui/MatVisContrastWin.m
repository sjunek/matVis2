function cw = MatVisContrastWin(parent, model, renderFcn)
% MatVisContrastWin  Colormap / gamma / contrast control panel.
%   Slider range is fixed to model.DataMin / model.DataMax for the lifetime
%   of this panel — never updated per-slice.

COLORMAP_NAMES = { ...
    'Gray', 'Gray (Range)', '4xGray', 'Turbo', 'Parula', 'Jet', 'HSV', 'Hot', 'Cool', ...
    'Red1', 'Green1', 'Blue1', 'Cyan1', 'Magenta1', 'Yellow1', ...
    'Red2', 'Green2', 'Blue2', 'Cyan2', 'Magenta2', 'Yellow2', ...
    'Rainbow1', 'Rainbow2', 'Rainbow3', 'Rainbow4', 'Rainbow5', 'Rainbow6', ...
    'Blue-Gray-Yellow', 'Blue-Gray-Red', 'Green-Gray-Red', 'Magenta-Gray-Green'};

% Fixed global data bounds — never change per slice
gMin = model.DataMin;
gMax = model.DataMax;
if gMin == gMax, gMax = gMin + 1; end
rangeSpan = gMax - gMin;

grid = uigridlayout(parent, [5 1]);
grid.RowHeight   = {'fit', 'fit', 'fit', 'fit', '1x'};
grid.ColumnWidth = {'1x'};
grid.Padding     = [4 4 4 4];
grid.RowSpacing  = 4;

% --- Colormap row ---
rowCmap = uigridlayout(grid, [1 2]);
rowCmap.Layout.Row  = 1;
rowCmap.ColumnWidth = {'fit', '1x'};
rowCmap.Padding     = [0 0 0 0];
uilabel(rowCmap, 'Text', 'Colormap');
cw.dropColormap = uidropdown(rowCmap, ...
    'Items', COLORMAP_NAMES, ...
    'Value', COLORMAP_NAMES{min(model.ColormapIdx, numel(COLORMAP_NAMES))}, ...
    'ValueChangedFcn', @onColormapChanged);

% --- Gamma row ---
rowGamma = uigridlayout(grid, [1 3]);
rowGamma.Layout.Row  = 2;
rowGamma.ColumnWidth = {'fit', '1x', 50};
rowGamma.Padding     = [0 0 0 0];
uilabel(rowGamma, 'Text', 'Gamma');
cw.sliderGamma = uislider(rowGamma);
cw.sliderGamma.Limits          = [0.1 5.0];
cw.sliderGamma.Value           = model.Gamma;
cw.sliderGamma.ValueChangedFcn = @onGammaSliderChanged;
cw.editGamma = uieditfield(rowGamma, 'numeric', ...
    'Limits', [0.1 5.0], 'Value', model.Gamma, ...
    'ValueChangedFcn', @onGammaEditChanged);

% --- Contrast Min row ---
rowCMin = uigridlayout(grid, [1 3]);
rowCMin.Layout.Row  = 3;
rowCMin.ColumnWidth = {'fit', '1x', 70};
rowCMin.Padding     = [0 0 0 0];
uilabel(rowCMin, 'Text', 'C Min');
cw.sliderCMin = uislider(rowCMin);
cw.sliderCMin.Limits          = [gMin gMax];
cw.sliderCMin.Value           = max(gMin, min(gMax, model.ContrastMin));
cw.sliderCMin.ValueChangedFcn = @onCMinSliderChanged;
cw.editCMin = uieditfield(rowCMin, 'numeric', ...
    'Limits', [gMin gMax], 'Value', max(gMin, min(gMax, model.ContrastMin)), ...
    'ValueChangedFcn', @onCMinEditChanged);

% --- Contrast Max row ---
rowCMax = uigridlayout(grid, [1 3]);
rowCMax.Layout.Row  = 4;
rowCMax.ColumnWidth = {'fit', '1x', 70};
rowCMax.Padding     = [0 0 0 0];
uilabel(rowCMax, 'Text', 'C Max');
cw.sliderCMax = uislider(rowCMax);
cw.sliderCMax.Limits          = [gMin gMax];
cw.sliderCMax.Value           = max(gMin, min(gMax, model.ContrastMax));
cw.sliderCMax.ValueChangedFcn = @onCMaxSliderChanged;
cw.editCMax = uieditfield(rowCMax, 'numeric', ...
    'Limits', [gMin gMax], 'Value', max(gMin, min(gMax, model.ContrastMax)), ...
    'ValueChangedFcn', @onCMaxEditChanged);

% --- Histogram axes ---
cw.axesHistogram = uiaxes(grid);
cw.axesHistogram.Layout.Row = 5;
cw.axesHistogram.XTick = [];
cw.axesHistogram.YTick = [];
cw.axesHistogram.Box   = 'off';
cw.axesHistogram.XLim  = [gMin gMax];
disableDefaultInteractivity(cw.axesHistogram);

cw.Update = @updatePanel;

% -------------------------------------------------------------------------
    function onColormapChanged(~, evt)
        model.ColormapIdx = find(strcmp(COLORMAP_NAMES, evt.Value), 1);
        renderFcn();
    end

    function onGammaSliderChanged(~, evt)
        model.Gamma        = evt.Value;
        cw.editGamma.Value = evt.Value;
        renderFcn();
    end

    function onGammaEditChanged(~, evt)
        model.Gamma          = evt.Value;
        cw.sliderGamma.Value = evt.Value;
        renderFcn();
    end

    function onCMinSliderChanged(~, evt)
        v = evt.Value;
        if v >= cw.sliderCMax.Value
            v = cw.sliderCMax.Value - rangeSpan * 1e-6;
            cw.sliderCMin.Value = v;
        end
        model.ContrastMin  = v;
        cw.editCMin.Value  = v;
        renderFcn();
    end

    function onCMinEditChanged(~, evt)
        v = evt.Value;
        if v >= model.ContrastMax
            v = model.ContrastMax - rangeSpan * 1e-6;
            cw.editCMin.Value = v;
        end
        model.ContrastMin   = v;
        cw.sliderCMin.Value = v;
        renderFcn();
    end

    function onCMaxSliderChanged(~, evt)
        v = evt.Value;
        if v <= cw.sliderCMin.Value
            v = cw.sliderCMin.Value + rangeSpan * 1e-6;
            cw.sliderCMax.Value = v;
        end
        model.ContrastMax  = v;
        cw.editCMax.Value  = v;
        renderFcn();
    end

    function onCMaxEditChanged(~, evt)
        v = evt.Value;
        if v <= model.ContrastMin
            v = model.ContrastMin + rangeSpan * 1e-6;
            cw.editCMax.Value = v;
        end
        model.ContrastMax   = v;
        cw.sliderCMax.Value = v;
        renderFcn();
    end

    function updatePanel(slice2D)
        % Only updates the histogram — slider range is fixed to global data bounds.
        if isempty(slice2D), return; end
        flat  = double(slice2D(:));
        nBins = min(256, max(2, numel(flat)));
        [counts, edges] = histcounts(flat * (gMax - gMin) + gMin, ...
                                     linspace(gMin, gMax, nBins + 1));
        bar(cw.axesHistogram, edges(1:end-1), counts, 1, ...
            'FaceColor', [0.4 0.4 0.4], 'EdgeColor', 'none');
        cw.axesHistogram.XLim  = [gMin gMax];
        cw.axesHistogram.XTick = [];
        cw.axesHistogram.YTick = [];
    end

end
