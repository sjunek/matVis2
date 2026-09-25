function img = matVisLockIcon(closed, sz)
% matVisLockIcon  Padlock icon for the lock state buttons (uibutton 'Icon').
%
%   img = matVisLockIcon(closed)        16 x 16 x 3
%   img = matVisLockIcon(closed, sz)    sz x sz x 3
%
% The glyph is drawn from signed-distance fields at 8x supersampling, so the
% shackle is a true semicircle of even stroke width and the body has rounded
% corners. The open state is hinged at the left leg and tilted, which reads
% as "open" at 16 px far better than a shortened right wall does.
%
% Pixels outside the glyph are NaN, which uifigure renders transparent -- an
% opaque background would otherwise show as a pale square on the pressed
% button. Edge pixels have to be composited against something, so they are
% blended with the button face the icon is actually seen on: these are all
% state buttons, so the closed lock sits on a pressed face and the open one
% on a released face.
%
% Results are cached per (state, size); rendering costs a few ms.

if nargin < 2, sz = 16; end
closed = logical(closed);

persistent cache
key = sprintf('k%d_%d', closed, sz);
if isstruct(cache) && isfield(cache, key)
    img = cache.(key);
    return;
end

SS       = 8;             % supersampling factor
RELEASED = 0.961;         % uifigure button face, Value = false
PRESSED  = 0.851;         % uifigure button face, Value = true
SCALE    = 0.92;          % breathing room inside the icon box
INK      = [0.16 0.18 0.22];

if closed, face = PRESSED; else, face = RELEASED; end

N = sz * SS;
[X0, Y0] = meshgrid(((1:N) - 0.5) / N);
X = (X0 - 0.5) / SCALE + 0.5;
Y = (Y0 - 0.5) / SCALE + 0.5;

% Body: rounded rectangle.
dBody = sdRoundRect(X, Y, 0.135, 0.865, 0.470, 0.950, 0.140);

% Shackle: polyline (left leg, arc, right leg) stroked with round caps.
cx = 0.500; hw = 0.205; cy = 0.400; legB = 0.560;
if closed
    th = linspace(pi, 0, 64);
    P  = [cx - hw, legB; [cx + hw*cos(th(:)), cy - hw*sin(th(:))]; cx + hw, legB];
else
    th = linspace(pi, 0.10, 60);            % no right leg -- it is off the body
    P  = [cx - hw, legB; [cx + hw*cos(th(:)), cy - hw*sin(th(:))]];
    P  = rotAbout(P, [cx - hw, legB], 32);  % hinged left, free end lifted
end
dShk = sdPolyline(X, Y, P) - 0.058;

% Keyhole: circle plus slot, knocked out of the body.
dKey = min(hypot(X - 0.5, Y - 0.655) - 0.085, ...
           sdPolyline(X, Y, [0.5 0.655; 0.5 0.820]) - 0.055);

aHi = (dShk <= 0) | (dBody <= 0);
aHi(dKey <= 0) = false;

a   = boxdown(double(aHi), SS);
img = repmat(a, 1, 1, 3) .* reshape(INK, 1, 1, 3) + (1 - a) .* face;
img(repmat(a, 1, 1, 3) == 0) = NaN;

cache.(key) = img;
end

% -------------------------------------------------------------------------
function d = sdRoundRect(X, Y, l, r, t, b, rad)
% Signed distance to a rounded rectangle (negative inside).
cxr = (l + r) / 2;        cyr = (t + b) / 2;
hx  = (r - l) / 2 - rad;  hy  = (b - t) / 2 - rad;
dx  = abs(X - cxr) - hx;  dy  = abs(Y - cyr) - hy;
d   = hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - rad;
end

function d = sdPolyline(X, Y, P)
% Distance to a polyline; subtract a half-width to get a round-capped stroke.
d = inf(size(X));
for k = 1:size(P, 1) - 1
    ax = P(k,1); ay = P(k,2);
    ex = P(k+1,1) - ax; ey = P(k+1,2) - ay;
    L2 = ex^2 + ey^2;
    if L2 == 0, continue; end
    t = min(1, max(0, ((X - ax)*ex + (Y - ay)*ey) / L2));
    d = min(d, hypot(X - ax - t*ex, Y - ay - t*ey));
end
end

function Q = rotAbout(P, piv, degCCW)
% Rotate points about a pivot, counter-clockwise on screen (y points down).
c = cosd(degCCW); s = sind(degCCW);
V = P - piv;
Q = [V(:,1)*c + V(:,2)*s, -V(:,1)*s + V(:,2)*c] + piv;
end

function B = boxdown(A, S)
% Average S-by-S blocks: the supersampled mask becomes coverage per pixel.
[H, W] = size(A);
B = squeeze(mean(mean(reshape(A, S, H/S, S, W/S), 1), 3));
end
