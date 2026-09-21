function raw = tiffDecompressSegment(comp, outLen, compression)
% tiffDecompressSegment  Decode one TIFF strip/tile to a uint8 column vector.
%   raw = tiffDecompressSegment(comp, outLen, compression)
%     comp         uint8 vector holding the segment exactly as stored
%     outLen       expected decoded size in bytes, from the strip/tile
%                  geometry -- required, because none of the codecs below
%                  can be trusted to carry it (see zstdDecompress)
%     compression  the value of TIFF tag 259 for the page the segment
%                  belongs to. Compression is a per-directory tag, so one
%                  file may mix schemes -- writers that fall back to a
%                  cheaper codec for pages a fast codec cannot help with do
%                  exactly that.
%
%   Supported: 1/32771 (uncompressed), 5 (LZW), 8/32946 (Deflate),
%   32773 (PackBits) and 50000 (Zstandard). Everything but "uncompressed"
%   decodes in Java, with the codecs bundled in bioformats_package.jar, so
%   ensureBioFormats() must succeed.
%
%   See also zstdDecompress, loadZstdTiff, tiffCompressionName.

if ~isa(comp, 'uint8')
    comp = uint8(comp);
end
outLen = double(outLen);
if outLen <= 0
    raw = zeros(0, 1, 'uint8');
    return;
end

switch compression
    case {1, 32771}                         % uncompressed (32771 = 2-byte aligned)
        raw = comp(:);
        if numel(raw) < outLen
            error('tiffDecompressSegment:truncated', ...
                'Uncompressed segment holds %d bytes, expected %d.', numel(raw), outLen);
        end
        raw = raw(1:outLen);
        return;
    case 50000                              % Zstandard
        raw = zstdDecompress(comp, outLen);
        return;
    case 5
        codec = javaCodec('LZWCodec', compression);
    case {8, 32946}
        codec = javaCodec('ZlibCodec', compression);
    case 32773
        codec = javaCodec('PackbitsCodec', compression);
    otherwise
        error('tiffDecompressSegment:unsupportedCompression', ...
            'TIFF compression %s is not supported.', tiffCompressionName(compression));
end

options = loci.formats.codec.CodecOptions();
options.maxBytes = int32(outLen);
try
    out = codec.decompress(typecast(comp(:), 'int8'), options);
catch e
    error('tiffDecompressSegment:decodeFailed', ...
        'Decoding a %s segment failed: %s', tiffCompressionName(compression), e.message);
end

raw = typecast(out(:), 'uint8');
if numel(raw) < outLen
    error('tiffDecompressSegment:sizeMismatch', ...
        '%s segment decoded to %d bytes, expected %d.', ...
        tiffCompressionName(compression), numel(raw), outLen);
end
raw = raw(1:outLen);   % codecs may round up to a whole run/code word
end

% =============================================================================
function codec = javaCodec(className, compression)
% Resolve (once per session) one of the Bio-Formats codec objects. They are
% stateless, so a single instance can serve every segment.
persistent cache
if isempty(cache)
    cache = struct();
end
if isfield(cache, className)
    codec = cache.(className);
    return;
end

if ~ensureBioFormats()
    error('tiffDecompressSegment:noEngine', ...
        ['Reading %s-compressed data needs the Java codecs bundled with ' ...
         'Bio-Formats, which is not set up. Place bioformats_package.jar in ' ...
         'io/bfmatlab (see ensureBioFormats).'], tiffCompressionName(compression));
end

try
    codec = feval(['loci.formats.codec.', className]);
catch e
    error('tiffDecompressSegment:noEngine', ...
        ['Bio-Formats is set up but its %s decoder ' ...
         '(loci.formats.codec.%s) could not be loaded: %s'], ...
        tiffCompressionName(compression), className, e.message);
end
cache.(className) = codec;
end
