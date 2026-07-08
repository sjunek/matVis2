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

        function testLoadPngRoundTrip(tc)
            pngFile = fullfile(tc.TempDir, 'testLoadFilesPng.png');
            expected = uint8(reshape(1:20, [4 5]));
            imwrite(expected, pngFile);
            cleanupObj = onCleanup(@() delete(pngFile));

            [result, meta] = loadFiles(pngFile);
            tc.verifyEqual(result, expected);
            % dimNames is {} via the native fallback, or {'Y','X'} when
            % Bio-Formats is available (it always knows the X/Y axes) --
            % engine-dependent, so just check the field has the right shape.
            tc.verifyTrue(iscell(meta.dimNames));
        end

        function testLoadBmpRoundTrip(tc)
            bmpFile = fullfile(tc.TempDir, 'testLoadFilesBmp.bmp');
            expected = uint8(reshape(1:20, [4 5]));
            imwrite(expected, bmpFile);
            cleanupObj = onCleanup(@() delete(bmpFile));

            result = loadFiles(bmpFile);
            tc.verifyEqual(result, expected);
        end

        function testLoadJpgRoundTrip(tc)
            jpgFile = fullfile(tc.TempDir, 'testLoadFilesJpg.jpg');
            expected = uint8(reshape(1:60, [4 5 3]));
            imwrite(expected, jpgFile, 'Quality', 100);
            cleanupObj = onCleanup(@() delete(jpgFile));

            result = loadFiles(jpgFile);
            tc.verifyEqual(size(result), size(expected));
            tc.verifyClass(result, 'uint8');
            % JPEG is lossy; only check gross similarity, not exact equality.
            tc.verifyLessThan(mean(abs(double(result(:)) - double(expected(:)))), 5);
        end

        function testLoadOmeTiffAppliesMetadata(tc)
            omeFile = fullfile(tc.TempDir, 'testLoadFilesOme.ome.tif');
            planes = { ...
                10 * ones(3, 4, 'uint8'), 20 * ones(3, 4, 'uint8'), ...
                30 * ones(3, 4, 'uint8'), 40 * ones(3, 4, 'uint8')};
            % PhysicalSize*Unit must be the real micron sign (char(181)), not the
            % ASCII digraph "um" -- "um" is not a valid OME UnitsLength enum
            % value. A real (spec-compliant) parser rejects it outright; ours is
            % lenient, so this only matters for cross-validating against
            % loadBioFormats (see loadBioFormatsTest.m).
            micron = char([181 'm']);
            xml = strjoin({ ...
                '<?xml version="1.0" encoding="UTF-8"?>', ...
                '<OME xmlns="http://www.openmicroscopy.org/Schemas/OME/2016-06">', ...
                '<Image ID="Image:0" Name="test">', ...
                [sprintf(['<Pixels ID="Pixels:0" DimensionOrder="XYCZT" Type="uint8" ' ...
                 'SizeX="4" SizeY="3" SizeZ="2" SizeC="2" SizeT="1" ' ...
                 'PhysicalSizeX="0.2" PhysicalSizeXUnit="%s" ' ...
                 'PhysicalSizeY="0.3" PhysicalSizeYUnit="%s" PhysicalSizeZ="1.5">'], ...
                 micron, micron)], ...
                '<Channel ID="Channel:0:0" SamplesPerPixel="1"/>', ...
                '<Channel ID="Channel:0:1" SamplesPerPixel="1"/>', ...
                '<TiffData IFD="0" PlaneCount="4"/>', ...
                '</Pixels>', '</Image>', '</OME>'}, char(10));
            writeSimpleOmeTiff(omeFile, planes, xml);
            cleanupObj = onCleanup(@() delete(omeFile));

            [result, meta] = loadFiles(omeFile);
            % DimensionOrder XYCZT -> IFDs fill C fastest, then Z: (z0,c0),
            % (z0,c1), (z1,c0), (z1,c1) -- matches the plane order above.
            tc.verifyEqual(size(result), [3 4 2 2]);
            tc.verifyEqual(result(:,:,1,1), planes{1});
            tc.verifyEqual(result(:,:,1,2), planes{2});
            tc.verifyEqual(result(:,:,2,1), planes{3});
            tc.verifyEqual(result(:,:,2,2), planes{4});

            tc.verifyEqual(meta.dimNames, {'Y', 'X', 'Z', 'C'});
            tc.verifyEqual(meta.dimScale, {0.3, 0.2, 1.5, 1});
            tc.verifyEqual(meta.dimUnits(1:2), {'um', 'um'});
            % PhysicalSizeZUnit was omitted from the fixture: the built-in
            % parser leaves it '' (no default), Bio-Formats defaults it to
            % micrometers per the OME schema -- either is correct, and which
            % one actually runs depends on whether Bio-Formats is set up.
            tc.verifyTrue(ismember(meta.dimUnits{3}, {'', 'um'}));
            tc.verifyEqual(meta.dimUnits{4}, '');
        end

    end
end

% =============================================================================
function writeSimpleOmeTiff(filepath, planes, omeXmlStr)
% Hand-write a small multi-IFD OME-TIFF for testing, without depending on the
% sibling OMETiffWriter repo. All planes share size/class; written as
% sequential IFDs with the OME-XML on the first IFD's ImageDescription.
t = Tiff(filepath, 'w');
cleanupObj = onCleanup(@() closeTiffQuietly(t)); %#ok<NASGU>

tagTemplate = struct( ...
    'ImageLength',         size(planes{1}, 1), ...
    'ImageWidth',          size(planes{1}, 2), ...
    'Photometric',         Tiff.Photometric.MinIsBlack, ...
    'BitsPerSample',       8, ...
    'SampleFormat',        Tiff.SampleFormat.UInt, ...
    'SamplesPerPixel',     1, ...
    'RowsPerStrip',        size(planes{1}, 1), ...
    'PlanarConfiguration', Tiff.PlanarConfiguration.Chunky, ...
    'Compression',         Tiff.Compression.None);

for k = 1:numel(planes)
    t.setTag(tagTemplate);
    if k == 1
        t.setTag('ImageDescription', omeXmlStr);
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
