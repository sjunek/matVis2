classdef MatVisRender
    methods (Static)

        function slice2D = renderSlice(model)
            % Build index expression: all dims fixed to CurrPos except XDim/YDim
            nDims = numel(model.Size);
            idx = num2cell(model.CurrPos);

            xRange = model.ZoomRange(model.XDim, 1) : model.ZoomRange(model.XDim, 2);
            yRange = model.ZoomRange(model.YDim, 1) : model.ZoomRange(model.YDim, 2);

            idx{model.XDim} = xRange;
            idx{model.YDim} = yRange;

            raw = double(model.Data(idx{:}));

            % Collapse singleton dims other than XDim/YDim by squeezing, then
            % permute so that YDim comes first (rows) and XDim second (cols).
            % After indexing, the free dims are XDim and YDim; everything else
            % is a singleton.  squeeze removes them, but the relative order of
            % XDim vs YDim in the original array determines which squeezed dim
            % is which — we need YDim as rows.
            raw = squeeze(raw);

            % After squeezing a sub-array with exactly two non-singleton dims,
            % the first remaining dim corresponds to whichever of XDim/YDim has
            % the smaller dimension index in the original array.
            if model.XDim < model.YDim
                % raw is [xRange x yRange] — transpose to [yRange x xRange]
                raw = raw.';
            end
            % else raw is already [yRange x xRange]

            cMin = model.ContrastMin;
            cMax = model.ContrastMax;
            if cMax == cMin
                slice2D = zeros(size(raw));
            else
                slice2D = (raw - cMin) ./ (cMax - cMin);
                slice2D = max(0, min(1, slice2D));
            end
        end

        function profile1D = renderProfile(model, dimIdx)
            nDims = numel(model.Size);
            idx = num2cell(model.CurrPos);

            zRange = model.ZoomRange(dimIdx, 1) : model.ZoomRange(dimIdx, 2);
            idx{dimIdx} = zRange;

            raw = double(model.Data(idx{:}));
            profile1D = raw(:);
        end

        function img = applyGamma(data, gamma)
            img = data .^ gamma;
        end

        function img = applyColormap(data, cmapIdx)
            cmap = MatVisRender.getColormap(cmapIdx, 256);
            % Map [0,1] data to colormap indices 1..256
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
                case 1  % Gray
                    cmap = gray(n);
                case 2  % Gray (Range) — endpoints blue/red, interior gray
                    cmap = MatVisRender.buildRainbow(n, 0, 1);
                case 3  % 4x Gray
                    cmap = repmat(gray(max(1, floor(n/4))), 4, 1);
                    cmap = cmap(1:n, :);
                case 4
                    cmap = turbo(n);
                case 5
                    cmap = parula(n);
                case 6
                    cmap = jet(n);
                case 7
                    cmap = hsv(n);
                case 8
                    cmap = hot(n);
                case 9
                    cmap = cool(n);
                case 10  % Red 1: Black-Red
                    r = linspace(0,1,n)';
                    cmap = [r, zeros(n,2)];
                case 11  % Red 2: Black-Red-White
                    cmap = MatVisRender.buildHue1to2(n, 1, 0, 0);
                case 12  % Green 1: Black-Green
                    g = linspace(0,1,n)';
                    cmap = [zeros(n,1), g, zeros(n,1)];
                case 13  % Green 2: Black-Green-White
                    cmap = MatVisRender.buildHue1to2(n, 0, 1, 0);
                case 14  % Blue 1: Black-Blue
                    b = linspace(0,1,n)';
                    cmap = [zeros(n,2), b];
                case 15  % Blue 2: Black-Blue-White
                    cmap = MatVisRender.buildHue1to2(n, 0, 0, 1);
                case 16  % Cyan 1: Black-Cyan
                    v = linspace(0,1,n)';
                    cmap = [zeros(n,1), v, v];
                case 17  % Cyan 2: Black-Cyan-White
                    cmap = MatVisRender.buildHue1to2(n, 0, 1, 1);
                case 18  % Magenta 1: Black-Magenta
                    v = linspace(0,1,n)';
                    cmap = [v, zeros(n,1), v];
                case 19  % Magenta 2: Black-Magenta-White
                    cmap = MatVisRender.buildHue1to2(n, 1, 0, 1);
                case 20  % Yellow 1: Black-Yellow
                    v = linspace(0,1,n)';
                    cmap = [v, v, zeros(n,1)];
                case 21  % Yellow 2: Black-Yellow-White
                    cmap = MatVisRender.buildHue1to2(n, 1, 1, 0);
                case 22  % Rainbow1
                    cmap = MatVisRender.buildRainbow(n, 1, 0.5);
                case 23  % Rainbow2
                    cmap = MatVisRender.buildRainbow(n, 2, 0.5);
                case 24  % Rainbow3
                    cmap = MatVisRender.buildRainbow(n, 3, 0.5);
                case 25  % Rainbow4
                    cmap = MatVisRender.buildRainbow(n, 4, 0.5);
                case 26  % Rainbow5
                    cmap = MatVisRender.buildRainbow(n, 5, 0.5);
                case 27  % Rainbow6
                    cmap = MatVisRender.buildRainbow(n, 6, 0.5);
                case 28  % Blue-Gray-Yellow (0 centered)
                    cmap = MatVisRender.buildDiverging(n, 'BlueGrayYellow');
                case 29  % Blue-Gray-Red (0 centered)
                    cmap = MatVisRender.buildDiverging(n, 'BlueGrayRed');
                case 30  % Green-Gray-Red (0 centered)
                    cmap = MatVisRender.buildDiverging(n, 'GreenGrayRed');
                case 31  % Magenta-Gray-Green (0 centered)
                    cmap = MatVisRender.buildDiverging(n, 'MagentaGrayGreen');
                otherwise
                    cmap = gray(n);
            end
            cmap = max(0, min(1, cmap));
        end

    end

    methods (Static, Access = private)

        function cmap = buildHue1to2(n, r, g, b)
            % Builds a ramp: black -> [r,g,b] -> white
            half = floor(n/2);
            rest = n - half;
            ramp1 = linspace(0, 1, half)';
            ramp2 = linspace(0, 1, rest)';
            lo = [r*ramp1, g*ramp1, b*ramp1];
            hi = [r + (1-r)*ramp2, g + (1-g)*ramp2, b + (1-b)*ramp2];
            cmap = [lo; hi];
        end

        function cmap = buildRainbow(n, fun_type, exp_val)
            % Replicates the colorMap(n, fun_type, exp) logic from original matVis
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
                    if col == 0
                        rgb = [0 0 1];
                    elseif col == 1
                        rgb = [1 0 0];
                    else
                        v = col^e;
                        rgb = [v v v];
                    end
                case 1  % black,blue,cyan,green,yellow,red,white
                    if col < 1/6
                        rgb = [0, 0, (col*6)^e];
                    elseif col < 2/6
                        rgb = [0, (col*6-1)^e, 1];
                    elseif col < 3/6
                        rgb = [0, 1, (3-col*6)^e];
                    elseif col < 4/6
                        rgb = [(col*6-3)^e, 1, 0];
                    elseif col < 5/6
                        rgb = [1, (5-col*6)^e, 0];
                    else
                        rgb = [1, (col*6-5)^e, (col*6-5)^e];
                    end
                case 2  % black,blue,cyan,green,yellow,red,magenta,white
                    if col < 1/7
                        rgb = [0, 0, (col*7)^e];
                    elseif col < 2/7
                        rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7
                        rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7
                        rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7
                        rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7
                        rgb = [1, 0, (col*7-5)^e];
                    else
                        rgb = [1, (col*7-6)^e, 1];
                    end
                case 3  % blue,cyan,green,yellow,red
                    if col < 1/4
                        rgb = [0, (col*4)^e, 1];
                    elseif col < 2/4
                        rgb = [0, 1, (2-col*4)^e];
                    elseif col < 3/4
                        rgb = [(col*4-2)^e, 1, 0];
                    else
                        rgb = [1, (4-col*4)^e, 0];
                    end
                case 4  % blue,cyan,green,yellow,red,magenta
                    if col < 1/5
                        rgb = [0, (col*5)^e, 1];
                    elseif col < 2/5
                        rgb = [0, 1, (2-col*5)^e];
                    elseif col < 3/5
                        rgb = [(col*5-2)^e, 1, 0];
                    elseif col < 4/5
                        rgb = [1, (4-col*5)^e, 0];
                    else
                        rgb = [1, 0, (col*5-4)^e];
                    end
                case 5  % white,blue,cyan,green,yellow,red,magenta,white
                    if col < 1/7
                        v = (1-col*7)^e;
                        rgb = [v, v, 1];
                    elseif col < 2/7
                        rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7
                        rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7
                        rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7
                        rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7
                        rgb = [1, 0, (col*7-5)^e];
                    else
                        rgb = [1, (col*7-6)^e, 1];
                    end
                case 6  % white,blue,cyan,green,yellow,red,magenta,black
                    if col < 1/7
                        v = (1-col*7)^e;
                        rgb = [v, v, 1];
                    elseif col < 2/7
                        rgb = [0, (col*7-1)^e, 1];
                    elseif col < 3/7
                        rgb = [0, 1, (3-col*7)^e];
                    elseif col < 4/7
                        rgb = [(col*7-3)^e, 1, 0];
                    elseif col < 5/7
                        rgb = [1, (5-col*7)^e, 0];
                    elseif col < 6/7
                        rgb = [1, 0, (col*7-5)^e];
                    else
                        v = (7-col*7)^e;
                        rgb = [v, 0, v];
                    end
                otherwise
                    rgb = [col, col, col];
            end
        end

        function cmap = buildDiverging(n, name)
            myGV = 0.9;
            cmap = zeros(n, 3);
            half = floor(n/2);
            rest = n - half;
            % negative side: blue -> gray
            cmap(1:half, 1) = linspace(0, myGV, half);
            cmap(1:half, 2) = linspace(0, myGV, half);
            cmap(1:half, 3) = linspace(1, myGV, half);
            % positive side: gray -> yellow (for Blue-Gray-Red as base)
            cmap(half+1:end, 1) = linspace(myGV, 1, rest);
            cmap(half+1:end, 2) = linspace(myGV, 0, rest);
            cmap(half+1:end, 3) = linspace(myGV, 0, rest);
            switch name
                case 'BlueGrayRed'
                    % already Blue-Gray-Red
                case 'BlueGrayYellow'
                    % R=R, G=R, B=B  =>  col(:,[1 1 3])
                    cmap = cmap(:, [1 1 3]);
                case 'GreenGrayRed'
                    % col(:,[1 3 2])
                    cmap = cmap(:, [1 3 2]);
                case 'MagentaGrayGreen'
                    % Blue-Gray-Yellow then swap col1 with col3
                    tmp = cmap(:, [1 1 3]);
                    tmp(:,1) = tmp(:,3);
                    cmap = tmp;
            end
        end

    end
end
