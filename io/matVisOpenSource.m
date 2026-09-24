function [src, meta] = matVisOpenSource(filepath)
%matVisOpenSource  Open a file as a lazy, plane-on-demand data source.
%
%   [src, meta] = matVisOpenSource(filepath)
%
%   Returns a MatVisDataSource that reads planes from the file as they are
%   displayed, together with the dimension metadata the full-load path would
%   have produced.  Returns src = [] when the file cannot be served lazily --
%   the caller then loads it in full, as before.
%
%   Opening is cheap because no pixels are read beyond one probe plane: 0.3 s
%   for a stitched .czi, ~2.3 s for a 5.9 GB time series, against 40 s to
%   read that same series in full.
%
%   Not served lazily (each falls back to a full load):
%     - Zstandard-compressed TIFFs.  Neither MATLAB's TIFF library nor
%       Bio-Formats can decode one; io/loadZstdTiff does, but only whole-file
%       at present, so there is no per-plane path to call.
%     - .mat files, and anything Bio-Formats cannot open.
%     - Files whose planes are interleaved RGB.
%
%   See also MatVisBioFormatsSource, loadFiles, matVisLoadPolicy.

src  = [];
meta = [];

if nargin < 1 || isempty(filepath) || ~isfile(filepath)
    return;
end

[~, ~, ext] = fileparts(lower(filepath));

if strcmp(ext, '.mat')
    return;
end

% ScanImage TIFFs and Zstandard TIFFs have their own readers, neither of
% which exposes a single page; route them to the full loader untouched.
if ismember(ext, {'.tif', '.tiff'})
    try
        if isZstdTiff(filepath) || isScanImageTiff(filepath)
            return;
        end
    catch
        return;
    end
end

if ~ensureBioFormats()
    return;
end

try
    src  = MatVisBioFormatsSource(filepath);
    meta = src.Meta;
catch e
    % A lazy open that fails is not an error: the caller still has the full
    % loader, which may well cope (a format Bio-Formats mis-detects, say).
    warning('matVisOpenSource:lazyOpenFailed', ...
        'Could not open "%s" for on-demand reading (%s); it will be loaded in full.', ...
        filepath, e.message);
    src  = [];
    meta = [];
end
end
