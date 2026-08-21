function v = tiffTagValue(ifd, tagId, defaultValue)
% tiffTagValue  Look one tag up in a directory returned by parseTiffIfds.
%   v = tiffTagValue(ifd, tagId)                 [] when the tag is absent
%   v = tiffTagValue(ifd, tagId, defaultValue)   defaultValue when absent
%
%   See also parseTiffIfds.

if nargin < 3
    defaultValue = [];
end

idx = find(ifd.tag == tagId, 1);
if isempty(idx)
    v = defaultValue;
else
    v = ifd.value{idx};
end
end
