classdef loadScanImageTiffTest < matlab.unittest.TestCase
    % Exercises loadScanImageTiff.m against the real ScanImageTiffReader MEX
    % reader. ScanImageTiffReader's metadata() only extracts SI.* fields from
    % a dedicated internal block that only genuine ScanImage-written files
    % have -- a hand-built Tiff::ImageDescription containing 'SI.*' text
    % (enough to trip isScanImageTiff's detection) is NOT enough for
    % metadata() to return anything (verified empirically: it comes back
    % empty). So this only exercises the graceful-degradation path (missing
    % metadata -> parseScanImageMetadata's NaN/[] defaults -> the
    % plane-count reconciliation driving Z/C/F/T entirely from the actual
    % IFD count). Full framesPerSlice/Z/C axis-splitting against real SI
    % metadata needs an authentic ScanImage-acquired sample file to verify
    % (see the loadScanImageTiff.m header and the project plan notes).
    %
    % Skips entirely (assumeTrue) if ScanImageTiffReader isn't set up on the
    % machine running the tests, mirroring loadBioFormatsTest.m's pattern.

    properties
        TempDir
        OrigPath
    end

    methods (TestClassSetup)
        function requireReader(tc)
            repoRoot = fullfile(fileparts(mfilename('fullpath')), '..');
            addpath(fullfile(repoRoot, 'io'));
            tc.assumeTrue(ensureScanImageTiffReader(), 'ScanImageTiffReader is not set up; skipping.');
        end
    end

    methods (TestMethodSetup)
        function setupPaths(tc)
            tc.TempDir = tempdir();
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

        function testGracefulDegradationOnMissingSIBlock(tc)
            f = fullfile(tc.TempDir, 'loadSITest_degrade.tif');
            cleanupObj = onCleanup(@() delete(f));

            page1 = uint16(reshape(1:20, [4 5]));
            page2 = uint16(reshape(21:40, [4 5]));
            page3 = uint16(reshape(41:60, [4 5]));
            writeTaggedTiff(f, {page1, page2, page3}, 'SI.VERSION_MAJOR = 2021');

            [data, meta] = loadScanImageTiff(f);
            % No real SI.* block -> nCh=framesPerSlice=zSize=tSize default to
            % 1 each; the 3-IFD/1-expected mismatch reconciliation folds all
            % 3 planes into T.
            tc.verifyEqual(size(data), [4 5 3]);
            tc.verifyEqual(data(:,:,1), page1);
            tc.verifyEqual(data(:,:,2), page2);
            tc.verifyEqual(data(:,:,3), page3);
            tc.verifyEqual(meta.dimNames, {'Y', 'X', 'T'});
            tc.verifyEqual(meta.channelNames, {'Ch1'});
        end

        function testLoadFilesRoutesThroughScanImageDetection(tc)
            f = fullfile(tc.TempDir, 'loadSITest_dispatch.tif');
            cleanupObj = onCleanup(@() delete(f));
            writeTaggedTiff(f, {uint16(reshape(1:20, [4 5]))}, 'SI.VERSION_MAJOR = 2021');

            [data, meta] = loadFiles(f);
            tc.verifyEqual(size(data), [4 5]);
            tc.verifyEqual(meta.channelNames, {'Ch1'});
        end

    end
end

% =============================================================================
function writeTaggedTiff(filepath, planes, software)
t = Tiff(filepath, 'w');
cleanupObj = onCleanup(@() closeTiffQuietly(t)); %#ok<NASGU>
tags = struct( ...
    'ImageLength',         size(planes{1}, 1), ...
    'ImageWidth',          size(planes{1}, 2), ...
    'Photometric',         Tiff.Photometric.MinIsBlack, ...
    'BitsPerSample',       16, ...
    'SampleFormat',        Tiff.SampleFormat.UInt, ...
    'SamplesPerPixel',     1, ...
    'RowsPerStrip',        size(planes{1}, 1), ...
    'PlanarConfiguration', Tiff.PlanarConfiguration.Chunky, ...
    'Compression',         Tiff.Compression.None);
for k = 1:numel(planes)
    t.setTag(tags);
    if k == 1
        t.setTag('Software', software);
    end
    t.write(planes{k});
    if k < numel(planes)
        t.writeDirectory();
    end
end
end

% =============================================================================
function closeTiffQuietly(t)
try
    t.close();
catch
end
end
