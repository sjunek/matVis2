function s = tiffCompressionName(code)
% tiffCompressionName  Readable name for a TIFF Compression (tag 259) value.
%   s = tiffCompressionName(code) returns e.g. 'PackBits (32773)'. Unknown
%   codes come back as just the number in parentheses, so the result can
%   always be dropped into a message or a metadata row.
%
%   See also tiffDecompressSegment, loadZstdTiff.

switch code
    case 1,     s = 'uncompressed (1)';
    case 2,     s = 'CCITT modified Huffman (2)';
    case 3,     s = 'CCITT Group 3 fax (3)';
    case 4,     s = 'CCITT Group 4 fax (4)';
    case 5,     s = 'LZW (5)';
    case 6,     s = 'JPEG, old-style (6)';
    case 7,     s = 'JPEG (7)';
    case 8,     s = 'Deflate (8)';
    case 32771, s = 'uncompressed, word-aligned (32771)';
    case 32773, s = 'PackBits (32773)';
    case 32946, s = 'Deflate, old-style (32946)';
    case 34712, s = 'JPEG 2000 (34712)';
    case 34925, s = 'LZMA (34925)';
    case 50000, s = 'Zstandard (50000)';
    case 50001, s = 'WebP (50001)';
    case 50002, s = 'JPEG XL (50002)';
    otherwise,  s = sprintf('scheme %d', code);
end
end
