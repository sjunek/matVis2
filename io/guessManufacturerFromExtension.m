function m = guessManufacturerFromExtension(filepathOrExt)
% guessManufacturerFromExtension  Best-effort instrument-manufacturer guess
%   from a proprietary microscopy file format.
%
%   m = guessManufacturerFromExtension(filepathOrExt)
%
%   Several formats are one vendor's own proprietary container (e.g. .czi is
%   Zeiss's), so the file extension itself implies who made the instrument
%   even when the file's own metadata never states a manufacturer string (as
%   Zeiss's CZI metadata doesn't -- verified against a real .czi, where
%   <Objective><Manufacturer> has no text, only a nested <Model> child).
%
%   This is an INFERENCE, not a read of recorded data -- it can be wrong
%   (e.g. a third-party objective fitted to a Zeiss stand). Use only as a
%   fallback for a manufacturer field the file itself leaves blank, never to
%   override an actual value.
%
%   filepathOrExt may be a full path/filename or a bare extension (with or
%   without the leading '.'). Returns '' for any extension not confidently
%   tied to a single vendor (e.g. .tif, which any vendor can write).

[~, ~, ext] = fileparts(filepathOrExt);
if isempty(ext)
    ext = filepathOrExt; % caller passed a bare extension, e.g. 'czi' or '.czi'
end
ext = lower(ext);
if ~isempty(ext) && ext(1) ~= '.'
    ext = ['.', ext];
end

switch ext
    case {'.czi', '.lsm', '.zvi'}
        m = 'Zeiss';
    case '.nd2'
        m = 'Nikon';
    case {'.lif', '.lof', '.xlef'}
        m = 'Leica';
    case {'.oib', '.oif'}
        m = 'Olympus';
    otherwise
        m = '';
end
end
