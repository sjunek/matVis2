function [ok, msg] = copyImageToClipboard(rgb)
%COPYIMAGETOCLIPBOARD  Put an image array on the Windows clipboard as a bitmap.
%
%   ok = copyImageToClipboard(rgb)
%
%   rgb - H×W×3 or H×W array; uint8, logical, or floating point in [0 1].
%   ok  - true when the clipboard was written.
%   msg - why not, when OK is false (empty otherwise).
%
%   The array is handed to the clipboard as a packed device-independent
%   bitmap (CF_DIB, 24 bpp, BI_RGB).  Two reasons for going to that trouble
%   instead of calling copygraphics:
%
%     * Format.  copygraphics places an enhanced metafile on the clipboard
%       (measured: EnhancedMetafile + MetaFilePict only).  Word and
%       PowerPoint paste that happily, but bitmap editors such as Photoshop
%       ignore it, so "Copy" looked broken outside Office.  CF_DIB is the
%       format every Windows imaging application accepts.
%     * Size.  copygraphics re-renders the axes at 150 dpi and adds a
%       one-pixel border, so a 180×180 image arrived as 282×282 with a white
%       frame.  Passing the array through untouched pastes exactly these
%       pixels at exactly this size.
%
%   Returns false without raising on non-Windows platforms or if the .NET
%   interface is unavailable, so callers can fall back to copygraphics.

ok  = false;
msg = '';
if ~ispc
    msg = 'the clipboard bitmap path is Windows-only';   return;
end
if isempty(rgb), msg = 'nothing to copy'; return; end

rgb = toUint8Rgb(rgb);
[H, W, ~] = size(rgb);
if H < 1 || W < 1, return; end

try
    NET.addAssembly('System.Windows.Forms');
    dib  = packDib(rgb, H, W);
    ms   = System.IO.MemoryStream(dib);
    dobj = System.Windows.Forms.DataObject();
    dobj.SetData('DeviceIndependentBitmap', ms);
    % copy = true hands the data to the OS clipboard so it outlives this
    % call.  The 20 x 100 ms retry rides out another process holding the
    % clipboard open — without it "Requested Clipboard operation did not
    % succeed" showed up now and then, which would silently demote the copy
    % to the metafile fallback.  MS is deliberately not disposed: the
    % clipboard reads from the stream after this returns, and disposing it
    % made the paste come out empty.
    System.Windows.Forms.Clipboard.SetDataObject(dobj, true, 20, 100);
    ok = true;
catch me
    ok  = false;
    msg = me.message;
end

end % copyImageToClipboard

% -------------------------------------------------------------------------
function rgb = toUint8Rgb(rgb)
    if islogical(rgb)
        rgb = uint8(rgb) * 255;
    elseif isfloat(rgb)
        rgb = uint8(round(255 * max(0, min(1, rgb))));
    elseif ~isa(rgb, 'uint8')
        rgb = uint8(rgb);
    end
    if ndims(rgb) == 2 %#ok<ISMAT>
        rgb = repmat(rgb, 1, 1, 3);
    elseif size(rgb, 3) > 3
        rgb = rgb(:, :, 1:3);          % drop an alpha channel
    end
end

% -------------------------------------------------------------------------
function dib = packDib(rgb, H, W)
    % BITMAPINFOHEADER followed by the pixel bits: 24 bpp, BGR, rows
    % bottom-up (positive biHeight), every row padded to 4 bytes.
    stride = 4 * ceil(3 * W / 4);
    ppm    = int32(round(96 / 0.0254));    % 96 dpi in pixels per metre

    hdr = zeros(40, 1, 'uint8');
    hdr(1:4)   = typecast(uint32(40),           'uint8');   % biSize
    hdr(5:8)   = typecast(int32(W),             'uint8');   % biWidth
    hdr(9:12)  = typecast(int32(H),             'uint8');   % biHeight
    hdr(13:14) = typecast(uint16(1),            'uint8');   % biPlanes
    hdr(15:16) = typecast(uint16(24),           'uint8');   % biBitCount
    hdr(17:20) = typecast(uint32(0),            'uint8');   % BI_RGB
    hdr(21:24) = typecast(uint32(stride * H),   'uint8');   % biSizeImage
    hdr(25:28) = typecast(ppm,                  'uint8');   % biXPelsPerMeter
    hdr(29:32) = typecast(ppm,                  'uint8');   % biYPelsPerMeter

    flat = reshape(permute(rgb(:, :, [3 2 1]), [3 2 1]), 3 * W, H);
    bits = zeros(stride, H, 'uint8');
    bits(1:3*W, :) = flat(:, H:-1:1);
    dib  = [hdr; bits(:)];
end
