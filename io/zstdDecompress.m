function raw = zstdDecompress(comp, outLen)
% zstdDecompress  Decompress one Zstandard frame to a uint8 column vector.
%   raw = zstdDecompress(comp, outLen)
%     comp    uint8 vector holding a complete Zstandard frame
%     outLen  expected decompressed size in bytes -- required, because TIFF
%             writers routinely omit the frame's optional content-size field
%             (that omission is exactly what makes Bio-Formats 8.5's
%             ome-codecs ZstdCodec throw NegativeArraySizeException on such
%             files). TIFF gives us the size from the strip/tile geometry
%             instead, so nothing has to be guessed.
%
%   Decompression runs in Java, via the pure-Java Zstandard implementation
%   (io.airlift.compress, "aircompressor") bundled inside
%   bioformats_package.jar -- MATLAB has no built-in Zstandard codec, so
%   ensureBioFormats() must succeed.
%
%   See also loadZstdTiff, ensureBioFormats.

if ~isa(comp, 'uint8')
    comp = uint8(comp);
end
outLen = double(outLen);
if outLen <= 0
    raw = zeros(0, 1, 'uint8');
    return;
end

decompressor = zstdDecompressor();

% Java arrays passed from MATLAB are copied, so a byte[] filled in on the
% Java side would never come back. ByteBuffers are Java objects that survive
% the call, so the output buffer can be read afterwards via array().
inBuf  = java.nio.ByteBuffer.wrap(typecast(comp(:), 'int8'));
outBuf = java.nio.ByteBuffer.allocate(outLen);
decompressor.decompress(inBuf, outBuf);

written = outBuf.position();
if written ~= outLen
    error('zstdDecompress:sizeMismatch', ...
        'Zstandard frame decompressed to %d bytes, expected %d.', written, outLen);
end
raw = typecast(outBuf.array(), 'uint8');
end

% =============================================================================
function decompressor = zstdDecompressor()
% Resolve the Java decompressor once per MATLAB session (the class lookup
% and ensureBioFormats are not free, and the object is stateless/reusable).
persistent cached
if ~isempty(cached)
    decompressor = cached;
    return;
end

if ~ensureBioFormats()
    error('zstdDecompress:noEngine', ...
        ['Reading Zstandard-compressed data needs the Java Zstandard decoder ' ...
         'bundled with Bio-Formats, which is not set up. Place ' ...
         'bioformats_package.jar in io/bfmatlab (see ensureBioFormats).']);
end

try
    decompressor = io.airlift.compress.zstd.ZstdDecompressor();
catch e
    error('zstdDecompress:noEngine', ...
        ['Bio-Formats is set up but its bundled Zstandard decoder ' ...
         '(io.airlift.compress.zstd.ZstdDecompressor) could not be loaded: %s'], ...
        e.message);
end
cached = decompressor;
end
