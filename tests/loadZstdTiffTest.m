classdef loadZstdTiffTest < matlab.unittest.TestCase
    % Round-trip tests for the Zstandard TIFF reader (loadZstdTiff,
    % isZstdTiff, zstdDecompress, parseTiffIfds), using synthetic files
    % written by writeTestZstdTiff so nothing depends on a large fixture.

    properties
        tmpDir
    end

    methods (TestClassSetup)
        function addIoToPath(testCase)
            here = fileparts(mfilename('fullpath'));
            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                fullfile(fileparts(here), 'io')));
            testCase.assumeTrue(ensureBioFormats(), ...
                'Bio-Formats (which bundles the Java Zstandard codec) is not set up.');
        end
    end

    methods (TestMethodSetup)
        function makeTmpDir(testCase)
            testCase.tmpDir = tempname;
            mkdir(testCase.tmpDir);
            testCase.addTeardown(@() rmdir(testCase.tmpDir, 's'));
        end
    end

    methods
        function p = tmpFile(testCase, name)
            p = fullfile(testCase.tmpDir, name);
        end
    end

    methods (Test)

        function singlePageOneStrip(testCase)
            ref = uint16(reshape(1:(7 * 5), 7, 5) * 37);
            f = testCase.tmpFile('single.tif');
            writeTestZstdTiff(f, ref);

            testCase.verifyTrue(isZstdTiff(f));
            [data, meta] = loadZstdTiff(f);
            testCase.verifyEqual(data, ref);
            testCase.verifyEqual(meta.dimNames, {'Y', 'X'});
        end

        function multiStrip(testCase)
            ref = uint16(randi([0, 65535], 20, 13));
            f = testCase.tmpFile('strips.tif');
            writeTestZstdTiff(f, ref, 'RowsPerStrip', 6);

            [~, hdr] = parseTiffIfds(f);
            testCase.verifyFalse(hdr.isBigTiff);
            testCase.verifyEqual(loadZstdTiff(f), ref);
        end

        function multiPageStack(testCase)
            ref = uint16(randi([0, 4095], 9, 11, 1, 4));
            f = testCase.tmpFile('stack.tif');
            writeTestZstdTiff(f, ref, 'RowsPerStrip', 4);

            [data, meta] = loadZstdTiff(f);
            testCase.verifyEqual(data, reshape(ref, 9, 11, 4));
            testCase.verifyEqual(meta.dimNames, {'Y', 'X', 'Z'});
        end

        function bigTiffMultiPage(testCase)
            ref = uint16(randi([0, 65535], 8, 8, 1, 3));
            f = testCase.tmpFile('big.tif');
            writeTestZstdTiff(f, ref, 'BigTiff', true, 'RowsPerStrip', 3);

            [~, hdr] = parseTiffIfds(f);
            testCase.verifyTrue(hdr.isBigTiff);
            testCase.verifyEqual(loadZstdTiff(f), reshape(ref, 8, 8, 3));
        end

        function tiledWithEdgePadding(testCase)
            ref = uint16(randi([0, 1000], 20, 18));
            f = testCase.tmpFile('tiled.tif');
            writeTestZstdTiff(f, ref, 'TileSize', [16, 16]);

            testCase.verifyEqual(loadZstdTiff(f), ref);
        end

        function horizontalDifferencingPredictor(testCase)
            ref = uint16(randi([0, 65535], 12, 10));
            f = testCase.tmpFile('pred2.tif');
            writeTestZstdTiff(f, ref, 'Predictor', 2, 'RowsPerStrip', 5);

            [data, meta] = loadZstdTiff(f);
            testCase.verifyEqual(data, ref);
            rows = meta.instrument.TiffTags;
            testCase.verifyTrue(any(strcmp(rows(:, 1), 'Predictor')));
        end

        function multiSampleRgb(testCase)
            ref = uint8(randi([0, 255], 6, 5, 3, 2));
            f = testCase.tmpFile('rgb.tif');
            writeTestZstdTiff(f, ref);

            [data, meta] = loadZstdTiff(f);
            testCase.verifyEqual(data, ref);
            testCase.verifyEqual(meta.dimNames, {'Y', 'X', 'C', 'Z'});
            testCase.verifyEqual(meta.channelNames, {'Ch1', 'Ch2', 'Ch3'});
        end

        function floatSamples(testCase)
            ref = single(randn(6, 7));
            f = testCase.tmpFile('float.tif');
            writeTestZstdTiff(f, ref);

            testCase.verifyEqual(loadZstdTiff(f), ref);
        end

        function signedSamples(testCase)
            ref = int16(randi([-32768, 32767], 5, 9));
            f = testCase.tmpFile('signed.tif');
            writeTestZstdTiff(f, ref);

            testCase.verifyEqual(loadZstdTiff(f), ref);
        end

        function resolutionInCentimetresBecomesScale(testCase)
            ref = uint16(ones(4, 4));
            f = testCase.tmpFile('res_cm.tif');
            % 20000 px/cm -> 0.5 um/px.
            writeTestZstdTiff(f, ref, 'Resolution', [20000, 20000], 'ResolutionUnit', 3);

            [~, meta] = loadZstdTiff(f);
            testCase.verifyEqual(meta.dimUnits, {'um', 'um'});
            testCase.verifyEqual(meta.dimScale{1}, 0.5, 'AbsTol', 1e-9);
            testCase.verifyEqual(meta.dimScale{2}, 0.5, 'AbsTol', 1e-9);
        end

        function unitlessDifferingResolutionsMeanLateralAndZ(testCase)
            % ResolutionUnit "none" leaves 282/283 undefined per spec; these
            % writers put micrometres per pixel there. Two differing values
            % cannot both be lateral pitches, so 282 is the lateral pitch for
            % Y and X and 283 is the Z step.
            ref = uint16(ones(4, 4, 1, 3));
            f = testCase.tmpFile('res_none.tif');
            writeTestZstdTiff(f, ref, 'Resolution', [0.4106, 5], 'ResolutionUnit', 1);

            [~, meta] = loadZstdTiff(f);
            testCase.verifyEqual(meta.dimNames, {'Y', 'X', 'Z'});
            testCase.verifyEqual(meta.dimUnits, {'um', 'um', 'um'});
            testCase.verifyEqual(meta.dimScale{1}, 0.4106, 'AbsTol', 1e-9); % Y
            testCase.verifyEqual(meta.dimScale{2}, 0.4106, 'AbsTol', 1e-9); % X
            testCase.verifyEqual(meta.dimScale{3}, 5, 'AbsTol', 1e-9);      % Z

            % The rows are labelled for how the two tags were actually used,
            % so tag 283 must not show up as a Y resolution.
            rows = meta.instrument.TiffTags;
            xyRow = rows(strcmp(rows(:, 1), 'X/Y resolution'), 2);
            testCase.verifyEqual(xyRow{1}, '0.4106 um/px');
            zRow = rows(strcmp(rows(:, 1), 'Z resolution'), 2);
            testCase.verifyEqual(zRow{1}, '5 um/px');
            testCase.verifyFalse(any(strcmp(rows(:, 1), 'X resolution')));
            testCase.verifyFalse(any(strcmp(rows(:, 1), 'Y resolution')));
            unitRow = rows(strcmp(rows(:, 1), 'Resolution unit'), 2);
            testCase.verifyEqual(unitRow{1}, 'none (values read as um/px)');
            testCase.verifyTrue(any(strcmp(rows(:, 1), 'Resolution reading')));
        end

        function unitlessEqualResolutionsStayLateral(testCase)
            % Matching tags are an ordinary isotropic calibration: both are
            % lateral pitches and nothing is claimed about Z.
            ref = uint16(ones(4, 4, 1, 3));
            f = testCase.tmpFile('res_none_equal.tif');
            writeTestZstdTiff(f, ref, 'Resolution', [0.325, 0.325], 'ResolutionUnit', 1);

            [~, meta] = loadZstdTiff(f);
            testCase.verifyEqual(meta.dimUnits, {'um', 'um', ''});
            testCase.verifyEqual(meta.dimScale{1}, 0.325, 'AbsTol', 1e-9);
            testCase.verifyEqual(meta.dimScale{2}, 0.325, 'AbsTol', 1e-9);
            testCase.verifyEqual(meta.dimScale{3}, 1);

            % Per-axis reading, so the rows keep the per-axis labels.
            rows = meta.instrument.TiffTags;
            testCase.verifyTrue(any(strcmp(rows(:, 1), 'X resolution')));
            testCase.verifyTrue(any(strcmp(rows(:, 1), 'Y resolution')));
            testCase.verifyFalse(any(strcmp(rows(:, 1), 'Resolution reading')));
        end

        function missingResolutionTagsClaimNoScale(testCase)
            ref = uint16(ones(4, 4));
            f = testCase.tmpFile('res_absent.tif');
            writeTestZstdTiff(f, ref);

            [~, meta] = loadZstdTiff(f);
            testCase.verifyEqual(meta.dimUnits, {'', ''});
            testCase.verifyEqual(meta.dimScale, {1, 1});
        end

        function tiffTagRowsDescribeTheContainer(testCase)
            ref = uint16(ones(8, 8, 1, 2));
            f = testCase.tmpFile('tags.tif');
            writeTestZstdTiff(f, ref, 'BigTiff', true, 'RowsPerStrip', 4, ...
                'Software', 'matVis2 test writer');

            [~, meta] = loadZstdTiff(f);
            rows = meta.instrument.TiffTags;
            map = containers.Map(rows(:, 1), rows(:, 2));
            testCase.verifyEqual(map('TIFF flavour'), 'BigTIFF, little-endian');
            testCase.verifyEqual(map('Compression'), 'Zstandard (50000)');
            testCase.verifyEqual(map('Image size'), '8 x 8 px');
            testCase.verifyEqual(map('Pages (IFDs)'), '2');
            testCase.verifyEqual(map('Sample format'), '16-bit unsigned integer');
            testCase.verifyEqual(map('Software'), 'matVis2 test writer');
            testCase.verifyTrue(contains(map('Segment layout'), '4 row(s) per strip'));
        end

        function loadFilesRoutesZstdTiffs(testCase)
            ref = uint16(randi([0, 65535], 10, 12, 1, 3));
            f = testCase.tmpFile('via_loadfiles.tif');
            writeTestZstdTiff(f, ref, 'RowsPerStrip', 4);

            [data, meta] = loadFiles(f);
            testCase.verifyEqual(data, reshape(ref, 10, 12, 3));
            testCase.verifyEqual(meta.dimNames, {'Y', 'X', 'Z'});
        end

        function isZstdTiffRejectsOtherCompression(testCase)
            f = testCase.tmpFile('plain.tif');
            imwrite(uint8(magic(8)), f);
            testCase.verifyFalse(isZstdTiff(f));

            g = testCase.tmpFile('notatiff.tif');
            fid = fopen(g, 'w'); fwrite(fid, uint8(1:32)); fclose(fid);
            testCase.verifyFalse(isZstdTiff(g));
        end

        function loadZstdTiffRejectsUnsupportedCompression(testCase)
            % Same container, but the Compression tag says JPEG.
            ref = uint16(ones(4, 4));
            f = testCase.tmpFile('faked.tif');
            writeTestZstdTiff(f, ref, 'Compression', 7);

            testCase.verifyError(@() loadZstdTiff(f), 'loadZstdTiff:unsupportedCompression');
        end

        function otherSchemesPerPage(testCase)
            % Compression is a per-directory tag, so one page's scheme says
            % nothing about the next one's.
            schemes = [1, 5, 8, 32773, 32946, 50000];
            ref = uint16(randi([0, 65535], 9, 7, 1, numel(schemes)));
            f = testCase.tmpFile('each_scheme.tif');
            writeTestZstdTiff(f, ref, 'Compression', schemes, 'RowsPerStrip', 4);

            testCase.verifyEqual(loadZstdTiff(f), reshape(ref, 9, 7, numel(schemes)));
        end

        function mixedPackbitsAndZstd(testCase)
            % The real-world case: mostly-empty planes stored as PackBits,
            % the rest as Zstandard, in one BigTIFF.
            ref = uint16(randi([0, 4095], 12, 10, 1, 4));
            ref(:, :, 1, [1, 3]) = 0;
            f = testCase.tmpFile('mixed.tif');
            writeTestZstdTiff(f, ref, 'BigTiff', true, 'RowsPerStrip', 5, ...
                'Compression', [32773, 50000, 32773, 50000]);

            testCase.verifyTrue(isZstdTiff(f));
            [data, meta] = loadFiles(f);
            testCase.verifyEqual(data, reshape(ref, 12, 10, 4));
            map = containers.Map(meta.instrument.TiffTags(:, 1), meta.instrument.TiffTags(:, 2));
            testCase.verifyEqual(map('Compression'), ...
                'mixed: PackBits (32773) on 2 page(s), Zstandard (50000) on 2 page(s)');
        end

        function zstdOnALaterPageStillRoutes(testCase)
            % Page 1 is PackBits, which MATLAB could read on its own -- but
            % the file as a whole still has to come here.
            ref = uint16(randi([0, 255], 6, 6, 1, 3));
            f = testCase.tmpFile('late_zstd.tif');
            writeTestZstdTiff(f, ref, 'Compression', [32773, 32773, 50000]);

            testCase.verifyTrue(isZstdTiff(f));
            testCase.verifyEqual(loadFiles(f), reshape(ref, 6, 6, 3));
        end

        function packbitsOnlyStaysWithMatlab(testCase)
            % No Zstandard anywhere: MATLAB reads it, so do not route here.
            ref = uint16(randi([0, 255], 5, 5, 1, 2));
            f = testCase.tmpFile('packbits_only.tif');
            writeTestZstdTiff(f, ref, 'Compression', 32773);

            testCase.verifyFalse(isZstdTiff(f));
            testCase.verifyEqual(loadZstdTiff(f), reshape(ref, 5, 5, 2));
        end

    end
end
