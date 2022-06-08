classdef ImageStackProcessor < nansen.DataMethod  %& matlab.mixin.Heterogenous  
%NANSEN.STACK.IMAGESTACKPROCESSOR Super class for image stack method.
%
%   This is a super class for methods that will run on an imagestack
%   object. This class provides functionality for splitting the stack in
%   multiple parts and running the processing on each part in sequence. The
%   class is designed so that methods can be started over and skip over 
%   data that have already been process. It is also possible to rerun the 
%   method on a specified set of parts.
%
%   This class is useful for stacks which are very large and may not fit 
%   in the computer memory. 
%
%   Constructing an object of this class will not start the processing, use
%   the runMethod for this.


%   NOTES:
%       Currently, the image stacks are divided into parts along the last
%       dimension (typically Time or Z-slices). This is done for
%       performance considerations, as loading data from disk is
%       time-consuming. This is not ideal for methods which require the
%       whole data set along this dimension, and where splitting the data
%       along the x- and or y- dimension is better. Such splitting should
%       be implemented at some point. 
    
%  A feature that can be developed: Use for processing different 
%  methods on each part, similar to mapreduce... Requires:
%       - Inherit from matlab.mixin.Heterogenous
%       - A loop within runMethod to loop over an array of class objects
%       - A method to make sure the sourceStack of all objs are the same


% - - - - - - - - - - TODO - - - - - - - - - - - - - - - - - - -
%     [ ] Make separate StackIterator class   
%
%     [ ] Check which parts are finished across channels and planes.
%
%     [ ] ProcessPart should be public. How to tell which part to process
%           if method is called externally? Input iPart or iInd? Or "synch"
%           with another method?
%           - ProcessSinglePart ??
%
%     [ ] Implement edit options method? To make sure number of frames per
%         part are not set after initialization
%
%     [ ] Don't allow updating options after IsInitialized = true; Here or
%         superclasses?
%
%     [ ] IF method is resumed, use old options and prohibit editing of 
%         options.
%
%     [v] Make option for reseting results before running. I.e when you
%         want to rerun the method and overwrite previous results.
%         Implemented on superclass DataMethod.
%     [ ] Make sure above works for all subclasses. Have an abstract method 
%         called reset?
%
%     [ ] Save intermediate results in processParts. I.e expand so that if
%         there are additional results (not just processed imagedata), it 
%         is also saved (see e.g. RoiSegmentation)
%
%     [ ] Don't show msg if all parts are processed
%
%       
%     Display/logging
%     [ ] Create a task stack, i.e a struct that holds all the substeps that
%         can be run. Right now, this is done in a very opaque way...
%     [ ] Add logging/progress messaging 
%     [v] Created print task method.
%     [v] Method for logging when method finished.
%     [ ] Output to log
%     [ ] Remove previous message when updating message in loop


% - - - - - - - - - PROPERTIES - - - - - - - - - - - - - - - - - 

    properties (SetAccess = protected) % Source and target stacks for processing
        SourceStack nansen.stack.ImageStack % The image stack to use as source
        TargetStack nansen.stack.ImageStack % The image stack to use as target (optional)
        ImageArray                          % Store a (sub)set of images that are loaded to memory
        DerivedStacks struct = struct       % Struct containing one or more derived stacks
    end
    
    properties % User preferences
        IsSubProcess = false        % Flag to indicate if this is a subprocess of another process (determines display output)
        PreprocessDataOnLoad = false; % Flag for whether to activate image stack data preprocessing...
        PartsToProcess = 'all'      % Parts to processs. Manually assign to process a subset of parts
        RedoProcessedParts = false  % Flag to use if processing should be done again on already processed parts
    end

    properties (Access = public) % Resolve: Should these instead be methods?
        DataPreProcessFcn   = []    % Function to apply on image data after loading (works on each part)
        DataPreProcessOpts  = []    % Options to use when preprocessing image data
        DataPostProcessFcn  = []    % Function to apply on image data before saving (works on each part)
        DataPostProcessOpts = []    % Options to use when postprocessing image data
    end
    
    properties (SetAccess = private, GetAccess = protected) % Current state of processor
        CurrentPart                 % Current part that is being processed (updated during processing)
        CurrentFrameIndices         % Current indices of frames that are being processed (updated during processing)
        NumParts                    % Number of parts that image stack is split into for processing
        
        NumChannelIterations
        NumPlaneIterations
        
        NumFramePerPart_
    end
    
% %     properties (Abstract) % Todo
% %         ChannelProcessingMode % 'serial' or 'batch'
% %         PlaneProcessingMode % 'serial' or 'batch'
% %     end
    
    properties (Dependent, SetAccess = private, GetAccess = protected)
        CurrentChannel  % Current channel of ImageStack
        CurrentPlane    % Current plane of ImageStack
    end
    
    properties (Dependent) % Options
        RunOnSeparateWorker
        FrameInterval
        NumFramesPerPart           
    end
    
    properties (Access = protected)
        NumSteps = 1                % Number of steps for algorithm. I.e Step 1/2 = downsample stack, Step 2/2 autosegment stack
        CurrentStep = 1;            % Current step of algorithm.
        StepDescription = {}        % Description of steps (cell array of text descriptions)
        FrameIndPerPart = []        % List (cell array) of frame indices for each subpart of image stack
        IsInitialized = false;      % Boolean flag; is processor already initialized?
        IsFinished = false;         % Boolean flag; has processor completed?
    end
    
% - - - - - - - - - - METHODS - - - - - - - - - - - - - - - - - 

    methods (Static) % Method to get default options
        function S = getDefaultOptions()
            S.Run.frameInterval = [];
            %S.Run.frameInterval_ = 'transient';
            S.Run.numFramesPerPart = 1000;            
            %S.Run.partsToProcess = 'all';
            %S.Run.redoPartIfFinished = false;
            S.Run.runOnSeparateWorker = false;
        end
    end
    
    methods (Abstract, Access = protected) % todo: make public??
        Y = processPart(obj, Y, iIndices);
    end
    
    methods % Constructor
        
        function obj = ImageStackProcessor(varargin)
                  
            if numel(varargin) == 0
                dataLocation = struct.empty;
                
            elseif numel(varargin) >= 1
                
                nvPairs = utility.getnvpairs(varargin{:});
                dataIoModel = utility.getnvparametervalue(nvPairs, 'DataIoModel');
                
                % Get datalocation from first input argument.
                if ~isempty(dataIoModel)
                    dataLocation = dataIoModel;
                elseif isa(varargin{1}, 'nansen.stack.ImageStack')
                    dataLocation = varargin{1}.FileName;
                else
                    dataLocation = varargin{1};
                end
                
            end
            
            % Call the constructor of the DataMethod parent class
            nvPairs = {};
            obj@nansen.DataMethod(dataLocation, nvPairs{:})
            
            if numel(varargin) == 0
                return
            end
            
            % Open source stack based on the first input argument.
            if ischar(varargin{1}) && isfile(varargin{1})
                obj.openSourceStack(varargin{1})
                
            elseif isa(varargin{1}, 'nansen.stack.ImageStack')
                obj.openSourceStack(varargin{1})
                
            elseif isa(varargin{1}, 'struct')
                % Todo. Subclass must implement....
            end
            
        end
        
    end

    methods % Set/get methods
        
        function runOnSeparateWorker = get.RunOnSeparateWorker(obj)
            if isfield(obj.Options, 'Run')
                runOnSeparateWorker = obj.Options.Run.runOnSeparateWorker;
            else
                S = nansen.stack.ImageStackProcessor.getDefaultOptions();
                runOnSeparateWorker = S.Run.runOnSeparateWorker;
            end
        end
        
        function numFramesPerPart = get.NumFramesPerPart(obj)
            
            if isempty(obj.NumFramePerPart_)
                if isfield(obj.Options, 'Run')
                    numFramesPerPart = obj.Options.Run.numFramesPerPart;
                else
                    S = nansen.stack.ImageStackProcessor.getDefaultOptions();
                    numFramesPerPart = S.Run.numFramesPerPart;
                end
            else
                numFramesPerPart = obj.NumFramePerPart_;
            end
        end
        
        function set.NumFramesPerPart(obj, numFramesPerPart)
            if isfield(obj.Options, 'Run')
                obj.Options.Run.numFramesPerPart = numFramesPerPart;
            end
            obj.NumFramePerPart_ = numFramesPerPart;
            obj.onNumFramesPerPartSet()
        end
        
        
        function frameInterval = get.FrameInterval(obj)
            if isfield(obj.Options, 'Run')
                frameInterval = obj.Options.Run.frameInterval;
            else
                S = nansen.stack.ImageStackProcessor.getDefaultOptions();
                frameInterval = S.Run.frameInterval;
            end
        end
        
        function currentChannel = get.CurrentChannel(obj)
            currentChannel = obj.SourceStack.CurrentChannel;
        end
        function set.CurrentChannel(obj, currentChannel)
            obj.SourceStack.CurrentChannel = currentChannel;
            obj.onCurrentChannelSet(currentChannel)
        end
        
        function currentPlane = get.CurrentPlane(obj)
            currentPlane = obj.SourceStack.CurrentPlane;
        end
        function set.CurrentPlane(obj, currentPlane)
            obj.SourceStack.CurrentPlane = currentPlane;
            obj.onCurrentPlaneSet(currentPlane)
        end
        
        
    end
    
    methods % User accessible methods
        
        function wasSuccess = preview(obj)
        %PREVIEW Open preview of data and options for method.
        %
        %   tf = preview(obj) returns 1 (true) if preview is successfully
        %   completed, i.e user completed the options editor.
        %
        %   This method opens an imviewer plugin for the current
        %   algorithm/tool if such a plugin is available. Otherwise it
        %   opens a generic options editor to edit the options of the
        %   algorithm
                
            pluginName = obj.ImviewerPluginName;
            pluginFcn = imviewer.App.getPluginFcnFromName(pluginName);

            if ~isempty(pluginFcn)

                obj.SourceStack.DynamicCacheEnabled = 'on';
                hImviewer = imviewer(obj.SourceStack);
                hImviewer.ImageDragAndDropEnabled = false; 
                % Todo: Should this be more specific. (I add this because 
                % the extract plugin has plot objects that can be dragged, 
                % and in that case the image should not be dragged...)
                
                h = hImviewer.openPlugin(pluginFcn, obj.OptionsManager, ...
                    'RunMethodOnFinish', false, 'DataIoModel', obj);
                % Will pause here until the plugin is closed.

                wasSuccess = obj.finishPreview(h);

                hImviewer.quit()
                obj.SourceStack.DynamicCacheEnabled = 'off';
                
            else
%                 warning('NANSEN:Roisegmentation:PluginMissing', ...
%                     'Plugin for %s was not found', CLASSNAME)

                % Todo: use superclass method editOptions
                [obj.Parameters, wasAborted] = tools.editStruct(obj.Parameters);
                wasSuccess = ~wasAborted;
            end
            
        end
        
        function runInitialization(obj)
        %runInitialization Run the processor initialization stage.
            obj.initialize()
        end
        
        function runMethod(obj, skipInit)
            
            if obj.RunOnSeparateWorker
                obj.runOnWorker()
                return
            end
            
            if nargin < 2; skipInit = false; end
            
            obj.runPreInitialization()
            
            if ~skipInit
                obj.initialize()
            end
        
            obj.processStack()

            obj.finish()
        end
        
        function runFinalization(obj)
        %runFinalization Run the processor finalization stage.
            obj.finish()
        end
        
        function runOnWorker(obj)
            
            tic
            
            jobDescription = sprintf('%s : %s', obj.MethodName, obj.SourceStack.Name);
            dependentPaths = obj.getDependentPaths();
            
            opts = obj.Options;
            opts.Run.runOnSeparateWorker = false;
            
            % Todo: should reconcile this, using a dataiomodel
            %args = {obj.SourceStack, opts};
            args = {obj.SessionObjects, opts};

            batchFcn = str2func( class(obj) );
            
            job = batch(batchFcn, 0, args, ...
                    'AutoAddClientPath',false, 'AutoAttachFiles', false, ...
                    'AdditionalPaths', dependentPaths);
            
            job.Tag = jobDescription;
            
            toc
            
        end
        
        function matchConfiguration(obj, referenceProcessor)
            obj.Options.Run.numFramesPerPart = referenceProcessor.NumFramesPerPart;
            obj.runInitialization()
        end
        
        function setCurrentPart(obj, partNumber)
            obj.CurrentPart = partNumber;
            obj.CurrentFrameIndices = obj.FrameIndPerPart{partNumber};
        end
        
        function delete(obj)
            % Todo: Delete source stack if it is opened on construction...
            
            if ~isempty(obj.TargetStack)
                delete(obj.TargetStack)
            end
        end
        
    end
    
    methods (Access = protected, Sealed) % initialize/processParts/finish
                
        function initialize(obj)
            
            % Check if SourceStack has been assigned.
            assert(~isempty(obj.SourceStack), 'SourceStack is not assigned')
            
            obj.printInitializationMessage()
            
%             if obj.IsInitialized
%                 fprintf('This method has already been initialized. Skipping...\n')
%                 return;
%             end

            obj.displayProcessingSteps()
            
            % Todo: Check if options exist from before, i.e we are resuming
            % this method on data that was already processed.
            % Also need to determine if the method should be resumed or
            % start over.
            
            obj.configureImageStackSplitting()
            
            % Todo: display message showing number of parts...

            % Run onInitialization ( Subclass may implement this method)
            obj.onInitialization()
            obj.IsInitialized = true;
            
        end
        
        function processStack(obj)
        %processStack Run the main processing step on the ImageStack
        %
        %   This method displays information about the processing and
        %   manages the iteration over channels and/or planes for
        %   ImageStack with multiple channels/planes
        
            obj.displayStartCurrentStep()

            obj.printTask(sprintf('Running method: %s', class(obj) ) )

            obj.CurrentChannel = 1;
            obj.CurrentPlane = 1;
            
            [channelIterator, nChannelsIter] = obj.getChannelIterationValues();
            [planeIterator, nPlanesIter] = obj.getPlaneIterationValues();

            obj.NumChannelIterations = nChannelsIter;
            obj.NumPlaneIterations = nPlanesIter;
            
            % Todo: Make method for displaying the following:
            
            numChans = obj.SourceStack.NumChannels;
            numPlanes = obj.SourceStack.NumPlanes;
            
            IND = obj.FrameIndPerPart;
            partsToProcess = obj.getPartsToProcess(IND);
            numParts =  numel(partsToProcess);
            
            if numParts == 1
                numPartsStr = sprintf('%d part', numParts);
            else
                numPartsStr = sprintf('%d parts', numParts);
            end
            
            if numChans > 1 && numPlanes > 1
                obj.printSubTask(sprintf('ImageStack contains %d channels and %d planes', numChans, numPlanes))
                obj.printSubTask(sprintf('Each channel and plane will be divided in %s during processing', numPartsStr))
            elseif numChans > 1
                obj.printSubTask(sprintf('ImageStack contains %d channels', numChans))
                obj.printSubTask(sprintf('Each channel will be divided in %s during processing', numPartsStr))
            elseif numPlanes > 1
                obj.printSubTask(sprintf('ImageStack contains %d planes', numPlanes))
                obj.printSubTask(sprintf('Each plane will be divided in %s during processing', numPartsStr))
            else
                obj.printSubTask(sprintf('ImageStack will be processed in %s', numPartsStr))
            end
            
            for iChannel = channelIterator
                obj.CurrentChannel = iChannel;
                for jPlane = planeIterator
                    obj.CurrentPlane = jPlane;
                    
                    obj.processParts()
                end
            end
            
            obj.displayFinishCurrentStep()
        end
        
        function processParts(obj)
        %processParts Process all parts in sequence
        %
        %   This method manages the iteration over all subparts of an
        %   ImageStack for the current channel and the current plane.
        %
        %   Four main steps are executed for each subpart:
        %       1) load frames
        %       2) preprocess data
        %       3) process data
        %       4) postprocess data (if image data is returned from processor)
        

            IND = obj.FrameIndPerPart;
            
            % Todo: Do this here or in initialization??
            partsToProcess = obj.getPartsToProcess(IND);

            if obj.NumParts > 1 && isempty(partsToProcess)
                obj.printTask(sprintf('All parts of imagestack have already been processed for method: %s',  class(obj)))
                return
            end
            

            % Loop through 
            for iPart = partsToProcess

                progressStr = obj.getCurrentPartString(iPart);
                obj.printSubTask(sprintf('Processing %s', progressStr))

                iIndices = IND{iPart};

                obj.CurrentPart = iPart;
                obj.CurrentFrameIndices = iIndices;
                
                % Load data Todo: Make method?
                Y = obj.SourceStack.getFrameSet(iIndices);
                Y = squeeze(Y);
                
                if ~isempty(obj.DataPreProcessFcn)
                    Y = obj.DataPreProcessFcn(Y, iIndices, obj.DataPreProcessOpts);
                end
                
                Y = obj.processPart(Y);
                
                if ~isempty(Y)
                    if ~isempty(obj.DataPostProcessFcn)
                        Y = obj.DataPostProcessFcn(Y, iIndices, obj.DataPostProcessOpts);
                    end
                    
                    if ~isempty(obj.TargetStack)
                        targetIndices = obj.getTargetIndices(iIndices);
                        obj.TargetStack.writeFrameSet(Y, targetIndices)
                    end
                end
                
            end
        end
        
        function finish(obj)
            
            %if obj.IsFinished; return; end
            [channelIterator, ~] = obj.getChannelIterationValues();
            [planeIterator, ~] = obj.getPlaneIterationValues();
            
            for iChannel = channelIterator
                obj.CurrentChannel = iChannel;
                for jPlane = planeIterator
                    obj.CurrentPlane = jPlane;
                    
                    % Subclass may implement
                    obj.onCompletion()
                end
            end

            obj.printCompletionMessage()
            %obj.IsFinished = true;
        end
        
    end
    
    methods (Access = protected) % Subroutines (Subclasses may override)
        
        function [channelIterator, nIter] = getChannelIterationValues(obj)
        %getChannelIterationValues Get index values for channel iteration
            channelIterator = 1:obj.SourceStack.NumChannels;
            nIter = numel(channelIterator);
        end
        
        function [planeIterator, nIter] = getPlaneIterationValues(obj)
            planeIterator = 1:obj.SourceStack.NumPlanes;
            nIter = numel(planeIterator);
        end
        
        function onCurrentChannelSet(obj, currentChannel)
            if ~isempty(obj.TargetStack)
                obj.TargetStack.CurrentChannel = currentChannel;
            end
            
            derivedStackNames = fieldnames(obj.DerivedStacks);
            for i = 1:numel(derivedStackNames)
                iStack = obj.DerivedStacks.(derivedStackNames{i});
                iStack.CurrentChannel = currentChannel;
            end
        end
        
        function onCurrentPlaneSet(obj, currentPlane)
            if ~isempty(obj.TargetStack)
                obj.TargetStack.CurrentPlane = currentPlane;
            end
            
            derivedStackNames = fieldnames(obj.DerivedStacks);
            for i = 1:numel(derivedStackNames)
                iStack = obj.DerivedStacks.(derivedStackNames{i});
                iStack.CurrentPlane = currentPlane;
            end
        end
        
        function runPreInitialization(obj) % todo: protected?
        %runPreInitialization Runs before the initialization step    
            % Subclasses can override
            obj.NumSteps = 1;
            obj.StepDescription = {obj.MethodName};
        end
        
        function openSourceStack(obj, imageStackRef)
        %openSourceStack Open/assign image stack which is source
        
            if isa(imageStackRef, 'nansen.stack.ImageStack')
                obj.SourceStack = imageStackRef;
            else
                try % Can we create an ImageStack?
                    obj.SourceStack = nansen.stack.ImageStack(imageStackRef);
                catch
                    error('Input must be transferable to an ImageStack')
                end
            end
        end
        
        function openTargetStack(obj, filePath, stackSize, dataType, varargin)
        %openTargetStack Open (or create) and assign the target image stack
        
            if ~isfile(filePath)
                obj.printTask('Creating target stack for method: %s...', class(obj))
                imageStackData = nansen.stack.open(filePath, stackSize, dataType, varargin{:});
            else
                imageStackData = nansen.stack.open(filePath, varargin{:});
            end
            
            obj.TargetStack = nansen.stack.ImageStack(imageStackData);
        end

        function iIndices = getTargetIndices(obj, iIndices)
            % This method is meant for subclasses where the indices of the
            % source and the target are different, i.e for downsampling
            % methods.
        end
        
        function tf = checkIfPartIsFinished(obj, partNumber)
            % Rename to isPartFinished?
            % Subclass may implement
            tf = false; 
        end
        
% % %         Todo: Add Results as property and use this instead
% % %         function tf = checkIfPartIsFinished(obj, partNumber)
% % %             tf = ~isempty(obj.Results{partNumber});
% % %         end
        
        function onInitialization(~)
            % Subclass may implement
        end
        
        function onCompletion(~)
            % Subclass may implement
        end
        
        function configureImageStackSplitting(obj)
        %configureImageStackSplitting Get split configuration from options
            
            % Get number of frames per part
            N = obj.NumFramesPerPart;
            
            % Get cell array of frame indices per part (IND) and numParts
            [IND, numParts] = obj.SourceStack.getChunkedFrameIndices(N);

            % Assign to property values
            obj.FrameIndPerPart = IND;
            obj.NumParts = numParts;

            % Todo: Make sure this method is not resuming from previous
            % instance that used a different stack splitting configuration
            
        end
        
        function imArray = getImageArray(obj, N)
        %loadImageData Load set of image frames from ImageStack        
            
            % Todo: add options for how many frames to load.
            obj.printTask('Loading image data from disk')
            
            if nargin < 2 || isempty(N)
                N = obj.SourceStack.chooseChunkLength();
            end

            imArray = obj.SourceStack.getFrameSet(1:N);
            % Todo: Include this but fix caching for multichannel data...
            % obj.SourceStack.addToStaticCache(imArray, 1:N)
            imArray = squeeze(imArray);
            
            obj.printTask('Finished loading data')
            
        end
        
        function S = repeatStructPerDimension(obj, S)
        %repeatStructPerDimension Repeat a struct of result per dimension
        %
        %   For stack with multiple channels or planes, the input struct is
        %   repeated for the length of each of those dimensions
        
            numChannels = obj.SourceStack.NumChannels;
            numPlanes = obj.SourceStack.NumPlanes;
            S = repmat({S}, numChannels, numPlanes);
        end
        
        function suffix = getFilenameSuffix(obj, channelNum, planeNum)
        %getFilenameSuffix Get filename suffix with channel and/or plane
        
            if nargin < 2;  channelNum = obj.CurrentChannel;    end
            if nargin < 3;  planeNum = obj.CurrentPlane;        end
            
            skipChannel = isequal( channelNum, 1:obj.SourceStack.NumChannels);
            skipPlane = isequal( planeNum, 1:obj.SourceStack.NumPlanes);
            
            suffix = '';
            
            if obj.SourceStack.NumChannels > 1 && ~skipChannel
                suffix = strcat(suffix, sprintf('_ch%d', channelNum)) ;
            end
            
            if obj.SourceStack.NumPlanes > 1 && ~skipPlane
                suffix = strcat(suffix, sprintf('_plane%02d', planeNum)) ;
            end
        end
        
        function suffix = getVariableNameSuffix(obj, channelNum, planeNum)
            if nargin < 2;  channelNum = obj.CurrentChannel;    end
            if nargin < 3;  planeNum = obj.CurrentPlane;        end
            
            suffix = obj.getFilenameSuffix(channelNum, planeNum);
            suffix = strrep(suffix, '_', '');
            suffix = strrep(suffix, 'ch', 'Ch');
            suffix = strrep(suffix, 'plane', 'Plane');
        end
    end
    
    methods (Access = protected) % Pre- and processing methods for imagedata

        function Y = preprocessImageData(obj, Y)
            % Subclasses may override
        end

        function Y = postprocessImageData(obj, Y)
            % Subclasses may override
        end
        
    end
    
    methods (Access = private)
        
        function partsToProcess = getPartsToProcess(obj, frameInd)
        %getPartsToProcess Get list of which parts to process.
        %
        %   partsToProcess = h.getPartsToProcess(numParts, frameInd)
        %
        %   Return a list of numbers for parts to process. By default, all
        %   parts will be processed, but this can be controlled using the
        %   PartsToProcess property. Also if parts are processed from 
        %   before, they will be skipped, unless the RedoProcessedParts
        %   property is set to true
        
        % Note: frameInd might be used by subclasses(?)
       
            % Set the parts to process.
            if strcmp(obj.PartsToProcess, 'all')
                partsToProcess = 1:obj.NumParts;
            else
                partsToProcess = obj.PartsToProcess;
            end
            
            % Make sure list of parts is a numeric
            assert(isnumeric(partsToProcess), 'PartsToProcess must be numeric')
            
            % Check if any parts can be skipped
            partsToSkip = [];
            for iPart = partsToProcess
                
                % Checks if shifts already exist for this part
                isPartFinished = obj.checkIfPartIsFinished(iPart);
                                
                if isPartFinished && ~obj.RedoProcessedParts
                    partsToSkip = [partsToSkip, iPart]; %#ok<AGROW>
                end
            end

            partsToProcess = setdiff(partsToProcess, partsToSkip);
            
            if isempty(partsToProcess); return; end
            
            % Make sure list of parts is in valid range.
            msgA = 'PartsToProcess can not be smaller than the first part';
            assert( min(partsToProcess) >= 1, msgA)
            msgB = 'PartsToProcess can not be larger than the last part';
            assert( max(partsToProcess) <= obj.NumParts, msgB)

        end
        
        function onNumFramesPerPartSet(obj)
        %onNumFramesPerPartSet Callback for property set method
        %
        %   Update NumParts and the FrameIndPerPart properties
            
            N = obj.NumFramePerPart_;
            
            % Get cell array of frame indices per part (IND) and numParts
            [IND, numParts] = obj.SourceStack.getChunkedFrameIndices(N);

            % Assign to property values
            obj.FrameIndPerPart = IND;
            obj.NumParts = numParts;
            
        end
    end
    
    methods (Access = protected) % Methods for printing commandline output
        
        function addProcessingStep(obj, description, position)
            
            % Placeholder / Todo
            switch position
                case 'beginning'
                    
                case 'end'
                    
            end
        end
        
        function printSubTask(obj, varargin)
            msg = sprintf(varargin{:});
            nowstr = datestr(now, 'HH:MM:ss');
            fprintf('%s: %s: %s\n', nowstr, obj.MethodName, msg)
        end
        
        function displayStartCurrentStep(obj)
        %displayStartCurrentStep Display message when current step starts    
            if obj.IsSubProcess; return; end

            i = obj.CurrentStep;
            obj.printTask('Running step %d/%d: %s...', i, obj.NumSteps, ...
                obj.StepDescription{i})
        end
        
        function displayFinishCurrentStep(obj)
        %displayFinishCurrentStep Display message when current step stops    
            
            if obj.IsSubProcess; return; end

            i = obj.CurrentStep;
            obj.printTask('Finished step %d/%d: %s.\n', i, obj.NumSteps, ...
                obj.StepDescription{i})
            obj.CurrentStep = obj.CurrentStep + 1;
        end
        
        function str = getCurrentPartString(obj, iPart)
        
        % Get string that looks like this based on current channel/plane: 
        % Processing part 2/80 (channel 1/2, plane 1/4, part 1/5)
            
            currentPlane = obj.CurrentPlane;
            currentChannel = obj.CurrentChannel(1); % Select first (sometimes channels are processed in batch) Todo: This should be generalized, what if some subclass would process channel 1 and 2 and then channel 3 and 4 or some weird stuff like that...
            
            currentPart = iPart;
            numParts = obj.NumParts;
            
            numChannelIter = obj.NumChannelIterations;
            numPlanesIter = obj.NumPlaneIterations;
            
            numChannels = obj.SourceStack.NumChannels;
            numPlanes = obj.SourceStack.NumPlanes;
            
            numRepetitions = numChannelIter .* numPlanesIter;
            currentRepetition = (currentChannel-1) .* numPlanes + currentPlane;
            
            currentPartTotal = (currentRepetition-1) .* numParts + currentPart;
            numPartsTotal = numParts .* numRepetitions;
            
            str = sprintf('part %d/%d', currentPartTotal, numPartsTotal);
            addendumStr = {};
            
            % Add channel addendum
            if numChannelIter > 1
                addendumStr{end+1} = sprintf('channel %d/%d', ...
                    obj.CurrentChannel, numChannels);
            end
            
            % Add plane addendum
            if numPlanesIter > 1
                addendumStr{end+1} = sprintf('plane %d/%d', ...
                    obj.CurrentPlane, numPlanes);
            end
            
            % Join addendums
            if ~isempty(addendumStr)
                addendumStr{end+1} = ...
                    sprintf('part %d/%d', currentPart, numParts);
            end
            
            % Finalize str output
            if ~isempty(addendumStr)
                addendumStr = strjoin(addendumStr, ', ');
                str = sprintf('%s (%s)', str, addendumStr);
            end
        end
        
    end
    
    methods (Access = private) % Should these methods be part of a data method logger class?
        
        function printInitializationMessage(obj)
        %printInitializationMessage Display message when method starts
        
            if obj.IsSubProcess; return; end

            fprintf(newline); fprintf('---'); fprintf(newline)
            obj.printTask(...
                sprintf('Initializing method "%s" on dataset "%s"', ...
                        class(obj), obj.DataId))
            fprintf(newline)
        end
        
        function displayProcessingSteps(obj)
        %displayProcessingSteps Display the processing steps for process    
            
            if obj.IsSubProcess; return; end
            
            obj.printTask('Processing will happen in %d steps:', obj.NumSteps);
            
            for i = 1:obj.NumSteps
                 obj.printTask('Step %d/%d: %s', i, obj.NumSteps, ...
                     obj.StepDescription{i})
            end
            fprintf('\n')
        end
        
        function printCompletionMessage(obj)
        %printCompletionMessage Display message when method is completed
        
            if obj.IsSubProcess; return; end
            
            obj.printTask(sprintf('Completed method: %s', class(obj)))
            fprintf('---\n')
            fprintf('\n')
        end
        
    end
    
    methods (Static)
        function printTask(varargin)
            msg = sprintf(varargin{:});
            nowstr = datestr(now, 'HH:MM:ss');
            fprintf('%s: %s\n', nowstr, msg)
        end
    end
    
end