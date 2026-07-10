classdef loadBioFormatsTest < matlab.unittest.TestCase
    % Cross-validates the Bio-Formats reader (loadBioFormats.m) against the
    % same hand-built OME-TIFF and expected values used by
    % loadFilesTest.testLoadOmeTiffAppliesMetadata (which exercises the
    % built-in regex-parser fallback). Skips gracefully if Bio-Formats isn't
    % set up on the machine running the tests.

    properties
        TempDir
        OrigPath
    end

    methods (TestClassSetup)
        function requireBioFormats(tc)
            repoRoot = fullfile(fileparts(mfilename('fullpath')), '..');
            addpath(fullfile(repoRoot, 'io'));
            tc.assumeTrue(ensureBioFormats(), 'Bio-Formats is not set up; skipping.');
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

        function testMatchesBuiltInReaderOnSameFile(tc)
            omeFile = fullfile(tc.TempDir, 'testLoadBioFormatsOme.ome.tif');
            planes = { ...
                10 * ones(3, 4, 'uint8'), 20 * ones(3, 4, 'uint8'), ...
                30 * ones(3, 4, 'uint8'), 40 * ones(3, 4, 'uint8')};
            % PhysicalSize*Unit must be the real micron sign (char(181)), not the
            % ASCII digraph "um" -- Bio-Formats' real OME-XML unmarshaller
            % rejects "um" as an invalid UnitsLength enum value and silently
            % falls back to treating every IFD as a flat T-stack, which is not
            % what we're testing here.
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

            [result, meta] = loadBioFormats(omeFile);

            % Same expectations as loadFilesTest.testLoadOmeTiffAppliesMetadata,
            % which reads this same layout via the built-in regex parser.
            tc.verifyEqual(size(result), [3 4 2 2]);
            tc.verifyEqual(result(:,:,1,1), planes{1});
            tc.verifyEqual(result(:,:,1,2), planes{2});
            tc.verifyEqual(result(:,:,2,1), planes{3});
            tc.verifyEqual(result(:,:,2,2), planes{4});

            tc.verifyEqual(meta.dimNames, {'Y', 'X', 'Z', 'C'});
            % PhysicalSizeZUnit was omitted from the fixture; Bio-Formats
            % defaults it to micrometers per the OME schema.
            tc.verifyEqual(meta.dimUnits, {'um', 'um', 'um', ''});
            expectedScale = [0.3, 0.2, 1.5, 1];
            for i = 1:numel(expectedScale)
                tc.verifyEqual(meta.dimScale{i}, expectedScale(i), 'AbsTol', 1e-9);
            end
        end

        function testExtractsInstrumentAndObjectiveMetadata(tc)
            omeFile = fullfile(tc.TempDir, 'testLoadBioFormatsInstrument.ome.tif');
            planes = {10 * ones(3, 4, 'uint8')};
            xml = strjoin({ ...
                '<?xml version="1.0" encoding="UTF-8"?>', ...
                '<OME xmlns="http://www.openmicroscopy.org/Schemas/OME/2016-06">', ...
                '<Instrument ID="Instrument:0">', ...
                '<Microscope Manufacturer="Zeiss" Model="LSM 900" Type="Inverted"/>', ...
                '<Objective ID="Objective:0" Manufacturer="Zeiss" Model="Plan-Apo 63x" ' ...
                    'NominalMagnification="63" LensNA="1.4" Immersion="Oil"/>', ...
                '</Instrument>', ...
                '<Image ID="Image:0" Name="test">', ...
                '<InstrumentRef ID="Instrument:0"/>', ...
                '<ObjectiveSettings ID="Objective:0" RefractiveIndex="1.518"/>', ...
                '<Pixels ID="Pixels:0" DimensionOrder="XYCZT" Type="uint8" ' ...
                    'SizeX="4" SizeY="3" SizeZ="1" SizeC="1" SizeT="1">', ...
                '<Channel ID="Channel:0:0" SamplesPerPixel="1"/>', ...
                '<TiffData IFD="0" PlaneCount="1"/>', ...
                '</Pixels>', '</Image>', '</OME>'}, char(10));
            writeSimpleOmeTiff(omeFile, planes, xml);
            cleanupObj = onCleanup(@() delete(omeFile));

            [~, meta] = loadBioFormats(omeFile);
            instr = meta.instrument;
            tc.verifyEqual(instr.MicroscopeManufacturer, 'Zeiss');
            tc.verifyEqual(instr.MicroscopeModel, 'LSM 900');
            tc.verifyEqual(instr.MicroscopeType, 'Inverted');
            tc.verifyEqual(instr.ObjectiveManufacturer, 'Zeiss');
            tc.verifyEqual(instr.ObjectiveModel, 'Plan-Apo 63x');
            tc.verifyEqual(instr.ObjectiveMagnification, 63, 'AbsTol', 1e-9);
            tc.verifyEqual(instr.ObjectiveNA, 1.4, 'AbsTol', 1e-9);
            tc.verifyEqual(instr.ObjectiveImmersion, 'Oil');
            tc.verifyEqual(instr.ObjectiveRefractiveIndex, 1.518, 'AbsTol', 1e-9);
        end

        function testManufacturerFallsBackToFormatWhenFileOmitsIt(tc)
            % Zeiss CZI metadata never states a manufacturer string at all
            % (verified against a real .czi), so loadBioFormats infers it
            % from the file extension when the metadata leaves it blank.
            % The fixture is content-wise an OME-TIFF (Bio-Formats detects
            % format by content, not extension) but saved with a .czi name,
            % so this exercises the extension-based fallback in isolation
            % without needing a real proprietary .czi file.
            omeFile = fullfile(tc.TempDir, 'testLoadBioFormatsCziGuess.czi');
            planes = {10 * ones(3, 4, 'uint8')};
            xml = strjoin({ ...
                '<?xml version="1.0" encoding="UTF-8"?>', ...
                '<OME xmlns="http://www.openmicroscopy.org/Schemas/OME/2016-06">', ...
                '<Instrument ID="Instrument:0">', ...
                '<Microscope Model="LSM 900"/>', ...
                '<Objective ID="Objective:0" Model="Plan-Apo 63x" NominalMagnification="63"/>', ...
                '</Instrument>', ...
                '<Image ID="Image:0" Name="test">', ...
                '<InstrumentRef ID="Instrument:0"/>', ...
                '<ObjectiveSettings ID="Objective:0"/>', ...
                '<Pixels ID="Pixels:0" DimensionOrder="XYCZT" Type="uint8" ' ...
                    'SizeX="4" SizeY="3" SizeZ="1" SizeC="1" SizeT="1">', ...
                '<Channel ID="Channel:0:0" SamplesPerPixel="1"/>', ...
                '<TiffData IFD="0" PlaneCount="1"/>', ...
                '</Pixels>', '</Image>', '</OME>'}, char(10));
            writeSimpleOmeTiff(omeFile, planes, xml);
            cleanupObj = onCleanup(@() delete(omeFile));

            [~, meta] = loadBioFormats(omeFile);
            tc.verifyEqual(meta.instrument.MicroscopeManufacturer, 'Zeiss');
            tc.verifyEqual(meta.instrument.ObjectiveManufacturer, 'Zeiss');
        end

        function testLoadFilesRoutesThroughBioFormats(tc)
            % With Bio-Formats set up, loadFiles's dispatch should prefer it
            % over the built-in reader -- verified indirectly via a plain
            % multi-page TIFF (no OME metadata), which both engines can read.
            tifFile = fullfile(tc.TempDir, 'testLoadBioFormatsMultiPage.tif');
            page1 = uint8(reshape(1:20, [4 5]));
            page2 = uint8(reshape(21:40, [4 5]));
            imwrite(page1, tifFile);
            imwrite(page2, tifFile, 'WriteMode', 'append');
            cleanupObj = onCleanup(@() delete(tifFile));

            result = loadFiles(tifFile);
            tc.verifyEqual(size(result), [4 5 2]);
            tc.verifyEqual(result(:,:,1), page1);
            tc.verifyEqual(result(:,:,2), page2);
        end

    end
end

% =============================================================================
function writeSimpleOmeTiff(filepath, planes, omeXmlStr)
% Hand-write a small multi-IFD OME-TIFF for testing (same helper as
% loadFilesTest.m's, duplicated here to keep each test file self-contained).
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
