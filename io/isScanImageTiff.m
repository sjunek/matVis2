function tf = isScanImageTiff(filepathOrInfo)
% isScanImageTiff  Cheap heuristic: does this Tiff look like it was written
%   by ScanImage? Checks the first IFD's Software/ImageDescription tags for
%   a ScanImage signature ('SI.' key-value lines, or the per-frame
%   'frameNumbers' field). Works without ScanImageTiffReader installed, so
%   loadFiles.m can decide whether the "reader not set up" warning is even
%   relevant to a given file.
%
%   tf = isScanImageTiff(filepath)   -- calls imfinfo internally
%   tf = isScanImageTiff(info)       -- reuses an already-fetched imfinfo struct

if ischar(filepathOrInfo) || (isstring(filepathOrInfo) && isscalar(filepathOrInfo))
    info = imfinfo(char(filepathOrInfo));
else
    info = filepathOrInfo;
end

tf = false;
if isempty(info)
    return;
end

sig = '';
if isfield(info, 'Software') && ~isempty(info(1).Software)
    sig = [sig, ' ', info(1).Software];
end
if isfield(info, 'ImageDescription') && ~isempty(info(1).ImageDescription)
    sig = [sig, ' ', info(1).ImageDescription];
end

tf = ~isempty(regexp(sig, 'SI\.', 'once')) || ~isempty(regexp(sig, 'frameNumbers', 'once'));
end
