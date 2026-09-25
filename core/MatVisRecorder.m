classdef MatVisRecorder < handle
    % MatVisRecorder  Turns a navigation timeline into a movie file.
    %
    %   Two ways to get a timeline, one renderer for both:
    %
    %   1. Scripted sweep — declare which dimension to step and over what
    %      range; the recorder generates the states.
    %          rec = MatVisRecorder(model, composer, writer);
    %          rec.Sweep = MatVisRecorder.SweepSpec(4, 'From', 1, 'To', 60);
    %          rec.Render();
    %
    %      Sweep may be a struct ARRAY, in which case the movie is the
    %      sequences played back to back.  Each one carries its own model
    %      state — held ('State') or interpolated across its frames
    %      ('StateRamp', e.g. a contrast window that opens) — and its own
    %      3-D camera ramp ('View3D'), which is what lets one movie step a
    %      dimension at one contrast and then orbit a still volume at
    %      another, without either transition jumping.  A sequence
    %      with dim <= 0 does not navigate at all and lasts 'Frames' frames,
    %      so a camera move over a single volume is just a sweep of nothing.
    %
    %   2. Recorded timeline (later phase) — states captured while the user
    %      navigates are replayed through the same Render path, so live
    %      recording costs nothing at interaction time.
    %          rec.Timeline = states;   rec.Render();
    %
    %   The recorder drives the model directly and restores every field it
    %   touched afterwards (including on error or cancel), so rendering never
    %   leaves the session on a different frame than it started.  Only the
    %   navigation state is copied — never the data arrays.

    properties
        Model
        Composer
        Writer
        Sweep     = []       % see SweepSpec; ignored when Timeline is set
        Timeline  = {}       % cell array of state structs
        OnProgress = []      % @(i, n) -> logical keepGoing (false = cancel)
        RefreshLiveWindows = false   % also update the GUI while rendering
        LiveRenderFcn      = []      % mw.Render, used when the above is true
        % Paint the composer's figure but neither grab nor write it.  Playing
        % a preview uses the same timeline as the movie this way, without
        % paying the ~54 ms capture per frame.
        PreviewOnly        = false
    end

    properties (SetAccess = private)
        LastFrameCount = 0
        LastElapsed    = 0
        Cancelled      = false
    end

    % ------------------------------------------------------------------
    methods (Static)
        function sp = SweepSpec(dim, varargin)
            % One sequence.  Defaults sweep DIM over its whole extent, step 1.
            %   'From' / 'To' / 'Step'  index range along DIM
            %   'Frames'  length when DIM <= 0 (no navigation at all)
            %   'Name'    label, for a caller that shows a sequence list
            %   'State'   struct of model fields held for this sequence;
            %             every field must be one of stateFields()
            %   'StateRamp'  the same, but each field is numeric and may be
            %             a [start end] pair walked over the sequence — this
            %             is how a contrast window opens or a gamma drifts
            %             smoothly instead of stepping between sequences
            %   'View3D'  struct with any of az / el / zoom, each a scalar or
            %             a [start end] pair ramped linearly over the frames
            p = inputParser;
            p.addParameter('From',      []);
            p.addParameter('To',        []);
            p.addParameter('Step',      1);
            p.addParameter('Frames',    []);
            p.addParameter('Name',      '');
            p.addParameter('State',     struct());
            p.addParameter('StateRamp', struct());
            p.addParameter('View3D',    []);
            p.parse(varargin{:});
            sp = struct('dim', dim, 'from', p.Results.From, ...
                        'to', p.Results.To, 'step', p.Results.Step, ...
                        'frames', p.Results.Frames, 'name', p.Results.Name, ...
                        'state', p.Results.State, ...
                        'stateRamp', p.Results.StateRamp, ...
                        'view3d', p.Results.View3D);
        end

        function s = CaptureState(model)
            % Snapshot of everything the composer reads.  Small and cheap:
            % scalars and short vectors, no data arrays.
            s = struct();
            for f = MatVisRecorder.stateFields()
                name = f{1};
                if isprop(model, name)
                    s.(name) = model.(name);
                end
            end
        end

        function RestoreState(model, s)
            % X/YDim are order-sensitive (the setters reject a clash), so
            % they are applied with both orders tried.
            if isfield(s, 'XDim') && isfield(s, 'YDim')
                try
                    model.XDim = s.XDim;  model.YDim = s.YDim;
                catch
                    try
                        model.YDim = s.YDim;  model.XDim = s.XDim;
                    catch
                    end
                end
            end
            for f = MatVisRecorder.stateFields()
                name = f{1};
                if any(strcmp(name, {'XDim', 'YDim'})), continue; end
                if isfield(s, name) && isprop(model, name)
                    try
                        model.(name) = s.(name);
                    catch
                    end
                end
            end
        end

        function v = rampStruct(spec, k, n, only)
            % Every field of SPEC evaluated at frame K of N: a scalar is
            % held, a [start end] pair is walked linearly.  One helper for
            % both ramps a sequence can carry — the 3-D camera and the
            % contrast window — because they interpolate identically.
            % ONLY, when given, restricts which fields are read.
            if nargin < 4, only = {}; end
            v = [];
            if isempty(spec) || ~isstruct(spec), return; end
            if n > 1, t = (k - 1) / (n - 1); else, t = 0; end
            v = struct();
            for f = fieldnames(spec)'
                if ~isempty(only) && ~any(strcmp(f{1}, only)), continue; end
                a = spec.(f{1});
                if ~isnumeric(a) && ~islogical(a), continue; end
                a = double(a);
                if isempty(a) || ~all(isfinite(a)), continue; end
                if isscalar(a)
                    v.(f{1}) = a;
                else
                    v.(f{1}) = a(1) + t * (a(2) - a(1));
                end
            end
            if isempty(fieldnames(v)), v = []; end
        end

        function v = rampView(spec, k, n)
            % Camera for frame K of N, so one sequence can orbit, tilt and
            % zoom at once.
            v = MatVisRecorder.rampStruct(spec, k, n, {'az', 'el', 'zoom'});
        end

        function names = stateFields()
            names = {'CurrPos', 'ZoomRange', 'XDim', 'YDim', ...
                     'ProjDim', 'ProjFun', 'ProjZoomLock', ...
                     'RGBDim', 'RGBStretchMode', 'RGBStretchRange', ...
                     'RGBStretchZoomLock', 'RGBContrastRange', ...
                     'Gamma', 'ColormapIdx', 'ContrastLocked', 'ContrastMode', ...
                     'ContrastMin', 'ContrastMax', 'ActiveDataset', ...
                     'FilterType', 'FilterPar', 'FlipX', 'FlipY', ...
                     'AlphaGamma', 'AlphaBgWhite'};
        end
    end

    % ------------------------------------------------------------------
    methods
        function obj = MatVisRecorder(model, composer, writer)
            obj.Model    = model;
            obj.Composer = composer;
            if nargin >= 3, obj.Writer = writer; end
        end

        function states = BuildTimeline(obj)
            % Expand the sweep into explicit states.  Doing this up front
            % means the frame count is known before the first frame, so the
            % progress bar is honest and a bad range fails immediately.
            if ~isempty(obj.Timeline)
                states = obj.Timeline;
                return;
            end
            if isempty(obj.Sweep)
                error('MatVisRecorder:noTimeline', ...
                    'Set either Sweep or Timeline before rendering.');
            end

            m      = obj.Model;
            base   = MatVisRecorder.CaptureState(m);
            states = {};
            for q = 1:numel(obj.Sweep)
                states = [states, obj.sequenceStates(obj.Sweep(q), base)]; %#ok<AGROW>
            end
        end

        function n = FrameCount(obj)
            % How many frames Render would write, without building them.
            n = numel(obj.BuildTimeline());
        end

        function info = Render(obj)
            if isempty(obj.Composer)
                error('MatVisRecorder:noComposer', 'No frame composer set.');
            end
            states = obj.BuildTimeline();
            n      = numel(states);

            % Restore the session's state whatever happens — cancel, error,
            % or normal completion.
            saved   = MatVisRecorder.CaptureState(obj.Model);
            cleanup = onCleanup(@() obj.restoreAndRefresh(saved));

            obj.Cancelled      = false;
            obj.LastFrameCount = 0;
            written            = 0;
            haveWriter         = ~isempty(obj.Writer) && ~obj.PreviewOnly;
            if haveWriter, obj.Writer.Open(); end

            savedView = obj.Composer.View3D;
            cleanupView = onCleanup(@() obj.restoreView(savedView));

            t0 = tic;
            for k = 1:n
                MatVisRecorder.RestoreState(obj.Model, states{k});
                % The 3-D camera is the composer's, not the model's, so it
                % rides alongside the model state rather than inside it.
                if isfield(states{k}, 'View3D') && ~isempty(states{k}.View3D)
                    obj.Composer.View3D = states{k}.View3D;
                end
                if obj.RefreshLiveWindows && ~isempty(obj.LiveRenderFcn)
                    try; obj.LiveRenderFcn(); catch; end
                end

                if obj.PreviewOnly
                    obj.Composer.PaintFrame();
                else
                    rgb = obj.Composer.RenderFrame();
                    if haveWriter
                        obj.Writer.WriteFrame(rgb);
                    end
                end
                written = written + 1;

                if ~isempty(obj.OnProgress)
                    keepGoing = obj.OnProgress(k, n);
                    if islogical(keepGoing) && ~keepGoing
                        obj.Cancelled = true;
                        break;
                    end
                end
            end
            elapsed = toc(t0);

            if haveWriter, obj.Writer.Close(); end

            obj.LastFrameCount = written;
            obj.LastElapsed    = elapsed;

            info = struct('frames', written, 'requested', n, ...
                          'elapsed', elapsed, 'cancelled', obj.Cancelled, ...
                          'msPerFrame', 1000 * elapsed / max(written, 1));
            if haveWriter
                info.file = obj.Writer.OutputPath();
            else
                info.file = '';
            end
        end
    end

    % ------------------------------------------------------------------
    methods (Access = private)
        function states = sequenceStates(obj, sp, base)
            % Expand one sequence into explicit states.  Doing this up front
            % means the frame count is known before the first frame, so the
            % progress bar is honest and a bad range fails immediately.
            m = obj.Model;

            % Per-sequence model overrides.  Anything outside stateFields
            % would be silently dropped by RestoreState, so say so instead.
            known = MatVisRecorder.stateFields();
            if ~isempty(sp.state) && isstruct(sp.state)
                for f = fieldnames(sp.state)'
                    if ~any(strcmp(f{1}, known))
                        error('MatVisRecorder:badStateField', ...
                            ['Sweep state field "%s" is not one the recorder ' ...
                             'restores. Known: %s.'], f{1}, strjoin(known, ', '));
                    end
                    base.(f{1}) = sp.state.(f{1});
                end
            end
            if isfield(sp, 'stateRamp') && ~isempty(sp.stateRamp) && isstruct(sp.stateRamp)
                for f = fieldnames(sp.stateRamp)'
                    if ~any(strcmp(f{1}, known))
                        error('MatVisRecorder:badStateField', ...
                            ['Sweep state field "%s" is not one the recorder ' ...
                             'restores. Known: %s.'], f{1}, strjoin(known, ', '));
                    end
                    if ~isnumeric(sp.stateRamp.(f{1}))
                        error('MatVisRecorder:badStateRamp', ...
                            ['Sweep state ramp "%s" must be numeric: only a ' ...
                             'number can be interpolated.'], f{1});
                    end
                end
            end

            d = sp.dim;
            if ~isscalar(d) || ~isnumeric(d)
                error('MatVisRecorder:badSweepDim', ...
                    'Sweep dimension %s is not a dimension of this dataset.', mat2str(d));
            end

            if d < 1
                % No navigation: a fixed number of frames on one position,
                % which is what an animated camera over a still volume needs.
                nF  = sp.frames;
                if isempty(nF) || ~isfinite(nF), nF = 1; end
                nF  = max(1, round(nF));
                idx = [];
            else
                if d > numel(m.Size)
                    error('MatVisRecorder:badSweepDim', ...
                        'Sweep dimension %s is not a dimension of this dataset.', mat2str(d));
                end
                from = sp.from;  if isempty(from), from = 1;          end
                to   = sp.to;    if isempty(to),   to   = m.Size(d);  end
                step = sp.step;  if isempty(step) || step == 0, step = 1; end

                from = max(1, min(m.Size(d), round(from)));
                to   = max(1, min(m.Size(d), round(to)));
                if (to < from && step > 0) || (to > from && step < 0)
                    step = -step;
                end
                idx = from:step:to;
                if isempty(idx), idx = from; end
                nF  = numel(idx);
            end

            if isfield(sp, 'stateRamp'), ramp = sp.stateRamp; else, ramp = []; end

            states = cell(1, nF);
            for k = 1:nF
                st = base;
                if ~isempty(idx)
                    st.CurrPos(d) = idx(k);
                end
                % Ramped fields are applied after the held ones, so a
                % sequence that sets both gets the interpolated value.
                rs = MatVisRecorder.rampStruct(ramp, k, nF);
                if ~isempty(rs)
                    for f = fieldnames(rs)'
                        st.(f{1}) = rs.(f{1});
                    end
                end
                st.View3D = MatVisRecorder.rampView(sp.view3d, k, nF);
                states{k} = st;
            end
        end

        function restoreView(obj, saved)
            try
                if ~isempty(obj.Composer) && isvalid(obj.Composer)
                    obj.Composer.View3D = saved;
                end
            catch
            end
        end

        function restoreAndRefresh(obj, saved)
            try
                MatVisRecorder.RestoreState(obj.Model, saved);
            catch
            end
            if ~isempty(obj.LiveRenderFcn)
                try; obj.LiveRenderFcn(); catch; end
            end
        end
    end
end
