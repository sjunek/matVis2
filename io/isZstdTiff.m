function tf = isZstdTiff(filepath)
% isZstdTiff  True for a TIFF whose first directory uses Zstandard (tag 259
%   == 50000). Cheap: reads the header and one IFD, never any pixel data.
%
%   Anything that isn't a readable TIFF returns false, so callers can use
%   this as a routing probe without wrapping it in try/catch.
%
%   See also loadZstdTiff, parseTiffIfds.

tf = false;
try
    ifds = parseTiffIfds(filepath, 1);
catch
    return;
end
if isempty(ifds)
    return;
end
compression = tiffTagValue(ifds(1), 259, 1);
tf = ~isempty(compression) && compression(1) == 50000;
end
