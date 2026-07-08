classdef RangeSlider < matlab.ui.componentcontainer.ComponentContainer
% RangeSlider  Custom combined position + zoom-range slider component.
%
%   Visual layout (two rows per dimension):
%     Row 1: [DimLabel] [PosEdit] [← | track | →] [PlayBtns] [chk] [lock]
%     Row 2:            [ZoomMin] [–] [ZoomMax] [: N]
%
%   Mouse interactions on the track:
%     Left-click / left-drag   → move / drag position marker
%     Middle-click / drag      → resize zoom edges or pan zoom bar
%
%   Cursor feedback (hover, no color in MATLAB uifigure — shape only):
%     Over position area       → 'crosshair'  (requested: light-red   cross)
%     Over zoom edges          → 'fleur'      (requested: light-blue  cross)
%     Over zoom body           → 'hand'       (requested: light-blue  hand)
%
%   Step buttons (← / →):
%     Click        → position ±1
%     Ctrl+click   → position ±10
%
%   Properties:
%     Value    ZoomMin  ZoomMax  Limits  DimLabel
%     ShowPlot PlotLock PlayMode IsPlaying
%
%   Events:
%     ValueChanged  ZoomChanged  PlayModeChanged
%     PlotToggled   PlotLockToggled

    properties
        Value    (1,1) double  = 1
        ZoomMin  (1,1) double  = 1
        ZoomMax  (1,1) double  = 2
        Limits   (1,2) double  = [1 2]
        DimLabel (1,:) char    = ''
        ShowPlot (1,1) logical = false
        PlotLock (1,1) logical = false
        PlayMode (1,:) char    = 'none'
        IsPlaying (1,1) logical = false
        ScaleFactor (1,1) double = 1    % real-world size of one index step
        ScaleUnit (1,:) char   = ''     % unit for the real-world scale ('' = none)
    end

    events (HasCallbackProperty, NotifyAccess = protected)
        ValueChanged
        ZoomChanged
        PlayModeChanged
        PlayToggled       % deprecated
        PlotToggled
        PlotLockToggled
    end

    properties (Access = private, Transient, NonCopyable)
        Grid_          matlab.ui.container.GridLayout
        LabelComp_     matlab.ui.control.Label
        EditPos_       matlab.ui.control.NumericEditField
        TrackAx_       matlab.ui.control.UIAxes
        BgPatch_
        ZoomPatch_
        PosPatch_
        BtnPlayFull_   matlab.ui.control.StateButton
        BtnPlayZoom_   matlab.ui.control.StateButton
        BtnPlayShift_  matlab.ui.control.StateButton
        ChkPlot_       matlab.ui.control.CheckBox
        BtnPlotLock_   matlab.ui.control.StateButton
        ZoomMinEdit_   matlab.ui.control.NumericEditField
        ZoomMaxEdit_   matlab.ui.control.NumericEditField
        ZoomLenLabel_  matlab.ui.control.Label

        DragState_  (1,:) char = 'none'   % 'none'|'pos'|'zoomLeft'|'zoomRight'|'zoomBar'
        DragOffset_ (1,1) double = 0
        LockIconState_ (1,1) double = -1  % last PlotLock state pushed as icon (-1 = never)
    end

    % ==================================================================
    methods (Access = protected)

        function setup(obj)
            % Grid: 2 rows × 6 cols
            % [label(50) | posEdit(38) | trackArea(1x) | play(84) | chk(20) | lock(24)]
            % Row 1 = 32 px so the track axes is tall enough for a visible zoom bar
            % (~29 px at 0.9 fill). Controls are vertically centred to stay 26 px.
            obj.Grid_ = uigridlayout(obj, [2 6]);
            obj.Grid_.ColumnWidth   = {38, 38, '1x', 84, 20, 24};
            obj.Grid_.RowHeight     = {32, 18};
            obj.Grid_.Padding       = [2 1 2 1];
            obj.Grid_.ColumnSpacing = 3;
            obj.Grid_.RowSpacing    = 2;

            % -- Dim label --
            obj.LabelComp_ = uilabel(obj.Grid_, ...
                'Text', '', ...
                'HorizontalAlignment', 'left', ...
                'FontWeight', 'bold', ...
                'FontSize', 13, ...
                'Tooltip', 'Dimension name');
            obj.LabelComp_.Layout.Row    = 1;
            obj.LabelComp_.Layout.Column = 1;

            % -- Position edit (vertically centred → 26 px in 32 px row) --
            posContainer = uigridlayout(obj.Grid_, [3, 1]);
            posContainer.Layout.Row    = 1;
            posContainer.Layout.Column = 2;
            posContainer.RowHeight     = {'1x', 26, '1x'};
            posContainer.ColumnWidth   = {'1x'};
            posContainer.Padding       = [0 0 0 0];
            posContainer.RowSpacing    = 0;

            obj.EditPos_ = uieditfield(posContainer, 'numeric', ...
                'Value', 1, ...
                'Limits', [1 2], ...
                'RoundFractionalValues', true, ...
                'HorizontalAlignment', 'center', ...
                'FontSize', 11, ...
                'Tooltip', 'Current frame — type a number to jump directly');
            obj.EditPos_.Layout.Row    = 2;
            obj.EditPos_.Layout.Column = 1;
            obj.EditPos_.ValueChangedFcn = @obj.onEditPosChanged_;

            % -- Track area: [← step btn | axes | step → btn] --
            % 3-row container: axes spans all rows (32 px); step buttons are
            % centred in row 2 (26 px) so they stay visually 26 px tall.
            trackContainer = uigridlayout(obj.Grid_, [3, 3]);
            trackContainer.Layout.Row    = 1;
            trackContainer.Layout.Column = 3;
            trackContainer.ColumnWidth   = {16, '1x', 16};
            trackContainer.RowHeight     = {'1x', 26, '1x'};
            trackContainer.Padding       = [0 0 0 0];
            trackContainer.ColumnSpacing = 1;
            trackContainer.RowSpacing    = 0;

            btnStepLeft = uibutton(trackContainer, 'push', ...
                'Text', '', ...
                'Icon', RangeSlider.makeTriangleIcon_(12, 'left'), ...
                'Tooltip', sprintf('Step back 1 frame\nCtrl+click: step back 10 frames'));
            btnStepLeft.Layout.Row    = 2;
            btnStepLeft.Layout.Column = 1;
            btnStepLeft.ButtonPushedFcn = @obj.onStepLeft_;

            obj.TrackAx_ = uiaxes(trackContainer);
            obj.TrackAx_.Layout.Row    = [1, 3];
            obj.TrackAx_.Layout.Column = 2;
            obj.TrackAx_.XLim    = [0 1];
            obj.TrackAx_.YLim    = [0 1];
            obj.TrackAx_.XTick   = [];
            obj.TrackAx_.YTick   = [];
            obj.TrackAx_.Box     = 'off';
            obj.TrackAx_.XColor  = 'none';
            obj.TrackAx_.YColor  = 'none';
            obj.TrackAx_.Color   = 'none';
            disableDefaultInteractivity(obj.TrackAx_);
            % Remove the axes toolbar entirely (not just Visible='off'): since
            % R2026a the toolbar has a collapse/expand chevron that Visible does
            % not hide and that steals vertical space. Setting Toolbar = []
            % removes it (also works on older releases).
            try; obj.TrackAx_.Toolbar = []; catch; end

            btnStepRight = uibutton(trackContainer, 'push', ...
                'Text', '', ...
                'Icon', RangeSlider.makeTriangleIcon_(12, 'right'), ...
                'Tooltip', sprintf('Step forward 1 frame\nCtrl+click: step forward 10 frames'));
            btnStepRight.Layout.Row    = 2;
            btnStepRight.Layout.Column = 3;
            btnStepRight.ButtonPushedFcn = @obj.onStepRight_;

            % Patches (drawn after axes is parented)
            obj.BgPatch_ = patch(obj.TrackAx_, ...
                [0 1 1 0], [0.1 0.1 0.9 0.9], ...
                [0.78 0.78 0.78], 'EdgeColor', 'none', 'PickableParts', 'all');
            obj.BgPatch_.ButtonDownFcn = @obj.onTrackClick_;

            obj.ZoomPatch_ = patch(obj.TrackAx_, ...
                [0 1 1 0], [0.05 0.05 0.95 0.95], ...
                [0.45 0.65 1.0], ...
                'EdgeColor', [0.2 0.4 0.8], 'LineWidth', 1.0, ...
                'PickableParts', 'all');
            obj.ZoomPatch_.ButtonDownFcn = @obj.onTrackClick_;

            obj.PosPatch_ = patch(obj.TrackAx_, ...
                [0 0 0.005 0.005], [0 1 1 0], ...
                [0.9 0.15 0.15], 'EdgeColor', [0.6 0 0], 'LineWidth', 0.5, ...
                'PickableParts', 'all');
            obj.PosPatch_.ButtonDownFcn = @obj.onTrackClick_;

            obj.TrackAx_.ButtonDownFcn = @obj.onTrackClick_;

            % -- Play buttons (vertically centred → 26 px in 32 px row) --
            playContainer = uigridlayout(obj.Grid_, [3, 1]);
            playContainer.Layout.Row    = 1;
            playContainer.Layout.Column = 4;
            playContainer.RowHeight     = {'1x', 26, '1x'};
            playContainer.ColumnWidth   = {'1x'};
            playContainer.Padding       = [0 0 0 0];
            playContainer.RowSpacing    = 0;

            playGrid = uigridlayout(playContainer, [1, 3]);
            playGrid.Layout.Row    = 2;
            playGrid.Layout.Column = 1;
            playGrid.RowHeight     = {'1x'};
            playGrid.ColumnWidth   = {'1x', '1x', '1x'};
            playGrid.Padding       = [0 0 0 0];
            playGrid.ColumnSpacing = 2;

            % ▶  full range  |▶|  zoom range  ▶▶  shift window
            obj.BtnPlayFull_ = uibutton(playGrid, 'state', ...
                'Text', char(9654), ...
                'FontSize', 12, ...
                'Tooltip', 'Play: step through the full dimension range');
            obj.BtnPlayFull_.Layout.Row    = 1;
            obj.BtnPlayFull_.Layout.Column = 1;
            obj.BtnPlayFull_.ValueChangedFcn = @obj.onPlayFullToggled_;

            obj.BtnPlayZoom_ = uibutton(playGrid, 'state', ...
                'Text', ['|' char(9654) '|'], ...
                'FontSize', 10, ...
                'Tooltip', 'Play: step through the current zoom range only');
            obj.BtnPlayZoom_.Layout.Row    = 1;
            obj.BtnPlayZoom_.Layout.Column = 2;
            obj.BtnPlayZoom_.ValueChangedFcn = @obj.onPlayZoomToggled_;

            obj.BtnPlayShift_ = uibutton(playGrid, 'state', ...
                'Text', [char(9654) char(9654)], ...
                'FontSize', 10, ...
                'Tooltip', 'Play: advance the zoom window forward one step at a time');
            obj.BtnPlayShift_.Layout.Row    = 1;
            obj.BtnPlayShift_.Layout.Column = 3;
            obj.BtnPlayShift_.ValueChangedFcn = @obj.onPlayShiftToggled_;

            % -- Profile-plot checkbox (col 5, no text label) --
            obj.ChkPlot_ = uicheckbox(obj.Grid_, ...
                'Text', '', ...
                'Value', false, ...
                'FontSize', 9, ...
                'Tooltip', 'Show 1-D intensity profile plot for this dimension');
            obj.ChkPlot_.Layout.Row    = 1;
            obj.ChkPlot_.Layout.Column = 5;
            obj.ChkPlot_.ValueChangedFcn = @obj.onPlotToggled_;

            % -- Plot zoom lock button (col 6, vertically centred → 26 px) --
            lockContainer = uigridlayout(obj.Grid_, [3, 1]);
            lockContainer.Layout.Row    = 1;
            lockContainer.Layout.Column = 6;
            lockContainer.RowHeight     = {'1x', 26, '1x'};
            lockContainer.ColumnWidth   = {'1x'};
            lockContainer.Padding       = [0 0 0 0];
            lockContainer.RowSpacing    = 0;

            obj.BtnPlotLock_ = uibutton(lockContainer, 'state', ...
                'Text', '', ...
                'Icon', RangeSlider.makeOpenLockIcon_(14), ...
                'Value', false, ...
                'Tooltip', sprintf(['Lock profile-plot X-axis to current zoom range.\n' ...
                    'When active, the plot shows only data within the zoom interval.']));
            obj.BtnPlotLock_.Layout.Row    = 2;
            obj.BtnPlotLock_.Layout.Column = 1;
            obj.BtnPlotLock_.ValueChangedFcn = @obj.onPlotLockToggled_;

            % -- Row 2: zoom min/max edits + length, centred under track (col 3) --
            % Layout: [1x pad | ZoomMin(38) | sep(12) | ZoomMax(38) | len(30) | 1x pad]
            zoomRow = uigridlayout(obj.Grid_, [1, 6]);
            zoomRow.Layout.Row    = 2;
            zoomRow.Layout.Column = 3;        % track column only — keeps edits under track
            zoomRow.RowHeight     = {'1x'};
            zoomRow.ColumnWidth   = {6, 38, 12, 38, 'fit', '1x'};
            zoomRow.Padding       = [0 0 0 0];
            zoomRow.ColumnSpacing = 2;

            obj.ZoomMinEdit_ = uieditfield(zoomRow, 'numeric', ...
                'Value', 1, 'Limits', [1 2], ...
                'RoundFractionalValues', true, ...
                'HorizontalAlignment', 'center', ...
                'FontSize', 10, ...
                'Tooltip', 'Zoom range start - type to set precisely');
            obj.ZoomMinEdit_.Layout.Column = 2;
            obj.ZoomMinEdit_.ValueChangedFcn = @obj.onZoomMinEditChanged_;

            sepLbl = uilabel(zoomRow, 'Text', char(8211), ...
                'HorizontalAlignment', 'center', 'FontSize', 10);
            sepLbl.Layout.Column = 3;

            obj.ZoomMaxEdit_ = uieditfield(zoomRow, 'numeric', ...
                'Value', 2, 'Limits', [1 2], ...
                'RoundFractionalValues', true, ...
                'HorizontalAlignment', 'center', ...
                'FontSize', 10, ...
                'Tooltip', 'Zoom range end - type to set precisely');
            obj.ZoomMaxEdit_.Layout.Column = 4;
            obj.ZoomMaxEdit_.ValueChangedFcn = @obj.onZoomMaxEditChanged_;

            obj.ZoomLenLabel_ = uilabel(zoomRow, ...
                'Text', '', ...
                'HorizontalAlignment', 'left', ...
                'FontSize', 10, ...
                'FontColor', [0.35 0.35 0.35], ...
                'Tooltip', ['Zoom range length in indices, and — when a real-world ' ...
                            'scale is defined for this dimension — in scaled units']);
            obj.ZoomLenLabel_.Layout.Column = [5 6];

            obj.DragState_  = 'none';
            obj.DragOffset_ = 0;

            % Register with figure-level hover dispatcher
            obj.installHoverTracking_();
        end

        function update(obj)
            % update() runs after EVERY public property change (e.g. each
            % playback frame).  Each widget write is a roundtrip to the web
            % renderer, so only properties that actually changed are pushed.
            if isempty(obj.LabelComp_) || ~isvalid(obj.LabelComp_)
                return;
            end

            lo = obj.Limits(1);
            hi = obj.Limits(2);
            if hi <= lo, hi = lo + 1; end

            obj.setIfChanged_(obj.LabelComp_, 'Text', obj.DimLabel);

            v = max(lo, min(hi, obj.Value));
            obj.setIfChanged_(obj.EditPos_, 'Limits', [lo hi]);
            obj.setIfChanged_(obj.EditPos_, 'Value',  v);

            zm = max(lo, min(hi, obj.ZoomMin));
            zx = max(lo, min(hi, obj.ZoomMax));
            if zm >= zx, zx = min(hi, zm + 1); end

            obj.setIfChanged_(obj.ChkPlot_,     'Value', obj.ShowPlot);
            obj.setIfChanged_(obj.BtnPlotLock_, 'Value', obj.PlotLock);
            if obj.LockIconState_ ~= double(obj.PlotLock)
                if obj.PlotLock
                    obj.BtnPlotLock_.Icon = RangeSlider.makeLockIcon_(14);
                else
                    obj.BtnPlotLock_.Icon = RangeSlider.makeOpenLockIcon_(14);
                end
                obj.LockIconState_ = double(obj.PlotLock);
            end

            obj.setIfChanged_(obj.ZoomMinEdit_, 'Limits', [lo, hi - 1]);
            obj.setIfChanged_(obj.ZoomMinEdit_, 'Value',  zm);
            obj.setIfChanged_(obj.ZoomMaxEdit_, 'Limits', [lo + 1, hi]);
            obj.setIfChanged_(obj.ZoomMaxEdit_, 'Value',  zx);
            obj.setIfChanged_(obj.ZoomLenLabel_, 'Text', obj.zoomLenText_(zx - zm + 1));

            pauseTxt  = '||';
            txtFull   = char(9654);
            txtZoom   = ['|' char(9654) '|'];
            txtShift  = [char(9654) char(9654)];
            valFull   = false;  valZoom = false;  valShift = false;
            switch obj.PlayMode
                case 'full'
                    valFull = obj.IsPlaying;
                    if obj.IsPlaying, txtFull = pauseTxt; end
                case 'zoom'
                    valZoom = obj.IsPlaying;
                    if obj.IsPlaying, txtZoom = pauseTxt; end
                case 'shift'
                    valShift = obj.IsPlaying;
                    if obj.IsPlaying, txtShift = pauseTxt; end
            end
            obj.setIfChanged_(obj.BtnPlayFull_,  'Value', valFull);
            obj.setIfChanged_(obj.BtnPlayFull_,  'Text',  txtFull);
            obj.setIfChanged_(obj.BtnPlayZoom_,  'Value', valZoom);
            obj.setIfChanged_(obj.BtnPlayZoom_,  'Text',  txtZoom);
            obj.setIfChanged_(obj.BtnPlayShift_, 'Value', valShift);
            obj.setIfChanged_(obj.BtnPlayShift_, 'Text',  txtShift);

            range = hi - lo;
            zminN = (zm - lo) / range;
            zmaxN = (zx - lo) / range;
            posN  = (v  - lo) / range;

            obj.setIfChanged_(obj.ZoomPatch_, 'XData', [zminN zmaxN zmaxN zminN]);
            hw = max(0.006, 1.0 / max(range, 1));
            obj.setIfChanged_(obj.PosPatch_, 'XData', ...
                [max(0,posN-hw), max(0,posN-hw), min(1,posN+hw), min(1,posN+hw)]);
        end
    end

    % ==================================================================
    methods (Access = private)

        function setIfChanged_(~, h, prop, val)
            % Write a widget property only when the value differs.
            % (Patch XData reads back as a column vector, hence the (:).)
            cur = h.(prop);
            if isnumeric(cur) && isnumeric(val)
                if isequaln(cur(:), val(:)), return; end
            elseif isequal(cur, val)
                return;
            end
            h.(prop) = val;
        end

        % ---- Edit / zoom callbacks -----------------------------------

        function onEditPosChanged_(obj, src, ~)
            obj.Value = round(src.Value);
            notify(obj, 'ValueChanged');
        end

        function onZoomMinEditChanged_(obj, src, ~)
            zm = max(obj.Limits(1), min(obj.ZoomMax - 1, round(src.Value)));
            if zm ~= obj.ZoomMin
                obj.ZoomMin = zm;
                notify(obj, 'ZoomChanged');
            end
        end

        function onZoomMaxEditChanged_(obj, src, ~)
            zx = max(obj.ZoomMin + 1, min(obj.Limits(2), round(src.Value)));
            if zx ~= obj.ZoomMax
                obj.ZoomMax = zx;
                notify(obj, 'ZoomChanged');
            end
        end

        % ---- Step buttons -------------------------------------------

        function onStepLeft_(obj, ~, ~)
            step = obj.ctrlStep_();
            newVal = max(obj.Limits(1), obj.Value - step);
            if newVal ~= obj.Value
                obj.Value = newVal;
                notify(obj, 'ValueChanged');
            end
        end

        function onStepRight_(obj, ~, ~)
            step = obj.ctrlStep_();
            newVal = min(obj.Limits(2), obj.Value + step);
            if newVal ~= obj.Value
                obj.Value = newVal;
                notify(obj, 'ValueChanged');
            end
        end

        function s = ctrlStep_(obj)
            fig = ancestor(obj, 'figure');
            if ~isempty(fig) && isvalid(fig) && ismember('control', fig.CurrentModifier)
                s = 10;
            else
                s = 1;
            end
        end

        % ---- Track mouse interactions --------------------------------

        function onTrackClick_(obj, ~, ~)
            cp = obj.TrackAx_.CurrentPoint;
            if isempty(cp), return; end
            x = max(0, min(1, cp(1, 1)));

            lo    = obj.Limits(1);
            hi    = obj.Limits(2);
            range = hi - lo;

            fig = ancestor(obj, 'figure');

            switch obj.hitTest_(x)
                case 'zoomLeft'
                    obj.DragState_ = 'zoomLeft';
                case 'zoomRight'
                    obj.DragState_ = 'zoomRight';
                case 'zoomBar'
                    obj.DragState_  = 'zoomBar';
                    zminN = (obj.ZoomMin - lo) / max(range, 1);
                    obj.DragOffset_ = x - zminN;
                otherwise   % 'pos'
                    obj.DragState_ = 'pos';
                    newVal = max(lo, min(hi, round(lo + x * range)));
                    if newVal ~= obj.Value
                        obj.Value = newVal;
                        notify(obj, 'ValueChanged');
                    end
            end

            if ~isempty(fig) && isvalid(fig)
                % Save the current motion handler so onMouseUp_ can restore it.
                setappdata(fig, 'RS_SavedMotionFcn', fig.WindowButtonMotionFcn);
                fig.WindowButtonMotionFcn = @obj.onMouseMove_;
                fig.WindowButtonUpFcn     = @obj.onMouseUp_;
            end
        end

        function target = hitTest_(obj, x)
            % Decide which element a click/hover at normalized x targets.
            % Returns 'pos' | 'zoomLeft' | 'zoomRight' | 'zoomBar'.
            %
            % The position indicator has PRIORITY: when the cursor is inside
            % the position hit zone and no closer to a zoom edge, position
            % wins.  This matters for short dimensions, where edgeTol/hw span
            % most of the track and the zoom edges would otherwise always be
            % picked first — making the position marker impossible to grab.
            lo    = obj.Limits(1);
            hi    = obj.Limits(2);
            range = hi - lo;
            if range <= 0, range = 1; end

            zminN = (obj.ZoomMin - lo) / range;
            zmaxN = (obj.ZoomMax - lo) / range;
            posN  = (obj.Value   - lo) / range;
            % Cap edgeTol so it can't swallow the whole track on short dims.
            hw      = max(0.008, 1.0 / max(range, 1));
            edgeTol = min(0.15, max(0.02, 4 / max(range, 1)));

            dPos   = abs(x - posN);
            dLeft  = abs(x - zminN);
            dRight = abs(x - zmaxN);

            if dPos <= hw + edgeTol && dPos <= dLeft && dPos <= dRight
                target = 'pos';
            elseif dLeft <= edgeTol
                target = 'zoomLeft';
            elseif dRight <= edgeTol
                target = 'zoomRight';
            elseif x > zminN + edgeTol && x < zmaxN - edgeTol
                target = 'zoomBar';
            else
                target = 'pos';
            end
        end

        function onMouseMove_(obj, ~, ~)
            % Installed as WindowButtonMotionFcn during a drag.
            if strcmp(obj.DragState_, 'none'), return; end
            cp = obj.TrackAx_.CurrentPoint;
            if isempty(cp), return; end
            x = max(0, min(1, cp(1, 1)));

            lo    = obj.Limits(1);
            hi    = obj.Limits(2);
            range = hi - lo;

            switch obj.DragState_
                case 'pos'
                    newVal = max(lo, min(hi, round(lo + x * range)));
                    if newVal ~= obj.Value
                        obj.Value = newVal;
                        notify(obj, 'ValueChanged');
                    end
                case 'zoomLeft'
                    zm = max(lo, min(obj.ZoomMax - 1, round(lo + x * range)));
                    if zm ~= obj.ZoomMin
                        obj.ZoomMin = zm;
                        notify(obj, 'ZoomChanged');
                    end
                case 'zoomRight'
                    zx = max(obj.ZoomMin + 1, min(hi, round(lo + x * range)));
                    if zx ~= obj.ZoomMax
                        obj.ZoomMax = zx;
                        notify(obj, 'ZoomChanged');
                    end
                case 'zoomBar'
                    width  = obj.ZoomMax - obj.ZoomMin;
                    newMin = max(lo, min(hi - width, ...
                                 round(lo + (x - obj.DragOffset_) * range)));
                    if newMin ~= obj.ZoomMin
                        obj.ZoomMin = newMin;
                        obj.ZoomMax = newMin + width;
                        notify(obj, 'ZoomChanged');
                    end
            end

            % Keep cursor in sync with the active drag type
            fig = ancestor(obj, 'figure');
            if ~isempty(fig) && isvalid(fig)
                switch obj.DragState_
                    case 'pos'
                        fig.Pointer = 'crosshair';
                    case 'zoomLeft'
                        fig.Pointer = 'left';
                    case 'zoomRight'
                        fig.Pointer = 'right';
                    case 'zoomBar'
                        fig.Pointer = 'hand';
                end
            end
        end

        function onMouseUp_(obj, ~, ~)
            obj.DragState_ = 'none';
            fig = ancestor(obj, 'figure');
            if ~isempty(fig) && isvalid(fig)
                fig.WindowButtonUpFcn = '';
                % Restore whatever motion handler was active before the drag.
                savedFcn = getappdata(fig, 'RS_SavedMotionFcn');
                if ~isempty(savedFcn)
                    fig.WindowButtonMotionFcn = savedFcn;
                else
                    fig.WindowButtonMotionFcn = @RangeSlider.hoverDispatch_;
                end
                c = obj.GetHoverCursor();
                if ~isempty(c), fig.Pointer = c; else, fig.Pointer = 'arrow'; end
            end
        end

        % ---- Hover cursor logic -------------------------------------

        function installHoverTracking_(obj)
            % Register this slider with the figure's shared motion dispatcher.
            fig = ancestor(obj, 'figure');
            if isempty(fig) || ~isvalid(fig), return; end

            list = getappdata(fig, 'RS_HoverList');
            if isempty(list), list = {}; end
            list{end+1} = obj;
            setappdata(fig, 'RS_HoverList', list);

            % Install dispatcher only once per figure.
            % Use isequal to avoid the ~[] == false pitfall when key is absent.
            if ~isequal(getappdata(fig, 'RS_MotionInstalled'), true)
                setappdata(fig, 'RS_MotionInstalled', true);
                fig.WindowButtonMotionFcn = @RangeSlider.hoverDispatch_;
            end
        end

        function cursor = getHoverCursor_(obj)
            % Return cursor string if mouse is over this track, else ''.
            % Uses CurrentPoint — same data path as onTrackClick_ — so
            % cursor display and drag behaviour are always in sync.
            cursor = '';
            if ~isvalid(obj.TrackAx_), return; end
            fig = ancestor(obj, 'figure');
            if isempty(fig) || ~isvalid(fig), return; end

            % Quick pixel-based guard: skip sliders whose track is far away.
            figPt = fig.CurrentPoint;
            try
                axPos = getpixelposition(obj.TrackAx_, true);
            catch
                return;
            end
            xRel = figPt(1) - axPos(1);
            yRel = figPt(2) - axPos(2);
            % Allow a generous margin so the pixel and CurrentPoint checks agree.
            edgePx = max(8, axPos(3) * 0.04);
            if xRel < -edgePx || xRel > axPos(3) + edgePx || ...
               yRel < -4      || yRel > axPos(4) + 4
                return;
            end

            % Hit-test using CurrentPoint — identical to onTrackClick_.
            cp = obj.TrackAx_.CurrentPoint;
            if isempty(cp), return; end
            x = max(0, min(1, cp(1,1)));

            switch obj.hitTest_(x)
                case 'zoomLeft',  cursor = 'left';
                case 'zoomRight', cursor = 'right';
                case 'zoomBar',   cursor = 'hand';
                otherwise,        cursor = 'crosshair';
            end
        end

        % ---- Play callbacks -----------------------------------------

        function onPlayFullToggled_(obj, src, ~)
            if src.Value
                obj.PlayMode  = 'full';
                obj.IsPlaying = true;
                obj.BtnPlayZoom_.Value   = false;
                obj.BtnPlayZoom_.Enable  = 'off';
                obj.BtnPlayShift_.Value  = false;
                obj.BtnPlayShift_.Enable = 'off';
            else
                obj.PlayMode  = 'none';
                obj.IsPlaying = false;
                obj.BtnPlayZoom_.Enable  = 'on';
                obj.BtnPlayShift_.Enable = 'on';
            end
            notify(obj, 'PlayModeChanged');
            notify(obj, 'PlayToggled');
        end

        function onPlayZoomToggled_(obj, src, ~)
            if src.Value
                obj.PlayMode  = 'zoom';
                obj.IsPlaying = true;
                obj.BtnPlayFull_.Value   = false;
                obj.BtnPlayFull_.Enable  = 'off';
                obj.BtnPlayShift_.Value  = false;
                obj.BtnPlayShift_.Enable = 'off';
            else
                obj.PlayMode  = 'none';
                obj.IsPlaying = false;
                obj.BtnPlayFull_.Enable  = 'on';
                obj.BtnPlayShift_.Enable = 'on';
            end
            notify(obj, 'PlayModeChanged');
            notify(obj, 'PlayToggled');
        end

        function onPlayShiftToggled_(obj, src, ~)
            if src.Value
                obj.PlayMode  = 'shift';
                obj.IsPlaying = true;
                obj.BtnPlayFull_.Value   = false;
                obj.BtnPlayFull_.Enable  = 'off';
                obj.BtnPlayZoom_.Value   = false;
                obj.BtnPlayZoom_.Enable  = 'off';
            else
                obj.PlayMode  = 'none';
                obj.IsPlaying = false;
                obj.BtnPlayFull_.Enable  = 'on';
                obj.BtnPlayZoom_.Enable  = 'on';
            end
            notify(obj, 'PlayModeChanged');
            notify(obj, 'PlayToggled');
        end

        function onPlotToggled_(obj, src, ~)
            obj.ShowPlot = src.Value;
            notify(obj, 'PlotToggled');
        end

        function onPlotLockToggled_(obj, src, ~)
            obj.PlotLock = logical(src.Value);
            if src.Value
                src.Icon = RangeSlider.makeLockIcon_(14);
            else
                src.Icon = RangeSlider.makeOpenLockIcon_(14);
            end
            notify(obj, 'PlotLockToggled');
        end

        % ---- Utility ------------------------------------------------

        function out = orDefault_(~, val, def)
            if isempty(val), out = def; else, out = val; end
        end

        function txt = zoomLenText_(obj, nPx)
            % Zoom-range length label.  Shows the index count and, when a
            % real-world scale is defined, the scaled length, e.g.
            % '120 px (240 µm)'.  Falls back to the plain ': N' form when the
            % dimension has no scaling information.
            if ~isempty(obj.ScaleUnit) || abs(obj.ScaleFactor - 1) > 1e-9
                realLen = nPx * obj.ScaleFactor;
                if isempty(obj.ScaleUnit)
                    txt = sprintf('%d px (%.4g)', nPx, realLen);
                else
                    txt = sprintf('%d px (%.4g %s)', nPx, realLen, obj.ScaleUnit);
                end
            else
                txt = sprintf(': %d', nPx);
            end
        end
    end

    % ==================================================================
    methods (Static, Access = private)

        function img = makeLockIcon_(sz)
            % Closed padlock icon: 3-channel RGB. Body + closed U-shackle.
            bg = 0.94;  fg = 0.18;
            img = bg * ones(sz, sz, 3);
            bL = round(sz * 0.18);  bR = sz + 1 - round(sz * 0.18);
            bT = round(sz * 0.52);  bB = min(sz, round(sz * 0.93));
            img(bT:bB, bL:bR, :) = fg;
            sL = round(sz * 0.32);  sR = sz + 1 - round(sz * 0.32);
            sT = max(1, round(sz * 0.10));  sw = max(2, round(sz * 0.13));
            img(sT:bT,      sL:sL+sw-1, :) = fg;   % left wall
            img(sT:bT,      sR-sw+1:sR, :) = fg;   % right wall
            img(sT:sT+sw-1, sL:sR,      :) = fg;   % top bar
        end

        function img = makeOpenLockIcon_(sz)
            % Open padlock icon: body + shackle with right side raised (open).
            bg = 0.94;  fg = 0.18;
            img = bg * ones(sz, sz, 3);
            bL = round(sz * 0.18);  bR = sz + 1 - round(sz * 0.18);
            bT = round(sz * 0.52);  bB = min(sz, round(sz * 0.93));
            img(bT:bB, bL:bR, :) = fg;
            sL = round(sz * 0.32);  sR = sz + 1 - round(sz * 0.32);
            sT = max(1, round(sz * 0.10));  sw = max(2, round(sz * 0.13));
            img(sT:bT,      sL:sL+sw-1, :) = fg;   % left wall (connects to body)
            img(sT:sT+sw-1, sL:sR,      :) = fg;   % top bar
            openEnd = max(sT+sw, round(sz * 0.32));
            img(sT:openEnd, sR-sw+1:sR,  :) = fg;  % right wall (short — open)
        end

        function img = makeTriangleIcon_(sz, direction)
            % Filled triangle, 3-channel RGB. direction: 'left' | 'right'
            bg = 0.94;  fg = 0.25;
            img = bg * ones(sz, sz, 3);

            pad = max(1, round(sz * 0.15));
            rLo = pad;  rHi = sz - pad + 1;
            cLo = pad;  cHi = sz - pad + 1;

            for r = rLo:rHi
                t  = (r - rLo) / max(rHi - rLo, 1);
                ww = 1 - abs(2*t - 1);
                if strcmp(direction, 'right')
                    c1 = cLo;
                    c2 = round(cLo + ww * (cHi - cLo));
                else
                    c2 = cHi;
                    c1 = round(cHi - ww * (cHi - cLo));
                end
                c1 = max(1, c1);  c2 = min(sz, c2);
                if c2 >= c1
                    img(r, c1:c2, :) = fg;
                end
            end
        end


        function hoverDispatch_(fig, ~)
            % Cursor-only hover handler. Active when no drag is in progress.
            % onTrackClick_ replaces this with a per-slider drag handler;
            % onMouseUp_ reinstates it.
            list = getappdata(fig, 'RS_HoverList');
            if isempty(list), return; end

            for k = 1:numel(list)
                rs = list{k};
                if isa(rs, 'function_handle')
                    % External hover provider (e.g. the RGB stretch bar):
                    % returns a Pointer string or '' when not applicable.
                    c = rs();
                elseif ~isempty(rs) && isvalid(rs)
                    c = rs.getHoverCursor_();
                else
                    continue;
                end
                if ~isempty(c)
                    fig.Pointer = c;
                    return;
                end
            end
            fig.Pointer = 'arrow';
        end

    end

    % ==================================================================
    methods

        function SetPlayButtonsEnabled(obj, tf)
            % Enable or disable all three play buttons (called when another
            % dimension starts/stops playing).  When re-enabling, respect any
            % within-dimension disable: if this slider is not playing, all
            % three go back to 'on'; if it IS playing, the active one stays
            % on and siblings stay off — but that state can't occur here
            % because we are only called for OTHER dimensions.
            en = 'on';
            if ~tf, en = 'off'; end
            obj.BtnPlayFull_.Enable  = en;
            obj.BtnPlayZoom_.Enable  = en;
            obj.BtnPlayShift_.Enable = en;
        end

        function cursor = GetHoverCursor(obj)
            % Public accessor so external dispatchers can query this slider's cursor.
            cursor = obj.getHoverCursor_();
        end

        function mode = GetPlayMode(obj)
            mode = obj.PlayMode;
        end

        function SetPlayMode(obj, mode)
            if ~ismember(mode, {'none', 'full', 'zoom', 'shift'})
                error('PlayMode must be ''none'', ''full'', ''zoom'', or ''shift''');
            end
            obj.PlayMode = mode;
            update(obj);
            notify(obj, 'PlayModeChanged');
        end
    end
end
