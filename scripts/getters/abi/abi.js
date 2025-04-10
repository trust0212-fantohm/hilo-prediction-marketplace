export const abi = [
  {
    inputs: [
      {
        internalType: "uint256",
        name: "_poolId",
        type: "uint256",
      },
    ],
    name: "GetEvaluationResultForPoolId",
    outputs: [
      {
        internalType: "bool",
        name: "processed",
        type: "bool",
      },
      {
        internalType: "bool",
        name: "finalApproval",
        type: "bool",
      },
      {
        internalType: "uint256",
        name: "winningOptionIndex",
        type: "uint256",
      },
      {
        internalType: "uint256[]",
        name: "evaluationVotes",
        type: "uint256[]",
      },
      {
        internalType: "uint256[]",
        name: "disputeVotes",
        type: "uint256[]",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint256",
        name: "_poolId",
        type: "uint256",
      },
    ],
    name: "processPool",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "uint256",
        name: "_poolId",
        type: "uint256",
      },
    ],
    name: "getPoolEvaluationStatus",
    outputs: [
      {
        internalType: "bool",
        name: "evaluationComplete",
        type: "bool",
      },
      {
        internalType: "bool",
        name: "evaluationApproved",
        type: "bool",
      },
      {
        internalType: "uint256",
        name: "approveVotes",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "rejectVotes",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "approveDisputeVotes",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "rejectDisputeVotes",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];
