function outFile = makeTestShapes4D(outFile)
% makeTestShapes4D  Synthetic 4-D test volume for the cross-section window.
%
%   makeTestShapes4D()          writes <repo>/testShapes4D.mat
%   f = makeTestShapes4D(path)  writes to PATH and returns it
%
% The file contains ONE numeric variable, shapes4D, of size
% [96 128 40 16] = [y x z t] (uint16), so it can be opened directly with
%   matVis2('testShapes4D.mat')
% and — with the acquisition scale that the .mat format cannot carry — as
%
%   matVis2('testShapes4D.mat', ...
%       'dimNames', {'y','x','z','t'}, 'dimUnits', {'um','um','um','s'}, ...
%       'dimScale', {(0:95)*0.1, (0:127)*0.1, (0:39)*0.5, (0:15)*2});
%
% Contents — three volumetric shapes at fixed positions, side by side along
% x, each changing size and brightness along t in a different way:
%
%   sphere       grows      (r 1.0 -> 2.0 um)         while dimming     (1.00 -> 0.35)
%   cube         shrinks    (half-edge 1.6 -> 1.0 um) while brightening (0.30 -> 1.00)
%   tetrahedron  pulsates   (circumradius 1.5 <-> 2.4 um, brightness in antiphase)
%
% Why it is built this way (all of it is deliberately load-bearing for the
% cross-section window):
%
%   * The four dimensions have four different lengths, so any accidental
%     transposition or permutation of a plane is immediately visible.
%   * The shapes are defined in REAL space with anisotropic voxels
%     (0.1 x 0.1 x 0.5 um): in raw pixel coordinates the sphere is a
%     5:1 ellipsoid, and only a display that honours DimScale shows it round
%     in the x/z and z/y panels. Same for the cube (a squat box in pixels).
%   * Each shape has a different cross-sectional signature — circle, square,
%     triangle — so it is obvious which plane a panel is showing.
%   * Positions stay fixed while size changes, so a position cross-hair
%     parked on a shape stays on it while stepping along t.
%   * A faint z-gradient background plus read/shot noise gives the contrast
%     modes (Global / Image / Zoom) visibly different results.

if nargin < 1 || isempty(outFile)
    repoDir = fileparts(fileparts(mfilename('fullpath')));
    outFile = fullfile(repoDir, 'testShapes4D.mat');
end

sz     = [96 128 40 16];          % [y x z t]
vox    = [0.1 0.1 0.5];           % um per voxel along [y x z]
nT     = sz(4);

% Real-world coordinate of every voxel (um), origin at index 1.
yv = (0:sz(1)-1) * vox(1);
xv = (0:sz(2)-1) * vox(2);
zv = (0:sz(3)-1) * vox(3);
[Y, X, Z] = ndgrid(yv, xv, zv);

% All three share a centre in y and z, so one cross-hair position shows all
% of them at once in the x/y and x/z panels; they are separated along x with
% enough room that they never touch at any t.
yC = yv(end) / 2;
zC = zv(end) / 2;
xSphere = 2.6;                    % centres along x (um), 3.8 um apart
xCube   = 6.4;
xTetra  = 10.2;

soft = 0.12;                      % edge softness (um) — anti-aliased surfaces

% Regular tetrahedron: intersection of four half-spaces. n·(p-c) <= h with
% these normals gives a tetrahedron of inradius h (circumradius 3h).
nT4 = [ 1  1  1;  1 -1 -1; -1  1 -1; -1 -1  1] / sqrt(3);

rng(42);                          % reproducible noise
shapes4D = zeros(sz, 'uint16');

for t = 1:nT
    s = (t - 1) / max(nT - 1, 1);          % 0 .. 1 along the 4th dimension

    % --- sphere: grows while dimming ------------------------------------
    rSph   = 1.0 + 1.0 * s;
    ampSph = 1.00 - 0.65 * s;
    dSph   = sqrt((Y-yC).^2 + (X-xSphere).^2 + (Z-zC).^2) - rSph;

    % --- cube: shrinks while brightening --------------------------------
    hCub   = 1.6 - 0.6 * s;
    ampCub = 0.30 + 0.70 * s;
    dCub   = max(max(abs(Y-yC), abs(X-xCube)), abs(Z-zC)) - hCub;

    % --- tetrahedron: size and brightness pulsate in antiphase ----------
    % Sized by circumradius R (1.5 -> 2.4 um); the half-space offset is the
    % inradius, R/3. Its axis-aligned extent is R/sqrt(3), which is what
    % keeps it clear of the cube.
    rTet   = 1.5 + 0.9 * (0.5 - 0.5*cos(2*pi*s));
    hTet   = rTet / 3;
    ampTet = 0.35 + 0.65 * (0.5 + 0.5*cos(2*pi*s));
    dTet   = -inf(sz(1:3));
    for k = 1:4
        dTet = max(dTet, nT4(k,1)*(Y-yC) + nT4(k,2)*(X-xTetra) + nT4(k,3)*(Z-zC));
    end
    dTet = dTet - hTet;

    vol = ampSph * edgeProfile(dSph, soft) ...
        + ampCub * edgeProfile(dCub, soft) ...
        + ampTet * edgeProfile(dTet, soft);

    % --- background + noise ---------------------------------------------
    bg    = 0.04 + 0.03 * (Z / max(zv(end), eps));
    clean = 3000 * vol + 300 * bg;
    noisy = clean + sqrt(max(clean, 0)) .* randn(sz(1:3)) + 25 * randn(sz(1:3));

    shapes4D(:, :, :, t) = uint16(max(0, min(65535, noisy)));
end

save(outFile, 'shapes4D', '-v7.3');
d = dir(outFile);
fprintf('Wrote %s  (%s uint16, %.1f MB on disk)\n', ...
    outFile, mat2str(sz), d.bytes / 1e6);
fprintf(['Open with real-world scale:\n' ...
    '  matVis2(''%s'', ...\n' ...
    '      ''dimNames'', {''y'',''x'',''z'',''t''}, ''dimUnits'', {''um'',''um'',''um'',''s''}, ...\n' ...
    '      ''dimScale'', {(0:%d)*0.1, (0:%d)*0.1, (0:%d)*0.5, (0:%d)*2});\n'], ...
    outFile, sz(1)-1, sz(2)-1, sz(3)-1, sz(4)-1);
end

% -------------------------------------------------------------------------
function w = edgeProfile(d, soft)
% Signed distance -> [0,1] occupancy with a smooth, few-voxel-wide edge.
% Anti-aliasing matters here: the 3-D MIP renders a strided-down copy of the
% volume, and hard-edged shapes alias badly once they are subsampled.
w = max(0, min(1, 0.5 - d / (2 * soft)));
end
