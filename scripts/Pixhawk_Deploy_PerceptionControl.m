%   Copyright 2026 The MathWorks, Inc.


Simulation = false;
project = simulinkproject;
projectRoot = project.RootFolder;
% --- Ensure PerceptionAndGuidance is open and configured for Pixhawk 6C ---
guidanceModelPath = fullfile(projectRoot, 'perception', 'PerceptionAndGuidance.slx');
open_system(guidanceModelPath);

% Set the hardware board for PerceptionAndGuidance to Pixhawk 6C
set_param('PerceptionAndGuidance', 'HardwareBoard', 'PX4 Pixhawk 6c');

% --- Now open PerceptionAndControl and update variant ---
controlModelPath = fullfile(projectRoot, 'perceptionAndController', 'PerceptionAndControl.slx');
open_system(controlModelPath);

set_param('PerceptionAndControl', 'SimulationCommand', 'update'); 
slbuild('PerceptionAndControl');
