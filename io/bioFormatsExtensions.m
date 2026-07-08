function extList = bioFormatsExtensions()
% bioFormatsExtensions  Lowercase list of every extension (no dot) Bio-Formats
%   can read, e.g. {'tif','tiff','czi','lsm','nd2','lif',...}. Cached for the
%   session, since enumerating every reader (bfGetFileExtensions) is not
%   free. Requires ensureBioFormats() to be true.
%
%   See also: ensureBioFormats, bfGetFileExtensions, buildFileFilter.

persistent cached
if isempty(cached)
    bfExt = bfGetFileExtensions();       % row 1 = {allPatterns, 'All formats'}
    toks = regexp(bfExt{1, 1}, '\*\.([^;]+)', 'tokens');
    cached = lower([toks{:}]);
end
extList = cached;
end
