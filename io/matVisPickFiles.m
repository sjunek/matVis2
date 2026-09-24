function filepaths = matVisPickFiles()
%matVisPickFiles  Multi-select file dialog for matVis, as a cell of paths.
%
%   filepaths = matVisPickFiles()
%
%   Errors with identifier 'matVisPickFiles:cancelled' when the dialog is
%   dismissed.
%
%   Split out so that the dialog is shown exactly once per call to matVis2:
%   the choice of how to open the files (in full, or reading planes on
%   demand) depends on how big they turn out to be, which can only be
%   answered after they have been named.
%
%   See also importMultiFile, buildFileFilter, matVisOpenSource.

[fnames, fpath] = uigetfile(buildFileFilter(), ...
    'Select one or more files', 'MultiSelect', 'on');
if isequal(fnames, 0)
    error('matVisPickFiles:cancelled', 'File selection cancelled.');
end
if ischar(fnames)
    fnames = {fnames};
end
filepaths = cellfun(@(f) fullfile(fpath, f), fnames, 'UniformOutput', false);
end
