classdef parseScanImageMetadataTest < matlab.unittest.TestCase

    properties
        OrigPath
    end

    methods (TestMethodSetup)
        function setupPaths(tc)
            repoRoot = fullfile(fileparts(mfilename('fullpath')), '..');
            tc.OrigPath = path();
            addpath(fullfile(repoRoot, 'io'));
        end
    end

    methods (TestMethodTeardown)
        function restorePaths(tc)
            path(tc.OrigPath);
        end
    end

    methods (Test)

        function testFullMetadataParsedCorrectly(tc)
            lines = { ...
                'SI.LINE_FORMAT_VERSION = 1'
                'SI.hRoiManager.pixelsPerLine = 512'
                'SI.hRoiManager.linesPerFrame = 256'
                'SI.hStackManager.actualNumSlices = 5'
                'SI.hStackManager.numVolumes = 20'
                'SI.hRoiManager.scanZoomFactor = 2.5'
                'SI.hRoiManager.scanFrameRate = 30.02'
                'SI.hRoiManager.scanVolumeRate = 1.2'
                'SI.hChannels.channelSave = [1 2]'
                'SI.hStackManager.actualStackZStepSize = 2'
                'SI.hStackManager.framesPerSlice = 8'
                'SI.hScan2D.logAverageFactor = 4'
                'SI.hRoiManager.imagingFovUm = [-100 -50;100 -50;100 50;-100 50]'
                'SI.acqState = ''grab'''};
            md = parseScanImageMetadata(strjoin(lines, char(10)));

            tc.verifyEqual(md.xSize, 512);
            tc.verifyEqual(md.ySize, 256);
            tc.verifyEqual(md.zSize, 5);
            tc.verifyEqual(md.tSize, 20);
            tc.verifyEqual(md.zoom, 2.5);
            tc.verifyEqual(md.frameRate_Hz, 30.02);
            tc.verifyEqual(md.volumeRate_Hz, 1.2);
            tc.verifyEqual(md.savedChannels, [1 2]);
            tc.verifyEqual(md.dz_um, 2);
            % Raw framesPerSlice (8) divided by logAverageFactor (4).
            tc.verifyEqual(md.framesPerSlice, 2);
            tc.verifyEqual(md.frameAverage, 4);
            tc.verifyEqual(md.FOV_um, [100 200], 'AbsTol', 1e-9);
            tc.verifyEqual(md.dx_um, 200/512, 'AbsTol', 1e-9);
            tc.verifyEqual(md.dy_um, 100/256, 'AbsTol', 1e-9);
        end

        function testMissingFieldsDefaultToNaN(tc)
            md = parseScanImageMetadata('SI.hRoiManager.pixelsPerLine = 100');
            tc.verifyEqual(md.xSize, 100);
            tc.verifyTrue(isnan(md.ySize));
            tc.verifyTrue(isnan(md.zSize));
            tc.verifyTrue(isnan(md.framesPerSlice));
            tc.verifyTrue(isnan(md.dx_um));
            tc.verifyTrue(isnan(md.dy_um));
            tc.verifyEmpty(md.savedChannels);
            tc.verifyEmpty(md.FOV_um);
        end

        function testEmptyStringYieldsAllDefaults(tc)
            md = parseScanImageMetadata('');
            tc.verifyTrue(isnan(md.xSize));
            tc.verifyTrue(isnan(md.framesPerSlice));
            tc.verifyEmpty(md.savedChannels);
        end

        function testFramesPerSliceNotDividedWithoutFrameAverage(tc)
            % frameAverage absent (NaN) -> framesPerSlice passed through raw,
            % not divided by NaN.
            lines = {'SI.hStackManager.framesPerSlice = 6'};
            md = parseScanImageMetadata(strjoin(lines, char(10)));
            tc.verifyEqual(md.framesPerSlice, 6);
        end

    end
end
