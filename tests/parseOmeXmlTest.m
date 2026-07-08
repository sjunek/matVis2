classdef parseOmeXmlTest < matlab.unittest.TestCase

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

        function testBasicAttributes(tc)
            xml = omeXml('XYCZT', struct( ...
                'SizeX', 64, 'SizeY', 32, 'SizeZ', 5, 'SizeC', 2, 'SizeT', 10, ...
                'Type', 'uint16', ...
                'PhysicalSizeX', 0.16, 'PhysicalSizeXUnit', 'um', ...
                'PhysicalSizeY', 0.16, 'PhysicalSizeYUnit', 'um', ...
                'PhysicalSizeZ', 0.5,  'PhysicalSizeZUnit', 'um', ...
                'TimeIncrement', 2.0,  'TimeIncrementUnit', 's'), ...
                {'GFP', 'RFP'}, {});

            meta = parseOmeXml(xml);
            tc.verifyTrue(meta.isOme);
            tc.verifyEqual(meta.SizeX, 64);
            tc.verifyEqual(meta.SizeY, 32);
            tc.verifyEqual(meta.SizeZ, 5);
            tc.verifyEqual(meta.SizeC, 2);
            tc.verifyEqual(meta.SizeT, 10);
            tc.verifyEqual(meta.DimensionOrder, 'XYCZT');
            tc.verifyEqual(meta.PixelType, 'uint16');
            tc.verifyEqual(meta.PhysicalSizeX, 0.16, 'AbsTol', 1e-12);
            tc.verifyEqual(meta.PhysicalSizeXUnit, 'um');
            tc.verifyEqual(meta.PhysicalSizeZ, 0.5, 'AbsTol', 1e-12);
            tc.verifyEqual(meta.TimeIncrement, 2.0, 'AbsTol', 1e-12);
            tc.verifyEqual(meta.TimeIncrementUnit, 's');
            tc.verifyEqual(meta.ChannelNames, {'GFP', 'RFP'});
            tc.verifyEmpty(meta.Planes);
            tc.verifyFalse(meta.hasMultipleSeries);
        end

        function testLowercaseDimensionOrderIsUppercased(tc)
            xml = omeXml('xyzct', struct( ...
                'SizeX', 4, 'SizeY', 4, 'SizeZ', 1, 'SizeC', 1, 'SizeT', 1), {}, {});
            meta = parseOmeXml(xml);
            tc.verifyEqual(meta.DimensionOrder, 'XYZCT');
        end

        function testMissingPhysicalSizeYieldsNaN(tc)
            xml = omeXml('XYCZT', struct( ...
                'SizeX', 4, 'SizeY', 4, 'SizeZ', 1, 'SizeC', 1, 'SizeT', 1), {}, {});
            meta = parseOmeXml(xml);
            tc.verifyTrue(isnan(meta.PhysicalSizeX));
            tc.verifyTrue(isnan(meta.PhysicalSizeY));
            tc.verifyTrue(isnan(meta.PhysicalSizeZ));
            tc.verifyTrue(isnan(meta.TimeIncrement));
            tc.verifyEqual(meta.PhysicalSizeXUnit, '');
        end

        function testMicronSignNormalizedToUm(tc)
            micron = char([181 'm']);
            xml = omeXml('XYCZT', struct( ...
                'SizeX', 4, 'SizeY', 4, 'SizeZ', 1, 'SizeC', 1, 'SizeT', 1, ...
                'PhysicalSizeX', 0.2, 'PhysicalSizeXUnit', micron), {}, {});
            meta = parseOmeXml(xml);
            tc.verifyEqual(meta.PhysicalSizeXUnit, 'um');
        end

        function testExplicitTiffDataPlanes(tc)
            tdLines = { ...
                '<TiffData IFD="0" FirstZ="0" FirstC="0" FirstT="0" PlaneCount="1"/>', ...
                '<TiffData IFD="1" FirstZ="0" FirstC="1" FirstT="0" PlaneCount="1"/>', ...
                '<TiffData IFD="2" FirstZ="1" FirstC="0" FirstT="0" PlaneCount="1"/>'};
            xml = omeXml('XYCZT', struct( ...
                'SizeX', 4, 'SizeY', 4, 'SizeZ', 2, 'SizeC', 2, 'SizeT', 1), {}, tdLines);
            meta = parseOmeXml(xml);
            tc.verifyEqual(numel(meta.Planes), 3);
            tc.verifyEqual([meta.Planes.IFD], [0 1 2]);
            tc.verifyEqual([meta.Planes.Z], [0 0 1]);
            tc.verifyEqual([meta.Planes.C], [0 1 0]);
            tc.verifyEqual([meta.Planes.T], [0 0 0]);
        end

        function testMultipleSeriesDetected(tc)
            img1 = imageBlock('Image:0', struct( ...
                'SizeX', 4, 'SizeY', 4, 'SizeZ', 1, 'SizeC', 1, 'SizeT', 1), {}, {});
            img2 = imageBlock('Image:1', struct( ...
                'SizeX', 8, 'SizeY', 8, 'SizeZ', 1, 'SizeC', 1, 'SizeT', 1), {}, {});
            xml = wrapOme({img1, img2});
            meta = parseOmeXml(xml);
            tc.verifyTrue(meta.hasMultipleSeries);
            tc.verifyEqual(meta.SizeX, 4); % only the first series is parsed
        end

        function testNonOmeStringIsNotOme(tc)
            meta = parseOmeXml('just a plain ImageDescription, not XML at all');
            tc.verifyFalse(meta.isOme);
            tc.verifyEqual(meta.SizeX, 1);
            tc.verifyEqual(meta.DimensionOrder, 'XYCZT');
        end

        function testEmptyStringIsNotOme(tc)
            meta = parseOmeXml('');
            tc.verifyFalse(meta.isOme);
        end

    end
end

% =============================================================================
function xml = omeXml(dimOrder, pixelsAttrs, channelNames, tiffDataLines)
xml = wrapOme({imageBlock('Image:0', setfield(pixelsAttrs, 'DimensionOrder', dimOrder), ...
    channelNames, tiffDataLines)}); %#ok<SFLD>
end

% =============================================================================
function block = imageBlock(imageId, pixelsAttrs, channelNames, tiffDataLines)
if ~isfield(pixelsAttrs, 'DimensionOrder')
    pixelsAttrs.DimensionOrder = 'XYCZT';
end
fields = fieldnames(pixelsAttrs);
attrStrs = cell(1, numel(fields));
for i = 1:numel(fields)
    v = pixelsAttrs.(fields{i});
    if ischar(v)
        attrStrs{i} = sprintf('%s="%s"', fields{i}, v);
    else
        attrStrs{i} = sprintf('%s="%.10g"', fields{i}, v);
    end
end
pixelsTag = sprintf('<Pixels ID="Pixels:0" %s>', strjoin(attrStrs, ' '));

chLines = cell(1, numel(channelNames));
for i = 1:numel(channelNames)
    chLines{i} = sprintf('<Channel ID="Channel:0:%d" SamplesPerPixel="1" Name="%s"/>', ...
        i - 1, channelNames{i});
end

lines = [{sprintf('<Image ID="%s" Name="test">', imageId), pixelsTag}, ...
    chLines, tiffDataLines, {'</Pixels>', '</Image>'}];
block = strjoin(lines, char(10));
end

% =============================================================================
function xml = wrapOme(imageBlocks)
lines = [{'<?xml version="1.0" encoding="UTF-8"?>', ...
    ['<OME xmlns="http://www.openmicroscopy.org/Schemas/OME/2016-06">']}, ...
    imageBlocks, {'</OME>'}];
xml = strjoin(lines, char(10));
end
