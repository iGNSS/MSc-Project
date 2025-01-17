clc;
clear;


% device_type = "WVD";
% switch device_type
%     case 'PC'
%         settings.fileName   = 'E:\Users\benji\OneDrive\Project\MSc-Project\Software Receiver\CH1SIM12p5MHzconfig2_int8.dat';
%     case 'WVD'
%         settings.fileName   = 'C:\Users\eexyh39\OneDrive\Project\MSc-Project\Software Receiver\CH1SIM12p5MHzconfig2_int8.dat';
%     otherwise
%         settings.fileName   = 'C:\dataSandbox\reduced_samples_rateNT1065\reducedSimRate\CH1SIM12p5MHzconfig2_int8.dat';
% end

settings.fileName   = '../../CH1SIM12p5MHzconfig2_int8.dat';

settings.skipNumberOfBytes  = 46250;
settings.samplingFreq       = 99.375e6;     %[Hz]
settings.codeFreqBasis      = 1.023e6;      %[Hz]
settings.codeLength         = 1023;
settings.dataType           = 'int8';
disp("RUNNING...")
[fid, message] = fopen(settings.fileName, 'rb');

% Move the starting point of processing. Can be used to start the
% signal processing at any point in the data record (e.g. good for long
% records or for signal processing in blocks).

fseek(fid, settings.skipNumberOfBytes, 'bof');

% Find number of samples per spreading code
samplesPerCode = round(settings.samplingFreq / (settings.codeFreqBasis / settings.codeLength));

% Read data for acquisition. 11ms of signal are needed for the fine
% frequency estimation
% data = fread(fid, 101*samplesPerCode, settings.dataType)';
time = 1;
data = fread(fid, time*samplesPerCode, settings.dataType)';

% data = data(settings.skipNumberOfBytes : end);
savedFileName = sprintf("FE_fs_99p375_MHz_skip_%d_time_%dms_int8.txt", settings.skipNumberOfBytes, time);
writematrix(data', savedFileName);
disp("DONE")


