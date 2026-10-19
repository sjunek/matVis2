function pos = matVisRemapWindowPos(pos, savedMon, curMon)
% matVisRemapWindowPos  Carry a saved window Position over to the current monitors.
%
%   pos = matVisRemapWindowPos(pos, savedMon, curMon)
%
%   pos      [x y w h] figure Position saved in a config file
%   savedMon get(0,'MonitorPositions') at the time it was saved (Nx4)
%   curMon   get(0,'MonitorPositions') now (Mx4)
%
%   The window keeps its place on the SAME monitor, whatever the mouse is
%   doing. get(0,'MonitorPositions') is not stable for one and the same
%   set of displays: the row order can change, and a secondary monitor can
%   be reported in DPI-scaled or in physical pixels depending on the MATLAB
%   session. So the window is assigned to the saved monitor it overlaps
%   most, that monitor is matched to a current one, and the window's
%   top-left corner keeps its offset from that monitor's top-left corner
%   (scaled if the monitor is now reported at a different size). The size
%   is kept. If the monitor layouts are identical, pos comes back unchanged.
%
%   Matching: an identical rectangle wins; the primary monitor (the one at
%   [1 1]) maps to the primary; the others are paired in left-to-right
%   order, among monitors of the same orientation if the counts differ. A
%   monitor with no counterpart maps to the current primary.

    if isempty(savedMon) || isempty(curMon) || numel(pos) ~= 4, return; end

    s = mostOverlap(pos, savedMon);
    if s == 0, return; end   % on no saved monitor: leave it to the clamp
    c = matchMonitor(s, savedMon, curMon);

    sm = savedMon(s, :);  cm = curMon(c, :);
    if isequal(sm, cm), return; end

    sx   = cm(3) / sm(3);
    sy   = cm(4) / sm(4);
    dx   = pos(1) - sm(1);                        % left offset
    dTop = (sm(2) + sm(4)) - (pos(2) + pos(4));   % offset below monitor top
    newTop = cm(2) + cm(4) - dTop * sy;
    pos(1) = round(cm(1) + dx * sx);
    pos(2) = round(newTop - pos(4));
end

function s = mostOverlap(pos, mon)
    s = 0;  best = 0;
    for i = 1:size(mon, 1)
        w = min(pos(1) + pos(3), mon(i,1) + mon(i,3)) - max(pos(1), mon(i,1));
        h = min(pos(2) + pos(4), mon(i,2) + mon(i,4)) - max(pos(2), mon(i,2));
        a = max(w, 0) * max(h, 0);
        if a > best, best = a; s = i; end
    end
end

function c = matchMonitor(s, savedMon, curMon)
    % Identical rectangle (layouts equal up to row order)
    hit = find(ismember(curMon, savedMon(s,:), 'rows'), 1);
    if ~isempty(hit), c = hit; return; end

    sp = primaryIdx(savedMon);
    cp = primaryIdx(curMon);
    c  = cp;
    if s == sp, return; end

    sOthers = setdiff(1:size(savedMon,1), sp);
    cOthers = setdiff(1:size(curMon,1),   cp);
    if numel(sOthers) ~= numel(cOthers)
        % Different monitor count: pair only monitors of the same orientation
        sPortrait = savedMon(s,4) > savedMon(s,3);
        sOthers = sOthers((savedMon(sOthers,4) > savedMon(sOthers,3)) == sPortrait);
        cOthers = cOthers((curMon(cOthers,4)   > curMon(cOthers,3))   == sPortrait);
    end
    [~, so] = sortrows(savedMon(sOthers, 1:2));  sOthers = sOthers(so);
    [~, co] = sortrows(curMon(cOthers, 1:2));    cOthers = cOthers(co);
    k = find(sOthers == s, 1);
    if ~isempty(k) && k <= numel(cOthers)
        c = cOthers(k);
    end
end

function p = primaryIdx(mon)
    p = find(mon(:,1) == 1 & mon(:,2) == 1, 1);
    if isempty(p), p = 1; end
end
