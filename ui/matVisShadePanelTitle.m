function matVisShadePanelTitle(p)
% matVisShadePanelTitle  Darken the title strip of a titled uipanel.
%
%   matVisShadePanelTitle(p)
%
% uipanel has no separate title colour, so the whole panel is darkened: the
% uigridlayout that fills the panel paints its own (default) background over
% the content area, which leaves only the title strip in the darker shade.
% Scaling the current colour keeps the shade relative to whatever background
% the panel starts with.  The title is set bold too, so every window's panel
% titles look the same.

p.BackgroundColor = 0.88 * p.BackgroundColor;
p.FontWeight      = 'bold';
end
