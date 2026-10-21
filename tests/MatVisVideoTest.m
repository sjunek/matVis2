classdef MatVisVideoTest < matlab.unittest.TestCase
    % Headless tests for the video generator: frame composer, video writer
    % and the sweep recorder.  No GUI is involved, so these run in
    % `matlab -batch` and are the regression net for the capture path.

    properties
        TmpDir
    end

    methods (TestMethodSetup)
        function makeTmp(tc)
            tc.TmpDir = tempname;
            mkdir(tc.TmpDir);
            tc.addTeardown(@() rmdir(tc.TmpDir, 's'));
        end
    end

    methods (Static)
        function model = makeModel()
            % 40×56×10, a bright blob that moves along dim 3 so successive
            % frames differ.
            sz = [40 56 10];
            d  = zeros(sz, 'single');
            for t = 1:sz(3)
                r = 8 + t;  c = 10 + 2*t;
                d(r:r+8, c:c+8, t) = 100 + 10*t;
            end
            d = d + single(reshape(1:prod(sz), sz)) * 1e-3;
            model = MatVisModel(d);
            model.DimNames = {'Y', 'X', 'T'};
        end

        function model = makeModel4D()
            % 24×28×9×5.  A blob whose position depends on dim 3 and whose
            % brightness depends on dim 4, so a volume over dims 1-3 changes
            % when dim 4 (which is NOT in the volume) is swept.
            sz = [24 28 9 5];
            d  = zeros(sz, 'single');
            for z = 1:sz(3)
                r = 4 + z;  c = 6 + 2*z;
                for t = 1:sz(4)
                    d(r:r+4, c:c+4, z, t) = 60 * t;
                end
            end
            d = d + single(reshape(1:prod(sz), sz)) * 1e-3;
            model = MatVisModel(d);
            model.DimNames = {'Y', 'X', 'Z', 'T'};
        end

        function tf = hasAxesWithXLim(fig, lim)
            % Does any axes in the composed figure span exactly LIM?
            tf = false;
            ax = findall(fig, 'Type', 'axes');
            for k = 1:numel(ax)
                if max(abs(ax(k).XLim - lim)) < 1e-6, tf = true; return; end
            end
        end

        function layout = histLayout(model, kind, position, logY)
            % What the UI builds for a histogram strip: base squeezed into
            % what is left, histogram panel in the reserved rectangle.
            base = MatVisFrameComposer.DefaultLayout(kind, model);
            switch position
                case 'bottom'
                    rect = [0 0 1 0.22];   content = [0 0.22 1 0.78];
                case 'right'
                    rect = [0.7 0 0.3 1];  content = [0 0 0.7 1];
                otherwise
                    layout = base;  return;
            end
            h = MatVisFrameComposer.panel('histogram', rect, []);
            h.histLog = logY;
            layout = [MatVisFrameComposer.ScaleInto(base, content), h];
        end

        function tf = throwBoom(~, ~)
            % An OnProgress callback that fails mid-render.  Written as a
            % real function because an anonymous @(i,n) error(...) called in
            % an output context raises MATLAB:maxlhs instead.
            error('MatVisVideoTest:boom', 'boom');
            tf = true; %#ok<UNRCH>
        end
    end

    methods (Test)

        % ---------------- frame composer --------------------------------
        function testComposer_exactFrameSize(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [320 240]);
            tc.addTeardown(@() delete(comp));

            rgb = comp.RenderFrame();
            tc.verifyEqual(size(rgb), [240 320 3]);
            tc.verifyClass(rgb, 'uint8');
        end

        function testComposer_oddAndEvenSizesAreExact(tc)
            % The device-scale division rounds; the grab must still come back
            % at exactly the requested size.
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            for sz = {[640 360], [641 361], [300 200]}
                comp = MatVisFrameComposer(model, layout, 'FrameSize', sz{1});
                rgb  = comp.RenderFrame();
                tc.verifyEqual([size(rgb,2) size(rgb,1)], sz{1}, ...
                    sprintf('frame size %s', mat2str(sz{1})));
                delete(comp);
            end
        end

        function testComposer_frameChangesWithPosition(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [320 240]);
            tc.addTeardown(@() delete(comp));

            model.CurrPos(3) = 1;
            a = comp.RenderFrame();
            model.CurrPos(3) = 9;
            b = comp.RenderFrame();
            tc.verifyNotEqual(a, b, 'frame did not change when CurrPos moved');
        end

        function testComposer_notBlank(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [320 240]);
            tc.addTeardown(@() delete(comp));

            rgb = comp.RenderFrame();
            tc.verifyGreaterThan(std(double(rgb(:))), 1, ...
                'frame looks blank — nothing was drawn');
        end

        function testComposer_imageIsNotVerticallyFlipped(tc)
            % Row 1 of the data must land at the TOP of the frame, as it does
            % in the live windows.  Building the panel with "hold on" before
            % image() silently leaves YDir='normal', which mirrors the movie.
            model = MatVisVideoTest.makeModel();
            % Bright stripe across the top rows only.
            d = zeros(model.Size, 'single');
            d(1:6, :, :) = 1000;
            model.Datasets{1} = d;

            layout = MatVisFrameComposer.panel('image', [0 0 1 1], ...
                struct('rois', false, 'profiles', false, ...
                       'crosshair', false, 'zoomRect', false));
            comp = MatVisFrameComposer(model, layout, 'FrameSize', [200 200]);
            tc.addTeardown(@() delete(comp));

            rgb = comp.RenderFrame();
            g   = double(mean(rgb, 3));
            topHalf    = mean(g(1:80, :), 'all');
            bottomHalf = mean(g(121:200, :), 'all');
            tc.verifyGreaterThan(topHalf, bottomHalf, ...
                'image is vertically flipped: bright top rows rendered at the bottom');
        end

        function testComposer_multiPanelLayouts(tc)
            % Every arrangement the UI offers, so a new one cannot ship
            % without a panel type to draw it.
            model = MatVisVideoTest.makeModel();
            kinds = MatVisFrameComposer.LayoutKinds();
            tc.verifyGreaterThan(numel(kinds), 4);
            for kind = kinds
                layout = MatVisFrameComposer.DefaultLayout(kind{1}, model);
                comp   = MatVisFrameComposer(model, layout, 'FrameSize', [400 300]);
                rgb    = comp.RenderFrame();
                tc.verifyEqual(size(rgb), [300 400 3], ...
                    sprintf('layout %s', kind{1}));
                tc.verifyGreaterThan(std(double(rgb(:))), 1, ...
                    sprintf('layout %s produced a blank frame', kind{1}));
                delete(comp);
            end
        end

        function testComposer_titleAndScalebarPanels(tc)
            model = MatVisVideoTest.makeModel();
            model.DimScale{2} = (0:model.Size(2)-1) * 0.25;
            model.DimUnits{2} = 'um';

            layout    = MatVisFrameComposer.DefaultLayout('image', model);
            titlePane = MatVisFrameComposer.panel('title', [0.02 0.9 0.9 0.08], []);
            titlePane.text  = 'Test movie';
            barPane   = MatVisFrameComposer.panel('scalebar', [0.6 0.02 0.35 0.08], []);
            comp = MatVisFrameComposer(model, [layout, titlePane, barPane], ...
                                       'FrameSize', [480 320]);
            tc.addTeardown(@() delete(comp));

            rgb = comp.RenderFrame();
            tc.verifyEqual(size(rgb), [320 480 3]);
        end

        function testComposer_reconfigureAndReRender(tc)
            % The UI keeps one composer alive and reconfigures it between
            % renders.  That path is not exercised by building a fresh
            % composer per frame, and it is where Layout/BackColor being
            % read-only properties broke rendering.
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('image', model), ...
                'FrameSize', [240 180]);
            tc.addTeardown(@() delete(comp));

            a = comp.RenderFrame();
            tc.verifyEqual(size(a), [180 240 3]);

            comp.SetLayout(MatVisFrameComposer.DefaultLayout('image+zoom', model));
            comp.SetBackColor([0 0 0]);
            comp.SetFrameSize([320 240]);

            b = comp.RenderFrame();
            tc.verifyEqual(size(b), [240 320 3]);
            tc.verifyGreaterThan(std(double(b(:))), 1);

            % Re-rendering without changing anything must still work.
            c = comp.RenderFrame();
            tc.verifyEqual(size(c), [240 320 3]);
        end

        function testComposer_usesInjectedDisplayFcn(tc)
            % The GUI passes its own pipeline in; the composer must use it.
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            called = false;
            function s = fakeDisplay(ds)
                called = true;
                s = struct('rgbFull', zeros(20, 30, 3, 'uint8'), ...
                           'rgbZoom', zeros(10, 15, 3, 'uint8'), ...
                           'cmin', 0, 'cmax', 1, 'gamma', 1, 'chanRange', [], ...
                           'srcFull', [], 'srcZoom', [], 'rawFull', [], ...
                           'profiles', {cell(1, numel(model.Size))});
            end
            comp = MatVisFrameComposer(model, layout, 'FrameSize', [200 160], ...
                                       'DisplayFcn', @fakeDisplay);
            tc.addTeardown(@() delete(comp));

            comp.RenderFrame();
            tc.verifyTrue(called, 'DisplayFcn was not used');
        end

        % ---------------- histogram panel -------------------------------
        function testHistPanel_rendersInEveryPosition(tc)
            model = MatVisVideoTest.makeModel();
            for pos = {'bottom', 'right'}
                for logY = [false true]
                    layout = MatVisVideoTest.histLayout(model, 'image+zoom', pos{1}, logY);
                    comp = MatVisFrameComposer(model, layout, 'FrameSize', [400 300]);
                    rgb  = comp.RenderFrame();
                    tc.verifyEqual(size(rgb), [300 400 3]);
                    tc.verifyGreaterThan(std(double(rgb(:))), 1, ...
                        sprintf('histogram %s logY=%d produced a blank frame', pos{1}, logY));
                    delete(comp);
                end
            end
        end

        function testHistPanel_reservesSpaceForTheRest(tc)
            % The strip must take room from the other panels, not overlap
            % them — that is the whole point of ScaleInto.
            model  = MatVisVideoTest.makeModel();
            layout = MatVisVideoTest.histLayout(model, 'image', 'bottom', false);
            tc.verifyNumElements(layout, 2);
            img  = layout(strcmp({layout.type}, 'image'));
            hist = layout(strcmp({layout.type}, 'histogram'));
            tc.verifyEqual(img.pos,  [0 0.22 1 0.78], 'AbsTol', 1e-12);
            tc.verifyEqual(hist.pos, [0 0    1 0.22], 'AbsTol', 1e-12);
        end

        function testHistPanel_followsTheContrastWindow(tc)
            % The min/max lines come from the display struct, so moving the
            % window must change the panel.
            model  = MatVisVideoTest.makeModel();
            layout = MatVisVideoTest.histLayout(model, 'image', 'bottom', false);
            comp = MatVisFrameComposer(model, layout, 'FrameSize', [320 240]);
            tc.addTeardown(@() delete(comp));

            model.ContrastMode = 'Manual';
            model.ContrastMin  = 0;
            model.ContrastMax  = 200;
            a = comp.RenderFrame();
            model.ContrastMax = 60;
            b = comp.RenderFrame();
            tc.verifyNotEqual(a, b, 'histogram ignored the contrast window');
        end

        % ---------------- live settings changes -------------------------
        function testSetLayout_keepsFigureWhenStructureIsUnchanged(tc)
            % The preview window IS the composer's figure, so a change that
            % needs no new graphics objects must not rebuild it — otherwise
            % every checkbox closes the preview under the user.
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image+zoom', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [200 160]);
            tc.addTeardown(@() delete(comp));

            comp.RenderFrame();
            fig0 = comp.Fig;
            tc.verifyTrue(isvalid(fig0));

            % Soft: same panels in the same places, different settings.
            soft = layout;
            soft(1).overlays.crosshair = ~soft(1).overlays.crosshair;
            comp.SetLayout(soft);
            tc.verifyTrue(isvalid(fig0), 'an overlay toggle rebuilt the figure');
            tc.verifySameHandle(comp.Fig, fig0);
            comp.RenderFrame();
            tc.verifySameHandle(comp.Fig, fig0);

            % Hard: a different arrangement has to rebuild.
            comp.SetLayout(MatVisFrameComposer.DefaultLayout('image', model));
            comp.RenderFrame();
            tc.verifyFalse(isequal(comp.Fig, fig0), ...
                'a layout change must rebuild the figure');
        end

        function testSetLayout_softChangeStillTakesEffect(tc)
            % Keeping the figure must not mean keeping the old picture.
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('3d', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [200 200]);
            tc.addTeardown(@() delete(comp));

            layout.box = true;   layout.showLabels = true;
            comp.SetLayout(layout);
            withBox = comp.RenderFrame();
            fig0    = comp.Fig;

            layout.box = false;  layout.showLabels = false;
            comp.SetLayout(layout);
            noBox = comp.RenderFrame();

            tc.verifySameHandle(comp.Fig, fig0, 'hiding the box rebuilt the figure');
            tc.verifyNotEqual(withBox, noBox, 'hiding the box changed nothing');
        end

        % ---------------- fill zoom -------------------------------------
        function testFillZoom_growsTheCropAndRestoresTheModel(tc)
            % A wide panel with a fixed aspect ratio letterboxes a square
            % crop; fillZoom widens the crop instead — and must hand the
            % shared zoom box back untouched.
            model = MatVisVideoTest.makeModel();
            model.AspectRatioFixed = true;
            model.AspectRatio      = [1 1];
            model.ZoomRange(1, :)  = [16 25];      % 10 rows
            model.ZoomRange(2, :)  = [21 30];      % 10 cols
            before = model.ZoomRange;

            layout = MatVisFrameComposer.panel('zoom', [0 0 1 1], []);
            comp = MatVisFrameComposer(model, layout, 'FrameSize', [400 100]);
            tc.addTeardown(@() delete(comp));

            plain = comp.RenderFrame();
            tc.verifyEqual(model.ZoomRange, before);

            layout.fillZoom = true;
            comp.SetLayout(layout);
            filled = comp.RenderFrame();

            tc.verifyEqual(model.ZoomRange, before, ...
                'fillZoom left the shared zoom box changed');
            tc.verifyNotEqual(plain, filled, 'fillZoom changed nothing');

            % The letterboxed frame has background columns at the left edge
            % that the filled one does not.
            colStd = @(im) std(double(reshape(im(:, 1:8, :), [], 1)));
            tc.verifyGreaterThan(colStd(filled), colStd(plain), ...
                'the filled frame should carry data where the plain one had background');
        end

        function testFillZoom_growsOnlyWithinTheData(tc)
            model = MatVisVideoTest.makeModel();
            model.AspectRatioFixed = true;
            model.AspectRatio      = [1 1];
            % Already the whole plane: there is nothing left to grow into.
            model.ZoomRange(1, :) = [1 model.Size(1)];
            model.ZoomRange(2, :) = [1 model.Size(2)];
            before = model.ZoomRange;

            layout = MatVisFrameComposer.panel('zoom', [0 0 1 1], []);
            layout.fillZoom = true;
            comp = MatVisFrameComposer(model, layout, 'FrameSize', [400 100]);
            tc.addTeardown(@() delete(comp));
            comp.RenderFrame();
            tc.verifyEqual(model.ZoomRange, before);
        end

        function testGrowZoomToPanel_matchesThePanelProportions(tc)
            % 10x10 indices, square pixels, in a 4:1 panel -> the X range
            % must reach 40 while Y stays put.
            [xr, yr] = MatVisFrameComposer.growZoomToPanel( ...
                [21 30], [16 25], 100, 100, [1 1], 400, 100);
            tc.verifyEqual(yr, [16 25], 'the short axis should not grow');
            tc.verifyEqual(xr(2) - xr(1) + 1, 40, 'AbsTol', 1);
            % Never past the data, and never shrinking.
            [xr2, ~] = MatVisFrameComposer.growZoomToPanel( ...
                [1 10], [1 10], 12, 100, [1 1], 400, 100);
            tc.verifyEqual(xr2, [1 12], 'grew past the data edge');
        end

        function testHistPanel_usesTheInjectedRange(tc)
            % The movie's histogram must be framed like the main window's,
            % which owns the range in its Hist Min / Hist Max fields.
            model  = MatVisVideoTest.makeModel();
            layout = MatVisVideoTest.histLayout(model, 'image', 'bottom', false);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [400 300]);
            tc.addTeardown(@() delete(comp));

            comp.HistRangeFcn = @() [-50 250];
            comp.RenderFrame();
            tc.verifyTrue(MatVisVideoTest.hasAxesWithXLim(comp.Fig, [-50 250]), ...
                'the histogram ignored the injected range');

            % Read at paint time, so moving those fields moves an open
            % preview rather than only the next build.
            comp.HistRangeFcn = @() [0 40];
            comp.RenderFrame();
            tc.verifyTrue(MatVisVideoTest.hasAxesWithXLim(comp.Fig, [0 40]), ...
                'the histogram cached the range instead of re-reading it');
        end

        function testHistPanel_injectedRangeIsNotWidened(tc)
            % A range narrower than the contrast window must be obeyed, not
            % stretched to fit the lines — the main window does not stretch.
            model = MatVisVideoTest.makeModel();
            model.ContrastMode = 'Manual';
            model.ContrastMin  = -500;
            model.ContrastMax  = 5000;
            layout = MatVisVideoTest.histLayout(model, 'image', 'bottom', false);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [400 300]);
            tc.addTeardown(@() delete(comp));

            comp.HistRangeFcn = @() [0 100];
            comp.RenderFrame();
            tc.verifyTrue(MatVisVideoTest.hasAxesWithXLim(comp.Fig, [0 100]));
        end

        function testHistPanel_fallsBackWhenTheRangeIsUnusable(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisVideoTest.histLayout(model, 'image', 'bottom', false);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [320 240]);
            tc.addTeardown(@() delete(comp));

            for fcn = {@() [5 5], @() [], @() error('boom')}
                comp.HistRangeFcn = fcn{1};
                rgb = comp.RenderFrame();          % must not throw
                tc.verifyEqual(size(rgb), [240 320 3]);
            end
            % And the panel still drew a sane axis from the data itself.
            ax = findall(comp.Fig, 'Type', 'axes');
            spans = arrayfun(@(h) diff(h.XLim), ax);
            tc.verifyTrue(all(spans > 0));
        end

        function testScaleInto_mapsPositions(tc)
            p = MatVisFrameComposer.panel('image', [0.5 0.5 0.5 0.5], []);
            q = MatVisFrameComposer.ScaleInto(p, [0.2 0.1 0.4 0.8]);
            tc.verifyEqual(q.pos, [0.4 0.5 0.2 0.4], 'AbsTol', 1e-12);
        end

        % ---------------- volume panel ----------------------------------
        function testVolumePanel_rendersAndFollowsCamera(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('3d', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [240 240]);
            tc.addTeardown(@() delete(comp));

            comp.View3D = struct('az', 0, 'el', 90, 'zoom', 1);
            a = comp.RenderFrame();
            tc.verifyGreaterThan(std(double(a(:))), 1, 'volume panel is blank');

            comp.View3D = struct('az', 40, 'el', 20, 'zoom', 1);
            b = comp.RenderFrame();
            tc.verifyNotEqual(a, b, 'frame did not follow az/el');

            comp.View3D = struct('az', 40, 'el', 20, 'zoom', 2.5);
            c = comp.RenderFrame();
            tc.verifyNotEqual(b, c, 'frame did not follow zoom');

            % Same state twice must give the same pixels: the volume cache
            % must not make a repeat render drift.
            d = comp.RenderFrame();
            tc.verifyEqual(d, c, 'repeat render differed');
        end

        function testVolumePanel_followsAspect(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('3d', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [240 240]);
            tc.addTeardown(@() delete(comp));
            comp.View3D = struct('az', 40, 'el', 20, 'zoom', 1);

            a = comp.RenderFrame();
            layout.aspect = [1 1 3];
            comp.SetLayout(layout);
            b = comp.RenderFrame();
            tc.verifyNotEqual(a, b, 'frame did not follow the axis stretch');
        end

        function testVolumePanel_defaultDimsAreDistinct(tc)
            model  = MatVisVideoTest.makeModel4D();
            layout = MatVisFrameComposer.DefaultLayout('3d', model);
            tc.verifyNumElements(unique(layout.dims3), 3);
            tc.verifyTrue(all(layout.dims3 >= 1 & layout.dims3 <= numel(model.Size)));
        end

        function testVolumePanel_followsPositionOutsideTheVolume(tc)
            % The volume spans dims 1-3; sweeping dim 4 must still change it,
            % or the cache key is missing the non-volume position.
            model  = MatVisVideoTest.makeModel4D();
            layout = MatVisFrameComposer.DefaultLayout('3d', model);
            layout.dims3 = [1 2 3];
            comp = MatVisFrameComposer(model, layout, 'FrameSize', [200 200]);
            tc.addTeardown(@() delete(comp));

            model.CurrPos(4) = 1;
            a = comp.RenderFrame();
            model.CurrPos(4) = 5;
            b = comp.RenderFrame();
            tc.verifyNotEqual(a, b, ...
                'volume did not change when a dimension outside it moved');
        end

        function testVolumePanel_ownContrastOverridesDisplay(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('3d', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [200 200]);
            tc.addTeardown(@() delete(comp));
            a = comp.RenderFrame();

            layout.contrast = [0 20 1];        % far tighter than the data range
            comp.SetLayout(layout);
            b = comp.RenderFrame();
            tc.verifyNotEqual(a, b, 'spec.contrast was ignored');
        end

        function testVolumePanel_degradesWhenDataIsTooFlat(tc)
            % Fewer than three dimensions: the panel must come up empty, not
            % throw, so a 2-D dataset can still use a 3-D layout by mistake.
            d = zeros(12, 14, 'single');
            d(3:6, 4:8) = 100;
            model  = MatVisModel(d);
            layout = MatVisFrameComposer.DefaultLayout('3d', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [120 120]);
            tc.addTeardown(@() delete(comp));
            rgb = comp.RenderFrame();
            tc.verifyEqual(size(rgb), [120 120 3]);
        end

        % ---------------- volume projector ------------------------------
        function testProjector_cameraFrameIsOrthonormal(tc)
            for az = [-180 -37.5 0 55 180]
                for el = [-89 -20 0 30 89]
                    [r, u, d] = MatVisVolumeProjector.camFrame(az, el);
                    M = [r; u; d];
                    tc.verifyEqual(M * M', eye(3), 'AbsTol', 1e-10, ...
                        sprintf('az %g el %g', az, el));
                    tc.verifyEqual(det(M), 1, 'AbsTol', 1e-10);
                end
            end
        end

        function testProjector_onAxisViewsAreOriented(tc)
            % Blob at low panel-X, high panel-Y.  Looking down -Z (az 0, el
            % 90) puts X to the right and Y up, so it must land top-left.
            V = zeros(40, 30, 20, 'uint8');
            V(2:8, 25:29, 9:11) = 255;
            for mode = {'auto', 'axis'}
                p = MatVisVolumeProjector.project(V, [1 1 1], 'Az', 0, 'El', 90, ...
                    'OutSize', [200 200], 'Mode', mode{1});
                [r, c] = find(p.gray > 128);
                tc.verifyNotEmpty(r, sprintf('%s: nothing projected', mode{1}));
                tc.verifyLessThan(mean(r), 100, ...
                    sprintf('%s: high panel-Y did not render at the top', mode{1}));
                tc.verifyLessThan(mean(c), 100, ...
                    sprintf('%s: low panel-X did not render at the left', mode{1}));
            end
        end

        function testProjector_zoomMagnifiesQuadratically(tc)
            % Centred blob, so zooming in cannot crop it: doubling the zoom
            % must roughly quadruple the covered pixels.
            V = zeros(40, 40, 20, 'uint8');
            V(18:22, 18:22, 9:11) = 255;
            n = zeros(1, 3);
            z = [1 2 4];
            for k = 1:3
                p = MatVisVolumeProjector.project(V, [1 1 1], 'Az', 0, 'El', 90, ...
                    'OutSize', [200 200], 'Zoom', z(k));
                n(k) = nnz(p.gray > 128);
            end
            tc.verifyEqual(n(2) / n(1), 4, 'RelTol', 0.15);
            tc.verifyEqual(n(3) / n(2), 4, 'RelTol', 0.15);
        end

        function testProjector_anisotropicVoxelsStretchTheBox(tc)
            % Looking along +Y (az/el = 0,0) puts panel Z on the screen's
            % vertical.  The volume is deliberately tallest in Z so that Z is
            % what the fit is limited by in both cases; stretching its voxels
            % four-fold then needs four-times coarser output pixels.
            V = ones(10, 10, 20, 'uint8') * 200;
            a = MatVisVolumeProjector.project(V, [1 1 1], 'Az', 0, 'El', 0, ...
                'OutSize', [200 200]);
            b = MatVisVolumeProjector.project(V, [1 1 4], 'Az', 0, 'El', 0, ...
                'OutSize', [200 200]);
            tc.verifyEqual(b.px / a.px, 4, 'RelTol', 0.05);
        end

        function testProjector_minStyleDiffersFromMax(tc)
            V = uint8(40 * ones(20, 20, 10));
            V(8:12, 8:12, 5) = 250;
            pMax = MatVisVolumeProjector.project(V, [1 1 1], 'Az', 0, 'El', 90, ...
                'OutSize', [100 100], 'Style', 'max');
            pMin = MatVisVolumeProjector.project(V, [1 1 1], 'Az', 0, 'El', 90, ...
                'OutSize', [100 100], 'Style', 'min');
            tc.verifyGreaterThan(max(pMax.gray(:)), 200, 'max projection lost the peak');
            tc.verifyNotEqual(pMax.gray, pMin.gray);
        end

        function testProjector_boxAndLabels(tc)
            V = ones(20, 20, 10, 'uint8') * 200;
            p = MatVisVolumeProjector.project(V, [1 1 1], 'Az', -37.5, 'El', 30, ...
                'OutSize', [200 160]);
            % 12 edges, drawn as one NaN-separated polyline.
            tc.verifyEqual(numel(p.boxX), 36);
            tc.verifyEqual(sum(isnan(p.boxX)), 12);
            tc.verifyEqual(size(p.corners), [8 2]);
            tc.verifyNumElements(p.labelPos, 3);
            % An oblique view shows all three axes.
            tc.verifyTrue(all([p.labelPos.visible]));
            % A straight-on view collapses one of them.
            q = MatVisVolumeProjector.project(V, [1 1 1], 'Az', 0, 'El', 90, ...
                'OutSize', [200 160]);
            tc.verifyEqual(sum([q.labelPos.visible]), 2, ...
                'the axis pointing at the camera should have no label');
        end

        function testProjector_emptyAndDegenerateInput(tc)
            p = MatVisVolumeProjector.project([], [1 1 1], 'OutSize', [64 48]);
            tc.verifyEqual(size(p.img), [48 64 3]);
            % A single-plane volume is what imwarp refuses; the fallback must
            % still return a frame of the right size with the data in it.
            q = MatVisVolumeProjector.project(200 * ones(6, 6, 1, 'uint8'), ...
                [1 1 1], 'OutSize', [64 48]);
            tc.verifyEqual(size(q.img), [48 64 3]);
            tc.verifyEqual(max(q.gray(:)), uint8(200));
        end

        % ---------------- video writer ----------------------------------
        function testWriter_formatTableIsConsistent(tc)
            F = MatVisVideoWriter.Formats();
            tc.verifyNotEmpty(F);
            tc.verifyNumElements(unique({F.key}), numel(F), 'duplicate format key');
            for i = 1:numel(F)
                tc.verifyTrue(startsWith(F(i).ext, '.'), ...
                    sprintf('%s: extension must start with a dot', F(i).key));
                tc.verifyTrue(ismember(F(i).backend, ...
                    {'videowriter', 'imageseq', 'gif'}), ...
                    sprintf('%s: unknown backend', F(i).key));
            end
        end

        function testWriter_unknownFormatErrors(tc)
            tc.verifyError(@() MatVisVideoWriter.FormatByKey('nope'), ...
                'MatVisVideoWriter:unknownFormat');
        end

        function testWriter_forcesCorrectExtension(tc)
            w = MatVisVideoWriter(fullfile(tc.TmpDir, 'movie.wrong'), 'mjavi');
            [~, ~, e] = fileparts(w.FileName);
            tc.verifyEqual(e, '.avi');
        end

        function testWriter_writesAvi(tc)
            f = fullfile(tc.TmpDir, 'out.avi');
            w = MatVisVideoWriter(f, 'mjavi', 'FrameRate', 10);
            w.Open();
            for k = 1:5
                w.WriteFrame(uint8(k * 20 * ones(32, 48, 3)));
            end
            w.Close();
            tc.verifyEqual(w.FrameCount, 5);
            tc.verifyTrue(isfile(f));

            v = VideoReader(f);
            tc.verifyEqual(v.Width, 48);
            tc.verifyEqual(v.Height, 32);
        end

        function testWriter_rejectsSizeChange(tc)
            w = MatVisVideoWriter(fullfile(tc.TmpDir, 'x.avi'), 'mjavi');
            w.Open();
            w.WriteFrame(zeros(20, 30, 3, 'uint8'));
            tc.verifyError(@() w.WriteFrame(zeros(21, 30, 3, 'uint8')), ...
                'MatVisVideoWriter:frameSizeChanged');
            w.Close();
        end

        function testWriter_rejectsOddSizeForMp4(tc)
            if ~ismember('mp4', MatVisVideoWriter.AvailableFormats())
                tc.assumeFail('MPEG-4 profile not available here');
            end
            w = MatVisVideoWriter(fullfile(tc.TmpDir, 'x.mp4'), 'mp4');
            w.Open();
            tc.verifyError(@() w.WriteFrame(zeros(31, 30, 3, 'uint8')), ...
                'MatVisVideoWriter:oddFrameSize');
            w.Close();
        end

        function testWriter_imageSequence(tc)
            w = MatVisVideoWriter(fullfile(tc.TmpDir, 'seq.png'), 'png_seq');
            w.Open();
            for k = 1:3
                w.WriteFrame(uint8(k * 30 * ones(16, 24, 3)));
            end
            w.Close();

            d = dir(fullfile(w.OutputPath(), '*.png'));
            tc.verifyNumElements(d, 3);
            img = imread(fullfile(w.OutputPath(), d(1).name));
            tc.verifyEqual(size(img), [16 24 3]);
        end

        function testWriter_gif(tc)
            f = fullfile(tc.TmpDir, 'anim.gif');
            w = MatVisVideoWriter(f, 'gif', 'FrameRate', 5);
            w.Open();
            for k = 1:4
                frame = uint8(zeros(16, 16, 3));
                frame(:, :, 1) = 40 * k;
                w.WriteFrame(frame);
            end
            w.Close();
            tc.verifyTrue(isfile(f));
            info = imfinfo(f);
            tc.verifyNumElements(info, 4);
        end

        function testWriter_floatFramesAreConverted(tc)
            w = MatVisVideoWriter(fullfile(tc.TmpDir, 'f.avi'), 'mjavi');
            w.Open();
            w.WriteFrame(0.5 * ones(16, 16, 3));   % double in [0,1]
            w.Close();
            tc.verifyEqual(w.FrameCount, 1);
        end

        % ---------------- recorder --------------------------------------
        function testRecorder_sweepFrameCount(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [160 120]);
            tc.addTeardown(@() delete(comp));
            w = MatVisVideoWriter(fullfile(tc.TmpDir, 'sweep.avi'), 'mjavi');

            rec = MatVisRecorder(model, comp, w);
            rec.Sweep = MatVisRecorder.SweepSpec(3, 'From', 2, 'To', 8, 'Step', 2);
            info = rec.Render();

            tc.verifyEqual(info.frames, 4);          % 2,4,6,8
            tc.verifyFalse(info.cancelled);
            tc.verifyTrue(isfile(info.file));
        end

        function testRecorder_restoresModelState(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [160 120]);
            tc.addTeardown(@() delete(comp));

            model.CurrPos(3) = 4;
            before = model.CurrPos;

            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(3);
            rec.Render();

            tc.verifyEqual(model.CurrPos, before, ...
                'recorder left the model on a different frame');
        end

        function testRecorder_restoresStateAfterError(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [160 120]);
            tc.addTeardown(@() delete(comp));

            model.CurrPos(3) = 6;
            before = model.CurrPos;

            rec = MatVisRecorder(model, comp);
            rec.Sweep      = MatVisRecorder.SweepSpec(3);
            rec.OnProgress = @MatVisVideoTest.throwBoom;

            tc.verifyError(@() rec.Render(), 'MatVisVideoTest:boom');
            tc.verifyEqual(model.CurrPos, before, ...
                'model state not restored after a failed render');
        end

        function testRecorder_cancelStopsEarly(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [160 120]);
            tc.addTeardown(@() delete(comp));

            rec = MatVisRecorder(model, comp);
            rec.Sweep      = MatVisRecorder.SweepSpec(3, 'From', 1, 'To', 10);
            rec.OnProgress = @(i, n) i < 3;          % cancel after frame 3

            info = rec.Render();
            tc.verifyEqual(info.frames, 3);
            tc.verifyTrue(info.cancelled);
        end

        function testRecorder_reverseSweep(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [160 120]);
            tc.addTeardown(@() delete(comp));

            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(3, 'From', 8, 'To', 3);
            states = rec.BuildTimeline();

            tc.verifyEqual(numel(states), 6);
            tc.verifyEqual(states{1}.CurrPos(3),   8);
            tc.verifyEqual(states{end}.CurrPos(3), 3);
        end

        function testRecorder_badSweepDimErrors(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [160 120]);
            tc.addTeardown(@() delete(comp));

            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(99);
            tc.verifyError(@() rec.Render(), 'MatVisRecorder:badSweepDim');
        end

        function testRecorder_explicitTimeline(tc)
            model  = MatVisVideoTest.makeModel();
            layout = MatVisFrameComposer.DefaultLayout('image', model);
            comp   = MatVisFrameComposer(model, layout, 'FrameSize', [160 120]);
            tc.addTeardown(@() delete(comp));

            base = MatVisRecorder.CaptureState(model);
            states = cell(1, 3);
            for k = 1:3
                s = base;  s.CurrPos(3) = 2*k;  states{k} = s;
            end

            rec = MatVisRecorder(model, comp);
            rec.Timeline = states;
            info = rec.Render();
            tc.verifyEqual(info.frames, 3);
        end

        % ---------------- sequences -------------------------------------
        function testSequences_timelineIsTheConcatenation(tc)
            model  = MatVisVideoTest.makeModel();
            comp   = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('image', model), ...
                'FrameSize', [120 100]);
            tc.addTeardown(@() delete(comp));

            sp    = MatVisRecorder.SweepSpec(3, 'From', 1, 'To', 6);      % 6
            sp(2) = MatVisRecorder.SweepSpec(0, 'Frames', 4);             % 4
            sp(3) = MatVisRecorder.SweepSpec(3, 'From', 9, 'To', 7);      % 3

            rec = MatVisRecorder(model, comp);
            rec.Sweep = sp;
            states = rec.BuildTimeline();

            tc.verifyNumElements(states, 13);
            tc.verifyEqual(states{1}.CurrPos(3),  1);
            tc.verifyEqual(states{6}.CurrPos(3),  6);
            % A "hold" sequence keeps whatever position it inherited.
            tc.verifyEqual(states{7}.CurrPos(3),  states{10}.CurrPos(3));
            tc.verifyEqual(states{11}.CurrPos(3), 9);
            tc.verifyEqual(states{13}.CurrPos(3), 7);
            tc.verifyEqual(rec.FrameCount(), 13);
        end

        function testSequences_perSequenceStateIsApplied(tc)
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('image', model), ...
                'FrameSize', [120 100]);
            tc.addTeardown(@() delete(comp));

            sp    = MatVisRecorder.SweepSpec(3, 'From', 1, 'To', 2, 'State', ...
                struct('ContrastLocked', true, 'ContrastMode', 'Manual', ...
                       'ContrastMin', 5, 'ContrastMax', 55, 'Gamma', 1.6));
            sp(2) = MatVisRecorder.SweepSpec(3, 'From', 3, 'To', 4);

            rec = MatVisRecorder(model, comp);
            rec.Sweep = sp;
            states = rec.BuildTimeline();

            tc.verifyEqual(states{1}.ContrastMode, 'Manual');
            tc.verifyEqual(states{1}.ContrastMin,  5);
            tc.verifyEqual(states{1}.ContrastMax,  55);
            tc.verifyEqual(states{1}.Gamma,        1.6, 'AbsTol', 1e-12);
            % The second sequence set nothing, so it keeps the session's own.
            tc.verifyEqual(states{3}.ContrastMode, model.ContrastMode);
            tc.verifyEqual(states{3}.Gamma, model.Gamma, 'AbsTol', 1e-12);
        end

        function testSequences_unknownStateFieldErrors(tc)
            % Silently dropping it would leave a movie rendered with the
            % wrong contrast and no way to tell.
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('image', model), ...
                'FrameSize', [80 80]);
            tc.addTeardown(@() delete(comp));
            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(3, 'State', struct('Nope', 1));
            tc.verifyError(@() rec.BuildTimeline(), 'MatVisRecorder:badStateField');
        end

        function testSequences_cameraRampWalksFromStartToEnd(tc)
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('3d', model), ...
                'FrameSize', [100 100]);
            tc.addTeardown(@() delete(comp));

            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(0, 'Frames', 5, 'View3D', ...
                struct('az', [0 360], 'el', 25, 'zoom', [1 3]));
            states = rec.BuildTimeline();

            tc.verifyEqual(states{1}.View3D.az,   0);
            tc.verifyEqual(states{3}.View3D.az,   180);
            tc.verifyEqual(states{5}.View3D.az,   360);
            tc.verifyEqual(states{1}.View3D.zoom, 1);
            tc.verifyEqual(states{5}.View3D.zoom, 3);
            % A scalar is held, not ramped.
            tc.verifyEqual([states{1}.View3D.el, states{5}.View3D.el], [25 25]);
        end

        function testSequences_cameraRampReachesTheComposer(tc)
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('3d', model), ...
                'FrameSize', [140 140]);
            tc.addTeardown(@() delete(comp));

            frames = {};
            function keepGoing = grab(~, ~)
                frames{end+1} = comp.RenderFrame();
                keepGoing = true;
            end

            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(0, 'Frames', 3, 'View3D', ...
                struct('az', [0 120], 'el', 20, 'zoom', 1));
            rec.OnProgress  = @grab;
            rec.PreviewOnly = true;
            rec.Render();

            tc.verifyNumElements(frames, 3);
            tc.verifyNotEqual(frames{1}, frames{3}, ...
                'the camera ramp never reached the volume panel');
        end

        function testSequences_sweepAndCameraMoveTogether(tc)
            % The two things the sequence editor exists for, in one sequence:
            % step a dimension while the camera turns.  Both must land on
            % every frame, not one or the other.
            model = MatVisVideoTest.makeModel4D();
            layout = MatVisFrameComposer.DefaultLayout('image+zoom+3d', model);
            comp = MatVisFrameComposer(model, layout, 'FrameSize', [300 200]);
            tc.addTeardown(@() delete(comp));

            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(4, 'From', 1, 'To', 5, ...
                'View3D', struct('az', [0 80], 'el', [10 40], 'zoom', 1));
            states = rec.BuildTimeline();

            tc.verifyNumElements(states, 5);
            tc.verifyEqual([states{1}.CurrPos(4), states{5}.CurrPos(4)], [1 5]);
            tc.verifyEqual([states{1}.View3D.az,  states{5}.View3D.az],  [0 80]);
            tc.verifyEqual([states{1}.View3D.el,  states{5}.View3D.el],  [10 40]);

            frames = {};
            function keepGoing = grab(~, ~)
                frames{end+1} = comp.RenderFrame();
                keepGoing = true;
            end
            rec.OnProgress  = @grab;
            rec.PreviewOnly = true;
            rec.Render();

            tc.verifyNumElements(frames, 5);
            for k = 2:5
                tc.verifyNotEqual(frames{k}, frames{k-1}, ...
                    sprintf('frame %d is identical to frame %d', k, k-1));
            end
        end

        function testRampView_pickAnyFrameOfASequence(tc)
            % What the preview slider needs: the camera at an arbitrary
            % point along a ramp, including its far end.
            ramp = struct('az', [0 90], 'el', 20, 'zoom', [1 5]);
            first = MatVisRecorder.rampView(ramp, 1, 5);
            mid   = MatVisRecorder.rampView(ramp, 3, 5);
            last  = MatVisRecorder.rampView(ramp, 5, 5);
            tc.verifyEqual([first.az, mid.az, last.az], [0 45 90]);
            tc.verifyEqual([first.zoom, mid.zoom, last.zoom], [1 3 5]);
            tc.verifyEqual([first.el, last.el], [20 20]);
            % A one-frame sequence sits at the start, not halfway.
            one = MatVisRecorder.rampView(ramp, 1, 1);
            tc.verifyEqual([one.az, one.zoom], [0 1]);
            tc.verifyEmpty(MatVisRecorder.rampView([], 1, 3));
        end

        function testRampStruct_holdsScalarsAndWalksPairs(tc)
            s = MatVisRecorder.rampStruct(struct('a', 5, 'b', [0 10]), 3, 5);
            tc.verifyEqual(s.a, 5,  'a scalar must be held');
            tc.verifyEqual(s.b, 5,  'a pair must be walked');
            tc.verifyEmpty(MatVisRecorder.rampStruct(struct(), 1, 3));
            tc.verifyEmpty(MatVisRecorder.rampStruct([], 1, 3));
            % Non-numeric fields are skipped rather than coerced.
            s2 = MatVisRecorder.rampStruct(struct('a', [0 10], 'name', 'x'), 1, 1);
            tc.verifyFalse(isfield(s2, 'name'));
            tc.verifyEqual(s2.a, 0);
            % ONLY restricts which fields are read.
            s3 = MatVisRecorder.rampStruct(struct('a', 1, 'b', 2), 1, 1, {'b'});
            tc.verifyEqual(fieldnames(s3), {'b'});
        end

        function testSequences_contrastRampWalksFromStartToEnd(tc)
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('image', model), ...
                'FrameSize', [120 100]);
            tc.addTeardown(@() delete(comp));

            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(3, 'From', 1, 'To', 5, ...
                'State', struct('ContrastLocked', true, 'ContrastMode', 'Manual'), ...
                'StateRamp', struct('ContrastMin', [0 100], ...
                                    'ContrastMax', [200 600], 'Gamma', [1 2]));
            states = rec.BuildTimeline();

            tc.verifyNumElements(states, 5);
            tc.verifyEqual([states{1}.ContrastMin, states{3}.ContrastMin, ...
                            states{5}.ContrastMin], [0 50 100], 'AbsTol', 1e-12);
            tc.verifyEqual([states{1}.ContrastMax, states{5}.ContrastMax], ...
                           [200 600], 'AbsTol', 1e-12);
            tc.verifyEqual([states{1}.Gamma, states{3}.Gamma, states{5}.Gamma], ...
                           [1 1.5 2], 'AbsTol', 1e-12);
            % The held fields survive alongside the ramped ones.
            tc.verifyEqual(states{4}.ContrastMode, 'Manual');
            tc.verifyTrue(states{4}.ContrastLocked);
        end

        function testSequences_contrastRampReachesThePixels(tc)
            % A held sequence: nothing navigates, so every frame differing
            % can only be the contrast ramp arriving.
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('image', model), ...
                'FrameSize', [160 120]);
            tc.addTeardown(@() delete(comp));

            frames = {};
            function keepGoing = grab(~, ~)
                frames{end+1} = comp.RenderFrame();
                keepGoing = true;
            end

            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(0, 'Frames', 4, ...
                'State', struct('ContrastLocked', true, 'ContrastMode', 'Manual'), ...
                'StateRamp', struct('ContrastMin', [0 0], 'ContrastMax', [40 400]));
            rec.OnProgress  = @grab;
            rec.PreviewOnly = true;
            rec.Render();

            tc.verifyNumElements(frames, 4);
            for k = 2:4
                tc.verifyNotEqual(frames{k}, frames{k-1}, ...
                    sprintf('frame %d is identical to frame %d', k, k-1));
            end
        end

        function testSequences_stateRampIsValidated(tc)
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('image', model), ...
                'FrameSize', [80 80]);
            tc.addTeardown(@() delete(comp));
            rec = MatVisRecorder(model, comp);

            % A name cannot be interpolated, so say so rather than drop it.
            rec.Sweep = MatVisRecorder.SweepSpec(3, ...
                'StateRamp', struct('ContrastMode', 'Manual'));
            tc.verifyError(@() rec.BuildTimeline(), 'MatVisRecorder:badStateRamp');

            rec.Sweep = MatVisRecorder.SweepSpec(3, ...
                'StateRamp', struct('Nope', [1 2]));
            tc.verifyError(@() rec.BuildTimeline(), 'MatVisRecorder:badStateField');
        end

        function testSequences_previewOnlyWritesNothing(tc)
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('image', model), ...
                'FrameSize', [120 100]);
            tc.addTeardown(@() delete(comp));

            f = fullfile(tc.TmpDir, 'nope.avi');
            w = MatVisVideoWriter(f, 'mjavi');
            rec = MatVisRecorder(model, comp, w);
            rec.Sweep       = MatVisRecorder.SweepSpec(3, 'From', 1, 'To', 3);
            rec.PreviewOnly = true;
            info = rec.Render();

            tc.verifyEqual(info.frames, 3);
            tc.verifyEqual(info.file, '');
            tc.verifyFalse(isfile(f), 'preview playback wrote a file');
            tc.verifyEqual(w.FrameCount, 0);
        end

        function testSequences_composerCameraIsRestored(tc)
            model = MatVisVideoTest.makeModel();
            comp  = MatVisFrameComposer(model, ...
                MatVisFrameComposer.DefaultLayout('3d', model), ...
                'FrameSize', [100 100]);
            tc.addTeardown(@() delete(comp));

            comp.View3D = struct('az', 11, 'el', 22, 'zoom', 1.5);
            rec = MatVisRecorder(model, comp);
            rec.Sweep = MatVisRecorder.SweepSpec(0, 'Frames', 3, 'View3D', ...
                struct('az', [0 90], 'el', 10, 'zoom', 1));
            rec.PreviewOnly = true;
            rec.Render();

            tc.verifyEqual(comp.View3D.az,   11);
            tc.verifyEqual(comp.View3D.el,   22);
            tc.verifyEqual(comp.View3D.zoom, 1.5);
        end

        function testCaptureRestoreRoundTrip(tc)
            model = MatVisVideoTest.makeModel();
            model.CurrPos(3)  = 7;
            model.Gamma       = 1.7;
            model.ColormapIdx = 3;
            model.ZoomRange(1, :) = [5 20];

            s = MatVisRecorder.CaptureState(model);
            model.CurrPos(3)  = 1;
            model.Gamma       = 1.0;
            model.ColormapIdx = 1;
            model.ZoomRange(1, :) = [1 model.Size(1)];

            MatVisRecorder.RestoreState(model, s);
            tc.verifyEqual(model.CurrPos(3),      7);
            tc.verifyEqual(model.Gamma,           1.7, 'AbsTol', 1e-12);
            tc.verifyEqual(model.ColormapIdx,     3);
            tc.verifyEqual(model.ZoomRange(1, :), [5 20]);
        end

        function testCaptureRestore_contrastLocked(tc)
            % A per-sequence contrast forces the lock on; without it in the
            % restored set, rendering would leave the session unlocked.
            model = MatVisVideoTest.makeModel();
            tc.verifyTrue(ismember('ContrastLocked', MatVisRecorder.stateFields()));

            model.ContrastLocked = false;
            s = MatVisRecorder.CaptureState(model);
            model.ContrastLocked = true;
            MatVisRecorder.RestoreState(model, s);
            tc.verifyFalse(model.ContrastLocked);
        end

    end
end
