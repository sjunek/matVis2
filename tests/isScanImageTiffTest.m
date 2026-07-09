classdef isScanImageTiffTest < matlab.unittest.TestCase

    properties
        TempDir
        OrigPath
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

        function testPlainTifIsNotScanImage(tc)
            f = fullfile(tc.TempDir, 'isSITest_plain.tif');
            imwrite(uint8(reshape(1:20, [4 5])), f);
            cleanupObj = onCleanup(@() delete(f));
            tc.verifyFalse(isScanImageTiff(f));
        end

        function testImageDescriptionSignatureDetected(tc)
            f = fullfile(tc.TempDir, 'isSITest_desc.tif');
            writeTiffWithTags(f, uint8(reshape(1:20, [4 5])), ...
                'SI.hRoiManager.pixelsPerLine = 5', '');
            cleanupObj = onCleanup(@() delete(f));
            tc.verifyTrue(isScanImageTiff(f));
        end

        function testSoftwareSignatureDetected(tc)
            f = fullfile(tc.TempDir, 'isSITest_soft.tif');
            writeTiffWithTags(f, uint8(reshape(1:20, [4 5])), '', 'SI.VERSION_MAJOR = 2021');
            cleanupObj = onCleanup(@() delete(f));
            tc.verifyTrue(isScanImageTiff(f));
        end

        function testFrameNumbersSignatureDetected(tc)
            f = fullfile(tc.TempDir, 'isSITest_frame.tif');
            writeTiffWithTags(f, uint8(reshape(1:20, [4 5])), 'frameNumbers = 1', '');
            cleanupObj = onCleanup(@() delete(f));
            tc.verifyTrue(isScanImageTiff(f));
        end

        function testAcceptsPrefetchedImfinfoStruct(tc)
            f = fullfile(tc.TempDir, 'isSITest_info.tif');
            writeTiffWithTags(f, uint8(reshape(1:20, [4 5])), 'SI.foo = 1', '');
            cleanupObj = onCleanup(@() delete(f));
            info = imfinfo(f);
            tc.verifyTrue(isScanImageTiff(info));
        end

    end
end

% =============================================================================
function writeTiffWithTags(filepath, plane, imageDescription, software)
t = Tiff(filepath, 'w');
cleanupObj = onCleanup(@() closeTiffQuietly(t)); %#ok<NASGU>
tags = struct( ...
    'ImageLength',         size(plane, 1), ...
    'ImageWidth',          size(plane, 2), ...
    'Photometric',         Tiff.Photometric.MinIsBlack, ...
    'BitsPerSample',       8, ...
    'SampleFormat',        Tiff.SampleFormat.UInt, ...
    'SamplesPerPixel',     1, ...
    'RowsPerStrip',        size(plane, 1), ...
    'PlanarConfiguration', Tiff.PlanarConfiguration.Chunky, ...
    'Compression',         Tiff.Compression.None);
t.setTag(tags);
if ~isempty(imageDescription)
    t.setTag('ImageDescription', imageDescription);
end
if ~isempty(software)
    t.setTag('Software', software);
end
t.write(plane);
end

% =============================================================================
function closeTiffQuietly(t)
try
    t.close();
catch
end
end
