classdef MatVisModelTest < matlab.unittest.TestCase
    % MatVisModelTest  Unit tests for core/MatVisModel.
    %
    %   Run from the project root:
    %     results = runtests('tests/MatVisModelTest.m');
    %     disp(results)

    % ------------------------------------------------------------------
    %  Shared test data
    % ------------------------------------------------------------------
    properties (Constant)
        SmallData2D = reshape(1:24, 4, 6)           % 4x6 double
        SmallData3D = reshape(1:60, 3, 4, 5)        % 3x4x5 double
    end

    % ==================================================================
    %  Constructor defaults
    % ==================================================================
    methods (Test)
        function testConstructor2D_Size(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.Size, [4, 6]);
        end

        function testConstructor2D_DimNames(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.DimNames, {'Dim1', 'Dim2'});
        end

        function testConstructor2D_DimScale(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.DimScale{1}, 1:4);
            tc.verifyEqual(m.DimScale{2}, 1:6);
        end

        function testConstructor2D_DimUnits(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.DimUnits, {'', ''});
        end

        function testConstructor2D_CurrPosCenter(tc)
            m = MatVisModel(tc.SmallData2D);
            % round([4,6]/2) = [2,3]
            tc.verifyEqual(m.CurrPos, [2, 3]);
        end

        function testConstructor2D_ZoomRangeFullExtent(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.ZoomRange, [1, 4; 1, 6]);
        end

        function testConstructor2D_XYDim(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.YDim, 1);
            tc.verifyEqual(m.XDim, 2);
        end

        function testConstructor2D_Gamma(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.Gamma, 1.0);
        end

        function testConstructor2D_ColormapIdx(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.ColormapIdx, 1);
        end

        function testConstructor2D_PlotDims(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.PlotDims, [false, false]);
        end

        function testConstructor2D_Contrast(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyEqual(m.ContrastMin, 1.0);
            tc.verifyEqual(m.ContrastMax, 24.0);
        end

        function testConstructor3D_Size(tc)
            m = MatVisModel(tc.SmallData3D);
            tc.verifyEqual(m.Size, [3, 4, 5]);
        end

        function testConstructor3D_DimNames(tc)
            m = MatVisModel(tc.SmallData3D);
            tc.verifyEqual(m.DimNames, {'Dim1', 'Dim2', 'Dim3'});
        end

        function testConstructor3D_CurrPos(tc)
            m = MatVisModel(tc.SmallData3D);
            % round([3,4,5]/2) = [2,2,3] (using MATLAB round-half-away)
            expected = max(1, round([3, 4, 5] / 2));
            tc.verifyEqual(m.CurrPos, expected);
        end

        function testConstructor3D_ZoomRange(tc)
            m = MatVisModel(tc.SmallData3D);
            tc.verifyEqual(m.ZoomRange, [1, 3; 1, 4; 1, 5]);
        end

        function testConstructorRejectsNonNumeric(tc)
            tc.verifyError(@() MatVisModel('hello'), ?MException);
        end

        function testConstructorRejectsEmpty(tc)
            tc.verifyError(@() MatVisModel([]), ?MException);
        end
    end

    % ==================================================================
    %  XDim / YDim setters
    % ==================================================================
    methods (Test)
        function testSetXDimValid(tc)
            m = MatVisModel(tc.SmallData3D);
            m.XDim = 3;
            tc.verifyEqual(m.XDim, 3);
        end

        function testSetYDimValid(tc)
            m = MatVisModel(tc.SmallData3D);
            m.YDim = 3;
            tc.verifyEqual(m.YDim, 3);
        end

        function testSetXDimEqualYDimErrors(tc)
            m = MatVisModel(tc.SmallData3D);
            % YDim is 1; setting XDim=1 must error
            tc.verifyError(@() setXDim(m, 1), 'MatVisModel:dimConflict');
        end

        function testSetYDimEqualXDimErrors(tc)
            m = MatVisModel(tc.SmallData3D);
            % XDim is 2; setting YDim=2 must error
            tc.verifyError(@() setYDim(m, 2), 'MatVisModel:dimConflict');
        end

        function testSetXDimOutOfRangeErrors(tc)
            m = MatVisModel(tc.SmallData3D);
            tc.verifyError(@() setXDim(m, 4), 'MatVisModel:invalidDim');
        end

        function testSetYDimOutOfRangeErrors(tc)
            m = MatVisModel(tc.SmallData3D);
            tc.verifyError(@() setYDim(m, 0), 'MatVisModel:invalidDim');
        end
    end

    % ==================================================================
    %  CurrPos setter
    % ==================================================================
    methods (Test)
        function testCurrPosClampsHigh(tc)
            m = MatVisModel(tc.SmallData2D);
            m.CurrPos = [100, 200];
            tc.verifyEqual(m.CurrPos, [4, 6]);
        end

        function testCurrPosClampsLow(tc)
            m = MatVisModel(tc.SmallData2D);
            m.CurrPos = [-5, 0];
            tc.verifyEqual(m.CurrPos, [1, 1]);
        end

        function testCurrPosWrongLengthErrors(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyError(@() setCurrPos(m, [1, 2, 3]), ...
                'MatVisModel:sizeMismatch');
        end
    end

    % ==================================================================
    %  ZoomRange setter
    % ==================================================================
    methods (Test)
        function testZoomRangeClampsHigh(tc)
            m = MatVisModel(tc.SmallData2D);
            m.ZoomRange = [1, 999; 1, 999];
            tc.verifyEqual(m.ZoomRange, [1, 4; 1, 6]);
        end

        function testZoomRangeClampsLow(tc)
            m = MatVisModel(tc.SmallData2D);
            m.ZoomRange = [-5, 2; -5, 2];
            tc.verifyEqual(m.ZoomRange, [1, 2; 1, 2]);
        end

        function testZoomRangeEnsuresLoLeHi(tc)
            m = MatVisModel(tc.SmallData2D);
            % lo > hi after clamping should produce lo == hi
            m.ZoomRange = [3, 2; 5, 3];
            % lo should be clamped to hi
            tc.verifyTrue(all(m.ZoomRange(:, 1) <= m.ZoomRange(:, 2)));
        end

        function testZoomRangeSizeMismatchErrors(tc)
            m = MatVisModel(tc.SmallData2D);
            tc.verifyError(@() setZoomRange(m, [1, 4; 1, 6; 1, 3]), ...
                'MatVisModel:sizeMismatch');
        end
    end

    % ==================================================================
    %  Gamma setter
    % ==================================================================
    methods (Test)
        function testGammaClampsHigh(tc)
            m = MatVisModel(tc.SmallData2D);
            m.Gamma = 10;
            tc.verifyEqual(m.Gamma, 5.0);
        end

        function testGammaClampsLow(tc)
            m = MatVisModel(tc.SmallData2D);
            m.Gamma = 0;
            tc.verifyEqual(m.Gamma, 0.1);
        end

        function testGammaValidValue(tc)
            m = MatVisModel(tc.SmallData2D);
            m.Gamma = 2.5;
            tc.verifyEqual(m.Gamma, 2.5);
        end
    end

    % ==================================================================
    %  Data setter (resets Size and Contrast)
    % ==================================================================
    methods (Test)
        function testSetDataUpdatesSize(tc)
            m = MatVisModel(tc.SmallData2D);
            newData = zeros(10, 20);
            m.Data = newData;
            tc.verifyEqual(m.Size, [10, 20]);
        end

        function testSetDataUpdatesContrast(tc)
            m = MatVisModel(tc.SmallData2D);
            newData = ones(5, 5) * 42;
            m.Data = newData;
            tc.verifyEqual(m.ContrastMin, 42.0);
            tc.verifyEqual(m.ContrastMax, 42.0);
        end
    end

    % ==================================================================
    %  applyStartPar
    % ==================================================================
    methods (Test)
        function testApplyStartParGamma(tc)
            m = MatVisModel(tc.SmallData3D);
            sp.gamma = 2.0;
            m.applyStartPar(sp);
            tc.verifyEqual(m.Gamma, 2.0);
        end

        function testApplyStartParCmap(tc)
            m = MatVisModel(tc.SmallData3D);
            sp.cmap = 5;
            m.applyStartPar(sp);
            tc.verifyEqual(m.ColormapIdx, 5);
        end

        function testApplyStartParXySel(tc)
            m = MatVisModel(tc.SmallData3D);
            sp.xySel = [3, 1];   % xDim=3, yDim=1
            m.applyStartPar(sp);
            tc.verifyEqual(m.XDim, 3);
            tc.verifyEqual(m.YDim, 1);
        end

        function testApplyStartParCurrPos(tc)
            m = MatVisModel(tc.SmallData3D);
            sp.currPos = [1, 2, 3];
            m.applyStartPar(sp);
            tc.verifyEqual(m.CurrPos, [1, 2, 3]);
        end

        function testApplyStartParZoomVal(tc)
            m = MatVisModel(tc.SmallData3D);
            sp.zoomVal = [1, 2; 2, 3; 1, 4];
            m.applyStartPar(sp);
            tc.verifyEqual(m.ZoomRange, [1, 2; 2, 3; 1, 4]);
        end

        function testApplyStartParGammaClamped(tc)
            m = MatVisModel(tc.SmallData3D);
            sp.gamma = 99;
            m.applyStartPar(sp);
            tc.verifyEqual(m.Gamma, 5.0);
        end

        function testApplyStartParEmptyStructNoOp(tc)
            m = MatVisModel(tc.SmallData2D);
            original_gamma = m.Gamma;
            m.applyStartPar(struct());
            tc.verifyEqual(m.Gamma, original_gamma);
        end

        function testApplyStartParNonStructNoOp(tc)
            m = MatVisModel(tc.SmallData2D);
            original_gamma = m.Gamma;
            m.applyStartPar([]);
            tc.verifyEqual(m.Gamma, original_gamma);
        end
    end
end

% ------------------------------------------------------------------
%  Local helper wrappers (allow verifyError with assignment setters)
% ------------------------------------------------------------------
function setXDim(m, v),    m.XDim    = v; end
function setYDim(m, v),    m.YDim    = v; end
function setCurrPos(m, v), m.CurrPos = v; end
function setZoomRange(m,v),m.ZoomRange = v; end
