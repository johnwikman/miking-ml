-- network.mc
-- Defines generic network behavior.

include "seq.mc"

include "./component.mc"
include "./lossfn.mc"
include "./linalg.mc"

lang NNStandard = NNStandardComponents + NNStandardLossFunctions
end


-- Defines the neural network type
type NeuralNetwork = {
  components: [NeuralNetworkComponent],
  lossfn: NeuralNetworkLossFunction,
  -- State variables, that can be initialized before the accelerate aspect.
  -- These are considered temporary variables that should be removed once the
  -- CUDA/C backend gets better support for allocating new sequences.
  st_weights: [Tensor[Float]],
  st_gradients: [Tensor[Float]],
  st_out_bufs: [Tensor[Float]]
}

-- A data point is a an input followed by the expected output index
type DataPoint = {
  input: Tensor[Float],
  correct_outidx: [Int]
}

-- Validates a neural network. Returns `None ()` if the network is well-formed.
-- Otherwise it returns a list of errors wrapped in an Option.
let nnValidate: NeuralNetwork -> Option [String] =
  lam network.
  use NNStandard in
  let accfinal = foldl (lam acc. lam comp.
    match acc with (idx, maybePrevcomp, errs) in
    -- Check that output dimension from previous component matches the current input dimension
    let errs =
      match maybePrevcomp with Some prevcomp then
        let prevdim = nnComponentDimensions prevcomp in
        let thisdim = nnComponentDimensions comp in
        if not (eqSeq eqi prevdim.outdim thisdim.indim) then
          snoc errs (join [
            "Mismatch in input/output dimensions between components ",
            int2string (subi idx 1), " (", nnComponent2string prevcomp, ") and ",
            int2string idx, " (", nnComponent2string comp, ")"
          ])
        else errs
      else errs
    in
    (addi idx 1, Some comp, errs)
  ) (0, None (), []) network.components in
  match accfinal with (_, _, errlist) in
  let errlist =
    let lossdim = nnLossFunctionDimensions network.lossfn in
    let n_components = length network.components in
    if geqi n_components 0 then
      let lastcomp = get network.components (subi n_components 1) in
      let lastcompdim = nnComponentDimensions lastcomp in
      if not (eqSeq eqi lastcompdim.outdim lossdim.indim) then
        snoc errlist (join [
          "Mismatch in input/output dimensions between final component (",
          nnComponent2string lastcomp,
          ") and loss function (",
          nnLossFunction2string network.lossfn, ")"
        ])
      else errlist
    else errlist
  in
  if gti (length errlist) 0 then
    Some errlist
  else
    None ()


-- Refreshes the state variables prefixed with "st_".
let nnRefreshState: NeuralNetwork -> NeuralNetwork = lam network.
  use NNStandard in
  {{{network with st_weights = foldl (lam acc. lam c. concat acc (nnComponentWeights c)) [] network.components}
             with st_gradients = foldl (lam acc. lam c. concat acc (nnComponentGradients c)) [] network.components}
             with st_out_bufs = map nnComponentOutBuf network.components}


-- Creates a neural network based on the provided list of components and a loss
-- function.
let nnMake: [NeuralNetworkComponent] -> NeuralNetworkLossFunction -> NeuralNetwork =
  lam components. lam lossfn.
  nnRefreshState {
    components = components,
    lossfn = lossfn,
    st_weights = [],
    st_gradients = [],
    st_out_bufs = []
  }


-- Returns a copy of the provided network, with independent tensor but
-- preserved weights. Note that this does not preserve an gradients.
let nnCopy: NeuralNetwork -> NeuralNetwork = lam network.
  use NNStandard in
  nnMake (map nnComponentCopy network.components)
         (nnLossFunctionCopy network.lossfn)


-- Resets all the gradients in the neural network to zero, preparing the
-- network for a batch of new training samples.
let nnZeroGrad: NeuralNetwork -> () = lam network.
  use NNStandard in
  foldl (lam. lam comp. nnComponentZeroGrad comp) () network.components


-- Evaluates the neural network, returning the output vector right before the
-- loss function is computed. This does not compute any gradients.
--  complist is the list of components that make up the neural network
--  input is the Nx1 input vector
-- Returns the output vector.
let nnEvalExn: NeuralNetwork -> Tensor[Float] -> Tensor[Float] =
  lam network. lam input.
  use NNStandard in
  foldl (lam prevout: Tensor[Float]. lam comp: NeuralNetworkComponent.
    -- Applies this component and returns the resulting output to the next
    -- iteration (the final iteration becomes the nnEvalExn output)
    nnComponentApplyExn prevout comp
  ) input network.components


-- Computes the loss on the provided data point when evaluated on the network.
-- This does not compute any gradients.
--  network is the neural network
--  dp is the data point
let nnComputeLossExn: NeuralNetwork -> DataPoint -> Float =
  lam network. lam dp.
  use NNStandard in
  let output = nnEvalExn network dp.input in
  -- Return the evaluated loss
  nnLossFunctionApplyExn output dp.correct_outidx network.lossfn


-- Computes the gradients for the components with respect to the loss function,
-- incrementing the values that are already there. Invoke this many times on
-- the different inputs to sum over all the gradients, in order to perform
-- batch normalization in a training step.
--  network is the network to train on
--  dp is the datapoint to backpropagate on
--
-- NOTE: If this is the first time computing gradients in this step, remember
--       to run `nnZeroGrad <network>` to clear the previous gradients.
let nnBackpropExn: NeuralNetwork -> DataPoint -> () =
  lam network. lam dp.
  use NNStandard in
  -- Step 1: Evaluate the network to populate the outputs at each step,
  --         necessary for computing the gradients at each component.
  let outputs = nnEvalExn network dp.input in
  -- Step 2: Compute gradient with respect to the loss function
  let lossgrad = nnLossFunctionBackpropExn outputs dp.correct_outidx network.lossfn in
  -- Step 3: Propagate the gradients backwards
  -- (pair the components with the evaluated inputs to each of those components)
  let n_components = length network.components in
  if eqi n_components 0 then ()
  else if eqi n_components 1 then (
    -- Special case: last component is the only component (in_buf = dp.input)
    let lastcomp = get network.components (subi n_components 1) in
    let lastcomp_in_buf = dp.input in
    let lastcomp_out_grad = lossgrad in
    nnComponentBackpropExn lastcomp_in_buf lastcomp_out_grad lastcomp;
    ()
  ) else (
    -- At least 2 components...
    -- Last component, special case on output gradient
    let lastcomp = get network.components (subi n_components 1) in
    let lastcomp_in_buf = get network.st_out_bufs (subi n_components 2) in
    let lastcomp_out_grad = lossgrad in
    let lastcomp_in_grad = nnComponentBackpropExn lastcomp_in_buf lastcomp_out_grad lastcomp in

    -- Middle components, iterate over all component not at the start or at the end
    let firstcomp_out_grad = seqLoopFoldl lastcomp_in_grad (subi n_components 2) (lam out_grad. lam i.
      -- Iterate in backwards order, skipping over the last element. i is in the range [0, |components| - 2)
      -- compidx = (|components| - 1) - (i+1) = |components| - (i+2)
      let compidx = (subi n_components (addi i 2)) in
      let comp = get network.components compidx in
      let comp_in_buf = get network.st_out_bufs (subi compidx 1) in
      let comp_out_grad = out_grad in
      -- output gradient is fed
      nnComponentBackpropExn comp_in_buf comp_out_grad comp
    ) in

    -- First component, special case on input buffer
    let firstcomp = get network.components 0 in
    let firstcomp_in_buf = dp.input in
    nnComponentBackpropExn firstcomp_in_buf firstcomp_out_grad firstcomp;
    ()
  )


-- Trains the network on the provided batch of data points, performing gradient
-- descent on the batch normalized output
--  network is the NN to train on
--  alpha is the learning rate
--  lambda is the regularization factor for fully connected layers, should be
--         in the range [0,1], where a value of 0.0 represents no
--         regularization
--  batch is the list of data points to train on, applies mini-batch
let nnGradientDescentExn: NeuralNetwork -> Float -> Float -> [DataPoint] -> () =
  lam network. lam alpha. lam lambda. lam batch.
  use NNStandard in
   -- zero out the gradients
  nnZeroGrad network;
  -- backpropagate over the data points
  foldl (lam. lam dp: DataPoint.
    nnBackpropExn network dp
  ) () batch;
  -- apply the mini-batch normalization ( grad = sum(grad) / |B| )
  let batchsize_normalizer = divf 1.0 (int2float (length batch)) in
  foldl (lam. lam grad.
    #var"tensorOpExn: z *= scalar(c)" batchsize_normalizer grad
  ) () network.st_gradients;
  -- apply any weight regularization
  (
    if eqf lambda 0.0 then () -- no regularization to do...
    else (
      seqLoopFoldl () (length network.st_weights) (lam. lam i: Int.
        let w = get network.st_weights i in
        let grad = get network.st_gradients i in
        #var"tensorOpExn: z += x * scalar(c)" w (mulf 2.0 lambda) grad
      )
    )
  );
  -- apply the gradient descent step (i.e. theta := theta - alpha*theta_grad)
  seqLoopFoldl () (length network.st_weights) (lam. lam i: Int.
    let w = get network.st_weights i in
    let grad = get network.st_gradients i in
    #var"tensorOpExn: z += x * scalar(c)" grad (negf alpha) w
  )

