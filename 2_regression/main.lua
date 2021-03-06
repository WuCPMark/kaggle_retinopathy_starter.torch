require 'cunn'
require 'optim'
paths.dofile('../fbcunn_files/AbstractParallel.lua')
paths.dofile('../fbcunn_files/ModelParallel.lua')
paths.dofile('../fbcunn_files/DataParallel.lua')
paths.dofile('../fbcunn_files/Optim.lua')

opt = {
   epoch=1,
   learningRate = 0.001,
   decay = 0.2,
   weightDecay = 5e-4,
   momentum = 0.0,
   manualSeed = 1,
   nDonkeys = 4,
   nEpochs = 30,
   batchSize = 128,
   GPU = 1,
   nGPU = 4,
   epochSize = 10000,
   model='small', -- models/[name].lua will be loaded
   bestAccuracy = 0,
   retrain='',
   loadSize=64, -- height/width of image to load
   sampleSize=56,-- height/width of image to sample
   dataRoot='../data' -- data in current folder
}
-- one-line argument parser. parses enviroment variables to override the defaults
for k,v in pairs(opt) do opt[k] = tonumber(os.getenv(k)) or os.getenv(k) or opt[k] end
print(opt)

torch.setdefaulttensortype('torch.FloatTensor')
cutorch.setDevice(opt.GPU) -- by default, use GPU 1
torch.manualSeed(opt.manualSeed)
paths.dofile('../data.lua')
utils=paths.dofile('../utils.lua') -- utils.lua in same directory
nClasses = 1 -- you are regressing over 1 variable which can go from 1 to 5

-------------- create model --------------
if opt.retrain ~= '' then -- load model from disk for retraining
   model = torch.load(opt.retrain).model
else
   local config = opt.model
   paths.dofile('../models/' .. config .. '.lua')
   print('=> Creating model from file: models/' .. config .. '.lua')
   model = createModel(opt.nGPU) -- for the model creation code, check the models/ folder
end
criterion = nn.MSECriterion()
print(model)
model:cuda()
criterion:cuda()
collectgarbage()

-- GPU inputs (preallocate)
inputs = torch.CudaTensor()
labels = torch.CudaTensor()
local timer = torch.Timer()
local dataTimer = torch.Timer()
-------------------- training functions ------------------------
function train()
   print("==> Training epoch # " .. opt.epoch)
   correct=0; loss = 0; batchNumber = 0
   model:training()
   local timer = torch.Timer()
   for i=1,opt.epochSize do
      donkeys:addjob(function() return getTrainingMiniBatch(opt.batchSize) end, trainBatch)
   end
   donkeys:synchronize()
   cutorch.synchronize()

   correct = correct * 100 / (opt.batchSize * opt.epochSize)
   loss = loss / opt.epochSize
   train_time = timer:time().real
   train_loss = loss
   train_accuracy = correct
end

function get_correct(outputs, labels)
   outputs=outputs:float():mul(2.0):add(3.0) -- get the outputs in 1,5 scale
   outputs:round()
   outputs[outputs:lt(1)] = 1
   outputs[outputs:gt(5)] = 5
   return outputs:eq(labels):sum()
end

function trainBatch(inputsCPU, labelsCPU)
   local dataLoadingTime = dataTimer:time().real; timer:reset(); -- timers
   batchNumber = batchNumber + 1
   labelsCPU:add(-3.0):div(2.0) -- normalize the labels to [-1.0, 1.0]
   inputs:resize(inputsCPU:size()):copy(inputsCPU)
   labels:resize(labelsCPU:size()):copy(labelsCPU)

   local err, outputs = optimizer:optimize(optim.sgd, inputs, labels, criterion)
   loss = loss + err
   -- unnormalize labels for computing correct
   labelsCPU:mul(2.0):add(3.0)
   correct = correct + get_correct(outputs, labelsCPU)
   print(('Epoch: [%d][%d/%d]\tTime %.3f DataTime %.3f Err %.4f '):format(
         opt.epoch, batchNumber, opt.epochSize, timer:time().real, dataLoadingTime, err))
   cutorch.synchronize(); collectgarbage();
   dataTimer:reset()
end
-------------------- testing functions ------------------------
function test()
   print("==> Validation epoch # " .. opt.epoch)
   correct = 0; loss = 0; batchNumber = 0
   model:evaluate()
   local timer = torch.Timer()
   for i=1,nTest/opt.batchSize do -- nTest is set in data.lua
      local indexStart = (i-1) * opt.batchSize + 1
      local indexEnd = (indexStart + opt.batchSize - 1)
      donkeys:addjob(function() return getValidationData(indexStart, indexEnd) end, testBatch)
   end
   donkeys:synchronize()
   cutorch.synchronize()
   correct = correct * 100 / nTest
   loss = loss / (nTest/opt.batchSize)
   test_loss = loss
   test_time = timer:time().real
   test_accuracy = correct
   return correct
end

function testBatch(inputsCPU, labelsCPU)
   cutorch.synchronize(); collectgarbage();
   batchNumber = batchNumber + opt.batchSize
   inputs:resize(inputsCPU:size()):copy(inputsCPU)
   labels:resize(labelsCPU:size()):copy(labelsCPU)
   local outputs = model:forward(inputs)
   local err = criterion:forward(outputs, labels)
   loss = loss + err
   correct = correct + get_correct(outputs, labelsCPU)
end

-----------------------------------------------------------------------------
optimizer = nn.Optim(model, opt)
while (opt.epoch < opt.nEpochs) do
   train()
   local acc = test()
   if opt.epoch % 4 == 0 then
      -- play around with different types of learning rate decay.
      -- Do you only want to decay at this constant schedule (decay every 4 epochs),
      -- or do you think you can do something slightly smarter.
      opt.learningRate = opt.learningRate * opt.decay
      optimizer = nn.Optim(model, opt)
   end
   if acc > opt.bestAccuracy then
      opt.bestAccuracy = acc
      torch.save('model_' .. opt.epoch .. '.t7',
                 {model=utils.cleanup(model), opt=opt})
   end
   print(string.format('SUMMARY: ' .. 
			  '\t epoch: %d' .. 
			  '\t train_accuracy: %.2f' .. 
			  '\t test_accuracy: %.2f' .. 
			  '\t train_loss: %.2f' .. 
			  '\t test_loss: %.2f' .. 
			  '\t train_time: %d secs' ..
			  '\t test_time: %d secs' .. 
			  '\t best_accuracy: %.2f', 
		       opt.epoch, train_accuracy, test_accuracy, 
		       train_loss, test_loss, 
		       train_time, test_time, opt.bestAccuracy))
   opt.epoch = opt.epoch + 1
end
