function ok = ensureScanImageTiffReader()
% ensureScanImageTiffReader  True if the ScanImageTiffReader MATLAB package
%   (a MEX-based reader for ScanImage-acquired Tiff/BigTiff files) is
%   loadable. Adds io/scanImageTiffReader to the path (the *parent* of the
%   +ScanImageTiffReader package folder -- required for MATLAB's package
%   resolution) and checks whether the package actually works. If missing,
%   warns and -- on Windows, in an interactive session -- offers to download
%   and unzip the pre-built package (no automated Mac/Linux build exists
%   upstream; see io/scanImageTiffReader/README.md). The result is cached
%   for the rest of the MATLAB session, so this only prompts or hits the
%   filesystem/network once per session.
%
%   Callers should treat ok==false as "fall back to a generic TIFF reader".

persistent cachedOk

% Cheap, idempotent: re-assert siDir on the path even on a cache hit, since
% test suites and other code may snapshot/restore path() between calls
% (path() is global state, not owned by this function).
siDir = fullfile(fileparts(mfilename('fullpath')), 'scanImageTiffReader');
pkgFile = fullfile(siDir, '+ScanImageTiffReader', 'ScanImageTiffReader.m');
if isempty(which('ScanImageTiffReader.ScanImageTiffReader')) || ...
        ~strcmpi(which('ScanImageTiffReader.ScanImageTiffReader'), pkgFile)
    addpath(siDir);
end

if ~isempty(cachedOk)
    ok = cachedOk;
    return;
end

ok = isReaderLoadable();
if ok
    cachedOk = ok;
    return;
end

if ~ispc
    warning('ensureScanImageTiffReader:notSetUp', ...
        ['ScanImageTiffReader is not set up (no automated Mac/Linux build is published upstream). ' ...
         'ScanImage files fall back to a generic TIFF reader (framesPerSlice will not be split out ' ...
         'as its own dimension). See io/scanImageTiffReader/README.md to install it manually.']);
    ok = false;
    cachedOk = ok;
    return;
end

doDownload = false;
if usejava('desktop')
    choice = questdlg( ...
        ['ScanImageTiffReader is not installed. It is used to read ScanImage-acquired Tiff files ' ...
         'with the correct framesPerSlice/Z/T/channel breakdown. A generic TIFF reader still ' ...
         'handles these files without it, just without that breakdown. Download it now?'], ...
        'ScanImageTiffReader not found', 'Download', 'Not now', 'Not now');
    doDownload = strcmp(choice, 'Download');
end

if ~doDownload
    warning('ensureScanImageTiffReader:notSetUp', ...
        ['ScanImageTiffReader is not set up; ScanImage files fall back to a generic TIFF reader. ' ...
         'Call matVis2(...) again and choose "Download" to fetch it automatically, or see ' ...
         'io/scanImageTiffReader/README.md.']);
    ok = false;
    cachedOk = ok;
    return;
end

zipUrl = 'https://gitlab.com/api/v4/projects/8668010/jobs/artifacts/master/download?job=build_windows';
zipPath = [tempname(), '.zip'];
fprintf('[matVis2] Downloading ScanImageTiffReader from %s ...\n', zipUrl);
try
    websave(zipPath, zipUrl);
    unzip(zipPath, siDir);
catch e
    warning('ensureScanImageTiffReader:downloadFailed', ...
        'Could not download/unzip ScanImageTiffReader (%s); falling back to a generic TIFF reader.', ...
        e.message);
    ok = false;
    cachedOk = ok;
    return;
end
try, delete(zipPath); catch, end

rehash path %#ok<RPTH> -- freshly-unzipped package files need a rehash to be found
ok = isReaderLoadable();
if ~ok
    warning('ensureScanImageTiffReader:loadFailed', ...
        'Downloaded ScanImageTiffReader to "%s" but it failed to load; falling back to a generic TIFF reader.', ...
        fullfile(siDir, '+ScanImageTiffReader'));
end
cachedOk = ok;
end

% =============================================================================
function ok = isReaderLoadable()
% Avoid an `import` statement here: MATLAB can fail to resolve an import of
% a not-yet-on-path package in a way that isn't a normal catchable runtime
% error. A fully-qualified static-method call degrades to an ordinary
% "undefined" error instead, which try/catch handles correctly.
ok = false;
try
    ScanImageTiffReader.ScanImageTiffReader.apiVersion();
    ok = true;
catch
end
end
