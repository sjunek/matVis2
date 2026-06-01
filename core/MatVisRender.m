classdef MatVisRender
    methods (Static)

        function slice2D = renderSlice(model)
            % Returns normalized [0,1] 2-D slice cropped to model.ZoomRange.
            idx = num2cell(model.CurrPos);
            xRange = model.ZoomRange(model.XDim, 1) : model.ZoomRange(model.XDim, 2);
            yRange = model.ZoomRange(model.YDim, 1) : model.ZoomRange(model.YDim, 2);
            idx{model.XDim} = xRange;
            idx{model.YDim} = yRange;
            raw = double(model.Data(idx{:}));
            raw = squeeze(raw);
            if model.XDim < model.YDim
                raw = raw.';
            end
            slice2D = MatVisRender.normalize_(raw, model.ContrastMin, model.ContrastMax);
        end

        function slice2D = renderFullSlice(model)
            % Returns normalized [0,1] 2-D slice using full extent (ignores ZoomRange).
            idx = num2cell(model.CurrPos);
            idx{model.XDim} = 1 : model.Size(model.XDim);
            idx{model.YDim} = 1 : model.Size(model.YDim);
            raw = double(model.Data(idx{:}));
            raw = squeeze(raw);
            if model.XDim < model.YDim
                raw = raw.';
            end
            slice2D = MatVisRender.normalize_(raw, model.ContrastMin, model.ContrastMax);
        end

        function profile1D = renderProfile(model, dimIdx)
            idx = num2cell(model.CurrPos);
            idx{dimIdx} = model.ZoomRange(dimIdx, 1) : model.ZoomRange(dimIdx, 2);
            raw = double(model.Data(idx{:}));
            profile1D = raw(:);
        end

        function img = applyGamma(data, gamma)
            img = data .^ gamma;
        end

        function img = applyColormap(data, cmapIdx)
            cmap    = MatVisRender.getColormap(cmapIdx, 256);
            indices = max(1, min(256, round(data * 255) + 1));
            H = size(data, 1);
            W = size(data, 2);
            rgb = reshape(cmap(indices(:), :), [H W 3]);
            img = uint8(rgb * 255);
        end

        function [counts, edges] = computeHistogram(data)
            [counts, edges] = histcounts(data(:), 256);
        end

        function cmap = getColormap(cmapIdx, nColors)
            n = nColors;
            switch cmapIdx
                case 1,  cmap = gray(n);
                case 2,  cmap = MatVisRender.buildRainbow(n, 0, 1);   % Gray(Range)
                case 3                                                  % 4x Gray
                    g4   = gray(ceil(n/4));
                    cmap = repmat(g4, 4, 1);
                    cmap = cmap(1:n, :);
                case 4,  cmap = turbo(n);
                case 5,  cmap = parula(n);
                case 6,  cmap = jet(n);
                case 7,  cmap = hsv(n);
                case 8,  cmap = hot(n);
                case 9,  cmap = cool(n);
                % Single-hue ramps — order matches dropdown: all *1 first, then all *2
                case 10  % Red1:     Black → Red
                    v = linspace(0,1,n)';  cmap = [v, zeros(n,2)];
                case 11  % Green1:   Black → Green
                    v = linspace(0,1,n)';  cmap = [zeros(n,1), v, zeros(n,1)];
                case 12  % Blue1:    Black → Blue
                    v = linspace(0,1,n)';  cmap = [zeros(n,2), v];
                case 13  % Cyan1:    Black → Cyan
                    v = linspace(0,1,n)';  cmap = [zeros(n,1), v, v];
                case 14  % Magenta1: Black → Magenta
                    v = linspace(0,1,n)';  cmap = [v, zeros(n,1), v];
                case 15  % Yellow1:  Black → Yellow
                    v = linspace(0,1,n)';  cmap = [v, v, zeros(n,1)];
                case 16  % Red2:     Black → Red → White
                    cmap = MatVisRender.buildHue1to2(n, 1, 0, 0);
                case 17  % Green2:   Black → Green → White
                    cmap = MatVisRender.buildHue1to2(n, 0, 1, 0);
                case 18  % Blue2:    Black → Blue → White
                    cmap = MatVisRender.buildHue1to2(n, 0, 0, 1);
                case 19  % Cyan2:    Black → Cyan → White
                    cmap = MatVisRender.buildHue1to2(n, 0, 1, 1);
                case 20  % Magenta2: Black → Magenta → White
                    cmap = MatVisRender.buildHue1to2(n, 1, 0, 1);
                case 21  % Yellow2:  Black → Yellow → White
                    cmap = MatVisRender.buildHue1to2(n, 1, 1, 0);
                case 22, cmap = MatVisRender.buildRainbow(n, 1, 0.5);
                case 23, cmap = MatVisRender.buildRainbow(n, 2, 0.5);
                case 24, cmap = MatVisRender.buildRainbow(n, 3, 0.5);
                case 25, cmap = MatVisRender.buildRainbow(n, 4, 0.5);
                case 26, cmap = MatVisRender.buildRainbow(n, 5, 0.5);
                case 27, cmap = MatVisRender.buildRainbow(n, 6, 0.5);
                case 28, cmap = MatVisRender.buildDiverging(n, 'BlueGrayYellow');
                case 29, cmap = MatVisRender.buildDiverging(n, 'BlueGrayRed');
                case 30, cmap = MatVisRender.buildDiverging(n, 'GreenGrayRed');
                case 31, cmap = MatVisRender.buildDiverging(n, 'MagentaGrayGreen');
                otherwise, cmap = gray(n);
            end
            cmap = max(0, min(1, cmap));
        end

    end

    methods (Static, Access = private)

        function out = normalize_(raw, cMin, cMax)
            if cMax == cMin
                out = zeros(size(raw));
            else
                out = max(0, min(1, (raw - cMin) ./ (cMax - cMin)));
            end
        end

        function cmap = buildHue1to2(n, r, g, b)
            half  = floor(n/2);
            rest  = n - half;
            ramp1 = linspace(0, 1, half)';
            ramp2 = linspace(0, 1, rest)';
            lo    = [r*ramp1, g*ramp1, b*ramp1];
            hi    = [r+(1-r)*ramp2, g+(1-g)*ramp2, b+(1-b)*ramp2];
            cmap  = [lo; hi];
        end

        function cmap = buildRainbow(n, fun_type, exp_val)
            if nargin < 3, exp_val = 1; end
            cmap = zeros(n, 3);
            for k = 1:n
                t = (k-1) / max(n-1, 1);
                cmap(k,:) = MatVisRender.rainbowRGB(t, fun_type, exp_val);
            end
        end

        function rgb = rainbowRGB(col, fun_type, e)
            switch fun_type
                case 0  % gray with blue/red endpoints
                    if col == 0,      rgb = [0 0 1];
                    elseif col == 1,  rgb = [1 0 0];
                    else,             v = col^e; rgb = [v v v];
                    end
                case 1  % black,blue,cyan,green,yellow,red,white
                    if col < 1/6,         rgb = [0, 0, (col*6)^e];
                    elseif col < 2/6,     rgb = [0, (col*6-1)^e, 1];
                    elseif col < 3/6,     rgb = [0, 1, (3-col*6)^e];
                    elseif col < 4/6,     rgb = [(col*6-3)^e, 1, 0];
                    elseif col < 5/6,     rgb = [1, (5-col*6)^e, 0];
                    else,                 rgb = [1, (col*6-5)^e, (col*6-5)^e];
                    end
                case 2  % black,blue,cyan,green,yellow,red,magenta,white
                    if col < 1/7,         rgb = [0, 0, (col*7)^e];
                    elseif col < 2/7,     rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7,     rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7,     rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7,     rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7,     rgb = [1, 0, (col*7-5)^e];
                    else,                 rgb = [1, (col*7-6)^e, 1];
                    end
                case 3  % blue,cyan,green,yellow,red
                    if col < 1/4,         rgb = [0, (col*4)^e, 1];
                    elseif col < 2/4,     rgb = [0, 1, (2-col*4)^e];
                    elseif col < 3/4,     rgb = [(col*4-2)^e, 1, 0];
                    else,                 rgb = [1, (4-col*4)^e, 0];
                    end
                case 4  % blue,cyan,green,yellow,red,magenta
                    if col < 1/5,         rgb = [0, (col*5)^e, 1];
                    elseif col < 2/5,     rgb = [0, 1, (2-col*5)^e];
                    elseif col < 3/5,     rgb = [(col*5-2)^e, 1, 0];
                    elseif col < 4/5,     rgb = [1, (4-col*5)^e, 0];
                    else,                 rgb = [1, 0, (col*5-4)^e];
                    end
                case 5  % white,blue,cyan,green,yellow,red,magenta,white
                    if col < 1/7,         v = (1-col*7)^e; rgb = [v, v, 1];
                    elseif col < 2/7,     rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7,     rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7,     rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7,     rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7,     rgb = [1, 0, (col*7-5)^e];
                    else,                 rgb = [1, (col*7-6)^e, 1];
                    end
                case 6  % white,blue,cyan,green,yellow,red,magenta,black
                    if col < 1/7,         v = (1-col*7)^e; rgb = [v, v, 1];
                    elseif col < 2/7,     rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7,     rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7,     rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7,     rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7,     rgb = [1, 0, (col*7-5)^e];
                    else,                 v = (7-col*7)^e; rgb = [v, 0, v];
                    end
                otherwise
                    rgb = [col, col, col];
            end
        end

        function cmap = buildDiverging(n, name)
            myGV = 0.9;
            half = floor(n/2);
            rest = n - half;
            cmap = zeros(n, 3);
            % Left (negative) side: blue → gray
            cmap(1:half, 1) = linspace(0,    myGV, half);
            cmap(1:half, 2) = linspace(0,    myGV, half);
            cmap(1:half, 3) = linspace(1,    myGV, half);
            % Right (positive) side: gray → red
            cmap(half+1:end, 1) = linspace(myGV, 1,    rest);
            cmap(half+1:end, 2) = linspace(myGV, 0,    rest);
            cmap(half+1:end, 3) = linspace(myGV, 0,    rest);
            switch name
                case 'BlueGrayRed'
                    % base is already Blue-Gray-Red

                case 'BlueGrayYellow'
                    % Replace green channel with red channel (red side → yellow)
                    cmap(:, 2) = cmap(:, 1);

                case 'GreenGrayRed'
                    % Swap red and blue channels (left becomes green, right stays red)
                    cmap = cmap(:, [3 2 1]);
                    % Now left: [myGV→0, myGV→0, 1→myGV] start=[0,0,1]=blue — wrong
                    % Redo: green-gray-red = left green, right red
                    cmap2 = zeros(n, 3);
                    cmap2(1:half, 1) = linspace(0,    myGV, half);
                    cmap2(1:half, 2) = linspace(1,    myGV, half);
                    cmap2(1:half, 3) = linspace(0,    myGV, half);
                    cmap2(half+1:end, 1) = linspace(myGV, 1,  rest);
                    cmap2(half+1:end, 2) = linspace(myGV, 0,  rest);
                    cmap2(half+1:end, 3) = linspace(myGV, 0,  rest);
                    cmap = cmap2;

                case 'MagentaGrayGreen'
                    cmap2 = zeros(n, 3);
                    cmap2(1:half, 1) = linspace(1,    myGV, half);
                    cmap2(1:half, 2) = linspace(0,    myGV, half);
                    cmap2(1:half, 3) = linspace(1,    myGV, half);
                    cmap2(half+1:end, 1) = linspace(myGV, 0,  rest);
                    cmap2(half+1:end, 2) = linspace(myGV, 1,  rest);
                    cmap2(half+1:end, 3) = linspace(myGV, 0,  rest);
                    cmap = cmap2;
            end
        end

    end
end
