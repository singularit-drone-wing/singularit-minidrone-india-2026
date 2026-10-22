classdef ImageProcess< matlab.System & coder.ExternalDependency
    
    % Image conversion reads the image data in C and
    % outputs the required channel as per the mask for code generation.
    % In simulation mode, the block reads the Y1UY2V data coming from the
    % asbquadcopter model and outputs the required color channels.

    % Copyright 2018-2026 The MathWorks, Inc.
    
    %#codegen
    
    properties(Nontunable)
        
        %Output color space
        ImageFormat = 'RGB';
    end
    
    properties (Hidden, Transient, Constant)
        % this StringSet object creates a drop-down menu
        ImageFormatSet = matlab.system.StringSet({...
            'RGB', ...
            'YUV' ...
            });
    end
    
    properties(Nontunable)
        %Output R Channel
        R (1, 1) logical = true;
        %Output Y Channel
        Y (1, 1) logical = true;
        %Output G Channel
        G (1, 1) logical = false;
        %Output U Channel
        U (1, 1) logical = false;
        %Output B Channel
        B (1, 1) logical = false;
        %Output V Channel
        V (1, 1) logical = false;
        
    end
    
    methods(Access = public)
        function out = ImageProcess()
            coder.allowpcode('plain');
        end
    end
    
    methods(Access = protected)
        
        function validatePropertiesImpl(obj)
            isRGB = isequal(obj.ImageFormat,'RGB');
            if ~isRGB && (obj.Y + obj.U + obj.V) < 1
            elseif isRGB && (obj.R + obj.G + obj.B) < 1
            end
        end
        
        function validateInputsImpl(~,image)
            if size(image,1) ~= 4 || size(image,2) ~= 9600
            end
        end
        
        function setupImpl(~)
            if coder.target ('Rtw')
                coder.cinclude('rsedu_image.h');
            end
        end
        
        function varargout = stepImpl(obj, image)
            isRGB = isequal(obj.ImageFormat,'RGB');
            imageBuff_1 = zeros(120, 160, 'uint8'); % Initialize the variables to 120*160, the size of each channel.
            imageBuff_2 = zeros(120, 160, 'uint8');
            imageBuff_3 = zeros(120, 160, 'uint8');
            
            if coder.target('MATLAB') %For Simulation
                if ~isRGB       % if YUV channel is chosen
                    if obj.Y    % if Y channel is chosen in the mask
                        imageBuff_1(1:2:end) = image(1,:); %copy the Y1 and Y2 data
                        imageBuff_1(2:2:end) = image(3,:);
                    end
                    if obj.U
                        imageBuff_2(1:2:end) = image(2,:); %copy the U data to two consecutive pixels.
                        imageBuff_2(2:2:end) = image(2,:);
                    end
                    if obj.V
                        imageBuff_3(1:2:end) = image(4,:); %copy the V data to two consecutive pixels.
                        imageBuff_3(2:2:end) = image(4,:);
                    end
                else      %else if RGB output is chosen...
                    imageBuff_1(1:2:end) = image(1,:); %copy the Y1UY2V data to the YUV channel buffers.
                    imageBuff_1(2:2:end) = image(3,:);
                    
                    imageBuff_2(1:2:end) = image(2,:);
                    imageBuff_2(2:2:end) = image(2,:);
                    
                    imageBuff_3(1:2:end) = image(4,:);
                    imageBuff_3(2:2:end) = image(4,:);
                    
                    % Convert the image from YUV to RGB
                    C = double(imageBuff_1) - 16;
                    D = double(imageBuff_2) - 128;
                    E = double(imageBuff_3) - 128;
                    
                    r = uint8((298*C+409*E+128)/256);
                    g = uint8((298*C-100*D-208*E+128)/256);
                    b = uint8((298*C+516*D+128)/256);
                    
                    %finally copy the converted channels back to the
                    %buffer, which will be outputted later.
                    if obj.R
                        imageBuff_1 = r;
                    end
                    if obj.G
                        imageBuff_2 = g;
                    end
                    if obj.B
                        imageBuff_3 = b;
                    end
                end
            end
            
            if coder.target ('Rtw') % for code generation
                if isRGB
                    coder.ceval('MW_Build_RGB', coder.rref(image),coder.wref(imageBuff_1),coder.wref(imageBuff_2),coder.wref(imageBuff_3));
                else
                    coder.ceval('MW_Build_YUV', coder.rref(image),coder.wref(imageBuff_1),coder.wref(imageBuff_2),coder.wref(imageBuff_3));
                end
            end
            
            %finally copy the data to the output buffers.
            outNo = 1;
            if isRGB
                if obj.R
                    varargout{outNo} = imageBuff_1;
                    outNo = outNo + 1;
                end
                if obj.G
                    varargout{outNo} = imageBuff_2;
                    outNo = outNo + 1;
                end
                if obj.B
                    varargout{outNo} = imageBuff_3;
                end
            else
                if obj.Y
                    varargout{outNo} = imageBuff_1;
                    outNo = outNo + 1;
                end
                if obj.U
                    varargout{outNo} = imageBuff_2;
                    outNo = outNo + 1;
                end
                if obj.V
                    varargout{outNo} = imageBuff_3;
                end
            end
            
        end
        
        function resetImpl(~)
            % Initialize / reset discrete-state properties
        end
        
        % getInputNamesImpl
        function inputName = getInputNamesImpl(~)
            inputName = 'In';
        end
        
        function varargout = getOutputNamesImpl(obj)
            isRGB = isequal(obj.ImageFormat,'RGB');
            outNo = 1;
            if isRGB
                if obj.R
                    varargout{outNo} = 'R';
                    outNo = outNo + 1;
                end
                if obj.G
                    varargout{outNo} = 'G';
                    outNo = outNo + 1;
                end
                if obj.B
                    varargout{outNo} = 'B';
                end
            else
                if obj.Y
                    varargout{outNo} = 'Y';
                    outNo = outNo + 1;
                end
                if obj.U
                    varargout{outNo} = 'U';
                    outNo = outNo + 1;
                end
                if obj.V
                    varargout{outNo} = 'V';
                end
            end
        end
        
        function varargout = getOutputSizeImpl(~)
            varargout{1} = [120 160];
            varargout{2} = [120 160];
            varargout{3} = [120 160];
        end
        
        function OutputNum = getNumOutputsImpl(obj)
            isRGB = isequal(obj.ImageFormat,'RGB');
            
            if isRGB
                OutputNum = obj.R + obj.G + obj.B;
            else
                OutputNum = obj.Y + obj.U + obj.V;
            end
        end
        
        function varargout = isOutputFixedSizeImpl(~)
            varargout{1} = true;
            varargout{2} = true;
            varargout{3} = true;
        end
        
        function InputNum = getNumInputsImpl(~)
            %Specifying the number of inputs for the block
            InputNum = 1;
        end
        
        function varargout = getOutputDataTypeImpl(~)
            varargout{1} = 'uint8';
            varargout{2} = 'uint8';
            varargout{3} = 'uint8';
        end
        
        function varargout = isOutputComplexImpl(~)
            varargout{1} = false;
            varargout{2} = false;
            varargout{3} = false;
        end
        
        function flag = isInactivePropertyImpl(obj,propertyName)
            isRGB = isequal(obj.ImageFormat,'RGB');
            
            if strcmp(propertyName,'R')
                flag = ~isRGB;
            elseif strcmp(propertyName,'G')
                flag = ~isRGB;
            elseif strcmp(propertyName,'B')
                flag = ~isRGB;
            elseif strcmp(propertyName,'Y')
                flag = isRGB;
            elseif strcmp(propertyName,'U')
                flag = isRGB;
            elseif strcmp(propertyName,'V')
                flag = isRGB;
            else
                flag = false;
            end
        end
        
        
        function string = getOutportNames(obj)
            string = '';
            portNo = 1;
            isRGB = strcmp(obj.ImageFormat,'RGB');
            
            if isRGB
                if obj.R
                    string = [string 'port_label(''output'',' num2str(portNo) ', ''R'');'];
                    portNo = portNo + 1;
                end
                if obj.G
                    string = [string 'port_label(''output'',' num2str(portNo) ', ''G'');'];
                    portNo = portNo + 1;
                end
                if obj.B
                    string = [string 'port_label(''output'',' num2str(portNo) ', ''B'');'];
                end
            else
                if obj.Y
                    string = [string 'port_label(''output'',' num2str(portNo) ', ''Y'');'];
                    portNo = portNo + 1;
                end
                if obj.U
                    string = [string 'port_label(''output'',' num2str(portNo) ', ''U'');'];
                    portNo = portNo + 1;
                end
                if obj.V
                    string = [string 'port_label(''output'',' num2str(portNo) ', ''V'');'];
                end
            end
        end
        
    end
    
    methods(Static, Access = protected)
        
        function simMode = getSimulateUsingImpl(~)
            simMode = 'Interpreted execution';
        end
        
        function flag = showSimulateUsingImpl
            flag = false;
        end
       
    end
    
    methods (Static)
        function name = getDescriptiveName(~)
            name = 'Parrot Image Conversion';
        end
        
        function tf = isSupportedContext(~)
			tf=true;
        end
        
        function updateBuildInfo(buildInfo,ctx)
        end
    end

    methods(Static, Access=protected)
		function [groups, PropertyList] = getPropertyGroupsImpl
			% Example: all properties in a single group
			PropertyList = {'ImageFormat', 'R', 'G', 'B', 'Y', 'U', 'V'};
			groups = matlab.system.display.Section( ...
				'Title', 'Parameters', ...
				'PropertyList', PropertyList);
		end
    end
end
