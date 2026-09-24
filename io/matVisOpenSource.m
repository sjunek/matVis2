function [src, meta, why] = matVisOpenSource(filepath)
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
why  = '';

if nargin < 1 || isempty(filepath) || ~isfile(filepath)
    why = 'the file does not exist';
    return;
end

[~, ~, ext] = fileparts(lower(filepath));

if strcmp(ext, '.mat')
    % Not an oversight: a plane read out of a typical `save -v7.3` file
    % measured 3.9 s, because the default chunk shape spans every dimension.
    % Reading such a file plane by plane is far worse than loading it whole.
    why = ['MAT-files are chunked across all dimensions, so reading one ' ...
           'plane at a time is slower than loading the whole array'];
    return;
end

% ScanImage TIFFs and Zstandard TIFFs have their own readers, neither of
% which exposes a single page; route them to the full loader untouched.
if ismember(ext, {'.tif', '.tiff'})
    try
        if isZstdTiff(filepath)
            why = 'no reader can decode a single page of a Zstandard TIFF';
            return;
        elseif isScanImageTiff(filepath)
            why = 'the ScanImage TIFF reader only returns the whole file';
            return;
        end
    catch
        why = 'the file could not be identified';
        return;
    end
end

if ~ensureBioFormats()
    why = 'Bio-Formats is not set up';
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
    why  = sprintf('Bio-Formats could not open it (%s)', e.message);
end
end
