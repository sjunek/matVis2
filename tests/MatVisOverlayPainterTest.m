classdef MatVisOverlayPainterTest < matlab.unittest.TestCase
    % Tests for the shared ROI / profile overlay painters in MatVisRender.
    % These are used by the image window, the zoom window and the offscreen
    % panels of the video composer, so they must draw identically apart from
    % the panel origin.

    methods (Static)
        function model = makeModel(~)
            % Default display dims are YDim=1, XDim=2.
            model = MatVisModel(reshape(1:(20*20*4), [20 20 4]));
            model.AddRoi([4 10 10 4 4; 5 5 12 12 5], 'roiA');
            model.AddProfile([3 9 15; 4 8 14]);
        end

        function ax = makeAxes(tc)
            f  = figure('Visible', 'off');
            tc.addTeardown(@() close(f));
            ax = axes('Parent', f);
        end
    end

    methods (Test)

        function testRoiOverlay_fullImageOrigin(tc)
            model = MatVisOverlayPainterTest.makeModel(tc);
            ax    = MatVisOverlayPainterTest.makeAxes(tc);

            h = MatVisRender.paintRoiOverlay(ax, model, [0 0], []);

            tc.verifyNumElements(h.lines, 1);
            tc.verifyNumElements(h.texts, 1);
            corners = model.RoiList(1).corners;
            tc.verifyEqual(h.lines(1).XData, corners(1,:), 'AbsTol', 1e-12);
            tc.verifyEqual(h.lines(1).YData, corners(2,:), 'AbsTol', 1e-12);
        end

        function testRoiOverlay_zoomOriginShiftsCoords(tc)
            model = MatVisOverlayPainterTest.makeModel(tc);
            ax    = MatVisOverlayPainterTest.makeAxes(tc);

            origin = [3 2];
            h = MatVisRender.paintRoiOverlay(ax, model, origin, []);

            corners = model.RoiList(1).corners;
            tc.verifyEqual(h.lines(1).XData, corners(1,:) - origin(1), 'AbsTol', 1e-12);
            tc.verifyEqual(h.lines(1).YData, corners(2,:) - origin(2), 'AbsTol', 1e-12);
        end

        function testPanelOrigin_matchesZoomRange(tc)
            model = MatVisOverlayPainterTest.makeModel(tc);
            % Origin is [XDim offset, YDim offset]; defaults XDim=2, YDim=1.
            model.ZoomRange(model.XDim, :) = [5 12];
            model.ZoomRange(model.YDim, :) = [3 9];

            tc.verifyEqual(MatVisRender.panelOrigin(model, false), [0 0]);
            tc.verifyEqual(MatVisRender.panelOrigin(model, true),  [4 2]);
        end

        function testRoiOverlay_reusesHandlePool(tc)
            % Repainting must not leak graphics objects.
            model = MatVisOverlayPainterTest.makeModel(tc);
            ax    = MatVisOverlayPainterTest.makeAxes(tc);

            h = MatVisRender.paintRoiOverlay(ax, model, [0 0], []);
            first = h.lines(1);
            for k = 1:5
                h = MatVisRender.paintRoiOverlay(ax, model, [0 0], h);
            end
            tc.verifyNumElements(h.lines, 1);
            tc.verifyEqual(h.lines(1), first);          % same object reused
            tc.verifyNumElements(findobj(ax, 'Type', 'line'), 1);
        end

        function testRoiOverlay_shrinksWhenRoiDeleted(tc)
            model = MatVisOverlayPainterTest.makeModel(tc);
            ax    = MatVisOverlayPainterTest.makeAxes(tc);
            model.AddRoi([1 6 6 1 1; 1 1 6 6 1], 'roiB');

            h = MatVisRender.paintRoiOverlay(ax, model, [0 0], []);
            tc.verifyNumElements(h.lines, 2);

            model.DeleteRois(2);
            h = MatVisRender.paintRoiOverlay(ax, model, [0 0], h);
            tc.verifyNumElements(h.lines, 1);
            tc.verifyNumElements(findobj(ax, 'Type', 'line'), 1);
        end

        function testProfileOverlay_fullImageOrigin(tc)
            model = MatVisOverlayPainterTest.makeModel(tc);
            ax    = MatVisOverlayPainterTest.makeAxes(tc);

            h = MatVisRender.paintProfileOverlay(ax, model, [0 0], []);

            tc.verifyNumElements(h.lines, 1);
            sp = model.ProfileList(1).smoothedPoints;
            tc.verifyEqual(h.lines(1).XData, sp(1,:), 'AbsTol', 1e-12);
            tc.verifyEqual(h.lines(1).YData, sp(2,:), 'AbsTol', 1e-12);
        end

        function testProfileOverlay_originShiftsEveryPart(tc)
            % Centerline, width band and direction arrow must all move with
            % the origin — the zoom window shifts all three.
            model = MatVisOverlayPainterTest.makeModel(tc);
            axA   = MatVisOverlayPainterTest.makeAxes(tc);
            axB   = MatVisOverlayPainterTest.makeAxes(tc);

            origin = [3 2];
            a = MatVisRender.paintProfileOverlay(axA, model, [0 0],  []);
            b = MatVisRender.paintProfileOverlay(axB, model, origin, []);

            tc.verifyEqual(b.lines(1).XData,  a.lines(1).XData  - origin(1), 'AbsTol', 1e-12);
            tc.verifyEqual(b.bands(1).XData,  a.bands(1).XData  - origin(1), 'AbsTol', 1e-12);
            tc.verifyEqual(b.arrows(1).XData, a.arrows(1).XData - origin(1), 'AbsTol', 1e-12);
            tc.verifyEqual(b.lines(1).YData,  a.lines(1).YData  - origin(2), 'AbsTol', 1e-12);
            tc.verifyEqual(b.bands(1).YData,  a.bands(1).YData  - origin(2), 'AbsTol', 1e-12);
            tc.verifyEqual(b.arrows(1).YData, a.arrows(1).YData - origin(2), 'AbsTol', 1e-12);
        end

        function testEmptyLists_paintNothing(tc)
            model = MatVisModel(reshape(1:(8*8*2), [8 8 2]));
            ax    = MatVisOverlayPainterTest.makeAxes(tc);

            hR = MatVisRender.paintRoiOverlay(ax, model, [0 0], []);
            hP = MatVisRender.paintProfileOverlay(ax, model, [0 0], []);

            tc.verifyEmpty(hR.lines);
            tc.verifyEmpty(hP.lines);
            tc.verifyEmpty(findobj(ax, 'Type', 'line'));
        end

        function testRoiShowNames_togglesTextVisibility(tc)
            model = MatVisOverlayPainterTest.makeModel(tc);
            ax    = MatVisOverlayPainterTest.makeAxes(tc);

            model.RoiShowNames = true;
            h = MatVisRender.paintRoiOverlay(ax, model, [0 0], []);
            tc.verifyEqual(char(h.texts(1).Visible), 'on');
            tc.verifyEqual(h.texts(1).String, 'roiA');

            model.RoiShowNames = false;
            h = MatVisRender.paintRoiOverlay(ax, model, [0 0], h);
            tc.verifyEqual(char(h.texts(1).Visible), 'off');
        end

    end
end
