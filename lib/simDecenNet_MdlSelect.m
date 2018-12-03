function [InputSet, NetStat] = simDecenNet_MdlSelect(InputSet, NetPars, outArgs)
% A decentralized system for information integration and segregation
% The whole system is composed of several networks, with each is composed
% two groups of neurons: congruent and opposite neurons.
% Each neuronal group inside each network is modelled as a continuous attractor
% neural network

% (ref. W.H. Zhang. et al., JNS 2016 and W.H. Zhang et al., NIPS 2016)
% Each network module contains congruent (C) and opposite (O) neurons;
% Within each network, no recurrent connections between (C) and (O) neurons
% Across networks, (C) neurons are connected in a congruent manner; while
%                  (O) neurons are connected in an opposite manner.

% Author: Wen-Hao Zhang, Mar-13-2017
% wenhaoz1@andrew.cmu.edu
% @Carnegie Mellon University

% Unfold parameters from struct NetPars and InputSet
PrefStim    = NetPars.PrefStim;
Width       = NetPars.Width;
dt          = NetPars.dt;
tau         = NetPars.tau;
numNets     = NetPars.numNets;
% seedNois    = NetPars.seedNois;

if nargin == 2
    outArgs = struct('InputSet', [], 'NetStat', []);
end

%% Connection kernel with unit connection strength
dPrefStim = mean(diff(PrefStim));
switch NetPars.connFunc
    case 'Gaussian'
        TunWidth  = NetPars.TunWidth;
        KerFtCong = angle(exp(1i*(PrefStim - PrefStim(1)) *pi/Width))* Width/pi;
        KerFtOppo = angle(exp(1i*(PrefStim - PrefStim(1)+dPrefStim+Width) *pi/Width))* Width/pi;
        KerFtCong = exp(-KerFtCong.^2/(2*TunWidth^2))/(sqrt(2*pi)*TunWidth);
        KerFtOppo = exp(-KerFtOppo.^2/(2*TunWidth^2))/(sqrt(2*pi)*TunWidth);
    case 'vonMises'
        TunKappa  = NetPars.TunKappa;
        KerFtCong = angle(exp(1i*(PrefStim - PrefStim(1)) *pi/Width)); % unit: rad
        KerFtOppo = angle(exp(1i*(PrefStim - PrefStim(1)+dPrefStim+Width) *pi/Width));
        KerFtCong = exp(TunKappa * cos(KerFtCong) )/(2*pi*besseli(0, TunKappa));
        KerFtOppo = exp(TunKappa * cos(KerFtOppo) )/(2*pi*besseli(0, TunKappa));
end
KerFtCong = fft(KerFtCong);
KerFtOppo = fft(KerFtOppo);

% Weight matrix
% The matrix will be right multiply with neural firing rate R (N-by-2 array);
JMat = [1, NetPars.JrpRatio; ...
    NetPars.JrpRatio, 1] * NetPars.Jrc;
JMatOppo = [diag(diag(JMat)); JMat - diag(diag(JMat))];

% Divisive normalization
pwr = 2; % the power of the u-r relation
% Weight matrix for divisive normalization.
divMat = [1, NetPars.krpRatio; ...
    NetPars.krpRatio, 1];
divMat = kron(divMat, eye(numNets));

% This part of code only work for two modules (170422)
divMat = divMat + ...
    kron(eye(2), NetPars.k12Ratio*(ones(2) - eye(2)));

%% Initiation
% [N, numNets, Time, nTrials]
sizeU = [NetPars.N, NetPars.numNets*NetPars.numGroupPerNet, ...
    NetPars.tLen/NetPars.dt, NetPars.nTrials];
if isfield(outArgs, 'InputSet')
    UArray = zeros(sizeU);
    OArray = zeros(sizeU);
end
if isfield(outArgs, 'NetStat')
    BumpPos = zeros(sizeU(2:end));
    OHeight = zeros(size(BumpPos));
end
if isfield(outArgs.NetStat, 'sumSqU')
   sumSqU = zeros(size(BumpPos));
end
if isfield(outArgs.NetStat, 'IrpCongHeight')
   IrpCongHeight = zeros(sizeU(2:end)./[2,1,1]);
end

%% Iteration
for iterTrial = 1: NetPars.nTrials
    U = zeros(sizeU(1:3));
    O = zeros(sizeU(1:3));
    
    % ------------------------------------------
    % Generate new noise sequence of every trial
    InputSet = makeNetInput(InputSet, NetPars, ...
        struct('ExtNois', [], 'IntNois', []));
    
    if NetPars.bAddNoise
        Iext = InputSet.Iext + InputSet.IntNois + InputSet.ExtNois;
    end
    % Add the mean value of background inputs
    Iext = Iext + NetPars.AmplBkg;
    
    % -----------------------------------------------------------
    % Iteration over time
    for t = 1: size(Iext, 3) - 1
        OFt = fft(O(:,:, t));
        
        % Inputs received by congruent neurons
        ICong = bsxfun(@times, KerFtCong,  OFt(:, 1:end/2)); % Nx2
        ICong = ifft(ICong);
        if exist('IrpCongHeight', 'var')
            IrpCongHeight(:,t,iterTrial) = sum(ICong * JMat(2), 1)*exp(NetPars.TunKappa/2) ...
                /(NetPars.rho*2*pi*besseli(0, NetPars.TunKappa/2)); % Average over neurons
        end
        ICong = ICong * JMat;
        
        % Inputs received by opposite neurons
        IOppo = [bsxfun(@times, KerFtCong, OFt(:,end/2+1:end) ), ...
            bsxfun(@times, KerFtOppo, OFt(:,end/2+1:end)) ];
        % IOppo(:,1:2): recurrent inputs (congruent connection)
        % IOppo(:,3:4): reciprocal inputs (opposite connection)
        IOppo = ifft(IOppo)*JMatOppo;
        ISyn = [ICong, IOppo];
        
        % Update
        dU = (-U(:,:,t) + ISyn + Iext(:,:,t)) * dt/tau;
        U(:,:,t+1) = U(:,:,t) + dU;
        
        % Synaptic input --> Firing rate
        Urec = U(:,:,t+1);
        Urec(Urec<0) = 0;
        Urec = Urec.^pwr;
        divU = sum(Urec, 1);
        if exist('sumSqU', 'var')
            % [numNets, Time, nTrials]
            sumSqU(:,t,iterTrial)  = divU;
        end
        divU = divU * divMat;
        
        O(:,:,t+1) = bsxfun(@rdivide, Urec, 1+ NetPars.k*divU);
    end
    
    if isfield(outArgs, 'InputSet')
        UArray(:,:,:, iterTrial) = U;
        OArray(:,:,:, iterTrial) = O;
    end
    
    % Make statistics of network's activities
    % Calculate the bump position and height
    if exist('BumpPos', 'var')
        BumpPos(:,:,iterTrial) = statBumpPos(O, NetPars);
    end
    if exist('OHeight', 'var')
        OHeight(:,:,iterTrial) = sum(O, 1)*exp(NetPars.TunKappa) ...
            /(NetPars.rho*2*pi*besseli(0, NetPars.TunKappa)); % Average over neurons
    end
end

% Make some statistics on I_12
% cirPos = exp(1i * NetPars.PrefStim/ NetPars.Width * pi);
% abs(sum(bsxfun(@times, cirPos, I_12),1)); % average over all neurons

%% Estimate the statistics of network activities
% Q: how do I judge whether winner-take-all happens? Dec-31, 2016

if isfield(outArgs.NetStat, 'OAvgXTime')
    OAvgXTime = mean(O,3);
end

if isfield(outArgs, 'NetStat')
    % Calculate the statistics according to winner of groups
    BumpPosTmp = reshape(BumpPos(:,NetPars.tStat/NetPars.dt+1:end, :), sizeU(2), []);
    [~, meanBumpPos, varBumpPos, concBumpPos, mrlBumpPos] = statBumpPos(BumpPosTmp, NetPars, 'BumpPos');
    
    OHeightAvg = mean(reshape(OHeight(:,NetPars.tStat/NetPars.dt+1:end, :), sizeU(2), []), 2);
    OHeightAvg = squeeze(OHeightAvg);
    
    % The output fields are dependent on the struct defined outside the
    % function. Dec-7, 2017
    for varName = fieldnames(outArgs.NetStat)'
        NetStat.(varName{1}) = eval(varName{1});
    end
end

%% Fold variables into output struct
if isfield(outArgs, 'InputSet')
    InputSet.U = UArray;
    InputSet.O = OArray;
end
