-- training.mc
-- Functionality for training a Neural Network

include "./accuracy.mc"
include "./network.mc"

-- Common parameters for stochastic gradient descent
type SGDParameters = {
  init_alpha: Float,
  init_lambda: Float,
  decay_alpha: Float,
  decay_lambda: Float,
  batchsize: Int,
  epochs: Int,
  printStatus: Bool,
  evaluateBetweenEpochs: Bool,
  evaluateBeforeFirstEpoch: Bool
}

let nnVanillaSGDParameters: SGDParameters = {
    init_alpha = 0.9,
    init_lambda = 0.01,
    decay_alpha = 0.1,
    decay_lambda = 0.1,
    batchsize = 32,
    epochs = 10,
    printStatus = true,
    evaluateBetweenEpochs = false,
    evaluateBeforeFirstEpoch = false
}

let nnTrainSGD =
  lam params: SGDParameters.
  lam network: NeuralNetwork.
  lam training_data: [DataPoint].
  lam validation_data: [DataPoint].
  -- Determine the number of rounds to try to cover the entire training set
  let rounds =
    divi (addi (length training_data)
               (subi params.batchsize 1))
         params.batchsize
  in
  -- TEMP!
  -- let rounds = 10 in
  (
    if params.printStatus then
      printLn "Starting SGD (stochastic gradient descent)";
      printLn (join [" - training_data size: ", int2string (length training_data)]);
      printLn (join [" - validation_data size: ", int2string (length validation_data)]);
      printLn (join [" - batchsize: ", int2string params.batchsize]);
      printLn (join [" - rounds: ", int2string rounds]);
      printLn (join [" - epochs: ", int2string params.epochs]);
      printLn (join [" - alpha (initial learning rate): ", float2string params.init_alpha]);
      printLn (join [" - alpha decay: ", float2string params.decay_alpha]);
      printLn (join [" - lambda (initial L2 regularization factor): ", float2string params.init_lambda]);
      printLn (join [" - lambda decay: ", float2string params.decay_lambda])
    else ()
  );
  (
    if params.evaluateBeforeFirstEpoch then
      (
        if params.printStatus then
          printLn "evalating performance..."
        else ()
      );
      let accuracy = nnAccuracyProportion params.printStatus network validation_data in
      if params.printStatus then
        printLn (join ["Computed accuracy: ", float2string (mulf accuracy 100.0), "%"])
      else ()
    else ()
  );
  recursive let iterate = lam it. lam alpha. lam lambda.
    if eqi it params.epochs then () else (
      (
        if params.printStatus then
          printLn (join ["[Iteration ", int2string (addi it 1), "/", int2string params.epochs, "]"]);
          printLn (join ["alpha = ", float2string alpha]);
          printLn (join ["lambda = ", float2string lambda])
        else ()
      );
      accelerate (
        seqLoop rounds (lam rnd.
          ( -- print round count (on a single line)
            if params.printStatus then (
              print "."
              --print (join ["\rround ", int2string (addi rnd 1), "/", int2string rounds]);
              --flushStdout ()
            ) else ()
          );

          let start_idx = muli rnd params.batchsize in
          let end_idx = addi start_idx params.batchsize in
          let end_idx = if gti end_idx (length training_data) then (length training_data) else end_idx in
          nnGradientDescentIndexedExn network alpha lambda training_data start_idx end_idx
        )
      );
      printLn "";
      (
        if params.evaluateBetweenEpochs then
          (
            if params.printStatus then
              printLn "evalating performance..."
            else ()
          );
          let accuracy = nnAccuracyProportion params.printStatus network validation_data in
          if params.printStatus then
            printLn (join ["Computed accuracy: ", float2string (mulf accuracy 100.0), "%"])
          else ()
        else ()
      );
      -- prepare for the next iteration
      let decayed_alpha = mulf alpha (subf 1.0 params.decay_alpha) in
      let decayed_lambda = mulf lambda (subf 1.0 params.decay_lambda) in
      iterate (addi it 1) decayed_alpha decayed_lambda
    )
  in
  iterate 0 params.init_alpha params.init_lambda;
  ( -- final printout
    if params.printStatus then
      printLn "SGD complete."
    else ()
  );
  ()
