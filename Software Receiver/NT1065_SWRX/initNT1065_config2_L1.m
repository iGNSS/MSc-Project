%--------------------------------------------------------------------------
%                           SoftGNSS v3.0
% 
% Copyright (C) Darius Plausinaitis and Dennis M. Akos
% Written by Darius Plausinaitis and Dennis M. Akos
%--------------------------------------------------------------------------
%This program is free software; you can redistribute it and/or
%modify it under the terms of the GNU General Public License
%as published by the Free Software Foundation; either version 2
%of the License, or (at your option) any later version.
%
%This program is distributed in the hope that it will be useful,
%but WITHOUT ANY WARRANTY; without even the implied warranty of
%MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%GNU General Public License for more details.
%
%You should have received a copy of the GNU General Public License
%along with this program; if not, write to the Free Software
%Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
%USA.
%--------------------------------------------------------------------------
%
%Script initializes settings and environment of the software receiver.
%Then the processing is started.

%--------------------------------------------------------------------------
% CVS record:
% $Id: init.m,v 1.14.2.21 2006/08/22 13:46:00 dpl Exp $

%% Clean up the environment first =========================================
clear; close all; clc;

% =========================================
skipNumberOfBytes = 46250;
% skipNumberOfBytes = 100e6 + 17e3;
% deviceType = 'WVD';
% deviceType = 'PC';
% deviceType = 'N/A';
DEBUG_ENABLE = false;
% DEBUG_ENABLE = true;
% =========================================

% save('deviceType.mat',"deviceType");
save('skipNumberOfBytes.mat',"skipNumberOfBytes");

format ('compact');
format ('long', 'g');

%--- Include folders with functions ---------------------------------------
addpath include             % The software receiver functions
addpath geoFunctions        % Position calculation related functions

%% Print startup ==========================================================
fprintf(['\n',...
    'Welcome \n\n']);
fprintf('                   -------------------------------\n\n');

%% Initialize constants, settings =========================================
[settings, EKF_track] = initSettingsNT1065_config2_L1();

if ~DEBUG_ENABLE
    clearvars skipNumberOfBytes deviceType
end

%% Generate plot of raw data and ask if ready to start processing =========
try
    fprintf('Probing data (%s)...\n', settings.fileName)
    probeData(settings);
catch
    % There was an error, print it and exit
    errStruct = lasterror;
    disp(errStruct.message);
    disp('  (change settings in "initSettingsNSL_26MHz.m" to reconfigure)')    
    return;
end
    
disp('  Raw IF data plotted ')
disp('  (change settings in "initSettingsNSL_26MHz.m" to reconfigure)')
disp(' ');
disp('  Processing is now split into three stages;  Acquisition, Tracking and Navigation')
disp('  Use runAcquisition and runTracking_...(many different types) and runNav to perform each stage ')

