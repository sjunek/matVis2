function [data, meta] = loadZstdTiff(filepath)
% loadZstdTiff  Read a Zstandard-compressed TIFF/BigTIFF (compression 50000).
%   [data, meta] = loadZstdTiff(filepath)
%
%   Neither MATLAB's TIFF library ("The compression scheme 50000 is not
%   currently supported when reading TIFF files.") nor Bio-Formats 8.5 can
%   read these files, so this is a self-contained reader: parseTiffIfds for
%   the tags, tiffDecompressSegment for the strip/tile payloads.
%
%   Compression is a per-directory tag, so a single file may mix schemes --
%   the stacks this was written for store mostly-empty planes as PackBits
%   and the rest as Zstandard. Every page is decoded with its own scheme;
%   see tiffDecompressSegment for the list of schemes understood.
%
%   data is [Y X] for a single-page grayscale image, [Y X Z] for a
%   multi-page one, and [Y X C] / [Y X C Z] when SamplesPerPixel > 1.
%
%   meta matches the contract the other readers use (see finalizeOmePlanes):
%   dimNames/dimScale/dimUnits/channelNames/instrument. A plain TIFF carries
%   no acquisition metadata, so instrument's Microscope*/Objective*/Channel*
%   fields are empty; every tag the file *does* carry is collected into
%   instrument.TiffTags (an Nx2 cell of Property/Value rows) for display in
%   MatVisMetadataWin. Scale comes from XResolution/YResolution: their
%   reciprocal when ResolutionUnit says inch or centimeter, and the values
%   themselves (micrometres per pixel) when ResolutionUnit is "none", which
%   is what the writers of these Zstandard stacks store there. In that case
%   two differing values mean tag 282 is the lateral pitch for both Y and X
%   and tag 283 is the Z step -- see resolutionScales below.
%
%   Supported: strips and tiles, 8/16/32/64-bit unsigned and signed integer
%   and 32/64-bit float samples, chunky and planar configuration, predictor
%   1 (none) and 2 (horizontal differencing, integer samples).
%
%   The tag reading and the per-page decode live in zstdTiffOpen and
%   zstdTiffReadPage, so a single plane can be decoded without the rest of
%   the file -- see MatVisZstdTiffSource, which reads one at a time.
%
%   See also zstdTiffOpen, zstdTiffReadPage, isZstdTiff, loadFiles.


S = zstdTiffOpen(filepath);

fid = fopen(filepath, 'r', 'ieee-le');
if fid < 0
    error('loadZstdTiff:cannotOpen', 'Cannot open file "%s".', filepath);
end
closer = onCleanup(@() fclose(fid));

g    = S.g;
data = zeros([g.height, g.width, g.spp, S.nPages], g.cls);
for k = 1:S.nPages
    data(:, :, :, k) = zstdTiffReadPage(fid, S.ifds(k), g, ...
        S.compressions(k), filepath, k);
end

% Collapse the axes the file does not actually use.
sz4  = [g.height, g.width, g.spp, S.nPages];
data = reshape(data, sz4(S.keep));
meta = S.meta;
end
