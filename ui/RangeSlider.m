classdef RangeSlider < matlab.ui.componentcontainer.ComponentContainer
% RangeSlider  Custom combined position + zoom-range slider component.
%
%   Visual layout (one row per dimension):
%     [DimLabel] [PosEdit] [===zoom====|pos|====zoom===] [ZoomMin] [ZoomMax] [Play] [P]
%
%   The track is drawn on a uiaxes:
%     - Gray bar   : full range
%     - Blue patch : zoom region between ZoomMin and ZoomMax
%     - Red marker : current position Value
%
%   Clicking anywhere on the track moves the position marker.
%
%   Properties (set after construction to configure):
%     Value    - current position (integer, 1-based)
%     ZoomMin  - zoom range lower bound
%     ZoomMax  - zoom range upper bound
%     Limits   - [lo, hi] total range (e.g. [1, nSteps])
%     DimLabel - label string shown on the left
%     ShowPlot - logical, state of the profile-plot checkbox
%
%   Events (use addlistener to wire callbacks):
%     ValueChanged  - Value was set via edit field or track click; src.Value
%     ZoomChanged   - ZoomMin/ZoomMax changed; src.ZoomMin, src.ZoomMax
%     PlayToggled   - play button toggled; src.BtnPlay_.Value for state
%     PlotToggled   - plot checkbox toggled; src.ShowPlot

    properties
        Value    (1,1) double  = 1
        ZoomMin  (1,1) double  = 1
        ZoomMax  (1,1) double  = 2
        Limits   (1,2) double  = [1 2]
        DimLabel (1,:) char    = ''
        ShowPlot (1,1) logical = false
    end

    events (HasCallbackProperty, NotifyAccess = protected)
        ValueChanged
        ZoomChanged
        PlayToggled
        PlotToggled
    end

    properties (Access = private, Transient, NonCopyable)
        Grid_        matlab.ui.container.GridLayout
        LabelComp_   matlab.ui.control.Label
        EditPos_     matlab.ui.control.NumericEditField
        TrackAx_     matlab.ui.control.UIAxes
        BgPatch_
        ZoomPatch_
        PosPatch_
        EditZoomMin_ matlab.ui.control.NumericEditField
        EditZoomMax_ matlab.ui.control.NumericEditField
        BtnPlay_     matlab.ui.control.StateButton
        ChkPlot_     matlab.ui.control.CheckBox
    end

    methods (Access = protected)

        function setup(obj)
            obj.Grid_ = uigridlayout(obj, [1 7]);
            obj.Grid_.ColumnWidth   = {80, 45, '1x', 45, 45, 28, 28};
            obj.Grid_.RowHeight     = {'1x'};
            obj.Grid_.Padding       = [2 1 2 1];
            obj.Grid_.ColumnSpacing = 3;

            % -- Label --
            obj.LabelComp_ = uilabel(obj.Grid_, ...
                'Text', '', ...
                'HorizontalAlignment', 'right', ...
                'FontWeight', 'bold');
            obj.LabelComp_.Layout.Column = 1;

            % -- Position edit --
            obj.EditPos_ = uieditfield(obj.Grid_, 'numeric', ...
                'Value', 1, ...
                'Limits', [1 2], ...
                'RoundFractionalValues', true, ...
                'HorizontalAlignment', 'center', ...
                'Tooltip', 'Current position');
            obj.EditPos_.Layout.Column = 2;
            obj.EditPos_.ValueChangedFcn = @obj.onEditPosChanged_;

            % -- Track axes --
            obj.TrackAx_ = uiaxes(obj.Grid_);
            obj.TrackAx_.Layout.Column = 3;
            obj.TrackAx_.XLim    = [0 1];
            obj.TrackAx_.YLim    = [0 1];
            obj.TrackAx_.XTick   = [];
            obj.TrackAx_.YTick   = [];
            obj.TrackAx_.Box     = 'off';
            obj.TrackAx_.XColor  = 'none';
            obj.TrackAx_.YColor  = 'none';
            obj.TrackAx_.Color   = 'none';
            disableDefaultInteractivity(obj.TrackAx_);

            % Background bar
            obj.BgPatch_ = patch(obj.TrackAx_, ...
                [0 1 1 0], [0.38 0.38 0.62 0.62], ...
                [0.78 0.78 0.78], 'EdgeColor', 'none', 'PickableParts', 'all');
            obj.BgPatch_.ButtonDownFcn = @obj.onTrackClick_;

            % Zoom region
            obj.ZoomPatch_ = patch(obj.TrackAx_, ...
                [0 1 1 0], [0.25 0.25 0.75 0.75], ...
                [0.45 0.65 1.0], ...
                'EdgeColor', [0.2 0.4 0.8], 'LineWidth', 0.5, ...
                'PickableParts', 'all');
            obj.ZoomPatch_.ButtonDownFcn = @obj.onTrackClick_;

            % Position marker (thin red bar)
            obj.PosPatch_ = patch(obj.TrackAx_, ...
                [0 0 0.005 0.005], [0.1 0.9 0.9 0.1], ...
                [0.9 0.15 0.15], 'EdgeColor', 'none', 'PickableParts', 'all');
            obj.PosPatch_.ButtonDownFcn = @obj.onTrackClick_;

            obj.TrackAx_.ButtonDownFcn = @obj.onTrackClick_;

            % -- Zoom min edit --
            obj.EditZoomMin_ = uieditfield(obj.Grid_, 'numeric', ...
                'Value', 1, ...
                'Limits', [1 2], ...
                'RoundFractionalValues', true, ...
                'HorizontalAlignment', 'center', ...
                'Tooltip', 'Zoom range minimum');
            obj.EditZoomMin_.Layout.Column = 4;
            obj.EditZoomMin_.ValueChangedFcn = @obj.onZoomMinChanged_;

            % -- Zoom max edit --
            obj.EditZoomMax_ = uieditfield(obj.Grid_, 'numeric', ...
                'Value', 2, ...
                'Limits', [1 2], ...
                'RoundFractionalValues', true, ...
                'HorizontalAlignment', 'center', ...
                'Tooltip', 'Zoom range maximum');
            obj.EditZoomMax_.Layout.Column = 5;
            obj.EditZoomMax_.ValueChangedFcn = @obj.onZoomMaxChanged_;

            % -- Play toggle button --
            obj.BtnPlay_ = uibutton(obj.Grid_, 'state', ...
                'Text', char(9654), ...
                'Tooltip', 'Play animation across zoom range');
            obj.BtnPlay_.Layout.Column = 6;
            obj.BtnPlay_.ValueChangedFcn = @obj.onPlayToggled_;

            % -- Plot checkbox --
            obj.ChkPlot_ = uicheckbox(obj.Grid_, ...
                'Text', 'P', ...
                'Value', false, ...
                'Tooltip', 'Show 1-D profile plot for this dimension');
            obj.ChkPlot_.Layout.Column = 7;
            obj.ChkPlot_.ValueChangedFcn = @obj.onPlotToggled_;
        end

        function update(obj)
            if isempty(obj.LabelComp_) || ~isvalid(obj.LabelComp_)
                return;
            end

            lo = obj.Limits(1);
            hi = obj.Limits(2);
            if hi <= lo
                hi = lo + 1;
            end

            obj.LabelComp_.Text = obj.DimLabel;

            v = max(lo, min(hi, obj.Value));
            obj.EditPos_.Limits = [lo hi];
            obj.EditPos_.Value  = v;

            zm = max(lo, min(hi, obj.ZoomMin));
            zx = max(lo, min(hi, obj.ZoomMax));
            if zm >= zx
                zx = min(hi, zm + 1);
            end
            obj.EditZoomMin_.Limits = [lo hi];
            obj.EditZoomMin_.Value  = zm;
            obj.EditZoomMax_.Limits = [lo hi];
            obj.EditZoomMax_.Value  = zx;

            obj.ChkPlot_.Value = obj.ShowPlot;

            % Update track patches (normalized 0..1 coords)
            range = hi - lo;
            zminN = (zm - lo) / range;
            zmaxN = (zx - lo) / range;
            posN  = (v  - lo) / range;

            obj.ZoomPatch_.XData = [zminN zmaxN zmaxN zminN];

            hw = max(0.004, 0.4 / max(range, 1));  % half-width of position marker
            obj.PosPatch_.XData = [max(0,posN-hw), max(0,posN-hw), ...
                                   min(1,posN+hw), min(1,posN+hw)];
        end
    end

    methods (Access = private)
        function onEditPosChanged_(obj, src, ~)
            obj.Value = round(src.Value);
            notify(obj, 'ValueChanged');
        end

        function onZoomMinChanged_(obj, src, ~)
            newMin = round(src.Value);
            obj.ZoomMin = max(obj.Limits(1), min(newMin, obj.ZoomMax - 1));
            notify(obj, 'ZoomChanged');
        end

        function onZoomMaxChanged_(obj, src, ~)
            newMax = round(src.Value);
            obj.ZoomMax = min(obj.Limits(2), max(newMax, obj.ZoomMin + 1));
            notify(obj, 'ZoomChanged');
        end

        function onTrackClick_(obj, ~, ~)
            cp = obj.TrackAx_.CurrentPoint;
            if isempty(cp), return; end
            x   = max(0, min(1, cp(1, 1)));
            lo  = obj.Limits(1);
            hi  = obj.Limits(2);
            val = round(lo + x * (hi - lo));
            val = max(lo, min(hi, val));
            obj.Value = val;
            notify(obj, 'ValueChanged');
        end

        function onPlayToggled_(obj, ~, ~)
            notify(obj, 'PlayToggled');
        end

        function onPlotToggled_(obj, src, ~)
            obj.ShowPlot = src.Value;
            notify(obj, 'PlotToggled');
        end
    end
end
