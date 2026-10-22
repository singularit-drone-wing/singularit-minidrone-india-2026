function Step_1_Deploy_Controller(options)
%Step_1_Deploy_Controller Build and deploy PX4 firmware to Pixhawk via Raspberry Pi
%
%   Step_1_Deploy_Controller() builds the default flight control model
%   and uploads firmware to Pixhawk through Raspberry Pi companion computer.
%
%   Step_1_Deploy_Controller(Name=Value) specifies additional options.
%
%   Name-Value Arguments:
%       ModelName         - Simulink model name (default: 'flightControlSystem')
%       HardwareBoard     - Target hardware (default: 'PX4 Pixhawk 6c')
%       PX4Config         - PX4 configuration (default: 'px4_fmu-v6c_default')
%       RaspiModelName    - Raspberry Pi model name (default: 'Raspi')
%       UpdateModelOnly   - Only update model without building (default: false)
%
%   Example:
%       Step_1_Deploy_Controller(ModelName='myController', PX4Config='px4_fmu-v5_default');
%
%   See also: uploadFirmwareToCompanionComputer
%
%   Copyright 2026 The MathWorks, Inc.

    arguments
        options.ModelName (1,1) string = "flightControlSystem"
        options.HardwareBoard (1,1) string = "PX4 Pixhawk 6c"
        options.PX4Config (1,1) string = "px4_fmu-v6c_default"
        options.RaspiModelName (1,1) string = "Raspi"
        options.UpdateModelOnly (1,1) logical = false
    end

    logMsg('=== Step_1_Deploy_Controller started ===');
    logMsg('Configuration: Model=%s, Board=%s, PX4Config=%s', ...
        options.ModelName, options.HardwareBoard, options.PX4Config);

    try
        % --- Phase 1: Project context ---
        logMsg('Phase 1: Getting project context...');
        projectInfo = getProjectContext();
        logMsg('Project root: %s', projectInfo.RootFolder);

        % --- Phase 2: Open and configure model ---
        logMsg('Phase 2: Locating and configuring model...');
        modelPath = locateModel(projectInfo.RootFolder, options.ModelName);
        openAndConfigureModel(modelPath, options.ModelName, options.HardwareBoard);
        logMsg('Model configured for %s.', options.HardwareBoard);

        if options.UpdateModelOnly
            logMsg('UpdateModelOnly=true — skipping build and upload.');
            fprintf('\nModel update complete. No build or upload performed.\n');
            return;
        end

        % --- Phase 3: Build firmware ---
        logMsg('Phase 3: Building PX4 firmware...');
        fprintf('Building PX4 firmware for %s...\n', options.HardwareBoard);
        buildModel(options.ModelName);
        logMsg('Build completed successfully.');

        % --- Phase 4: Locate generated firmware ---
        logMsg('Phase 4: Locating generated firmware...');
        firmwareInfo = locateFirmware(options.PX4Config);
        logMsg('Firmware located: %s', firmwareInfo.Path);

        % --- Phase 5: Ensure px_uploader.py is on RPi ---
        logMsg('Phase 5: Ensuring px_uploader.py is on Raspberry Pi...');
        px4BaseDir = codertarget.pixhawk.internal.getPX4BaseDir();
        % Uses folderExistsRobust to handle WSL UNC paths with $ (e.g. \\wsl$\ubuntu\...)
        if isempty(px4BaseDir) || ~folderExistsRobust(px4BaseDir)
            error('Step_1_Deploy_Controller:PX4BaseDirNotFound', ...
                ['PX4 base directory not found or not configured.\n' ...
                'Action: Ensure the PX4 Toolchain support package is installed in Simulink.\n' ...
                'Run: codertarget.pixhawk.internal.getPX4BaseDir() to verify.']);
        end
        firmwareUploadScript = fullfile(px4BaseDir, 'Tools', 'px_uploader.py');
        if ~fileExistsRobust(firmwareUploadScript)
            error('Step_1_Deploy_Controller:PxUploaderNotFound', ...
                ['px_uploader.py not found at: %s\n' ...
                'Action: Verify PX4 Toolchain installation. ' ...
                'Expected location: <PX4_BASE>/Tools/px_uploader.py'], ...
                firmwareUploadScript);
        end

        islastpi64bit = isequal(getfield(getpref('Hardware_Last_Connected_RaspberryPi'),'Bitness'),64);
        if islastpi64bit
            strName = 'RaspberryPi64bit';
        else
            strName = 'RaspberryPi';
        end
        hb = rpiutils.linux.remotebuild.BoardParameters(strName);
        remoteDir = ['/home/',hb.getParam('username')];

        uploadFirmwareToCompanionComputer.ensurePxUploaderOnRpi(firmwareUploadScript, remoteDir);
        logMsg('px_uploader.py ready on RPi.');

        % --- Phase 6: Upload firmware to Pixhawk via RPi ---
        logMsg('Phase 6: Uploading firmware to Pixhawk via Raspberry Pi...');
        fprintf('Uploading firmware to Pixhawk via Raspberry Pi...\n');
        [uploadStatus, uploadMsg] = uploadFirmwareToCompanionComputer.upload(...
            firmwareInfo.Path, firmwareInfo.Config, ...
            RaspiModelName=options.RaspiModelName);

        % --- Phase 7: Report results ---
        reportUploadResults(uploadStatus, uploadMsg);
        logMsg('=== Step_1_Deploy_Controller finished ===');

    catch ME
        logMsg('FATAL ERROR: %s', ME.message);
        % Print full stack trace for debugging
        for k = 1:length(ME.stack)
            logMsg('  in %s (line %d)', ME.stack(k).name, ME.stack(k).line);
        end
        fprintf('\n--- Deployment Failed ---\n');
        fprintf('Error: %s\n', ME.message);
        fprintf('Action: Review the error above and the timestamped log output.\n');
        fprintf('  Common issues:\n');
        fprintf('  - Simulink project not open: open the .prj file first\n');
        fprintf('  - Model not found: check the ModelName parameter\n');
        fprintf('  - Build failure: check Simulink model for errors\n');
        fprintf('  - RPi not reachable: check network and power\n');
        fprintf('  - Pixhawk not connected: check USB cable to RPi\n\n');
        % Re-throw so callers can catch programmatically
        rethrow(ME);
    end
end

%% Helper Functions

function projectInfo = getProjectContext()
    %getProjectContext Get current Simulink project information
    try
        proj = simulinkproject();
        projectInfo.RootFolder = proj.RootFolder;
        projectInfo.Name = proj.Name;
    catch
        error('Step_1_Deploy_Controller:NoProject', ...
            ['No Simulink project is currently loaded.\n' ...
            'Action: Open the project first by double-clicking the .prj file ' ...
            'or running: openProject(''path/to/project'')']);
    end
end

function modelPath = locateModel(projectRoot, modelName)
    %locateModel Find model file in project
    modelFileName = sprintf('%s.slx', modelName);
    modelPath = fullfile(projectRoot, 'controller', modelFileName);

    if ~fileExistsRobust(modelPath)
        error('Step_1_Deploy_Controller:ModelNotFound', ...
            ['Model not found: %s\n' ...
            'Action: Verify the model exists in the controller/ folder ' ...
            'and check the ModelName parameter.'], modelPath);
    end
end

function openAndConfigureModel(modelPath, modelName, hardwareBoard)
    %openAndConfigureModel Open model and configure for PX4 target
    assignin('base', 'Simulation', false);

    % Load model if not already loaded
    if ~bdIsLoaded(modelName)
        try
            open_system(modelPath);
        catch ME
            error('Step_1_Deploy_Controller:ModelOpenFailed', ...
                ['Could not open model: %s\n' ...
                'Detail: %s\n' ...
                'Action: Check that required toolboxes are installed and licensed.'], ...
                modelPath, ME.message);
        end
    end

    % Update model diagram (resolves variants, etc.)
    set_param(modelName, 'SimulationCommand', 'update');

    % Configure hardware target
    set_param(modelName, 'HardwareBoard', char(hardwareBoard));

    % Ensure code generation is enabled (not code-gen-only)
    configSet = getActiveConfigSet(modelName);
    set_param(configSet, 'GenCodeOnly', 'off');
end

function buildModel(modelName)
    %buildModel Build Simulink model for embedded target
    try
        slbuild(modelName);
    catch ME
        error('Step_1_Deploy_Controller:BuildFailed', ...
            ['Model build failed for "%s".\n' ...
            'Detail: %s\n' ...
            'Action:\n' ...
            '  1. Open the model and check for unresolved references.\n' ...
            '  2. Ensure all required toolboxes are installed.\n' ...
            '  3. Check the Diagnostic Viewer for detailed errors.'], ...
            modelName, ME.message);
    end
end

function firmwareInfo = locateFirmware(px4Config)
    %locateFirmware Locate generated firmware file
    %   First tries the exact PX4Config name. If not found, auto-detects
    %   any .px4 file in the build directory (the build output name may
    %   differ from the config name, e.g. px4_fmu-v6c_multicopter vs
    %   px4_fmu-v6c_default).
    buildDir = px4.internal.util.CommonUtility.getPX4FirmwareBuildDir();
    firmwareFileName = sprintf('%s.px4', px4Config);
    firmwarePath = fullfile(buildDir, firmwareFileName);

    % Uses fileExistsRobust — the build dir is often under a WSL UNC path
    % (e.g. \\wsl$\ubuntu\home\px4\...) where isfile() fails on the $ character.
    if ~fileExistsRobust(firmwarePath)
        % Auto-detect: search for any .px4 file in the build directory
        logMsg('Specified firmware "%s" not found. Searching for .px4 files in build dir...', firmwareFileName);
        px4Files = dir(fullfile(buildDir, '*.px4'));
        if numel(px4Files) == 1
            firmwarePath = fullfile(buildDir, px4Files(1).name);
            [~, detectedConfig] = fileparts(px4Files(1).name);
            logMsg('Auto-detected firmware: %s (config: %s)', px4Files(1).name, detectedConfig);
            px4Config = detectedConfig;
        elseif numel(px4Files) > 1
            names = strjoin({px4Files.name}, ', ');
            error('Step_1_Deploy_Controller:MultipleFirmwareFiles', ...
                ['Multiple .px4 files found in build directory: %s\n' ...
                'Files: %s\n' ...
                'Action: Specify the correct PX4Config parameter to disambiguate.'], ...
                buildDir, names);
        else
            error('Step_1_Deploy_Controller:FirmwareNotFound', ...
                ['No .px4 firmware file found in build directory: %s\n' ...
                'Looked for: %s\n' ...
                'Action:\n' ...
                '  1. Verify the build completed without errors.\n' ...
                '  2. Check that PX4Config "%s" matches your hardware.\n' ...
                '  3. Look in build directory: %s\n' ...
                'Note: If the path contains $ (e.g. \\wsl$\\...), this is handled automatically.'], ...
                buildDir, firmwareFileName, px4Config, buildDir);
        end
    end

    firmwareInfo.Path = firmwarePath;
    firmwareInfo.Config = px4Config;
end

function reportUploadResults(uploadStatus, uploadMsg)
    %reportUploadResults Display upload results to user
    %   uploadStatus: true = success, false = failure

    fprintf('\n');
    if uploadStatus
        fprintf('=== FIRMWARE UPLOAD SUCCESSFUL ===\n');
        if ~isempty(uploadMsg)
            fprintf('%s\n', uploadMsg);
        end
        fprintf('\nNext steps:\n');
        fprintf('  1. Verify Pixhawk LEDs indicate normal boot.\n');
        fprintf('  2. Connect via QGroundControl to confirm firmware version.\n');
        fprintf('  3. Run Step_2_Deploy_PerceptionModel if needed.\n');
    else
        fprintf('=== FIRMWARE UPLOAD FAILED ===\n');
        fprintf('%s\n', uploadMsg);
        fprintf('\nTroubleshooting:\n');
        fprintf('  1. Review the timestamped log messages above for the failure point.\n');
        fprintf('  2. Address the suggested action in the error message.\n');
        fprintf('  3. Re-run Step_1_Deploy_Controller after fixing the issue.\n');
    end
    fprintf('\n');
end

function logMsg(fmt, varargin)
    %logMsg Print a timestamped log message
    timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<TNOW1,DATST>
    fprintf('[%s] %s\n', timestamp, sprintf(fmt, varargin{:}));
end

function tf = fileExistsRobust(filePath)
    %fileExistsRobust Check if a file exists, handling WSL UNC paths with $
    %
    %   tf = fileExistsRobust(filePath)
    %
    %   MATLAB's isfile() fails on Windows UNC paths containing $ (e.g.
    %   \\wsl$\ubuntu\...) because the internal Java-based path resolution
    %   mishandles the $ character. This function uses dir() as the primary
    %   check for $ paths, which calls the Windows FindFirstFile API directly
    %   and works correctly with all UNC paths including WSL $ shares.
    %
    %   Falls back to isfile() for non-$ paths to maintain standard behavior.
    %
    %   Supports: local Windows paths, WSL UNC paths (\\wsl$\...),
    %   standard UNC paths (\\server\share\...), and Linux paths.

    filePath = char(filePath);

    if contains(filePath, '$')
        % Use dir() for paths containing $ — immune to Java path bugs
        d = dir(filePath);
        tf = ~isempty(d) && ~d(1).isdir;
    else
        tf = isfile(filePath);
    end
end

function tf = folderExistsRobust(folderPath)
    %folderExistsRobust Check if a folder exists, handling WSL UNC paths with $
    %
    %   tf = folderExistsRobust(folderPath)
    %
    %   Same rationale as fileExistsRobust — uses dir() for paths with $
    %   to avoid MATLAB's isfile/isfolder Java-path resolution issues on
    %   WSL UNC paths like \\wsl$\ubuntu\...
    %
    %   Supports: local Windows paths, WSL UNC paths (\\wsl$\...),
    %   standard UNC paths, and Linux paths.

    folderPath = char(folderPath);

    if contains(folderPath, '$')
        % Use dir() for paths containing $
        d = dir(folderPath);
        tf = ~isempty(d) && d(1).isdir;
    else
        tf = isfolder(folderPath);
    end
end
