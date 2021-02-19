function [reconVersion,refinedFolder,translatedDraftsFolder,summaryFolder] = runPipeline(draftFolder, varargin)
% This function runs the semi-automatic refinement pipeline consisting of
% three steps: 1) refining all draft reconstructions, 2) testing the
% refined reconstructions against the input data, 3) preparing a report
% detailing any additional debugging that needs to be performed.
%
% USAGE:
%
%    [refinedFolder,translatedDraftsFolder,summaryFolder,sbmlFolder] = runPipeline(draftFolder, varargin)
%
% REQUIRED INPUTS
% draftFolder              Folder with draft COBRA models generated by
%                          KBase pipeline to analyze
% OPTIONAL INPUTS
% refinedFolder            Folder with refined COBRA models generated by
%                          the refinement pipeline
% translatedDraftsFolder   Folder with draft COBRA models with translated
%                          nomenclature and stored as mat files
% infoFilePath             File with information on reconstructions to refine
% inputDataFolder          Folder with experimental data and database files
%                          to load
% summaryFolder            Folder with information on performed gapfilling
%                          and refinement
% reconVersion             Name of the refined reconstruction resource
%                          (default: "Reconstructions")
% numWorkers               Number of workers in parallel pool (default: 2)
% sbmlFolder               Folder where SBML files, if desired, will be saved
% overwriteModels          Define whether already finished reconstructions
%                          should be overwritten (default: false)
%
% OUTPUTS
% reconVersion             Name of the refined reconstruction resource
%                          (default: "Reconstructions")
% refinedFolder            Folder with refined COBRA models generated by
%                          the refinement pipeline
% translatedDraftsFolder   Folder with draft COBRA models with translated
%                          nomenclature and stored as mat files
% summaryFolder            Folder with information on performed gapfilling
%                          and refinement
%
% .. Authors:
%       - Almut Heinken, 06/2020

% Define default input parameters if not specified
parser = inputParser();
parser.addRequired('draftFolder', @ischar);
parser.addParameter('refinedFolder', [pwd filesep 'refinedReconstructions'], @ischar);
parser.addParameter('translatedDraftsFolder', [pwd filesep 'translatedDraftReconstructions'], @ischar);
parser.addParameter('summaryFolder', [pwd filesep 'refinementSummary'], @ischar);
parser.addParameter('infoFilePath', '', @ischar);
parser.addParameter('inputDataFolder', '', @ischar);
parser.addParameter('numWorkers', 2, @isnumeric);
parser.addParameter('reconVersion', 'Reconstructions', @ischar);
parser.addParameter('sbmlFolder', '', @ischar);
parser.addParameter('overwriteModels', false, @islogical);


parser.parse(draftFolder, varargin{:});

draftFolder = parser.Results.draftFolder;
refinedFolder = parser.Results.refinedFolder;
translatedDraftsFolder = parser.Results.translatedDraftsFolder;
summaryFolder = parser.Results.summaryFolder;
infoFilePath = parser.Results.infoFilePath;
inputDataFolder = parser.Results.inputDataFolder;
numWorkers = parser.Results.numWorkers;
reconVersion = parser.Results.reconVersion;
sbmlFolder = parser.Results.sbmlFolder;
overwriteModels = parser.Results.overwriteModels;

if isempty(infoFilePath)
    % create a file with reconstruction names based on file names. Note:
    % this will lack taxonomy information.
    infoFile={'MicrobeID'};
    % Get all models from the input folder
    dInfo = dir(fullfile(draftFolder, '**/*.*'));  %get list of files and folders in any subfolder
    dInfo = dInfo(~[dInfo.isdir]);
    models={dInfo.name};
    models=models';
    % remove any files that are not SBML or mat files
    delInd=find(~any(contains(models(:,1),{'sbml','mat'})));
    models(delInd,:)=[];
    for i=1:length(models)
        infoFile{i+1,1}=adaptDraftModelID(models{i});
    end
    writetable(cell2table(infoFile),[pwd filesep 'infoFile.txt'],'FileType','text','WriteVariableNames',false,'Delimiter','tab');
    infoFilePath = [pwd filesep 'infoFile.txt'];
end

% create folders where output data will be saved
mkdir(refinedFolder)
mkdir(translatedDraftsFolder)
mkdir(summaryFolder)
if ~isempty(sbmlFolder)
mkdir(sbmlFolder)
end

%% prepare pipeline run
% Get all models from the input folder
dInfo = dir(fullfile(draftFolder, '**/*.*'));  %get list of files and folders in any subfolder
dInfo = dInfo(~[dInfo.isdir]);
models={dInfo.name};
models=models';
folders={dInfo.folder};
folders=folders';
% remove any files that are not SBML or mat files
delInd=find(~any(contains(models(:,1),{'sbml','mat'})));
models(delInd,:)=[];
folders(delInd,:)=[];
% remove duplicates if there are any
for i=1:length(models)
    outputNamesToTest{i,1}=adaptDraftModelID(models{i,1});
end
[C,IA]=unique(outputNamesToTest);
models=models(IA);
folders=folders(IA);
outputNamesToTest=outputNamesToTest(IA);

% get already refined reconstructions
dInfo = dir(refinedFolder);
modelList={dInfo.name};
modelList=modelList';
if size(modelList,1)>0
    modelList(~contains(modelList(:,1),'.mat'),:)=[];
    modelList(:,1)=strrep(modelList(:,1),'.mat','');
    
    if ~overwriteModels
        % remove models that were already created
        [C,IA]=intersect(outputNamesToTest(:,1),modelList(:,1));
        if ~isempty(C)
            models(IA,:)=[];
            folders(IA,:)=[];
        end
    end
end

%% load the results from existing pipeline run and restart from there
if isfile([summaryFolder filesep 'summaries.mat'])
    load([summaryFolder filesep 'summaries.mat']);
else
    summaries=struct;
end

%% initialize COBRA Toolbox and parallel pool
global CBT_LP_SOLVER
if isempty(CBT_LP_SOLVER)
    initCobraToolbox
end
solver = CBT_LP_SOLVER;

if numWorkers>0 && ~isempty(ver('parallel'))
    % with parallelization
    poolobj = gcp('nocreate');
    if isempty(poolobj)
        parpool(numWorkers)
    end
end
environment = getEnvironment();


%% First part: refine all draft reconstructions in the input folder

% define the intervals in which the refining and regular saving will be
% performed
if length(models)>200
    steps=100;
else
    steps=25;
end

for i=1:steps:length(models)
    if length(models)-i>=steps-1
        endPnt=steps-1;
    else
        endPnt=length(models)-i;
    end
    
    modelsTmp = {};
    draftModelsTmp = {};
    summariesTmp = {};
    
    parfor j=i:i+endPnt
        restoreEnvironment(environment);
        changeCobraSolver(solver, 'LP', 0, -1);
        
        % create an appropriate ID for the model
        microbeID=adaptDraftModelID(models{j});
        
        % load the model
        draftModel = readCbModel([folders{j} filesep models{j}]);
        %% create the model
        [model,summary]=refinementPipeline(draftModel,microbeID, infoFilePath, inputDataFolder);
        modelsTmp{j}=model;
        summariesTmp{j}=summary;

        outputFileNamesTmp{j,1}=microbeID;
        
        %% save translated version of the draft model as a mat file
        if contains(models{j},'sbml')
            draftModel = translateDraftReconstruction(draftModel);
            draftModelsTmp{j}=draftModel;
        end
    end
    % save the data
    for j=i:i+endPnt
        model=modelsTmp{j};
        save([refinedFolder filesep outputFileNamesTmp{j,1}],'model');
        if contains(models{j},'sbml')
            model=draftModelsTmp{j};
            save([translatedDraftsFolder filesep outputFileNamesTmp{j,1}],'model');
        end
        if ~isnan(str2double(outputFileNamesTmp{j,1}))
            summaries.(outputFileNamesTmp{j,1})=['m' summariesTmp{j}];
        else
            summaries.(outputFileNamesTmp{j,1})=summariesTmp{j};
        end
    end
    save([summaryFolder filesep 'summaries_' reconVersion],'summaries');
end

%% Get summary of curation efforts performed
orgs=fieldnames(summaries);
pipelineFields={};
for i=1:length(orgs)
    pipelineFields=union(pipelineFields,fieldnames(summaries.(orgs{i})));
end
pipelineFields=unique(pipelineFields);
for i=1:length(pipelineFields)
    for j=1:length(orgs)
        pipelineSummary.(pipelineFields{i,1}){j,1}=orgs{j};
        if isfield(summaries.(orgs{j}),pipelineFields{i,1})
            if ~isempty(summaries.(orgs{j}).(pipelineFields{i,1}))
                if isnumeric(summaries.(orgs{j}).(pipelineFields{i,1}))
                    pipelineSummary.(pipelineFields{i,1}){j,2}=num2str(summaries.(orgs{j}).(pipelineFields{i,1}));
                elseif ischar(summaries.(orgs{j}).(pipelineFields{i,1}))
                    pipelineSummary.(pipelineFields{i,1}){j,2}=summaries.(orgs{j}).(pipelineFields{i,1});
                else
                    pipelineSummary.(pipelineFields{i,1})(j,2:length(summaries.(orgs{j}).(pipelineFields{i,1}))+1)=summaries.(orgs{j}).(pipelineFields{i,1})';
                end
            end
        end
    end
    if any(strcmp(pipelineFields{i,1},{'untranslatedMets','untranslatedRxns'}))
        cases={};
        spreadsheet=pipelineSummary.(pipelineFields{i});
        for j=1:size(spreadsheet,1)
            nonempty=spreadsheet(j,find(~cellfun(@isempty,spreadsheet(j,:))));
            for k=2:length(nonempty)
                cases{length(cases)+1}=nonempty{k};
            end
        end
        spreadsheet=unique(cases)';
        spreadsheet=cell2table(spreadsheet);
    else
        spreadsheet=cell2table(pipelineSummary.(pipelineFields{i}));
    end
    writetable(spreadsheet,[summaryFolder filesep pipelineFields{i,1}],'FileType','text','WriteVariableNames',false,'Delimiter','tab');
end

%% create SBML files (default=not created)

if ~isempty(sbmlFolder)
    createSBMLFiles(refinedFolder, sbmlFolder)
end

end

