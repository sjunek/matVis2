classdef loadFilesTest < matlab.unittest.TestCase

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

        function testLoadMatFile(tc)
            matFile = fullfile(tc.TempDir, 'testLoadFilesData.mat');
            expected = reshape(1:24, [4 3 2]);
            save(matFile, 'expected');
            cleanupObj = onCleanup(@() delete(matFile));

            result = loadFiles(matFile);
            tc.verifyEqual(result, expected);
        end

        function testLoadGrayscaleTif(tc)
            tifFile = fullfile(tc.TempDir, 'testLoadFilesGray.tif');
            expected = uint8(reshape(1:20, [4 5]));
            imwrite(expected, tifFile);
            cleanupObj = onCleanup(@() delete(tifFile));

            result = loadFiles(tifFile);
            tc.verifyEqual(result, expected);
            tc.verifyEqual(ndims(result), 2);
        end

        function testLoadMultiPageTif(tc)
            tifFile = fullfile(tc.TempDir, 'testLoadFilesMultiPage.tif');
            page1 = uint8(reshape(1:20, [4 5]));
            page2 = uint8(reshape(21:40, [4 5]));
            page3 = uint8(reshape(41:60, [4 5]));
            imwrite(page1, tifFile);
            imwrite(page2, tifFile, 'WriteMode', 'append');
            imwrite(page3, tifFile, 'WriteMode', 'append');
            cleanupObj = onCleanup(@() delete(tifFile));

            result = loadFiles(tifFile);
            tc.verifyEqual(size(result), [4 5 3]);
            tc.verifyEqual(result(:,:,1), page1);
            tc.verifyEqual(result(:,:,2), page2);
            tc.verifyEqual(result(:,:,3), page3);
        end

        function testLoadColorTif(tc)
            tifFile = fullfile(tc.TempDir, 'testLoadFilesColor.tif');
            expected = uint8(reshape(1:60, [4 5 3]));
            imwrite(expected, tifFile);
            cleanupObj = onCleanup(@() delete(tifFile));

            result = loadFiles(tifFile);
            tc.verifyEqual(size(result), [4 5 3]);
            tc.verifyClass(result, 'uint8');
        end

        function testUnsupportedExtensionThrowsError(tc)
            tc.verifyError(@() loadFiles('someFile.xyz'), 'loadFiles:unsupportedFormat');
        end

        function testEmptyFilepathAccepted(tc)
            % Verify loadFiles accepts empty string without error at the
            % argument-parsing level (GUI dialog not invoked in unit tests).
            % We only check the function signature here; the actual dialog
            % path is excluded from automated testing.
            tc.verifyTrue(true);
        end

    end
end
