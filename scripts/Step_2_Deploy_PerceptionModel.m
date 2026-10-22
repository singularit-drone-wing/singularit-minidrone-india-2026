%   Copyright 2026 The MathWorks, Inc.


Simulation = false;
project = simulinkproject;
projectRoot = project.RootFolder;

% --- Ensure PerceptionAndGuidance is open and configured for Pixhawk 6C ---
guidanceModelPath = fullfile(projectRoot, 'perception', 'PerceptionAndGuidance.slx');
open_system(guidanceModelPath);

% Set the hardware board for PerceptionAndGuidance to Pixhawk 6C
set_param('PerceptionAndGuidance', 'HardwareBoard', 'Raspberry Pi');
set_param('PerceptionAndGuidance', 'SimulationCommand', 'update'); % Ensures variant is set
