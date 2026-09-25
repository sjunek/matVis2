function tf = isZstdTiff(filepath)
% isZstdTiff  True for a TIFF that uses Zstandard (tag 259 == 50000) on at
%   least one of its directories. Cheap: reads only the Compression tag of
%   every IFD, never any pixel data.
%
%   Compression is a per-directory tag, and writers do mix schemes within
%   one file -- the stacks that prompted this reader store mostly-empty
%   planes as PackBits and the rest as Zstandard -- so the whole chain has
%   to be checked, not just page 1. Any page of Zstandard is enough to send
%   the file to loadZstdTiff, which handles the other schemes too.
%
%   Anything that isn't a readable TIFF returns false, so callers can use
%   this as a routing probe without wrapping it in try/catch.
%
%   See also loadZstdTiff, parseTiffIfds.

tf = false;
try
    ifds = parseTiffIfds(filepath, Inf, 259);
catch
    return;
end

for k = 1:numel(ifds)
    compression = tiffTagValue(ifds(k), 259, 1);
    if ~isempty(compression) && compression(1) == 50000
        tf = true;
        return;
    end
end
end
