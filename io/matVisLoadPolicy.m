function d = matVisLoadPolicy(info)
%matVisLoadPolicy  Decide whether a dataset should be read on demand.
%
%   d = matVisLoadPolicy(info)
%
%   info is a struct describing what is about to be opened:
%     bytes          total size in memory, summed over all datasets
%     estSeconds     estimated time to read it in full (NaN if unknown)
%
%   d has fields:
%     recommend      'full' | 'lazy'
%     shouldAsk      true when the user should be given the choice
%     reasons        cellstr, one plain-language line per triggered threshold
%     availableBytes free memory the estimate was made against (NaN if unknown)
%
%   Two thresholds, deliberately separate, because they are different
%   failures.  Size against available memory is the one that makes a full
%   load impossible -- on a 16 GB laptop a 10 GB stack does not load slowly,
%   it does not load.  Load time is the one that makes it merely expensive:
%   on a workstation with room to spare, 40 s of waiting is still 40 s.
%   Either crossing is enough to offer the choice.
%
%   This function performs no I/O and opens no windows, so the decision can
%   be tested on its own.
%
%   See also matVisOpenSource, MatVisBioFormatsSource.

MEMORY_FRACTION = 0.5;    % of free memory, above which a full load is risky
SLOW_SECONDS    = 15;     % a wait worth offering to skip

avail = availableBytes();

reasons   = {};
recommend = 'full';

if isfinite(avail) && info.bytes > MEMORY_FRACTION * avail
    reasons{end+1} = sprintf( ...
        'It needs %s of memory and only %s is free.', ...
        bytesText(info.bytes), bytesText(avail));
    recommend = 'lazy';
end

if isfield(info, 'estSeconds') && isfinite(info.estSeconds) && ...
        info.estSeconds > SLOW_SECONDS
    reasons{end+1} = sprintf('Reading it in full takes about %s.', ...
        secondsText(info.estSeconds));
    recommend = 'lazy';
end

d = struct( ...
    'recommend',      recommend, ...
    'shouldAsk',      ~isempty(reasons), ...
    'reasons',        {reasons}, ...
    'availableBytes', avail);
end

% =============================================================================
function n = availableBytes()
% Free memory for MATLAB arrays.  `memory` is Windows-only; elsewhere there
% is no portable equivalent, and NaN makes the size threshold stand down
% rather than guess.
n = NaN;
try
    if ispc
        u = memory;
        n = u.MemAvailableAllArrays;
    end
catch
end
end

% =============================================================================
function s = bytesText(n)
if ~isfinite(n), s = 'an unknown amount'; return; end
u = {'B', 'kB', 'MB', 'GB', 'TB'};
k = min(numel(u), max(1, floor(log(max(n, 1)) / log(1024)) + 1));
s = sprintf('%.1f %s', n / 1024^(k-1), u{k});
end

% =============================================================================
function s = secondsText(t)
if t < 90
    s = sprintf('%.0f seconds', t);
else
    s = sprintf('%.0f minutes', t / 60);
end
end
