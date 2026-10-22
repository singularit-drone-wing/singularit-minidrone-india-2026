classdef uploadFirmwareToCompanionComputer
%uploadFirmwareToCompanionComputer Upload PX4 firmware via Raspberry Pi companion computer
%
%   Static methods for transferring and flashing PX4 firmware to Pixhawk
%   through a Raspberry Pi companion computer.
%
%   Methods:
%       upload                - Transfer firmware and flash Pixhawk via RPi
%       ensurePxUploaderOnRpi - Ensure px_uploader.py is present on RPi
%       connectToRaspberryPi  - Create and validate RPi connection
%
%   Copyright 2026 The MathWorks, Inc.

	methods(Static)

		function [uploadStatus, uploadMsg] = upload(firmwareImagePath, ConfigCMake, options)
			%upload Upload PX4 firmware to Pixhawk via Raspberry Pi
			%
			%   [uploadStatus, uploadMsg] = upload(firmwareImagePath, ConfigCMake)
			%   [uploadStatus, uploadMsg] = upload(__, RaspiModelName='Raspi')
			%
			%   Inputs:
			%       firmwareImagePath - Full path to the local .px4 firmware file
			%       ConfigCMake       - PX4 config name (e.g. 'px4_fmu-v6c_default')
			%
			%   Name-Value Arguments:
			%       RaspiModelName - Simulink model on RPi (default: 'Raspi')
			%
			%   Outputs:
			%       uploadStatus - true if successful, false otherwise
			%       uploadMsg    - Descriptive result message

			arguments
				firmwareImagePath (1,1) string
				ConfigCMake (1,1) string
				options.RaspiModelName (1,1) string = "Raspi"
			end

			% Initialize outputs
			uploadStatus = false;
			uploadMsg = '';

			try
				% --- Step 1: Validate local firmware file ---
				% Uses fileExistsRobust to handle WSL UNC paths with $ (e.g. \\wsl$\ubuntu\...)
				uploadFirmwareToCompanionComputer.logMsg('Validating firmware file: %s', firmwareImagePath);
				if ~uploadFirmwareToCompanionComputer.fileExistsRobust(firmwareImagePath)
					uploadMsg = sprintf(['Firmware file not found: %s\n' ...
						'Action: Re-run the build step or check the PX4 config name.'], ...
						firmwareImagePath);
					uploadFirmwareToCompanionComputer.logMsg('ERROR: %s', uploadMsg);
					return;
				end

				% --- Step 2: Connect to Raspberry Pi ---
				uploadFirmwareToCompanionComputer.logMsg('Connecting to Raspberry Pi...');
				raspiObj = uploadFirmwareToCompanionComputer.connectToRaspberryPi();
				uploadFirmwareToCompanionComputer.logMsg('Connected to Raspberry Pi at %s.', raspiObj.DeviceAddress);

				% --- Step 3: Stop running Simulink model if needed ---
				modelWasRunning = false;
				if raspiObj.isModelRunning(options.RaspiModelName)
					uploadFirmwareToCompanionComputer.logMsg('Stopping model "%s" on RPi...', options.RaspiModelName);
					raspiObj.stopModel(options.RaspiModelName);
					modelWasRunning = true;
					pause(2); % Allow serial port release
				end

                islastpi64bit = isequal(getfield(getpref('Hardware_Last_Connected_RaspberryPi'),'Bitness'),64);
                if islastpi64bit
                    strName = 'RaspberryPi64bit';
                else
                    strName = 'RaspberryPi';
                end
                hb = rpiutils.linux.remotebuild.BoardParameters(strName);
                remoteDir = ['/home/',hb.getParam('username')];

				% --- Step 4: Transfer firmware file to RPi ---
				uploadFirmwareToCompanionComputer.logMsg('Transferring firmware to RPi:%s ...', remoteDir);
				try
					raspiObj.putFile(char(firmwareImagePath), remoteDir);
				catch transferME
					uploadMsg = sprintf(['Failed to transfer firmware to Raspberry Pi.\n' ...
						'Detail: %s\n' ...
						'Action: Check network connection and RPi disk space (run "df -h" on RPi).'], ...
						transferME.message);
					uploadFirmwareToCompanionComputer.logMsg('ERROR: %s', uploadMsg);
					return;
				end

				% Verify firmware file arrived on RPi
				% Use explicit POSIX path (fullfile uses backslashes on Windows
				% but RPi expects forward slashes for SSH commands)
				[~, fwName, fwExt] = fileparts(firmwareImagePath);
				remoteFirmware = [remoteDir '/' char(fwName) char(fwExt)];
				verifyResult = raspiObj.system(sprintf('ls %s 2>/dev/null', remoteFirmware));
				if isempty(strtrim(verifyResult))
					uploadMsg = sprintf(['Firmware file was not found on RPi after transfer: %s\n' ...
						'Action: Check RPi disk space and file permissions.'], remoteFirmware);
					uploadFirmwareToCompanionComputer.logMsg('ERROR: %s', uploadMsg);
					return;
				end
				uploadFirmwareToCompanionComputer.logMsg('Firmware transferred and verified on RPi.');

				% --- Step 5: Verify px_uploader.py is present on RPi ---
				uploaderCheck = raspiObj.system(sprintf('ls %s/px_uploader.py 2>/dev/null', remoteDir));
				if ~contains(uploaderCheck, 'px_uploader.py')
					uploadMsg = sprintf(['px_uploader.py not found on Raspberry Pi at %s.\n' ...
						'Action: Re-run deployment — the script will be auto-transferred.\n' ...
						'If the problem persists, manually copy px_uploader.py from PX4 Toolchain/Tools/ to RPi:%s.'], ...
						remoteDir, remoteDir);
					uploadFirmwareToCompanionComputer.logMsg('ERROR: %s', uploadMsg);
					return;
				end

				% --- Step 6: Verify Python is available on RPi ---
				pythonCheck = strtrim(raspiObj.system('which python3 2>/dev/null || which python 2>/dev/null'));
				if isempty(pythonCheck)
					uploadMsg = sprintf(['Python is not installed on the Raspberry Pi.\n' ...
						'Action: SSH into RPi and run: sudo apt-get install python3']);
					uploadFirmwareToCompanionComputer.logMsg('ERROR: %s', uploadMsg);
					return;
				end
				% Use whichever python was found
				pythonCmd = strtrim(pythonCheck);
				% If multiple lines, take the first
				lines = strsplit(pythonCmd, newline);
				pythonCmd = strtrim(lines{1});
				uploadFirmwareToCompanionComputer.logMsg('Using Python: %s', pythonCmd);

				% --- Step 7: Reboot Pixhawk into bootloader mode ---
				uploadFirmwareToCompanionComputer.logMsg('Rebooting Pixhawk into bootloader mode...');
				try
					raspiObj.system('stty -F /dev/ttyS0 57600; echo -e "\nreboot\n" > /dev/ttyS0;');
				catch rebootME
					uploadFirmwareToCompanionComputer.logMsg('WARNING: Reboot command returned: %s (may be normal)', rebootME.message);
				end

				% --- Step 8: Wait for Pixhawk bootloader USB port ---
				uploadFirmwareToCompanionComputer.logMsg('Waiting for Pixhawk bootloader USB port...');
				usbPort = '';
				maxRetries = 10;
				for attempt = 1:maxRetries
					pause(2);
					try
						usbPort = strtrim(raspiObj.system('ls /dev/ttyACM* 2>/dev/null'));
					catch
						usbPort = '';
					end
					if ~isempty(usbPort)
						break;
					end
					uploadFirmwareToCompanionComputer.logMsg('  Attempt %d/%d: Pixhawk USB port not yet available...', attempt, maxRetries);
				end

				if isempty(usbPort)
					uploadFirmwareToCompanionComputer.logMsg('ERROR: Pixhawk USB port not detected. Connect the Px4 board and Retry Again.');
					% usbPort = '/dev/ttyACM0';
					return;
				end

				% Handle multiple ports — use the first one
				portLines = strsplit(usbPort, newline);
				usbPort = strtrim(portLines{1});
				uploadFirmwareToCompanionComputer.logMsg('Pixhawk detected on port: %s', usbPort);

				% --- Step 9: Flash firmware via px_uploader.py ---
				firmwareFile = sprintf('%s.px4', ConfigCMake);
				flashCmd = sprintf('cd %s && %s px_uploader.py --port %s %s 2>&1', ...
					remoteDir, pythonCmd, usbPort, firmwareFile);
				uploadFirmwareToCompanionComputer.logMsg('Flashing firmware: %s', flashCmd);

				try
					flashOutput = raspiObj.system(flashCmd);
				catch flashME
					uploadMsg = sprintf(['Firmware flashing command failed on Raspberry Pi.\n' ...
						'Detail: %s\n' ...
						'Action:\n' ...
						'  1. Check that Pixhawk is connected and in bootloader mode.\n' ...
						'  2. Verify px_uploader.py is not corrupted (re-transfer if needed).\n' ...
						'  3. Check RPi system logs: journalctl -xe'], ...
						flashME.message);
					uploadFirmwareToCompanionComputer.logMsg('ERROR: %s', uploadMsg);
					return;
				end

				uploadFirmwareToCompanionComputer.logMsg('Flash output:\n%s', flashOutput);

				% --- Step 10: Validate flash result ---
				if contains(flashOutput, 'error', 'IgnoreCase', true) && ...
						~contains(flashOutput, 'Erase', 'IgnoreCase', true)
					uploadMsg = sprintf(['Firmware flashing reported errors.\n' ...
						'Flash output:\n%s\n' ...
						'Action:\n' ...
						'  1. Check Pixhawk USB connection.\n' ...
						'  2. Power-cycle Pixhawk and retry.\n' ...
						'  3. If persistent, try a different USB cable.'], flashOutput);
					uploadFirmwareToCompanionComputer.logMsg('ERROR: %s', uploadMsg);
					return;
				end

				% --- Step 11: Verify Pixhawk restarts after flashing ---
				uploadFirmwareToCompanionComputer.logMsg('Waiting for Pixhawk to boot after flashing...');
				pixhawkBooted = false;
				for attempt = 1:5
					pause(3);
					try
						bootCheck = raspiObj.system('ls /dev/ttyACM* 2>/dev/null');
						if ~isempty(strtrim(bootCheck))
							pixhawkBooted = true;
							break;
						end
					catch
						% Port may momentarily disappear during reboot
					end
					uploadFirmwareToCompanionComputer.logMsg('  Attempt %d/5: Waiting for Pixhawk reboot...', attempt);
				end

				if ~pixhawkBooted
					uploadFirmwareToCompanionComputer.logMsg('WARNING: Pixhawk USB port not re-detected after flash.');
					uploadMsg = sprintf(['Firmware was flashed but Pixhawk may not have restarted properly.\n' ...
						'Flash output:\n%s\n' ...
						'Action:\n' ...
						'  1. Power-cycle the Pixhawk manually.\n' ...
						'  2. Check if /dev/ttyACM* appears on RPi (ssh in and run: ls /dev/ttyACM*).\n' ...
						'  3. If the port appears, the flash likely succeeded.'], flashOutput);
					% Still mark as success since the flash itself may have worked
					uploadStatus = true;
					return;
				end

				% --- Step 12: Restart Simulink model if it was running ---
				if modelWasRunning
					uploadFirmwareToCompanionComputer.logMsg('Restarting model "%s" on RPi...', options.RaspiModelName);
					pause(5); % Wait for PX4 to fully boot and create serial port
					try
						raspiObj.runModel(options.RaspiModelName);
						uploadFirmwareToCompanionComputer.logMsg('Model "%s" restarted successfully.', options.RaspiModelName);
					catch modelME
						uploadFirmwareToCompanionComputer.logMsg('WARNING: Could not restart model: %s', modelME.message);
						uploadMsg = sprintf(['Firmware upload succeeded, but the Simulink model "%s" could not be restarted.\n' ...
							'Detail: %s\n' ...
							'Action: Manually restart the model on RPi or power-cycle and redeploy.'], ...
							options.RaspiModelName, modelME.message);
						uploadStatus = true; % Flash itself succeeded
						return;
					end
				end

				% --- Success ---
				uploadStatus = true;
				uploadMsg = sprintf('Firmware flashed successfully.\nFlash output:\n%s', flashOutput);
				uploadFirmwareToCompanionComputer.logMsg('Firmware upload and flash completed successfully.');

			catch ME
				uploadStatus = false;
				uploadMsg = sprintf(['Unexpected error during firmware upload.\n' ...
					'Detail: %s\n' ...
					'Stack: %s\n' ...
					'Action: Review the error above. Common causes:\n' ...
					'  - RPi not powered or not on the network\n' ...
					'  - Pixhawk not connected via USB to RPi\n' ...
					'  - SSH credentials changed on RPi'], ...
					ME.message, uploadFirmwareToCompanionComputer.formatStack(ME));
				uploadFirmwareToCompanionComputer.logMsg('ERROR: %s', uploadMsg);
			end
		end


		function ensurePxUploaderOnRpi(pxUploaderPath, remoteFolder, forceUpload)
			%ensurePxUploaderOnRpi Upload px_uploader.py to RPi if not already present
			%
			%   ensurePxUploaderOnRpi(pxUploaderPath, remoteFolder)
			%   ensurePxUploaderOnRpi(pxUploaderPath, remoteFolder, true) forces re-upload
			%
			%   Inputs:
			%       pxUploaderPath - Local path to px_uploader.py
			%       remoteFolder   - Target folder on RPi (e.g. '/home/rpi')
			%       forceUpload    - true to overwrite even if present (default: false)

			if nargin < 3
				forceUpload = false;
			end

			% --- SUPPORT PACKAGE CHECK ---
			uploadFirmwareToCompanionComputer.ensureRaspiSupportPackage();

			% Validate local file exists (robust check for WSL $ paths)
			if ~uploadFirmwareToCompanionComputer.fileExistsRobust(pxUploaderPath)
				error('uploadFirmwareToCompanionComputer:UploaderNotFound', ...
					['px_uploader.py not found locally at: %s\n' ...
					'Action: Verify your PX4 Toolchain installation. The file should be in <PX4_BASE>/Tools/px_uploader.py.'], ...
					pxUploaderPath);
			end

			% Connect to RPi
			uploadFirmwareToCompanionComputer.logMsg('Connecting to Raspberry Pi for px_uploader.py check...');
			raspiObj = uploadFirmwareToCompanionComputer.connectToRaspberryPi();

			remoteScript = [remoteFolder '/px_uploader.py'];
			checkCmd = sprintf('test -f %s && echo EXISTS || echo NOT_FOUND', remoteScript);
			checkResult = raspiObj.system(checkCmd);
			scriptExists = contains(checkResult, 'EXISTS');

			if ~scriptExists || forceUpload
				uploadFirmwareToCompanionComputer.logMsg('Uploading px_uploader.py to RPi:%s ...', remoteFolder);
				try
					winPxUploaderPath = uploadFirmwareToCompanionComputer.ensureWindowsLocalCopy(pxUploaderPath);
					raspiObj.putFile(winPxUploaderPath, remoteFolder);
				catch transferME
					error('uploadFirmwareToCompanionComputer:UploaderTransferFailed', ...
						['Failed to transfer px_uploader.py to Raspberry Pi.\n' ...
						'Detail: %s\n' ...
						'Action: Check network connection, RPi disk space, and file permissions.'], ...
						transferME.message);
				end

				% Verify transfer
				verifyCmd = sprintf('ls %s 2>/dev/null', remoteScript);
				verifyResult = uploadFirmwareToCompanionComputer.safeRaspiSystem(raspiObj, verifyCmd);
				if isempty(verifyResult) || ~contains(verifyResult, 'px_uploader.py')
					error('uploadFirmwareToCompanionComputer:UploaderVerifyFailed', ...
						['px_uploader.py was transferred but could not be verified on RPi.\n' ...
						'Action: SSH into RPi and check: ls -la %s'], remoteScript);
				end

				% Make executable
				chmodCmd = sprintf('chmod +x %s', remoteScript);
				chmodResult = uploadFirmwareToCompanionComputer.safeRaspiSystem(raspiObj, chmodCmd);
				if isempty(chmodResult)
					warning('uploadFirmwareToCompanionComputer:ChmodFailed', ...
						'Could not confirm px_uploader.py was made executable on RPi.');
				end
				
				uploadFirmwareToCompanionComputer.logMsg('px_uploader.py uploaded and verified on RPi.');
			else
				uploadFirmwareToCompanionComputer.logMsg('px_uploader.py already present on RPi.');
			end
		end

		function ensureRaspiSupportPackage()
			% Try to call the function, catch "undefined" errors
			try
				codertarget.raspi.internal.getSpPkgRootDir();
			catch ME
				if contains(ME.message, 'Undefined function') || contains(ME.message, 'not found')
					error('uploadFirmwareToCompanionComputer:RaspiSupportPackageNotInstalled', ...
						['Raspberry Pi Support Package is not installed or not on the MATLAB path.\n' ...
						'Action: Install the "Simulink Support Package for Raspberry Pi Hardware" from Add-Ons.']);
				else
					rethrow(ME); % Some other error, not a missing function
				end
			end
		end

		function localWinPath = ensureWindowsLocalCopy(wslPath)
			% If the path is already on Windows, just return it
			if ispc && ~startsWith(wslPath, '\\wsl$')
				localWinPath = wslPath;
				return;
			end

			% Otherwise, copy from WSL to a Windows temp folder
			[~, fname, ext] = fileparts(wslPath);
			tempFolder = fullfile(tempdir, 'px4_upload_temp');
			if ~exist(tempFolder, 'dir')
				mkdir(tempFolder);
			end
			localWinPath = fullfile(tempFolder, [fname ext]);

			% Use WSL's cp to copy file to /mnt/c/Users/YourUser/AppData/Local/Temp/...
			% but here, use MATLAB's 'copyfile' if possible
			try
				% Try MATLAB copyfile first (works in R2022b and later for \\wsl$)
				copyfile(wslPath, localWinPath);
			catch
				% Fallback: use system 'wsl cp ...' if MATLAB can't access \\wsl$
				winTempPathInWsl = strrep(localWinPath, '\', '/');
				wslCopyCmd = sprintf('wsl cp "%s" "/mnt/c%s"', ...
					strrep(wslPath, '\\wsl$\ubuntu\', '/home/'), winTempPathInWsl(3:end));
				[status, cmdout] = system(wslCopyCmd);
				if status ~= 0
					error('Failed to copy file from WSL to Windows temp folder: %s', cmdout);
				end
			end
		end

		function result = safeRaspiSystem(raspiObj, cmd)
			% Robust system command execution for raspiObj.system
			% Returns '' on failure, result otherwise
			result = '';
			try
				out = raspiObj.system(cmd);
				if isempty(out) || ~ischar(out)
					% Could be error, empty, or unexpected
					result = '';
				else
					result = strtrim(out);
				end
			catch raspiSystemErr
				% Optionally log or warn here
				warning('uploadFirmwareToCompanionComputer:RemoteSystemCmdFailed', ...
					'Failed to execute remote system command: %s\nError: %s', cmd, raspiSystemErr.message);
				result = '';
			end
		end

		function raspiObj = connectToRaspberryPi()
			%connectToRaspberryPi Create and validate a Raspberry Pi connection
			%
			%   raspiObj = connectToRaspberryPi()
			%   Returns a connected raspberrypi object or throws a descriptive error.

			try
				raspiObj = raspberrypi();
			catch ME
				if contains(ME.message, 'Expected username to be nonempty', 'IgnoreCase', true)
					error('uploadFirmwareToCompanionComputer:RpiNotConfigured', ...
						['Raspberry Pi hardware is not configured in Simulink.\n' ...
						'Action: Run the hardware setup wizard:\n' ...
						'  >> targetHardware = "Raspberry Pi"\n' ...
						'  Or follow: https://in.mathworks.com/help/simulink/supportpkg/raspberrypi_ug/install-target-for-raspberry-pi-hardware.html']);
				elseif contains(ME.message, 'Unable to connect', 'IgnoreCase', true) || ...
						contains(ME.message, 'timeout', 'IgnoreCase', true) || ...
						contains(ME.message, 'Connection refused', 'IgnoreCase', true)
					error('uploadFirmwareToCompanionComputer:RpiConnectionFailed', ...
						['Cannot reach Raspberry Pi on the network.\n' ...
						'Detail: %s\n' ...
						'Action:\n' ...
						'  1. Check that RPi is powered on and connected to the same network.\n' ...
						'  2. Verify the IP address in Simulink hardware settings.\n' ...
						'  3. Try: ping <RPi_IP_address> from your host machine.\n' ...
						'  4. Check that SSH is enabled on the RPi.'], ME.message);
				else
					error('uploadFirmwareToCompanionComputer:RpiConnectionFailed', ...
						['Failed to connect to Raspberry Pi.\n' ...
						'Detail: %s\n' ...
						'Action: Verify RPi is powered, on the network, and SSH is enabled.'], ...
						ME.message);
				end
			end

			% Quick connectivity check
			try
				raspiObj.system('echo ok');
			catch
				error('uploadFirmwareToCompanionComputer:RpiUnresponsive', ...
					['Connected to Raspberry Pi but it is not responding to commands.\n' ...
					'Action: Power-cycle the RPi and retry.']);
			end
		end

	end

	methods(Static, Access=private)

		function logMsg(fmt, varargin)
			%logMsg Print a timestamped log message to the command window
			timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<TNOW1,DATST>
			fprintf('[%s] %s\n', timestamp, sprintf(fmt, varargin{:}));
		end

		function stackStr = formatStack(ME)
			%formatStack Format an MException stack trace as a readable string
			stackStr = '';
			for k = 1:length(ME.stack)
				stackStr = sprintf('%s  %s (line %d)\n', stackStr, ...
					ME.stack(k).name, ME.stack(k).line);
			end
			if isempty(stackStr)
				stackStr = '  (no stack trace available)';
			end
		end

	end

	methods(Static)

		function tf = fileExistsRobust(filePath)
			%fileExistsRobust Check if a file exists, handling WSL UNC paths with $
			%
			%   tf = fileExistsRobust(filePath)
			%
			%   MATLAB's isfile() fails on Windows UNC paths containing $ (e.g.
			%   \\wsl$\ubuntu\...) because the internal Java-based path resolution
			%   mishandles the $ character. This method uses dir() as the primary
			%   check, which calls the Windows FindFirstFile API directly and
			%   works correctly with all UNC paths including WSL $ shares.
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

	end
end
