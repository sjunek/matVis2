classdef MatVisRenderTest < matlab.unittest.TestCase

    methods (Test)

        function testRenderSlice_basic(tc)
            model = MatVisRenderTest.makeModel3D();
            slice = MatVisRender.renderSlice(model);
            tc.verifyEqual(size(slice), [4, 5]);  % [yRange, xRange]
            tc.verifyGreaterThanOrEqual(min(slice(:)), 0);
            tc.verifyLessThanOrEqual(max(slice(:)), 1);
        end

        function testRenderSlice_normalization(tc)
            model = MatVisRenderTest.makeModel3D();
            model.ContrastMin = 0;
            model.ContrastMax = 100;
            model.Data = MatVisMemorySource(ones(5,4,3) * 50);
            slice = MatVisRender.renderSlice(model);
            tc.verifyEqual(slice, repmat(0.5, size(slice)), 'AbsTol', 1e-10);
        end

        function testRenderSlice_clamp(tc)
            model = MatVisRenderTest.makeModel3D();
            model.ContrastMin = 0;
            model.ContrastMax = 1;
            model.Data = MatVisMemorySource(ones(5,4,3) * 5);
            slice = MatVisRender.renderSlice(model);
            tc.verifyEqual(max(slice(:)), 1);
        end

        function testRenderSlice_contrastMinEqualsMax(tc)
            model = MatVisRenderTest.makeModel3D();
            model.ContrastMin = 5;
            model.ContrastMax = 5;
            slice = MatVisRender.renderSlice(model);
            tc.verifyEqual(slice, zeros(size(slice)));
        end

        function testRenderProfile_basic(tc)
            model = MatVisRenderTest.makeModel3D();
            profile = MatVisRender.renderProfile(model, 3);
            tc.verifyEqual(numel(profile), model.ZoomRange(3,2) - model.ZoomRange(3,1) + 1);
        end

        function testRenderProfile_isVector(tc)
            model = MatVisRenderTest.makeModel3D();
            profile = MatVisRender.renderProfile(model, 1);
            tc.verifyEqual(size(profile, 2), 1);
        end

        function testApplyGamma_identity(tc)
            data = rand(10, 10);
            out = MatVisRender.applyGamma(data, 1);
            tc.verifyEqual(out, data, 'AbsTol', 1e-12);
        end

        function testApplyGamma_squaring(tc)
            data = rand(5, 5);
            out = MatVisRender.applyGamma(data, 2);
            tc.verifyEqual(out, data.^2, 'AbsTol', 1e-12);
        end

        function testApplyGamma_sizePreserved(tc)
            data = rand(3, 7);
            out = MatVisRender.applyGamma(data, 0.5);
            tc.verifyEqual(size(out), size(data));
        end

        function testApplyColormap_outputClass(tc)
            data = rand(8, 8);
            img = MatVisRender.applyColormap(data, 1);
            tc.verifyClass(img, 'uint8');
        end

        function testApplyColormap_outputSize(tc)
            data = rand(6, 10);
            img = MatVisRender.applyColormap(data, 1);
            tc.verifyEqual(size(img), [6, 10, 3]);
        end

        function testApplyColormap_grayZerosAreBlack(tc)
            data = zeros(2, 2);
            img = MatVisRender.applyColormap(data, 1);  % gray
            tc.verifyEqual(img(1,1,:), zeros(1,1,3,'uint8'));
        end

        function testApplyColormap_grayOnesAreWhite(tc)
            data = ones(2, 2);
            img = MatVisRender.applyColormap(data, 1);
            tc.verifyEqual(img(1,1,:), uint8(255*ones(1,1,3)));
        end

        function testComputeHistogram_counts(tc)
            data = rand(100, 100);
            [counts, edges] = MatVisRender.computeHistogram(data);
            tc.verifyEqual(sum(counts), numel(data));
        end

        function testComputeHistogram_numBins(tc)
            data = rand(50, 50);
            [counts, edges] = MatVisRender.computeHistogram(data);
            tc.verifyEqual(numel(counts), 256);
            tc.verifyEqual(numel(edges), 257);
        end

        function testGetColormap_gray(tc)
            cmap = MatVisRender.getColormap(1, 256);
            tc.verifyEqual(size(cmap), [256, 3]);
            tc.verifyEqual(cmap(1,:), [0 0 0], 'AbsTol', 1e-10);
            tc.verifyEqual(cmap(end,:), [1 1 1], 'AbsTol', 1e-10);
        end

        function testGetColormap_allCmapsReturnCorrectSize(tc)
            for k = 1:31
                cmap = MatVisRender.getColormap(k, 128);
                tc.verifyEqual(size(cmap, 1), 128, ...
                    sprintf('Colormap index %d returned wrong row count', k));
                tc.verifyEqual(size(cmap, 2), 3, ...
                    sprintf('Colormap index %d returned wrong col count', k));
            end
        end

        function testGetColormap_rangeIn01(tc)
            for k = 1:31
                cmap = MatVisRender.getColormap(k, 64);
                tc.verifyGreaterThanOrEqual(min(cmap(:)), 0, ...
                    sprintf('Colormap %d has values below 0', k));
                tc.verifyLessThanOrEqual(max(cmap(:)), 1, ...
                    sprintf('Colormap %d has values above 1', k));
            end
        end

        function testGetColormap_unknown_fallsBackToGray(tc)
            cmap = MatVisRender.getColormap(999, 64);
            expected = gray(64);
            tc.verifyEqual(cmap, expected, 'AbsTol', 1e-10);
        end

        function testProfileNeighborAlpha_singlePixelEqualsData(tc)
            % avgMode 0: weighted mean over a single pixel is the data itself
            model = MatVisRenderTest.makeModel3D();
            alpha = MatVisRenderTest.makeAlpha3D();
            alphaSrc = MatVisMemorySource(alpha);
            [p, a] = MatVisRender.renderProfileNeighborAlphaFromData( ...
                model, model.Data, alphaSrc, 3, 0);
            expectedP = squeeze(model.Raw(3, 2, :));
            expectedA = squeeze(alpha(3, 2, :));
            tc.verifyEqual(p, double(expectedP), 'AbsTol', 1e-12);
            tc.verifyEqual(a, expectedA, 'AbsTol', 1e-12);
        end

        function testProfileNeighborAlpha_weightedMean3x3(tc)
            model = MatVisRenderTest.makeModel3D();
            alpha = MatVisRenderTest.makeAlpha3D();
            alphaSrc = MatVisMemorySource(alpha);
            [p, a] = MatVisRender.renderProfileNeighborAlphaFromData( ...
                model, model.Data, alphaSrc, 3, 1);
            % 3x3 neighborhood around CurrPos = [3, 2] (clipped to bounds)
            xR = 2:4;  yR = 1:3;
            nT = model.Size(3);
            expP = zeros(nT, 1);  expA = zeros(nT, 1);
            for t = 1:nT
                v = double(model.Raw(xR, yR, t));
                w = alpha(xR, yR, t);
                expP(t) = sum(v(:) .* w(:)) / sum(w(:));
                expA(t) = mean(w(:));
            end
            tc.verifyEqual(p, expP, 'AbsTol', 1e-10);
            tc.verifyEqual(a, expA, 'AbsTol', 1e-10);
        end

        function testProfileNeighborAlpha_omitsNanData(tc)
            model = MatVisRenderTest.makeModel3D();
            model.Raw = double(model.Raw);
            model.Raw(2, 1, 1) = NaN;   % inside the 3x3 neighborhood, t=1
            model.Data = MatVisMemorySource(model.Raw);
            alpha = MatVisRenderTest.makeAlpha3D();
            alphaSrc = MatVisMemorySource(alpha);
            [p, ~] = MatVisRender.renderProfileNeighborAlphaFromData( ...
                model, model.Data, alphaSrc, 3, 1);
            xR = 2:4;  yR = 1:3;
            v = model.Raw(xR, yR, 1);
            w = alpha(xR, yR, 1);
            keep = ~isnan(v);
            expected = sum(v(keep) .* w(keep)) / sum(w(keep));
            tc.verifyEqual(p(1), expected, 'AbsTol', 1e-10);
            tc.verifyFalse(isnan(p(1)));
        end

        function testFullProfileNeighborAlpha_ignoresZoom(tc)
            model = MatVisRenderTest.makeModel3D();
            model.ZoomRange(3, :) = [2, 2];
            alpha = MatVisRenderTest.makeAlpha3D();
            alphaSrc = MatVisMemorySource(alpha);
            [pZoom, ~] = MatVisRender.renderProfileNeighborAlphaFromData( ...
                model, model.Data, alphaSrc, 3, 1);
            [pFull, aFull] = MatVisRender.renderFullProfileNeighborAlphaFromData( ...
                model, model.Data, alphaSrc, 3, 1);
            tc.verifyEqual(numel(pZoom), 1);
            tc.verifyEqual(numel(pFull), model.Size(3));
            tc.verifyEqual(numel(aFull), model.Size(3));
            tc.verifyEqual(pFull(2), pZoom(1), 'AbsTol', 1e-12);
        end

        function testRoiProfileAlpha_weightedMean(tc)
            model = MatVisRenderTest.makeModel3D();
            alpha = MatVisRenderTest.makeAlpha3D();
            alphaSrc = MatVisMemorySource(alpha);
            roi.index.x = [2; 3; 4];
            roi.index.y = [2; 2; 3];
            [p, a] = MatVisRender.renderRoiProfileAlphaFromData( ...
                model, model.Data, alphaSrc, 3, roi, false);
            nT = model.Size(3);
            expP = zeros(nT, 1);  expA = zeros(nT, 1);
            for t = 1:nT
                v = zeros(3, 1);  w = zeros(3, 1);
                for q = 1:3
                    v(q) = double(model.Raw(roi.index.x(q), roi.index.y(q), t));
                    w(q) = alpha(roi.index.x(q), roi.index.y(q), t);
                end
                expP(t) = sum(v .* w) / sum(w);
                expA(t) = mean(w);
            end
            tc.verifyEqual(p, expP, 'AbsTol', 1e-10);
            tc.verifyEqual(a, expA, 'AbsTol', 1e-10);
        end

        function testRoiProfileAlpha_displayAxisReturnsEmpty(tc)
            model = MatVisRenderTest.makeModel3D();
            alpha = MatVisRenderTest.makeAlpha3D();
            alphaSrc = MatVisMemorySource(alpha);
            roi.index.x = [2; 3];
            roi.index.y = [2; 2];
            [p, a] = MatVisRender.renderRoiProfileAlphaFromData( ...
                model, model.Data, alphaSrc, model.XDim, roi, false);
            tc.verifyEmpty(p);
            tc.verifyEmpty(a);
        end

        function testRoiProfileAlpha_matchesPlainMeanForUniformAlpha(tc)
            % With a constant alpha map the weighted mean must equal the
            % plain ROI mean.
            model = MatVisRenderTest.makeModel3D();
            alpha = 0.7 * ones(model.Size);
            alphaSrc = MatVisMemorySource(alpha);
            roi.index.x = [1; 2; 5];
            roi.index.y = [1; 3; 4];
            [p, a] = MatVisRender.renderRoiProfileAlphaFromData( ...
                model, model.Data, alphaSrc, 3, roi, false);
            pPlain = MatVisRender.renderRoiProfileFromData( ...
                model, model.Data, 3, roi, false);
            tc.verifyEqual(p, pPlain, 'AbsTol', 1e-10);
            tc.verifyEqual(a, repmat(0.7, model.Size(3), 1), 'AbsTol', 1e-12);
        end

    end

    methods (Static)
        function model = makeModel3D()
            % Simple mock struct that matches MatVisModel interface
            raw = reshape(1:60, [5, 4, 3]);
            model.Data = MatVisMemorySource(raw);  % mirrors MatVisModel.Data
            model.Raw  = raw;                      % same values, for expected-value math
            model.Size = [5, 4, 3];
            model.CurrPos = [3, 2, 2];
            model.ZoomRange = [1, 5; 1, 4; 1, 3];
            model.XDim = 1;   % dim 1 = columns (x)
            model.YDim = 2;   % dim 2 = rows (y)
            model.ContrastMin = min(raw(:));
            model.ContrastMax = max(raw(:));
            model.ProjFun     = 'none';
            model.ProjDim     = 0;
            model.ProjZoomLock = false;
            model.RGBDim      = 0;
            model.FlipX       = false;
            model.FlipY       = false;
        end

        function alpha = makeAlpha3D()
            % Deterministic, strictly positive alpha map matching makeModel3D
            alpha = reshape(linspace(0.1, 1, 60), [5, 4, 3]);
        end
    end
end
