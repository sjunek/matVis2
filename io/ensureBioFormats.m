function ok = ensureBioFormats()
% ensureBioFormats  True if the Bio-Formats Java library is loadable.
%   ok = ensureBioFormats() adds io/bfmatlab to the path and checks whether
%   bioformats_package.jar is present and loads (via bfCheckJavaPath). If
%   the jar is missing, warns and — in an interactive session — offers to
%   download it. The result is cached for the rest of the MATLAB session
%   (persists until `clear functions`/`clear all`), so this only prompts or
%   hits the filesystem/network once per session.
%
%   Callers should treat ok==false as "fall back to the built-in reader".

persistent cachedOk

% Cheap, idempotent: re-assert bfDir on the path even on a cache hit, since
% test suites and other code may snapshot/restore path() between calls
% (path() is global state, not owned by this function).
bfDir = fullfile(fileparts(mfilename('fullpath')), 'bfmatlab');
if isempty(which('bfGetReader')) || ~strcmpi(which('bfGetReader'), fullfile(bfDir, 'bfGetReader.m'))
    addpath(bfDir);
end

if ~isempty(cachedOk)
    ok = cachedOk;
    return;
end

status = bfCheckJavaPath();
if status
    ok = true;
    cachedOk = ok;
    return;
end

jarPath = fullfile(bfDir, 'bioformats_package.jar');
jarUrl  = 'https://downloads.openmicroscopy.org/bio-formats/8.5.0/artifacts/bioformats_package.jar';

if ~exist(jarPath, 'file')
    doDownload = false;
    if usejava('desktop')
        choice = questdlg( ...
            ['Bio-Formats (bioformats_package.jar, ~55 MB) is not installed. It is used to read ' ...
             'OME-TIFF metadata and other microscopy formats (.czi, .lsm, .nd2, .lif, ...). ' ...
             'A built-in fallback still handles .tif/.jpg/.png/.bmp without it. ' ...
             'Download Bio-Formats now?'], ...
            'Bio-Formats not found', 'Download', 'Not now', 'Not now');
        doDownload = strcmp(choice, 'Download');
    end

    if doDownload
        fprintf('[matVis2] Downloading Bio-Formats from %s ...\n', jarUrl);
        try
            websave(jarPath, jarUrl);
        catch e
            warning('ensureBioFormats:downloadFailed', ...
                'Could not download Bio-Formats (%s); falling back to the built-in reader.', ...
                e.message);
            ok = false;
            cachedOk = ok;
            return;
        end
    else
        warning('ensureBioFormats:notSetUp', ...
            ['Bio-Formats is not set up; falling back to the built-in reader (.tif/.jpg/.png/.bmp ' ...
             'only, OME-TIFF metadata via a simpler parser). Place bioformats_package.jar in "%s", ' ...
             'or call matVis2(...) again and choose "Download" to fetch it automatically.'], bfDir);
        ok = false;
        cachedOk = ok;
        return;
    end
end

ok = bfCheckJavaPath();
if ~ok
    warning('ensureBioFormats:loadFailed', ...
        'Found bioformats_package.jar in "%s" but it failed to load; falling back to the built-in reader.', ...
        bfDir);
end
cachedOk = ok;
end
