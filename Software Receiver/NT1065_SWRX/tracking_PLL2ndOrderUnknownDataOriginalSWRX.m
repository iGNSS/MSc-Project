function [trackResults, channel]= tracking_PLL2ndOrderUnknownDataOriginalSWRX(fid, channel, settings)
% Performs code and carrier tracking for all channels.
%
%[trackResults, channel] = tracking_PLL3rdOrderUnknownData(fid, channel, settings)
%
%   Inputs:
%       fid             - file identifier of the signal record.
%       channel         - PRN, carrier frequencies and code phases of all
%                       satellites to be tracked (prepared by preRum.m from
%                       acquisition results).
%       settings        - receiver settings.
%   Outputs:
%       trackResults    - tracking results (structure array). Contains
%                       in-phase prompt outputs and absolute spreading
%                       code's starting positions, together with other
%                       observation data from the tracking loops. All are
%                       saved every millisecond.

%--------------------------------------------------------------------------
%                           SoftGNSS v3.0
% 
% Copyright (C) Dennis M. Akos
% Written by Darius Plausinaitis and Dennis M. Akos
% Based on code by DMAkos Oct-1999
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

%CVS record:
%$Id: tracking.m,v 1.14.2.31 2006/08/14 11:38:22 dpl Exp $

%% Initialize result structure ============================================

% Channel status
trackResults.status         = '-';      % No tracked signal, or lost lock

% The absolute sample in the record of the C/A code start:
trackResults.absoluteSample = zeros(1, settings.msToProcess);

% Freq of the C/A code:
trackResults.codeFreq       = inf(1, settings.msToProcess);

% Frequency of the tracked carrier wave:
trackResults.carrFreq       = inf(1, settings.msToProcess);

% Outputs from the correlators (In-phase):
trackResults.I_P            = zeros(1, settings.msToProcess);
trackResults.I_E            = zeros(1, settings.msToProcess);
trackResults.I_L            = zeros(1, settings.msToProcess);

% Outputs from the correlators (Quadrature-phase):
trackResults.Q_E            = zeros(1, settings.msToProcess);
trackResults.Q_P            = zeros(1, settings.msToProcess);
trackResults.Q_L            = zeros(1, settings.msToProcess);

% Loop discriminators
trackResults.dllDiscr       = inf(1, settings.msToProcess);
trackResults.dllDiscrFilt   = inf(1, settings.msToProcess);
trackResults.pllDiscr       = inf(1, settings.msToProcess);
trackResults.pllDiscrFilt   = inf(1, settings.msToProcess);
trackResults.I_P_D          = zeros(1, settings.msToProcess);
trackResults.Q_P_D          = zeros(1, settings.msToProcess);
trackResults.CdLi           = zeros(1, settings.msToProcess);
trackResults.CrLi           = zeros(1, settings.msToProcess);
trackResults.CNo            = zeros(1, settings.msToProcess);
trackResults.NavBits        = zeros(1, settings.msToProcess);
trackResults.bitSyncCnt     = zeros(1, 20);
trackResults.bitSync        = zeros(1, settings.msToProcess);
trackResults.remCodePhase   = zeros(1, settings.msToProcess);
%--- Copy initial settings for all channels -------------------------------
trackResults = repmat(trackResults, 1, settings.numberOfChannels);


%% Initialize tracking variables ==========================================

codePeriods = settings.msToProcess;     % For GPS one C/A code is one ms

hwb = waitbar(0,'Tracking...');

%% Start processing channels ==============================================
for channelNr = 1:settings.numberOfChannels
    
    % Only process if PRN is non zero (acquisition was successful)
    if (channel(channelNr).PRN ~= 0)
        % Save additional information - each channel's tracked PRN
        trackResults(channelNr).PRN     = channel(channelNr).PRN;
        
        % Move the starting point of processing. Can be used to start the
        % signal processing at any point in the data record (e.g. for long
        % records). In addition skip through that data file to start at the
        % appropriate sample (corresponding to code phase). Assumes sample
        % type is schar (or 1 byte per sample) 
        fseek(fid, ...
              settings.skipNumberOfBytes + channel(channelNr).codePhase-1, ...
              'bof');


        % Get a vector with the C/A code sampled 1x/chip
        caCode = generateCAcode(channel(channelNr).PRN);
        % Then make it possible to do early and late versions
        caCode = [caCode(1023) caCode caCode(1)];

        %--- Perform various initializations ------------------------------

        % define initial code frequency basis of NCO
        codeFreq      = settings.codeFreqBasis;
        % define residual code phase (in chips)
        remCodePhase  = 0.0;
        % define carrier frequency which is used over whole tracking period
        carrFreq      = channel(channelNr).acquiredFreq;
        carrFreqBasis = channel(channelNr).acquiredFreq;
        % define residual carrier phase
        remCarrPhase  = 0.0;

        %carrier/Costas loop parameters
        I_P_D = 0;
        Q_P_D = 0;
        I_E_S = 0;
        Q_E_S = 0;
        I_P_S = 0;
        Q_P_S = 0;
        I_L_S = 0;
        Q_L_S = 0;
        carrNco = 0;
        codeLockInd = 0;
        carrLockInd = 0;
        NavBit = 1;
        accmCount = 1;
        
        % Define early-late offset (in chips)
        earlyLateSpc = 0.5;

        % Summation interval
        coherentAccmNum = 1;
        PDIcode = 0.001*coherentAccmNum;
        PDIcarr = 0.001*coherentAccmNum;
        % bit sync counters
        bitSync = 0;
        bitSyncCnt = zeros(1, 20);

        % inital phase estimate
        phi_k = 0;
        % inital Doppler shift estimate
        phiDot_k = 0;
        % inital rate of change of Doppler shift estimate
        phiDotDot_k = 0;
        %carrier/Costas loop parameters
        oldCarrNco   = 0.0;
        oldCarrError = 0.0;
        % Carrier phase locked loop bandwidth
        Bl_ca = 25;
        % Calculate filter coefficient values
        [tau1carr, tau2carr] = calcLoopCoef(Bl_ca, ...
                                    0.7, ...
                                    0.25);
        Kca1 = 2.4 * Bl_ca * PDIcarr;
        Kca2 = 2.88 * ((Bl_ca * PDIcarr)^2);
        Kca3 = 1.728 * ((Bl_ca * PDIcarr)^3);
        % code frequency
        Fco = settings.codeFreqBasis;
        % intial code Doppler shift estimate
        deltaFco_k = settings.spectrumInversion*carrFreq/1540;
        TstMinus_k = (((Fco + deltaFco_k)/Fco)*PDIcode);
        Bl_co = 1;
        Kco = 4 * Bl_co * PDIcode;
       
        % Initial values for Cno estimation
        Pw = 0;
       
        % set to loss of lock threshold
        cdLi = 10;
        CNo = 10*log10(cdLi);

        %=== Process the number of specified code periods =================
        for loopCnt =  1:codePeriods
            
%% GUI update -------------------------------------------------------------
            % The GUI is updated every 50ms. This way Matlab GUI is still
            % responsive enough. At the same time Matlab is not occupied
            % all the time with GUI task.
            if (rem(loopCnt, 50) == 0)
                try
                    waitbar(loopCnt/codePeriods, ...
                            hwb, ...
                            ['Tracking: Ch ', int2str(channelNr), ...
                            ' of ', int2str(settings.numberOfChannels), ...
                            '; PRN#', int2str(channel(channelNr).PRN), ...
                            '; Completed ',int2str(loopCnt), ...
                            ' of ', int2str(codePeriods), ' msec']);                       
                catch
                    % The progress bar was closed. It is used as a signal
                    % to stop, "cancel" processing. Exit.
                    disp('Progress bar closed, exiting...');
                    return
                end
            end

%% Read next block of data ------------------------------------------------            
            % Find the size of a "block" or code period in whole samples
            
            % Update the phasestep based on code freq (variable) and
            % sampling frequency (fixed)
            codePhaseStep = codeFreq / settings.samplingFreq;
                        
            blksize = ceil((settings.codeLength-remCodePhase) / codePhaseStep);
            
            % Read in the appropriate number of samples to process this
            % interation 
            [rawSignal, samplesRead] = fread(fid, ...
                                             blksize, settings.dataType);
            rawSignal = rawSignal';  %transpose vector
            
            % If did not read in enough samples, then could be out of 
            % data - better exit 
            if (samplesRead ~= blksize)
                disp('Not able to read the specified number of samples  for tracking, exiting!')
                fclose(fid);
                return
            end

%% Set up all the code phase tracking information -------------------------
            % Define index into early code vector
            tcode       = (remCodePhase-earlyLateSpc) : ...
                          codePhaseStep : ...
                          ((blksize-1)*codePhaseStep+remCodePhase-earlyLateSpc);
            tcode2      = ceil(tcode) + 1;
            earlyCode   = caCode(tcode2);
            
            % Define index into late code vector
            tcode       = (remCodePhase+earlyLateSpc) : ...
                          codePhaseStep : ...
                          ((blksize-1)*codePhaseStep+remCodePhase+earlyLateSpc);
            tcode2      = ceil(tcode) + 1;
            lateCode    = caCode(tcode2);
            
            % Define index into prompt code vector
            tcode       = remCodePhase : ...
                          codePhaseStep : ...
                          ((blksize-1)*codePhaseStep+remCodePhase);
            tcode2      = ceil(tcode) + 1;
            promptCode  = caCode(tcode2);
            
            remCodePhase = (tcode(blksize) + codePhaseStep) - 1023.0;

%% Generate the carrier frequency to mix the signal to baseband -----------
            time    = (0:blksize) ./ settings.samplingFreq;
            
            % Get the argument to sin/cos functions
            trigarg = ((carrFreq * 2.0 * pi) .* time) + remCarrPhase;
            remCarrPhase = rem(trigarg(blksize+1), (2 * pi));
            
            % Finally compute the signal to mix the collected data to bandband
            carrCos = cos(trigarg(1:blksize));
            carrSin = sin(trigarg(1:blksize));

%% Generate the six standard accumulated values ---------------------------
            % First mix to baseband
            qBasebandSignal = carrCos .* rawSignal;
            iBasebandSignal = carrSin .* rawSignal;

            % Now get early, late, and prompt values for each
            
            % accumulate 1ms
            I_E = sum(earlyCode  .* iBasebandSignal);
            Q_E = sum(earlyCode  .* qBasebandSignal);
            I_P = sum(promptCode .* iBasebandSignal);
            Q_P = sum(promptCode .* qBasebandSignal);
            I_L = sum(lateCode   .* iBasebandSignal);
            Q_L = sum(lateCode   .* qBasebandSignal);
            
            
            % accumulate coherently further
            I_E_S = I_E_S + I_E;
            Q_E_S = Q_E_S + Q_E;
            I_P_S = I_P_S + I_P;
            Q_P_S = Q_P_S + Q_P;
            I_L_S = I_L_S + I_L;
            Q_L_S = Q_L_S + Q_L;
            
            % check if there has been a bit flip
            if coherentAccmNum == 1
                iim1_plus_qqm1 = (I_P * I_P_D) + (Q_P * Q_P_D);
                % form histogram of bit edges
                if(iim1_plus_qqm1 < 0)
                    bitSyncCnt(rem(loopCnt,20)+1)=bitSyncCnt(rem(loopCnt,20)+1) + 1;
                end
            end
            
            % check if more than 50 bit edges in a bin
            if (coherentAccmNum == 1) && any(bitSyncCnt == 50)                       
                   % record bit sync 0 to 19 
                   bitSync = find(bitSyncCnt == 50)-1;  
                   % increase the coherent accumulations
                   coherentAccmNum = 20;
                   PDIcode = 0.001*coherentAccmNum;
                   PDIcarr = 0.001*coherentAccmNum;
                   % Adjust the gains accordingly and reduce the bandwidth
                   Bl_ca = 5;
                   [tau1carr, tau2carr] = calcLoopCoef(Bl_ca, ...
                                    0.7, ...
                                    0.25);
                   Kca1 = 2.4 * Bl_ca * PDIcarr;
                   Kca2 = 2.88 * ((Bl_ca * PDIcarr)^2);
                   Kca3 = 1.728 * ((Bl_ca * PDIcarr)^3); 
                   Bl_co = 0.1;
                   Kco = 4 * Bl_co * PDIcode;
            end
            
%% update when accumulations are ready ----------------------------------
            % Only update at the end of accumulation
            if accmCount == coherentAccmNum   
%% Carrier to noise estimation 
                % Square up the correlations
                I2_plus_Q2 = (I_P_S * I_P_S) + (Q_P_S * Q_P_S);
                % Compute the narrow band power 
                Pn = I2_plus_Q2;
                
                % Accumulate the wide band power
                Pw = Pw + (I_P * I_P) + (Q_P * Q_P);
                
                if (coherentAccmNum == 20)
                   % Use a moving average 
                   cdLi = cdLi + (((Pn/Pw) - cdLi)/100);
                   cnoEst = (coherentAccmNum*(cdLi - 1))/(PDIcode*(coherentAccmNum - cdLi));
                   CNo = 10*log10(cnoEst);
                end
%% Find PLL error and update carrier NCO         
               
               % Implement carrier loop discriminator (phase detector)
                carrError = atan(Q_P_S / I_P_S) / (2.0 * pi);

                % Implement carrier loop filter and generate NCO command
                carrNco = oldCarrNco + (tau2carr/tau1carr) * ...
                    (carrError - oldCarrError) + carrError * (PDIcarr/tau1carr);
                oldCarrNco   = carrNco;
                oldCarrError = carrError;


                iim1_plus_qqm1 = (I_P_S * I_P_D) + (Q_P_S * Q_P_D);

                if(iim1_plus_qqm1 < 0)
                    NavBit = -NavBit;                       
                end
                              
                I_P_D = I_P_S;
                Q_P_D = Q_P_S;
                            
%% Find DLL error and update code NCO -------------------------------------
                
                %Code discriminator normalisation function
                Nele = (sqrt(I_E_S * I_E_S + Q_E_S * Q_E_S) + sqrt(I_L_S * I_L_S + Q_L_S * Q_L_S));
                
                %Code phase error
                if Nele == 0
                   X_k = 0; 
                else
                   X_k = (sqrt(I_E_S * I_E_S + Q_E_S * Q_E_S) - sqrt(I_L_S * I_L_S + Q_L_S * Q_L_S)) / Nele;
                end
                
                % code phase estimate
                TstPlus_k = TstMinus_k -((Kco * X_k)/Fco);
                
                % Calculate code Doppler shift from the carrier
                deltaFco_k = settings.spectrumInversion*((carrFreq - settings.IF)/1540);
                 
                % code phase estimate predicted forward
                TstMinus_kPlus1 = TstPlus_k + (((Fco + deltaFco_k)/Fco)*PDIcode); 
                
                % set the NCO frequency
                codeNcoGroves = (((TstMinus_kPlus1 - TstMinus_k)/PDIcode)*Fco);
                
                % store code phase for next iteration
                TstMinus_k = TstMinus_kPlus1;
                
                % restart the accumulations
                Pw = 0;
                I_E_S = 0;
                Q_E_S = 0;
                I_P_S = 0;
                Q_P_S = 0;
                I_L_S = 0;
                Q_L_S = 0;
                
                accmCount = 1;
            else
                % increment the accumulation counter 
                accmCount = accmCount + 1;
                % Accumulate the wide band power
                Pw = Pw + (I_P * I_P) + (Q_P * Q_P);
            end 
                         
                %%Update the NCOs      
                carrFreq = carrFreqBasis + carrNco;
 
                codeFreq = codeNcoGroves;
               

%% Record various measures to show in postprocessing ----------------------
            % Record sample number (based on 8bit samples)
            trackResults(channelNr).carrFreq(loopCnt) = carrFreq;
            trackResults(channelNr).codeFreq(loopCnt) = codeFreq;
            trackResults(channelNr).absoluteSample(loopCnt) = ftell(fid);

            trackResults(channelNr).dllDiscr(loopCnt)       = X_k;
            trackResults(channelNr).dllDiscrFilt(loopCnt)   = codeNcoGroves;
            trackResults(channelNr).pllDiscr(loopCnt)       = carrError;
            trackResults(channelNr).pllDiscrFilt(loopCnt)   = carrNco;

            trackResults(channelNr).I_E(loopCnt) = I_E;
            trackResults(channelNr).I_P(loopCnt) = I_P;
            trackResults(channelNr).I_L(loopCnt) = I_L;
            trackResults(channelNr).Q_E(loopCnt) = Q_E;
            trackResults(channelNr).Q_P(loopCnt) = Q_P;
            trackResults(channelNr).Q_L(loopCnt) = Q_L;
            trackResults(channelNr).I_P_D(loopCnt) = I_P_D;
            trackResults(channelNr).Q_P_D(loopCnt) = Q_P_D;
            trackResults(channelNr).CdLi(loopCnt) = codeLockInd;
            trackResults(channelNr).CrLi(loopCnt) = carrLockInd;
            trackResults(channelNr).CNo(loopCnt) = CNo;
            trackResults(channelNr).NavBits(loopCnt) = NavBit;
            trackResults(channelNr).bitSync(loopCnt) = bitSync;
            trackResults(channelNr).bitSyncCnt = bitSyncCnt;
            trackResults(channelNr).remCodePhase(loopCnt) = remCodePhase;
        end % for loopCnt

        % C/No based lock detector
        if CNo > 6.0
            trackResults(channelNr).status  = 'T';
        else
            trackResults(channelNr).status  = '-';
        end        
        
    end % if a PRN is assigned
end % for channelNr 

% Close the waitbar
close(hwb)
