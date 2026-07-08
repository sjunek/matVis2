function u = normalizeOmeUnit(u)
% normalizeOmeUnit  Normalize a physical-unit string to matVis's convention.
%   Vendor-supplied unit strings may spell "microns" with the micron sign
%   (U+00B5) or the Greek small letter mu (U+03BC) depending on the writer;
%   both are normalized to the plain ASCII 'um' used elsewhere in matVis.
%   Any other unit string is passed through unchanged.
u = char(u);
if isempty(u)
    return;
end
if any(double(u) == 181) || any(double(u) == 956)
    u = 'um';
end
end
