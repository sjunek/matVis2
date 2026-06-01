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
            model.Data = ones(5,4,3) * 50;
            slice = MatVisRender.renderSlice(model);
            tc.verifyEqual(slice, repmat(0.5, size(slice)), 'AbsTol', 1e-10);
        end

        function testRenderSlice_clamp(tc)
            model = MatVisRenderTest.makeModel3D();
            model.ContrastMin = 0;
            model.ContrastMax = 1;
            model.Data = ones(5,4,3) * 5;
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

    end

    methods (Static)
        function model = makeModel3D()
            % Simple mock struct that matches MatVisModel interface
            model.Data = reshape(1:60, [5, 4, 3]);
            model.Size = [5, 4, 3];
            model.CurrPos = [3, 2, 2];
            model.ZoomRange = [1, 5; 1, 4; 1, 3];
            model.XDim = 1;   % dim 1 = columns (x)
            model.YDim = 2;   % dim 2 = rows (y)
            model.ContrastMin = min(model.Data(:));
            model.ContrastMax = max(model.Data(:));
        end
    end
end
