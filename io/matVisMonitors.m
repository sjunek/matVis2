function [mon, primWork] = matVisMonitors()
% matVisMonitors  Monitor layout now, in figure Position units.
%
%   [mon, primWork] = matVisMonitors()
%
%   mon       Nx4 [left bottom width height] per monitor, MATLAB y-up
%             convention, like get(0,'MonitorPositions')
%   primWork  1x4 the same for the primary monitor's working area (without
%             the taskbar)
%
% get(0,'ScreenSize') and get(0,'MonitorPositions') are read once when MATLAB
% starts.  A session that outlives a change of displays (docking, a remote
% desktop session, a monitor switched off) keeps placing windows on a layout
% that no longer exists -- partly off screen, where Windows pushes them back
% on top of one another.  So the layout is asked of Windows each time,
% through .NET, and scaled from device pixels to figure units by the system
% DPI.  While MATLAB's own list still agrees with Windows about the primary
% monitor it is used as it is: per-monitor DPI scaling (R2026a) places
% secondary monitors differently than one system-wide factor would.
% Off Windows, or without .NET, MATLAB's own list is all there is.

mp = get(0, 'MonitorPositions');
ss = get(0, 'ScreenSize');
mon      = mp;
primWork = ss;
try
    NET.addAssembly('System.Windows.Forms');
    NET.addAssembly('System.Drawing');
    g = System.Drawing.Graphics.FromHwnd(System.IntPtr.Zero);
    s = double(g.DpiX) / 96;
    g.Dispose();
    prim  = System.Windows.Forms.Screen.PrimaryScreen;
    primH = double(prim.Bounds.Height);
    primB = toMatlab(prim.Bounds, s, primH);
    primWork = toMatlab(prim.WorkingArea, s, primH);
    if ~any(all(abs(mp - primB) < 1.5, 2))
        scr = System.Windows.Forms.Screen.AllScreens;
        mon = zeros(scr.Length, 4);
        for k = 1:scr.Length
            mon(k,:) = toMatlab(scr(k).Bounds, s, primH);
        end
    end
catch
end
end

function r = toMatlab(b, s, primH)
% Windows measures y down from the primary monitor's top edge, MATLAB up from
% its bottom edge.
x = double(b.X);  y = double(b.Y);  w = double(b.Width);  h = double(b.Height);
r = [x / s + 1, (primH - (y + h)) / s + 1, w / s, h / s];
end
