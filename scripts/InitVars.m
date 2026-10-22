%

%   Copyright 2026 The MathWorks, Inc.

%Based on the quadcopter model used in jMAVSim

Ixx = 0.003; % Kgm^2 (estimated)
Iyy = 0.003;
Izz = 0.0046;

inertia = diag([Ixx, Iyy, Izz]);

mass = 0.7; %Kg
g = 9.81; %m/s^2

armLength = 0.125; % ~0.177 m

rotorThrustMax = 6.2; %N

rotorTorqueMax = 0.3;%Nm

rotorTimeConst = 0.005;% time constant of rotor (motor + propeller)

%rotorOffset = [0 0 0]; % Rotors position offsets from Gravity center

dragCoeffMov = 0.05; %drag coefficient for linear motion of quadcopter
windVel = [0 0 0]';

% Contact model
contact.translation.spring = 3100;
contact.translation.damper = 100;
contact.translation.friction = 0.5;
contact.translation.vd = 0.02;
contact.translation.maxFriction = 20;
contact.translation.maxNormal = 80;

contact.rotation.spring = 2;
contact.rotation.damper = 1;
contact.rotation.friction = 0.03;
control.rotation.maxMoment = 0.1;
control.rotation.friction = 0.025;
control.rotation.vd = 0.2;

% Initial states
init.equilibriumZ =  mass*g/contact.translation.spring;
initData = struct();
initFilePath = fullfile(slproject.getCurrentProject().RootFolder,"initData.mat");

% Load or create initialization data
if isfile(initFilePath)
    initData = load(initFilePath);
    init.posNED = initData.posNED;
else
    init.posNED = [0, 0, init.equilibriumZ];
end

init.vb = [0 0 0]'; %m/s
init.euler = [0, 0, 0]'; %Roll Pitch Yaw Rads
init.angRates = [0, 0, 0]; %rad/s

%Computed from above values
% Quadrotor X
if ~exist('frameType', 'var') || isempty(frameType)
	frameType = "QuadX";
end

if(frameType == "QuadX")
	rotorPositions = zeros(3,4);
	axisD = armLength;
	rotorPositions(:,1) = [axisD, axisD, 0]';
	rotorPositions(:,2) = [-axisD, -axisD, 0]';
	rotorPositions(:,3) = [-axisD, axisD, 0]';
	rotorPositions(:,4) = [axisD, -axisD, 0]';
	rotorDir = [-1, -1, 1, 1]; %rotation direction. +ve = clockwise

	NoOfRotors = 4;
end

if(frameType == "Quad+")
	rotorPositions = zeros(3,4);
	axisD = armLength;
	rotorPositions(:,3) = [ 0,  axisD, 0]'; % Front
	rotorPositions(:,4) = [ 0, -axisD, 0]'; % Rear
	rotorPositions(:,1) = [-axisD, 0, 0]';  % Left
	rotorPositions(:,2) = [ axisD, 0, 0]';  % Right
	rotorDir = [-1, -1, 1, 1]; % CW, CCW, CW, CCW

	NoOfRotors = 4;
end

if(frameType == "QuadH")

	a = armLength;
	b = armLength * 0.5; % H frame, y shorter than x
	% Rotor order: FL, FR, RL, RR
	rotorPositions = zeros(3,4);
	rotorPositions(:,1) = [ a,  b, 0]'; % FL
	rotorPositions(:,2) = [ -a,  -b, 0]'; % FR
	rotorPositions(:,3) = [-a,  b, 0]'; % RL
	rotorPositions(:,4) = [ a, -b, 0]'; % RR

	% Rotor directions: [CW, CCW, CCW, CW] (typical for H)
	rotorDir = [-1, -1, 1, 1];

	NoOfRotors = 4;
end

if(frameType == "Hexa+")
	rotorPositions = zeros(3,6);
	axisD = armLength;

	% Precompute constants
	s60 = sqrt(3)/2;  % sin(60°)
	c60 = 1/2;        % cos(60°)

	rotorPositions(:,1) = [0,      axisD,         0]';                % Front (1)
	rotorPositions(:,2) = [0,     -axisD,         0]';                % Rear  (2)
	rotorPositions(:,3) = [-axisD*s60, -axisD*c60, 0]';               % Rear-Left (3)
	rotorPositions(:,4) = [ axisD*s60,  axisD*c60, 0]';               % Front-Right (4)
	rotorPositions(:,5) = [-axisD*s60,  axisD*c60, 0]';               % Front-Left (5)
	rotorPositions(:,6) = [ axisD*s60, -axisD*c60, 0]';     % Rear-Right (6)

	% Rotor directions: 1 for CW, -1 for CCW (from image)
	rotorDir = [1, -1, 1, -1, -1, 1];
	NoOfRotors = 6;
end

NoOfRotorsSimulation = 4;

if(frameType == "HexaX")
	rotorPositions = zeros(3,6);

	s30 = 0.5;
	c30 = sqrt(3)/2;

	rotorPositions(:,5) = [ axisD*s30,  axisD*c30, 0]';  % Front-Right  (1, 30°)
	rotorPositions(:,1) = [ axisD,      0,         0]';  % Right        (2, 90°)
	rotorPositions(:,3) = [-axisD*s30,  axisD*c30, 0]';  % Rear-Right   (3, 150°)
	rotorPositions(:,6) = [-axisD*s30, -axisD*c30, 0]';  % Rear-Left    (4, 210°)
	rotorPositions(:,2) = [-axisD,     0,          0]';  % Left         (5, 270°)
	rotorPositions(:,4) = [ axisD*s30, -axisD*c30, 0]';  % Front-Left   (6, 330°)

	% Rotor directions: 1 for CW, -1 for CCW (standard Hexa X)
	rotorDir = [1, -1, 1, -1, -1, 1];
	NoOfRotors = 6;
end

%Reference location: Zurich
% This is the home position also

ref_lat = 473977420e-7;
ref_lon = 85455940e-7;
ref_height = 488;

% Sample Time of Plant and Controller (100 Hz)
SampleTime = 0.001;
Sim3dVisualisationSampleTime = 0.1;

%% UAV Dynamics Data Serialization Constants

%Gain to convert m to mm
m_to_mm = 1000;

%Gain to convert uT to Gauss
uT_to_gauss = 0.01;

%Gain to convert m/s^2 to mg
ms2_to_mg = (1/9.80665)*1000;

%Gain to convert m/s to cm/s
ms_to_cms = 100;


for k = 1:15
	elems(k) = Simulink.BusElement;
end

names = {'X','Y','Z','yaw','pitch','roll','dx','dy','dz','p','q','r','ddx','ddy','ddz'};
for k = 1:15
	elems(k).Name = names{k};
	% elems(k).DataType = 'single'; % Explicitly set to single
end

UAVStatesBus = Simulink.Bus;
UAVStatesBus.Elements = elems;

posSetpoints(1) = Simulink.BusElement; posSetpoints(1).Name = 'X';
posSetpoints(2) = Simulink.BusElement; posSetpoints(2).Name = 'Y';
posSetpoints(3) = Simulink.BusElement; posSetpoints(3).Name = 'Z';
posSetpoints(4) = Simulink.BusElement; posSetpoints(4).Name = 'Yaw';
desiredSetpoint = Simulink.Bus;
desiredSetpoint.Elements = posSetpoints;

velSetpoints(1) = Simulink.BusElement; velSetpoints(1).Name = 'Vx';
velSetpoints(2) = Simulink.BusElement; velSetpoints(2).Name = 'Vy';
velSetpoints(3) = Simulink.BusElement; velSetpoints(3).Name = 'Vz';
desiredVelSetpoint = Simulink.Bus;
desiredVelSetpoint.Elements = velSetpoints;

AccSetpoints(1) = Simulink.BusElement; AccSetpoints(1).Name = 'Ax';
AccSetpoints(2) = Simulink.BusElement; AccSetpoints(2).Name = 'Ay';
AccSetpoints(3) = Simulink.BusElement; AccSetpoints(3).Name = 'Az';
desiredAccSetpoint = Simulink.Bus;
desiredAccSetpoint.Elements = AccSetpoints;

targetSetpoint(1) = Simulink.BusElement; targetSetpoint(1).Name = 'X';
targetSetpoint(2) = Simulink.BusElement; targetSetpoint(2).Name = 'Y';
targetSetpoint(3) = Simulink.BusElement; targetSetpoint(3).Name = 'Z';
targetSetpoint(4) = Simulink.BusElement; targetSetpoint(4).Name = 'Yaw';

targetSetpoint(5) = Simulink.BusElement; targetSetpoint(5).Name = 'Vx';
targetSetpoint(6) = Simulink.BusElement; targetSetpoint(6).Name = 'Vy';
targetSetpoint(7) = Simulink.BusElement; targetSetpoint(7).Name = 'Vz';

targetSetpoint(8) = Simulink.BusElement; targetSetpoint(8).Name = 'Ax';
targetSetpoint(9) = Simulink.BusElement; targetSetpoint(9).Name = 'Ay';
targetSetpoint(10) = Simulink.BusElement; targetSetpoint(10).Name = 'Az';

targetSetpoint(11) = Simulink.BusElement; targetSetpoint(11).Name = 'ID';

desiredTargetSetpoints = Simulink.Bus;
desiredTargetSetpoints.Elements = targetSetpoint;

statPos(1) = Simulink.BusElement; statPos(1).Name = 'X';
statPos(2) = Simulink.BusElement; statPos(2).Name = 'Y';
statPos(3) = Simulink.BusElement; statPos(3).Name = 'Z';
statPos(4) = Simulink.BusElement; statPos(4).Name = 'Yaw';
getcurrentState = Simulink.Bus;
getcurrentState.Elements = statPos;

PWMInput(1) = Simulink.BusElement; PWMInput(1).Name = 'M1';
PWMInput(2) = Simulink.BusElement; PWMInput(2).Name = 'M2';
PWMInput(3) = Simulink.BusElement; PWMInput(3).Name = 'M3';
PWMInput(4) = Simulink.BusElement; PWMInput(4).Name = 'M4';
PWMInput(5) = Simulink.BusElement; PWMInput(5).Name = 'M5';
PWMInput(6) = Simulink.BusElement; PWMInput(6).Name = 'M6';
PWMInput(7) = Simulink.BusElement; PWMInput(7).Name = 'M7';
PWMInput(8) = Simulink.BusElement; PWMInput(8).Name = 'M8';

setPWMInput = Simulink.Bus;
setPWMInput.Elements = PWMInput;

if ~exist('Simulation', 'var') || isempty(Simulation)
	Simulation = true;
end

TFinal = 100;

% Set Preferences to configure Wait-For-Host 
setpref('MW_SCI_CDC_WAIT_FOR_HOST','CheckEnabled','true');
setpref('MW_SCI_CDC_WAIT_FOR_HOST','OpenMaxRetries','100');