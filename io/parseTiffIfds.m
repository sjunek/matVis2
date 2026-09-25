function [ifds, hdr] = parseTiffIfds(filepath, maxIfds, wantedTags)
% parseTiffIfds  Read the raw IFD (tag directory) chain of a TIFF/BigTIFF.
%   [ifds, hdr] = parseTiffIfds(filepath)
%   [ifds, hdr] = parseTiffIfds(filepath, maxIfds)  stops after maxIfds
%       directories (use 1 for a cheap "what is in the first page?" probe).
%   [ifds, hdr] = parseTiffIfds(filepath, maxIfds, wantedTags)  keeps only
%       those tag ids; the rest are skipped without reading their values,
%       which is what makes a whole-chain probe cheap on a long stack.
%
%   This is a plain tag reader -- it never touches pixel data -- so it works
%   on files MATLAB's own TIFF library refuses to open (e.g. an unsupported
%   compression scheme). loadZstdTiff/isZstdTiff build on it.
%
%   hdr  struct with fields
%       isBigTiff    true for the BigTIFF variant (version 43, 64-bit offsets)
%       littleEndian true for 'II' files
%       byteOrder    'II' or 'MM'
%   ifds 1xN struct array, one entry per directory, with fields
%       tag    1xM double, the tag ids in file order
%       type   1xM double, the TIFF field types (1..18)
%       count  1xM double, the element counts
%       value  1xM cell, the decoded values: a char row for ASCII, a double
%              row vector otherwise. RATIONAL/SRATIONAL values are returned
%              already divided out (numerator/denominator), NaN for a zero
%              denominator. Unrecognized field types decode to [].
%
%   Use tiffTagValue(ifds(k), tagId, default) to look a tag up by id.
%
%   See also tiffTagValue, isZstdTiff, loadZstdTiff.

if nargin < 2 || isempty(maxIfds)
    maxIfds = Inf;
end
if nargin < 3
    wantedTags = [];
end
filterTags = ~isempty(wantedTags);

% Byte order comes from the first two bytes, so open once to read it and
% reopen with the matching machine format (fread has no per-call override).
fid = fopen(filepath, 'r', 'ieee-le');
if fid < 0
    error('parseTiffIfds:cannotOpen', 'Cannot open file "%s".', filepath);
end
bom = fread(fid, 2, '*char')';
fclose(fid);

switch bom
    case 'II'
        machine = 'ieee-le';
    case 'MM'
        machine = 'ieee-be';
    otherwise
        error('parseTiffIfds:notTiff', ...
            'File "%s" is not a TIFF: byte-order mark is "%s", expected "II" or "MM".', ...
            filepath, bom);
end

fid = fopen(filepath, 'r', machine);
if fid < 0
    error('parseTiffIfds:cannotOpen', 'Cannot open file "%s".', filepath);
end
closer = onCleanup(@() fclose(fid)); %#ok<NASGU>

fseek(fid, 2, 'bof');
version = fread(fid, 1, 'uint16');
switch version
    case 42
        isBig = false;
        firstOffset = fread(fid, 1, 'uint32');
    case 43
        isBig = true;
        offsetSize = fread(fid, 1, 'uint16');
        padding    = fread(fid, 1, 'uint16');
        if offsetSize ~= 8 || padding ~= 0
            error('parseTiffIfds:unsupportedBigTiff', ...
                'BigTIFF "%s" declares a %d-byte offset size; only 8 is supported.', ...
                filepath, offsetSize);
        end
        firstOffset = fread(fid, 1, 'uint64');
    otherwise
        error('parseTiffIfds:notTiff', ...
            'File "%s" has TIFF version %d; expected 42 (TIFF) or 43 (BigTIFF).', ...
            filepath, version);
end

hdr = struct('isBigTiff', isBig, 'littleEndian', strcmp(machine, 'ieee-le'), ...
    'byteOrder', bom);

if isBig
    valueBytes = 8;
else
    valueBytes = 4;
end

ifds = struct('tag', {}, 'type', {}, 'count', {}, 'value', {});
offset = firstOffset;
seen = [];
while offset > 0 && numel(ifds) < maxIfds
    if any(seen == offset)
        warning('parseTiffIfds:ifdLoop', ...
            'IFD chain in "%s" loops back to offset %d; stopping after %d directories.', ...
            filepath, offset, numel(ifds));
        break;
    end
    seen(end+1) = offset; %#ok<AGROW>

    if fseek(fid, offset, 'bof') ~= 0
        error('parseTiffIfds:badIfdOffset', ...
            'IFD offset %d is past the end of "%s".', offset, filepath);
    end
    if isBig
        nEntries = fread(fid, 1, 'uint64');
    else
        nEntries = fread(fid, 1, 'uint16');
    end
    if isempty(nEntries) || nEntries <= 0
        break;
    end

    tag   = zeros(1, nEntries);
    type  = zeros(1, nEntries);
    count = zeros(1, nEntries);
    value = cell(1, nEntries);
    keep  = true(1, nEntries);
    for k = 1:nEntries
        tag(k)  = fread(fid, 1, 'uint16');
        type(k) = fread(fid, 1, 'uint16');
        if isBig
            count(k) = fread(fid, 1, 'uint64');
        else
            count(k) = fread(fid, 1, 'uint32');
        end

        if filterTags && ~any(wantedTags == tag(k))
            keep(k) = false;
            fseek(fid, valueBytes, 'cof');
            continue;
        end

        elemSize = tiffTypeSize(type(k));
        total    = elemSize * count(k);
        valuePos = ftell(fid);
        if total <= valueBytes
            value{k} = readTiffValues(fid, type(k), count(k));
            fseek(fid, valuePos + valueBytes, 'bof');
        else
            if isBig
                dataOffset = fread(fid, 1, 'uint64');
            else
                dataOffset = fread(fid, 1, 'uint32');
            end
            resume = ftell(fid);
            fseek(fid, dataOffset, 'bof');
            value{k} = readTiffValues(fid, type(k), count(k));
            fseek(fid, resume, 'bof');
        end
    end

    ifds(end+1) = struct('tag', tag(keep), 'type', type(keep), ...
        'count', count(keep), 'value', {value(keep)}); %#ok<AGROW>

    if isBig
        offset = fread(fid, 1, 'uint64');
    else
        offset = fread(fid, 1, 'uint32');
    end
    if isempty(offset)
        break;
    end
end
end

% =============================================================================
function n = tiffTypeSize(type)
% Bytes per element for TIFF field types 1..18. Unknown types count as one
% byte each, which keeps the "is the value inline?" test conservative.
sizes = [1 1 2 4 8 1 1 2 4 8 4 8 4 0 0 8 8 8];
if type >= 1 && type <= numel(sizes) && sizes(type) > 0
    n = sizes(type);
else
    n = 1;
end
end

% =============================================================================
function v = readTiffValues(fid, type, count)
% Read count elements of the given TIFF field type at the current position.
% fread applies the file's byte order, so no manual swapping is needed here.
switch type
    case 1                                  % BYTE
        v = double(fread(fid, count, '*uint8'))';
    case 2                                  % ASCII
        raw = fread(fid, count, '*uint8')';
        v = char(raw(raw ~= 0));
    case 3                                  % SHORT
        v = double(fread(fid, count, '*uint16'))';
    case {4, 13}                            % LONG, IFD
        v = double(fread(fid, count, '*uint32'))';
    case 5                                  % RATIONAL
        v = ratioOf(double(fread(fid, 2 * count, '*uint32')));
    case 6                                  % SBYTE
        v = double(fread(fid, count, '*int8'))';
    case 7                                  % UNDEFINED
        v = double(fread(fid, count, '*uint8'))';
    case 8                                  % SSHORT
        v = double(fread(fid, count, '*int16'))';
    case 9                                  % SLONG
        v = double(fread(fid, count, '*int32'))';
    case 10                                 % SRATIONAL
        v = ratioOf(double(fread(fid, 2 * count, '*int32')));
    case 11                                 % FLOAT
        v = double(fread(fid, count, '*single'))';
    case 12                                 % DOUBLE
        v = double(fread(fid, count, '*double'))';
    case {16, 18}                           % LONG8, IFD8
        v = double(fread(fid, count, '*uint64'))';
    case 17                                 % SLONG8
        v = double(fread(fid, count, '*int64'))';
    otherwise
        v = [];
end
end

% =============================================================================
function v = ratioOf(pairs)
% Turn an interleaved [num den num den ...] vector into num/den, with NaN
% where the denominator is zero.
num = pairs(1:2:end)';
den = pairs(2:2:end)';
v = num ./ den;
v(den == 0) = NaN;
end
