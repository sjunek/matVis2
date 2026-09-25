function v = tiffScalarTag(ifd, tagId, defaultValue, name, filepath)
% tiffScalarTag  One scalar tag value, with a readable error when it is
%   missing and no default was given.
%
%   v = tiffScalarTag(ifd, tagId, defaultValue, name, filepath)
%
%   Shared by the Zstandard TIFF reader's two halves -- zstdTiffOpen reads
%   geometry with it, zstdTiffReadPage checks each page against that geometry
%   -- so the two cannot disagree about what a tag means.
%
%   See also tiffTagValue, parseTiffIfds, zstdTiffOpen, zstdTiffReadPage.

v = tiffTagValue(ifd, tagId, defaultValue);
if isempty(v)
    error('loadZstdTiff:missingTag', ...
        'Required TIFF tag %s (%d) is missing from "%s".', name, tagId, filepath);
end
v = v(1);
end

% =============================================================================
