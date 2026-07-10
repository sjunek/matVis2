classdef guessManufacturerFromExtensionTest < matlab.unittest.TestCase

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

        function testKnownVendorExtensionsFromFullPath(tc)
            tc.verifyEqual(guessManufacturerFromExtension('C:\data\sample.czi'), 'Zeiss');
            tc.verifyEqual(guessManufacturerFromExtension('sample.lsm'), 'Zeiss');
            tc.verifyEqual(guessManufacturerFromExtension('sample.zvi'), 'Zeiss');
            tc.verifyEqual(guessManufacturerFromExtension('sample.nd2'), 'Nikon');
            tc.verifyEqual(guessManufacturerFromExtension('sample.lif'), 'Leica');
            tc.verifyEqual(guessManufacturerFromExtension('sample.oib'), 'Olympus');
            tc.verifyEqual(guessManufacturerFromExtension('sample.oif'), 'Olympus');
        end

        function testBareExtensionWithOrWithoutDot(tc)
            tc.verifyEqual(guessManufacturerFromExtension('czi'), 'Zeiss');
            tc.verifyEqual(guessManufacturerFromExtension('.czi'), 'Zeiss');
        end

        function testCaseInsensitive(tc)
            tc.verifyEqual(guessManufacturerFromExtension('sample.CZI'), 'Zeiss');
        end

        function testUnknownOrGenericExtensionReturnsEmpty(tc)
            tc.verifyEqual(guessManufacturerFromExtension('sample.tif'), '');
            tc.verifyEqual(guessManufacturerFromExtension('sample.ome.tif'), '');
            tc.verifyEqual(guessManufacturerFromExtension('sample'), '');
        end

    end
end
