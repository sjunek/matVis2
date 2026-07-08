classdef importMultiFileTest < matlab.unittest.TestCase

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

        function testSeparateModeReturnsEachFile(tc)
            [f1, im1] = tc.makeTif('a', [4 5]);
            [f2, im2] = tc.makeTif('b', [4 5]);

            [datasets, dsMeta] = importMultiFile({f1, f2}, 'Mode', 'separate');

            tc.verifyEqual(numel(datasets), 2);
            tc.verifyEqual(datasets{1}, im1);
            tc.verifyEqual(datasets{2}, im2);
            tc.verifyEqual(dsMeta.datasetNames, {'importMultiFileTest_a', 'importMultiFileTest_b'});
        end

        function testConcatenateModeStacksAlongNewDim(tc)
            [f1, im1] = tc.makeTif('c', [4 5]);
            [f2, im2] = tc.makeTif('d', [4 5]);

            [datasets, dsMeta] = importMultiFile({f1, f2}, 'Mode', 'concatenate');

            tc.verifyEqual(numel(datasets), 1);
            tc.verifyEqual(size(datasets{1}), [4 5 2]);
            tc.verifyEqual(datasets{1}(:,:,1), im1);
            tc.verifyEqual(datasets{1}(:,:,2), im2);
            tc.verifyEqual(dsMeta.dimNames{end}, 'Series');
            tc.verifyEqual(dsMeta.dimScale{end}, 1:2);
            tc.verifyEqual(dsMeta.datasetNames, {'Concatenated'});
        end

        function testMismatchedSizesCroppedWithWarning(tc)
            [f1, ~] = tc.makeTif('big', [4 5]);
            [f2, ~] = tc.makeTif('small', [3 5]);

            tc.verifyWarning(@() importMultiFile({f1, f2}, 'Mode', 'separate'), ...
                'importMultiFile:sizeMismatch');

            [datasets, ~] = importMultiFile({f1, f2}, 'Mode', 'separate');
            tc.verifyEqual(size(datasets{1}), [3 5]);
            tc.verifyEqual(size(datasets{2}), [3 5]);
        end

        function testSingleFileSkipsDialogEvenInAskMode(tc)
            [f1, im1] = tc.makeTif('solo', [4 5]);
            [datasets, dsMeta] = importMultiFile({f1}); % default Mode='ask'
            tc.verifyEqual(numel(datasets), 1);
            tc.verifyEqual(datasets{1}, im1);
            tc.verifyEqual(dsMeta.datasetNames, {'importMultiFileTest_solo'});
        end

        function testBadModeThrowsError(tc)
            [f1, ~] = tc.makeTif('e', [4 5]);
            tc.verifyError(@() importMultiFile({f1}, 'Mode', 'bogus'), ...
                'importMultiFile:badMode');
        end

    end

    methods
        function [filepath, img] = makeTif(tc, name, sz)
            filepath = fullfile(tc.TempDir, ['importMultiFileTest_' name '.tif']);
            img = uint8(mod(reshape(1:prod(sz), sz), 250));
            imwrite(img, filepath);
            tc.addTeardown(@() deleteIfExists(filepath));
        end
    end
end

% =============================================================================
function deleteIfExists(filepath)
if exist(filepath, 'file')
    delete(filepath);
end
end
