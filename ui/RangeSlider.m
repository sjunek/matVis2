function rs = RangeSlider(parent, dimIdx, nSteps, label, onPositionChanged, onZoomChanged)
% RangeSlider  Custom position + zoom-range control for one data dimension.
%
%   rs = RangeSlider(parent, dimIdx, nSteps, label, onPositionChanged, onZoomChanged)
%
%   Inputs
%   ------
%   parent             : uigridlayout cell or uipanel that owns this control
%   dimIdx             : integer — which dimension this slider represents
%   nSteps             : total number of steps (size of data along this dim)
%   label              : string label for the dimension
%   onPositionChanged  : function handle @(val) called when position changes
%   onZoomChanged      : function handle @(lo, hi) called when zoom range changes
%
%   Returns struct rs with fields
%   -----------------------------
%   rs.panel           uipanel container
%   rs.label           uilabel
%   rs.editPos         uieditfield (current position, 1..nSteps)
%   rs.sliderPos       uislider    (main position slider)
%   rs.editZoomMin     uieditfield (zoom range lower bound)
%   rs.editZoomMax     uieditfield (zoom range upper bound)
%   rs.btnPlay         uibutton    (toggle — play animation)
%   rs.plotCheck       uicheckbox  (show profile plot for this dim)
%   rs.SetValue        @(val)      set position programmatically
%   rs.GetZoomRange    @()         returns [lo, hi]
%   rs.SetZoomRange    @(lo, hi)   set zoom range programmatically
%   rs.GetPlotChecked  @()         returns logical

    arguments
        parent
        dimIdx    (1,1) double {mustBeInteger, mustBePositive}
        nSteps    (1,1) double {mustBeInteger, mustBePositive}
        label     (1,:) char
        onPositionChanged (1,1) function_handle
        onZoomChanged     (1,1) function_handle
    end

    % ------------------------------------------------------------------ %
    %  Container panel                                                     %
    % ------------------------------------------------------------------ %
    rs.panel = uipanel(parent, ...
        'BorderType', 'none', ...
        'BackgroundColor', [0.94 0.94 0.94]);

    % Inner grid: 7 columns, 1 row
    % [Label | EditPos | Slider | EditZoomMin | EditZoomMax | PlayBtn | PlotCheck]
    grid = uigridlayout(rs.panel, [1, 7]);
    grid.ColumnWidth = {'fit', 50, '1x', 50, 50, 40, 40};
    grid.RowHeight   = {22};
    grid.Padding     = [2 1 2 1];
    grid.ColumnSpacing = 3;

    % ------------------------------------------------------------------ %
    %  Widgets                                                             %
    % ------------------------------------------------------------------ %
    rs.label = uilabel(grid, ...
        'Text', label, ...
        'HorizontalAlignment', 'right', ...
        'FontWeight', 'bold');
    rs.label.Layout.Column = 1;

    rs.editPos = uieditfield(grid, 'numeric', ...
        'Value', 1, ...
        'Limits', [1 nSteps], ...
        'RoundFractionalValues', true, ...
        'HorizontalAlignment', 'center', ...
        'Tooltip', sprintf('Current position for dimension %s (1..%d)', label, nSteps));
    rs.editPos.Layout.Column = 2;

    rs.sliderPos = uislider(grid, ...
        'Limits', [1 nSteps], ...
        'Value', 1, ...
        'MajorTicksMode', 'none', ...
        'MinorTicks', [], ...
        'Tooltip', sprintf('Position slider for dimension %s', label));
    rs.sliderPos.Layout.Column = 3;

    rs.editZoomMin = uieditfield(grid, 'numeric', ...
        'Value', 1, ...
        'Limits', [1 nSteps], ...
        'RoundFractionalValues', true, ...
        'HorizontalAlignment', 'center', ...
        'Tooltip', 'Zoom range minimum');
    rs.editZoomMin.Layout.Column = 4;

    rs.editZoomMax = uieditfield(grid, 'numeric', ...
        'Value', nSteps, ...
        'Limits', [1 nSteps], ...
        'RoundFractionalValues', true, ...
        'HorizontalAlignment', 'center', ...
        'Tooltip', 'Zoom range maximum');
    rs.editZoomMax.Layout.Column = 5;

    rs.btnPlay = uibutton(grid, 'state', ...
        'Text', char(9654), ...
        'Tooltip', 'Play animation through zoom range');
    rs.btnPlay.Layout.Column = 6;

    rs.plotCheck = uicheckbox(grid, ...
        'Text', 'P', ...
        'Value', false, ...
        'Tooltip', 'Show 1-D profile plot for this dimension');
    rs.plotCheck.Layout.Column = 7;

    % ------------------------------------------------------------------ %
    %  Callbacks                                                           %
    % ------------------------------------------------------------------ %
    rs.sliderPos.ValueChangedFcn   = @onSliderChanged;
    rs.editPos.ValueChangedFcn     = @onEditPosChanged;
    rs.editZoomMin.ValueChangedFcn = @onZoomEditChanged;
    rs.editZoomMax.ValueChangedFcn = @onZoomEditChanged;

    % ------------------------------------------------------------------ %
    %  Public API — function handles                                       %
    % ------------------------------------------------------------------ %
    rs.SetValue       = @setValue;
    rs.GetZoomRange   = @getZoomRange;
    rs.SetZoomRange   = @setZoomRange;
    rs.GetPlotChecked = @getPlotChecked;

    % ================================================================== %
    %  Local functions                                                     %
    % ================================================================== %
    function onSliderChanged(~, ~)
        val = round(rs.sliderPos.Value);
        rs.sliderPos.Value = val;
        rs.editPos.Value   = val;
        onPositionChanged(val);
    end

    function onEditPosChanged(~, ~)
        val = round(rs.editPos.Value);
        val = max(1, min(nSteps, val));
        rs.editPos.Value   = val;
        rs.sliderPos.Value = val;
        onPositionChanged(val);
    end

    function onZoomEditChanged(~, ~)
        lo = round(rs.editZoomMin.Value);
        hi = round(rs.editZoomMax.Value);
        lo = max(1, min(nSteps, lo));
        hi = max(1, min(nSteps, hi));
        if lo > hi
            tmp = lo; lo = hi; hi = tmp;
        end
        rs.editZoomMin.Value = lo;
        rs.editZoomMax.Value = hi;
        onZoomChanged(lo, hi);
    end

    function setValue(val)
        val = round(max(1, min(nSteps, val)));
        rs.sliderPos.Value = val;
        rs.editPos.Value   = val;
    end

    function range = getZoomRange()
        range = [rs.editZoomMin.Value, rs.editZoomMax.Value];
    end

    function setZoomRange(lo, hi)
        lo = round(max(1, min(nSteps, lo)));
        hi = round(max(1, min(nSteps, hi)));
        if lo > hi
            tmp = lo; lo = hi; hi = tmp;
        end
        rs.editZoomMin.Value = lo;
        rs.editZoomMax.Value = hi;
    end

    function tf = getPlotChecked()
        tf = logical(rs.plotCheck.Value);
    end

end
