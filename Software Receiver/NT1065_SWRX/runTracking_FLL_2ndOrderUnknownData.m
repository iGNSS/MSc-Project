disp ('Starting processing...');

[fid, message] = fopen(settings.fileName, 'rb');

%If success, then process the data
if (fid > 0)
    
%% Initialize channels and prepare for the run ============================

    % Start further processing only if a GNSS signal was acquired (the
    % field FREQUENCY will be set to 0 for all not acquired signals)
    if (any(acqResults.carrFreq))
        channel = preRun(acqResults, settings);
        showChannelStatus(channel, settings);
    else
        % No satellites to track, exit
        disp('No GNSS signals detected, DEBUG_ENABLE = true;signal processing finished.');
        trackResults = [];
        return;
    end

%% Track the signal =======================================================
    startTime = now;
    disp (['   Tracking started at ', datestr(startTime)]);
    
    % Process all channels for given data block
%     [trackResults, channel] = tracking_FLL_2ndOrderUnknownData(fid, channel, settings);

    %% ===============Copy of tracking_FLL_2ndOrderUnknownData.m===============


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
    trackResults.carrierDoppler = inf(1, settings.msToProcess);
    trackResults.codeDoppler    = inf(1, settings.msToProcess);
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
            %bit sync counters
            bitSync = 0;
            bitSyncCnt = zeros(1, 20);
     
            % inital Doppler shift estimate
            deltaFcaMinus_k = 0;
            % inital rate of change of Doppler shift estimate
            deltaFcaDotMinus_k = 0;
            % Carrier frequency locked loop bandwidth
            Bl_ca = 5;
            % FLL gains
            Kcf1 = 3.4 *(Bl_ca*PDIcarr);
            Kcf2 = 2.04 *((Bl_ca*PDIcarr)^2);
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
    
            I_P_S_reg = [];
            I_P_reg = [];
            Q_P_S_reg = [];

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
                DEBUG_COUNT = 10;
%                 if loopCnt < DEBUG_COUNT && loopCnt > 0
%                     disp(rawSignal(1 : 10));
%                 end
                
                     
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
                

                if loopCnt < DEBUG_COUNT && loopCnt > 0
                    fprintf("Early@%d\n", loopCnt);
%                     disp(tcode(1 : 10));
                    disp(tcode2(1 : 10));
                    disp(earlyCode(1 : 10));
                end

                % Define index into late code vector
                tcode       = (remCodePhase+earlyLateSpc) : ...
                              codePhaseStep : ...
                              ((blksize-1)*codePhaseStep+remCodePhase+earlyLateSpc);
                tcode2      = ceil(tcode) + 1;
                lateCode    = caCode(tcode2);
                 if loopCnt < DEBUG_COUNT && loopCnt > 0
                    fprintf("Late@%d\n", loopCnt);
%                     disp(tcode(1 : 10));
                    disp(tcode2(1 : 10));
                    disp(lateCode(1 : 10));
                end


                % Define index into prompt code vector
                tcode       = remCodePhase : ...
                              codePhaseStep : ...
                              ((blksize-1)*codePhaseStep+remCodePhase);
                tcode2      = ceil(tcode) + 1;
                promptCode  = caCode(tcode2);
                 if loopCnt < DEBUG_COUNT && loopCnt > 0
                    fprintf("Prompt@%d\n", loopCnt);
%                     disp(tcode(1 : 10));
                    disp(tcode2(1 : 10));
                    disp(promptCode(1 : 10));
                end

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
                
                % slide to get inner product
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

                I_P_reg = [I_P_reg, I_P];
                I_P_S_reg = [I_P_S_reg, I_P_S];
                Q_P_S_reg = [Q_P_S_reg, Q_P_S];
                
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
                       % adjust gains to new accumulation time
                       % FLL gains
                       Bl_ca = 0.5;                   
                       Kcf1 = 3.4 *(Bl_ca*PDIcarr);
                       Kcf2 = 2.04 *((Bl_ca*PDIcarr)^2);
                       % DLL gain
                       Bl_co = 0.1;
                       Kco = 4 * Bl_co * PDIcode;   
                       % adjust the stored correlations and lock indicators
                       I_P_D = coherentAccmNum * I_P_D;
                       Q_P_D = coherentAccmNum * Q_P_D;
                       carrLockInd = carrLockInd * (coherentAccmNum*coherentAccmNum);
                       codeLockInd = codeLockInd * (coherentAccmNum*coherentAccmNum);
                       switchTime = loopCnt;
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
                       cdLi = cdLi + (((Pn/Pw) - cdLi)/10);
                       cnoEst = (coherentAccmNum*(cdLi - 1))/(PDIcode*(coherentAccmNum - cdLi));
                       CNo = 10*log10(cnoEst);
                    end
    %% Find PLL error and update carrier NCO         
                        
                    % Carrier frequency discriminator
    
                    useFilteredDenominator = 0;
                    
                    cross = (Q_P_S * I_P_D) - (I_P_S * Q_P_D);
                    
                    dot = (I_P_S * I_P_D) + (Q_P_S * Q_P_D);
                    
                     if (dot == 0)
                        F = 0;
                    else
                        F = atan(cross / dot);
                    end	
                    
                    if(dot < 0)
    
                        NavBit = -NavBit;
                        cross = -cross;
                        dot = -dot;
                    end
    
                    carrLockInd = carrLockInd + (dot - carrLockInd)/(1000/coherentAccmNum);
                    codeLockInd = codeLockInd + (I2_plus_Q2 - codeLockInd)/(1000/coherentAccmNum);
    
                    if (useFilteredDenominator == 1)
                        if (carrLockInd == 0)
                            F = 0;
                        else
                            F = atan(cross / carrLockInd);
                        end
                    end
                     
                    % Carrier frequency discriminator normalisation function
                    Ncod = (1/(2*pi*PDIcarr));
    
                    % Carrier frequency error
                    deltaFca_k = Ncod * F;
    
                    % Doppler shift
                    deltaFcaPlus_k = deltaFcaMinus_k + (Kcf1*deltaFca_k);
    
                    % Rate of change of Doppler shift
                    deltaFcaDotPlus_k = deltaFcaDotMinus_k + ((Kcf2/PDIcarr)*deltaFca_k); 
    
                    % Doppler shift predicted forward to next iteration
                    deltaFcaMinus_kplus1 = deltaFcaPlus_k + (deltaFcaDotPlus_k*PDIcarr);
    
                    % Rate of change of Doppler shift predicted forward to next iteration
                    deltaFcaDotMinus_kplus1 = deltaFcaDotPlus_k;
    
                    % NCO update
                    carrNco = deltaFcaMinus_kplus1;
    
                    % Store Doppler shift for next iteration
                    deltaFcaMinus_k = deltaFcaMinus_kplus1;
    
                    % Store rate of change of Doppler for next iteration
                    deltaFcaDotMinus_k = deltaFcaDotMinus_kplus1;
                    
                    I_P_D = I_P_S;
                    Q_P_D = Q_P_S;
                 
    %% Find DLL error and update code NCO -------------------------------------
                    
                    %Code discriminator normalisation function
                    Nele = sqrt(codeLockInd);
                    %Code phase error
                    if Nele == 0
                       X_k = 0; 
                    else
                       X_k = (sqrt(I_E_S * I_E_S + Q_E_S * Q_E_S) - sqrt(I_L_S * I_L_S + Q_L_S * Q_L_S)) / Nele;
                    end
                    
                    % code phase estimate
                    TstPlus_k = TstMinus_k - ((Kco * X_k)/Fco);
                    
                    % Calculate code Doppler shift from the carrier
                    deltaFco_k = settings.spectrumInversion*((carrFreq - settings.IF)/1540);
                     
                    % code phase estimate predicted forward
                    TstMinus_kPlus1 = TstPlus_k + (((Fco + deltaFco_k)/Fco)*PDIcode); 
                    
                    % set the NCO frequency
                    codeNcoGroves = (((TstMinus_kPlus1 - TstMinus_k)/PDIcode)*Fco);
                    
                    % store the code Doppler
                    codeDoppler = TstMinus_kPlus1;
                    
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
                trackResults(channelNr).dllDiscrFilt(loopCnt)   = codeNcoGroves - settings.codeFreqBasis;
                trackResults(channelNr).pllDiscr(loopCnt)       = deltaFca_k;
                trackResults(channelNr).pllDiscrFilt(loopCnt)   = carrNco;
                trackResults(channelNr).carrierDoppler(loopCnt) = deltaFcaPlus_k;
                trackResults(channelNr).codeDoppler(loopCnt) = codeDoppler;
                
                
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
    figure(666);plot(I_P_S_reg);
    figure(777);plot(I_P_reg);
    figure(888);
    I_Q_2 = I_P_S_reg .^ 2 + Q_P_S_reg .^ 2;
    plot(I_Q_2);

    %% ===============End of tracking_FLL_2ndOrderUnknownData.m===============
    


    % Close the data file
    fclose(fid);
    
    disp(['   Tracking is over (elapsed time ', ...
                                        datestr(now - startTime, 13), ')'])     

    % Auto save the acquisition & tracking results to a file to allow
    % running the positioning solution afterwards.
    disp('   Saving Acq & Tracking results to file "trackingResults.mat"')
    save('trackingResults', ...
                      'trackResults', 'settings', 'acqResults', 'channel');    
    disp ('   Ploting results...');
    if settings.plotTracking
        plotTracking(1:settings.numberOfChannels, trackResults, settings);
    end
    disp ('   Done!');
end
